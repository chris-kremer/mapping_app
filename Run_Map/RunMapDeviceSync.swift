import Combine
import CryptoKit
import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    static let runMapRouteArchiveDidChange = Notification.Name("runMapRouteArchiveDidChange")
    static let runMapDeviceSyncDidImport = Notification.Name("runMapDeviceSyncDidImport")
}

enum RunMapRuntime {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return isMac ? ProcessInfo.processInfo.hostName : UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}

enum RunMapSyncCredentials {
    enum CredentialError: LocalizedError {
        case invalidCode
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidCode: return "Enter the complete pairing code shown on your Mac."
            case .keychain: return "The pairing key could not be saved securely. Try again after unlocking this device."
            }
        }
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.chris.RunMap") + ".deviceSync",
         kSecAttrAccount as String: "paired-device-key"]
    }

    static func load() throws -> Data? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 16 else {
            throw CredentialError.keychain(status)
        }
        return data
    }

    static func generate() throws -> Data {
        var data = Data(count: 16)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return data
    }

    static func save(_ data: Data) throws {
        guard data.count == 16 else { throw CredentialError.invalidCode }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    static func code(for secret: Data) -> String {
        let hex = secret.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    static func secret(from code: String) throws -> Data {
        let text = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard text.count == 32, text.allSatisfy({ "0123456789ABCDEF".contains($0) }) else {
            throw CredentialError.invalidCode
        }
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw CredentialError.invalidCode }
            data.append(byte)
            index = next
        }
        return data
    }
}

struct RunMapSyncMessage: Codable {
    enum Kind: String, Codable { case hello, backup, acknowledgement, failure }
    let version: Int
    let kind: Kind
    var deviceName: String?
    var backup: RunMapExperienceBackup?
    var fingerprint: String?
    var error: String?

    init(_ kind: Kind) { version = 1; self.kind = kind }

    func validatedBackup() throws -> (RunMapExperienceBackup, String) {
        guard version == 1 else { throw RunMapExperienceBackup.BackupError.unsupportedVersion }
        guard kind == .backup, let backup, let fingerprint,
              fingerprint.count == 64,
              fingerprint.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RunMapExperienceBackup.BackupError.invalidData
        }
        try backup.validate()
        // TLS authenticates the payload. The sender's fingerprint is a receipt
        // token, not a cross-OS JSON encoding comparison (Foundation can differ).
        return (backup, fingerprint)
    }
}

final class RunMapDeviceSync: ObservableObject {
    static let shared = RunMapDeviceSync()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isPaired: Bool
    @Published private(set) var isConnected = false
    @Published private(set) var status = "Not paired"
    @Published private(set) var peerName: String?
    @Published private(set) var lastSyncedAt: Date?
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let worker = DispatchQueue(label: "explore.device-sync.archive", qos: .utility)
    private var transport: RunMapSyncTransport?
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastSent: [UUID: (fingerprint: String, date: Date)] = [:]
    private var acknowledged: [UUID: String] = [:]
    private var connectedIDs = Set<UUID>()
    private var activeTransportID: ObjectIdentifier?
    private var cachedMessage: (revision: String, preferences: Data, fingerprint: String, data: Data)?

