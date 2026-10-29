import CryptoKit
import Foundation
import Network
import Security

final class RunMapSyncTransport {
    static let serviceType = "_explore-sync._tcp"
    static let maximumMessageSize = 256 * 1_024 * 1_024

    enum Status {
        case waiting
        case connected
        case failed(String)
    }

    var onStatus: ((Status) -> Void)?
    var onReady: ((UUID) -> Void)?
    var onDisconnected: ((UUID) -> Void)?
    var onMessage: ((UUID, Data) -> Void)?
    var onListening: ((NWEndpoint.Port) -> Void)?

    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var ready = false
        var sending = false
        var pending: [Data] = []
        var incoming = Data()

        init(connection: NWConnection) { self.connection = connection }
    }

    private let secret: Data
    private let isHost: Bool
    private let queue = DispatchQueue(label: "explore.device-sync.network")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [UUID: Peer] = [:]
    private var endpoints: [NWEndpoint] = []
    private var running = false

    init(secret: Data, isHost: Bool) {
        self.secret = secret
        self.isHost = isHost
    }

    private var serviceName: String {
        "Explore-" + SHA256.hash(data: secret).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func parameters(secret: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data("ExploreDeviceSync-v1".utf8)
        let keyData = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identityData as __DispatchData)
        // An exclusive PSK cipher authenticates both devices without accepting an
        // unverified certificate or allowing a plaintext/certificate fallback.
        let cipher = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, cipher)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    func start(advertise: Bool = true) {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.onStatus?(.waiting)
            if self.isHost { self.listen(advertise: advertise) }
            else if advertise { self.browse() }
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.browser?.cancel()
            self.browser = nil
            self.listener?.cancel()
            self.listener = nil
            let connections = self.peers.values.map(\.connection)
            self.peers.removeAll()
            connections.forEach { $0.cancel() }
            self.endpoints.removeAll()
        }
    }

    private func listen(advertise: Bool) {
        do {
            let listener = try NWListener(using: Self.parameters(secret: secret))
            self.listener = listener
            if advertise { listener.service = NWListener.Service(name: serviceName, type: Self.serviceType) }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.running, self.peers.count < 4 else { connection.cancel(); return }
                self.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.running else { return }
                switch state {
                case .ready:
                    if let port = listener?.port { self.onListening?(port) }
                case .failed:
                    self.onStatus?(.failed("Device sync could not start. Check Local Network access."))
                default: break
                }
            }
            listener.start(queue: queue)
        } catch {
            onStatus?(.failed("Device sync could not start. Try again."))
        }
    }

    private func browse() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.running else { return }
            self.endpoints = results.compactMap { result in
                if case .service(let name, _, _, _) = result.endpoint, name == self.serviceName {
                    return result.endpoint
                }
                return nil
            }.sorted { String(describing: $0) < String(describing: $1) }
            self.connectToDiscoveredMac()
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .waiting:
                self?.onStatus?(.failed("Looking for your Mac. Check Local Network access on both devices."))
            default: break
            }
        }
        browser.start(queue: queue)
    }

    private func connectToDiscoveredMac() {
        guard running, peers.isEmpty, let endpoint = endpoints.first else { return }
        accept(NWConnection(to: endpoint, using: Self.parameters(secret: secret)))
    }

    func connect(to endpoint: NWEndpoint) {
        queue.async {
            guard self.running else { return }
            self.accept(NWConnection(to: endpoint, using: Self.parameters(secret: self.secret)))
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection)
        peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer, self.peers[peer.id] != nil else { return }
            switch state {
            case .ready:
                guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                      sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue == UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256) else {
                    self.remove(peer)
                    return
                }
                peer.ready = true
                self.onStatus?(.connected)
                self.receiveHeader(peer)
                self.onReady?(peer.id)
            case .failed, .cancelled, .waiting:
                self.remove(peer)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak peer] in
            guard let self, let peer, !peer.ready else { return }
            self.remove(peer)
        }
    }

    private func remove(_ peer: Peer) {
        guard peers.removeValue(forKey: peer.id) != nil else { return }
        peer.connection.cancel()
        onDisconnected?(peer.id)
        if peers.values.contains(where: \.ready) { onStatus?(.connected) }
        else { onStatus?(.waiting) }
        if running && !isHost {
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connectToDiscoveredMac() }
        }
    }

    func send(_ data: Data, to id: UUID? = nil) {
        queue.async {
            guard !data.isEmpty, data.count <= Self.maximumMessageSize else {
                self.onStatus?(.failed("The workout history is too large to sync in one transfer."))
                return
            }
            for peer in self.peers.values where peer.ready && (id == nil || id == peer.id) {
                if peer.sending {
                    if peer.pending.count < 4 { peer.pending.append(data) }
                    else { peer.pending[peer.pending.count - 1] = data }
                } else { self.sendFrame(data, to: peer) }
            }
        }
    }

    private func sendFrame(_ data: Data, to peer: Peer) {
        peer.sending = true
        var length = UInt32(data.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        peer.connection.send(content: header, completion: .contentProcessed { [weak self, weak peer] error in
            guard let self, let peer else { return }
            if error != nil { self.remove(peer); return }
            self.sendChunk(data, offset: 0, to: peer)
        })
    }

    private func sendChunk(_ data: Data, offset: Int, to peer: Peer) {
        guard peers[peer.id] != nil else { return }
        guard offset < data.count else {
            peer.sending = false
            if !peer.pending.isEmpty { sendFrame(peer.pending.removeFirst(), to: peer) }
            return
        }
        let end = min(offset + 64 * 1_024, data.count)
        peer.connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self, weak peer] error in
            guard let self, let peer else { return }
            if error != nil { self.remove(peer); return }
            self.sendChunk(data, offset: end, to: peer)
        })
    }

    private func receiveHeader(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer else { return }
            guard error == nil, let data, data.count == 4 else { self.remove(peer); return }
            let length = data.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumMessageSize else { self.remove(peer); return }
            peer.incoming = Data()
            self.receiveBody(peer, remaining: length)
        }
    }

    private func receiveBody(_ peer: Peer, remaining: Int) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 64 * 1_024)) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer else { return }
            guard error == nil, let data, !data.isEmpty, data.count <= remaining else { self.remove(peer); return }
            peer.incoming.append(data)
            let left = remaining - data.count
            if left == 0 {
                let message = peer.incoming
                peer.incoming = Data()
                self.onMessage?(peer.id, message)
                self.receiveHeader(peer)
            } else if complete { self.remove(peer) }
            else { self.receiveBody(peer, remaining: left) }
        }
    }
}
