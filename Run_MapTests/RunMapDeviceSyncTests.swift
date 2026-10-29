import Foundation
import Network
import XCTest
@testable import Run_Map

final class RunMapDeviceSyncTests: XCTestCase {
    func testEncryptedChunkedRoundTrip() {
        let secret = Data(repeating: 42, count: 16)
        let host = RunMapSyncTransport(secret: secret, isHost: true)
        let client = RunMapSyncTransport(secret: secret, isHost: false)
        let received = expectation(description: "Encrypted payload echoed")
        let payload = Data(repeating: 0x61, count: 200_000)
        host.onListening = { port in client.connect(to: .hostPort(host: .ipv4(.loopback), port: port)) }
        client.onReady = { id in client.send(payload, to: id) }
        host.onMessage = { [weak host] id, data in
            XCTAssertEqual(data, payload)
            host?.send(data, to: id)
        }
        client.onMessage = { _, data in
            XCTAssertEqual(data, payload)
            received.fulfill()
        }
        defer { host.stop(); client.stop() }
        client.start(advertise: false)
        host.start(advertise: false)
        wait(for: [received], timeout: 15)
    }

    func testIncorrectPairingKeyIsRejected() {
        let host = RunMapSyncTransport(secret: Data(repeating: 1, count: 16), isHost: true)
        let client = RunMapSyncTransport(secret: Data(repeating: 2, count: 16), isHost: false)
        let rejected = expectation(description: "Wrong key connection rejected")
        client.onReady = { _ in XCTFail("A device with the wrong pairing key connected") }
        client.onDisconnected = { _ in rejected.fulfill() }
        host.onListening = { port in client.connect(to: .hostPort(host: .ipv4(.loopback), port: port)) }
        defer { host.stop(); client.stop() }
        client.start(advertise: false)
        host.start(advertise: false)
        wait(for: [rejected], timeout: 15)
    }

    func testOversizedFrameIsRejectedBeforeAllocatingPayload() {
        let secret = Data(repeating: 3, count: 16)
        let host = RunMapSyncTransport(secret: secret, isHost: true)
        let rejected = expectation(description: "Oversized frame rejected")
        var connection: NWConnection?
        host.onMessage = { _, _ in XCTFail("An oversized frame was accepted") }
        host.onDisconnected = { _ in rejected.fulfill() }
        host.onListening = { port in
            let client = NWConnection(to: .hostPort(host: .ipv4(.loopback), port: port),
                                      using: RunMapSyncTransport.parameters(secret: secret))
            connection = client
            client.stateUpdateHandler = { state in
                if case .ready = state {
                    client.send(content: Data([0xff, 0xff, 0xff, 0xff]), completion: .contentProcessed { _ in })
                }
            }
            client.start(queue: DispatchQueue(label: "explore.sync.test.client"))
        }
        defer { host.stop(); connection?.cancel() }
        host.start(advertise: false)
        wait(for: [rejected], timeout: 15)
    }

    func testPairingCodeRoundTripAndValidation() throws {
        let key = Data(0..<16)
        let code = RunMapSyncCredentials.code(for: key)
        XCTAssertEqual(try RunMapSyncCredentials.secret(from: code.lowercased()), key)
        XCTAssertThrowsError(try RunMapSyncCredentials.secret(from: "1234"))
        XCTAssertThrowsError(try RunMapSyncCredentials.secret(from: String(repeating: "Z", count: 32)))
    }

    func testDeletedSavedPlanDoesNotReturnAfterResync() throws {
        let name = "RunMapSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let plan = SavedRoutePlan(title: "Weekend", createdAt: Date(), coordinates: [])
        let key = "plan:\(plan.id.uuidString)"
        let original = RunMapSyncedPreference(modifiedAt: Date(timeIntervalSince1970: 100), data: try JSONEncoder().encode(plan))
        let deleted = RunMapSyncedPreference(modifiedAt: Date(timeIntervalSince1970: 101), data: nil)
        try RunMapSyncedPreferences.merge([key: original], defaults: defaults)
        try RunMapSyncedPreferences.merge([key: deleted], defaults: defaults)
        try RunMapSyncedPreferences.merge([key: original], defaults: defaults)
        let data = try XCTUnwrap(defaults.data(forKey: "routePlanner.savedPlans.v1"))
        XCTAssertTrue(try JSONDecoder().decode([SavedRoutePlan].self, from: data).isEmpty)
    }

    func testNewerGoalEditWinsOnBothDevices() throws {
        let phoneName = "RunMapSyncTests.phone.\(UUID().uuidString)"
        let macName = "RunMapSyncTests.mac.\(UUID().uuidString)"
        let phone = UserDefaults(suiteName: phoneName)!
        let mac = UserDefaults(suiteName: macName)!
        defer {
            phone.removePersistentDomain(forName: phoneName)
            mac.removePersistentDomain(forName: macName)
        }
        let oldGoals = MonthlyGoals(distanceKm: 50)
        let newGoals = MonthlyGoals(distanceKm: 100)
        let old = RunMapSyncedPreference(modifiedAt: Date(timeIntervalSince1970: 100), data: try JSONEncoder().encode(oldGoals))
        let new = RunMapSyncedPreference(modifiedAt: Date(timeIntervalSince1970: 101), data: try JSONEncoder().encode(newGoals))
        for defaults in [phone, mac] {
            try RunMapSyncedPreferences.merge(["monthlyGoals.v1": old], defaults: defaults)
            try RunMapSyncedPreferences.merge(["monthlyGoals.v1": new], defaults: defaults)
            try RunMapSyncedPreferences.merge(["monthlyGoals.v1": old], defaults: defaults)
            let restored = try JSONDecoder().decode(MonthlyGoals.self, from: XCTUnwrap(defaults.data(forKey: "monthlyGoals.v1")))
            XCTAssertEqual(restored, newGoals)
        }
    }
}