    private init() {
        isEnabled = defaults.bool(forKey: "deviceSync.enabled")
        isPaired = (try? RunMapSyncCredentials.load()) != nil
        peerName = defaults.string(forKey: "deviceSync.peerName")
        lastSyncedAt = defaults.object(forKey: "deviceSync.lastSyncedAt") as? Date
        if isPaired { status = isEnabled ? "Waiting for paired device" : "Sync paused" }

        Publishers.Merge(
            NotificationCenter.default.publisher(for: .runMapRouteArchiveDidChange),
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        )
        .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.captureAndSend() }
        .store(in: &subscriptions)
    }

    func enableOnMac() -> String? {
        do {
            let key = try RunMapSyncCredentials.load() ?? RunMapSyncCredentials.generate()
            try RunMapSyncCredentials.save(key)
            isPaired = true
            setEnabled(true)
            return RunMapSyncCredentials.code(for: key)
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func pair(with code: String) {
        do {
            let secret = try RunMapSyncCredentials.secret(from: code)
            try RunMapSyncCredentials.save(secret)
            stop()
            isPaired = true
            setEnabled(true)
        } catch { errorMessage = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || isPaired else {
            errorMessage = "Pair this device with your Mac first."
            return
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: "deviceSync.enabled")
        if enabled { startIfEnabled() }
        else { stop(); status = "Sync paused" }
    }

    func forgetPairing() {
        do {
            try RunMapSyncCredentials.remove()
            setEnabled(false)
            isPaired = false
            peerName = nil
            lastSyncedAt = nil
            defaults.removeObject(forKey: "deviceSync.peerName")
            defaults.removeObject(forKey: "deviceSync.lastSyncedAt")
            status = "Not paired"
        } catch { errorMessage = error.localizedDescription }
    }

    func startIfEnabled() {
        guard isEnabled, transport == nil else { return }
        do {
            guard let key = try RunMapSyncCredentials.load() else {
                isPaired = false
                setEnabled(false)
                return
            }
            let transport = RunMapSyncTransport(secret: key, isHost: RunMapRuntime.isMac)
            self.transport = transport
            worker.async { self.activeTransportID = ObjectIdentifier(transport) }
            transport.onStatus = { [weak self, weak transport] status in
                DispatchQueue.main.async {
                    guard let self, self.transport === transport else { return }
                    switch status {
                    case .connected:
                        self.isConnected = true
                        self.status = "Connected securely"
                    case .waiting:
                        self.isConnected = false
                        self.status = RunMapRuntime.isMac ? "Waiting for paired iPhone" : "Looking for paired Mac"
                    case .failed(let message):
                        self.isConnected = false
                        self.status = message
                    }
                }
            }
            transport.onReady = { [weak self, weak transport] id in
                DispatchQueue.main.async {
                    guard let self, let transport, self.transport === transport else { return }
                    self.worker.async { self.connectedIDs.insert(id) }
                    var hello = RunMapSyncMessage(.hello)
                    hello.deviceName = RunMapRuntime.deviceName
                    if let data = try? JSONEncoder().encode(hello) { transport.send(data, to: id) }
                    self.captureAndSend(to: id, force: true)
                }
            }
            transport.onMessage = { [weak self, weak transport] id, data in
                guard let self, let transport else { return }
                self.worker.async { self.receive(data, from: id, transport: transport) }
            }
            transport.onDisconnected = { [weak self] id in
                self?.worker.async {
                    self?.connectedIDs.remove(id)
                    self?.lastSent.removeValue(forKey: id)
                    self?.acknowledged.removeValue(forKey: id)
                }
            }
            transport.start()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.captureAndSend()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func sceneBecameActive() {
        if !isConnected { stop() }
        startIfEnabled()
    }

    func sceneEnteredBackground() {
        guard !RunMapRuntime.isMac else { return }
        stop()
        if isEnabled { status = "Sync resumes when Explore! opens" }
    }

    func syncNow() {
        if !isConnected { stop(); startIfEnabled() }
        else { captureAndSend(force: true) }
    }

    func preferencesDidChange() {
        _ = try? RunMapSyncedPreferences.capture(defaults: defaults)
        captureAndSend()
    }

    private func stop() {
        transport?.stop()
        transport = nil
        timer?.invalidate()
        timer = nil
        isConnected = false
        worker.async {
            self.activeTransportID = nil
            self.lastSent.removeAll()
            self.acknowledged.removeAll()
            self.connectedIDs.removeAll()
            self.cachedMessage = nil
        }
    }

    private func captureAndSend(to id: UUID? = nil, force: Bool = false) {
        guard isEnabled, let transport, isConnected || id != nil else { return }
        worker.async {
            guard self.activeTransportID == ObjectIdentifier(transport) else { return }
            do {
                let revision = RouteStorage.shared.archiveRevision()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var preferenceData = try encoder.encode(RunMapSyncedPreferences.capture(defaults: self.defaults))
                if let achievementData = self.defaults.data(forKey: "unlockedAchievements") {
                    let achievements = try JSONDecoder().decode([String: AchievementsManager.AchievementSaveData].self, from: achievementData)
                    preferenceData.append(try encoder.encode(achievements))
                }
                let preferenceHash = Data(SHA256.hash(data: preferenceData))
                let cached = self.cachedMessage
                if cached?.revision != revision || cached?.preferences != preferenceHash {
                    let backup = try RunMapExperienceBackup(routes: RouteStorage.shared.loadRoutes())
                    let fingerprint = try backup.fingerprint()
                    var message = RunMapSyncMessage(.backup)
                    message.backup = backup
                    message.fingerprint = fingerprint
                    self.cachedMessage = (revision, preferenceHash, fingerprint, try encoder.encode(message))
                }
                guard let message = self.cachedMessage else { return }
                let fingerprint = message.fingerprint
                let ids = id.map { Set([$0]) } ?? self.connectedIDs
                let targets = ids.filter { peer in
                    if !force, self.acknowledged[peer] == fingerprint { return false }
                    guard !force, let sent = self.lastSent[peer] else { return true }
                    return sent.fingerprint != fingerprint || Date().timeIntervalSince(sent.date) > 60
                }
                guard !targets.isEmpty else { return }
                for peer in targets {
                    transport.send(message.data, to: peer)
                    self.lastSent[peer] = (fingerprint, Date())
                }
            } catch { self.report(error, for: transport) }
        }
    }

    private func receive(_ data: Data, from id: UUID, transport: RunMapSyncTransport) {
        guard activeTransportID == ObjectIdentifier(transport) else { return }
        do {
            let message = try JSONDecoder().decode(RunMapSyncMessage.self, from: data)
            guard message.version == 1 else { throw RunMapExperienceBackup.BackupError.unsupportedVersion }
            switch message.kind {
            case .hello:
                let name = String((message.deviceName ?? "Paired device").prefix(80))
                DispatchQueue.main.async {
                    guard self.transport === transport else { return }
                    self.peerName = name
                    self.defaults.set(name, forKey: "deviceSync.peerName")
                }
            case .backup:
                let (backup, fingerprint) = try message.validatedBackup()
                _ = try RouteStorage.shared.mergeSyncedRoutes(backup.routes.map { $0.toRoute() })
                try backup.restorePreferences(synchronizing: true)
                var acknowledgement = RunMapSyncMessage(.acknowledgement)
                acknowledgement.fingerprint = fingerprint
                transport.send(try JSONEncoder().encode(acknowledgement), to: id)
                self.markSynced(for: transport, imported: true)
            case .acknowledgement:
                guard let fingerprint = message.fingerprint, self.lastSent[id]?.fingerprint == fingerprint else { return }
                self.acknowledged[id] = fingerprint
                self.markSynced(for: transport, imported: false)
            case .failure:
                throw NSError(domain: "ExploreDeviceSync", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String((message.error ?? "The paired device could not save this transfer.").prefix(300))])
            }
        } catch {
            if let message = try? JSONDecoder().decode(RunMapSyncMessage.self, from: data), message.kind != .failure {
                var failure = RunMapSyncMessage(.failure)
                failure.error = error.localizedDescription
                if let encoded = try? JSONEncoder().encode(failure) { transport.send(encoded, to: id) }
            }
            report(error, for: transport)
        }
    }

    private func markSynced(for transport: RunMapSyncTransport, imported: Bool) {
        DispatchQueue.main.async {
            guard self.transport === transport else { return }
            self.lastSyncedAt = Date()
            self.defaults.set(self.lastSyncedAt, forKey: "deviceSync.lastSyncedAt")
            self.status = "Up to date"
            if imported {
                NotificationCenter.default.post(name: .runMapDeviceSyncDidImport, object: nil)
            }
        }
    }

    private func report(_ error: Error, for transport: RunMapSyncTransport) {
        DispatchQueue.main.async {
            guard self.transport === transport else { return }
            self.status = "Sync needs attention"
            self.errorMessage = error.localizedDescription
        }
    }
}
