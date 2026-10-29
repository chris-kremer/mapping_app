import CoreLocation
import Foundation
import HealthKit
import Testing
@testable import Run_Map

struct RunMapExperienceBackupTests {
    private func defaults() -> (String, UserDefaults) {
        let name = "RunMapExperienceBackupTests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func route() -> Route {
        Route(
            coordinates: [
                CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
                CLLocationCoordinate2D(latitude: 52.521, longitude: 13.406)
            ],
            date: Date(timeIntervalSince1970: 1_750_000_000),
            workoutType: .walking,
            durationSec: 300,
            sourceWorkoutID: UUID(),
            sourceRouteID: UUID()
        )
    }

    @Test func roundTripPreservesWorkoutsAndPersonalState() throws {
        let (sourceName, source) = defaults()
        let (targetName, target) = defaults()
        defer {
            source.removePersistentDomain(forName: sourceName)
            target.removePersistentDomain(forName: targetName)
        }
        let workout = route()
        let unlockDate = Date(timeIntervalSince1970: 1_740_000_000)
        let achievements = ["distance": AchievementsManager.AchievementSaveData(tier: "Gold", date: unlockDate)]
        let goals = MonthlyGoals(distanceKm: 120, newStreetCount: 20, newDistrictCount: 2)
        let plan = SavedRoutePlan(title: "Weekend", createdAt: unlockDate, coordinates: workout.coordinates)
        source.set(try JSONEncoder().encode(achievements), forKey: "unlockedAchievements")
        source.set(try JSONEncoder().encode(goals), forKey: "monthlyGoals.v1")
        source.set(try JSONEncoder().encode([plan]), forKey: "routePlanner.savedPlans.v1")
        source.set(1, forKey: "mapType")

        let backup = try RunMapExperienceBackup(routes: [workout], defaults: source)
        let restored = try JSONDecoder().decode(RunMapExperienceBackup.self, from: JSONEncoder().encode(backup))
        try restored.restorePreferences(defaults: target)
        let restoredWorkout = try #require(restored.routes.first).toRoute()
        #expect(restoredWorkout.id == workout.id)
        #expect(restoredWorkout.sourceWorkoutID == workout.sourceWorkoutID)
        #expect(restoredWorkout.sourceRouteID == workout.sourceRouteID)
        #expect(restoredWorkout.date == workout.date)
        #expect(restoredWorkout.durationSec == workout.durationSec)
        #expect(restoredWorkout.distanceKm == workout.distanceKm)
        #expect(restored.achievements["distance"]?.date == unlockDate)
        #expect(try JSONDecoder().decode(MonthlyGoals.self, from: #require(target.data(forKey: "monthlyGoals.v1"))) == goals)
        let restoredPlans = try JSONDecoder().decode([SavedRoutePlan].self, from: #require(target.data(forKey: "routePlanner.savedPlans.v1")))
        #expect(restoredPlans.map(\.id) == [plan.id])
        #expect(restoredPlans.first?.title == "Weekend")
        #expect(target.integer(forKey: "mapType") == 1)
    }

    @Test func repeatedRestorePreservesLocalPlansAndHigherAchievementTiers() throws {
        let (sourceName, source) = defaults()
        let (targetName, target) = defaults()
        defer {
            source.removePersistentDomain(forName: sourceName)
            target.removePersistentDomain(forName: targetName)
        }
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let later = early.addingTimeInterval(100)
        let workout = route()
        let localPlan = SavedRoutePlan(title: "Mac plan", createdAt: early, coordinates: workout.coordinates)
        let phonePlan = SavedRoutePlan(title: "Phone plan", createdAt: later, coordinates: workout.coordinates)
        source.set(try JSONEncoder().encode([phonePlan]), forKey: "routePlanner.savedPlans.v1")
        target.set(try JSONEncoder().encode([localPlan]), forKey: "routePlanner.savedPlans.v1")
        source.set(try JSONEncoder().encode(["distance": AchievementsManager.AchievementSaveData(tier: "Bronze", date: early)]), forKey: "unlockedAchievements")
        target.set(try JSONEncoder().encode(["distance": AchievementsManager.AchievementSaveData(tier: "Gold", date: later)]), forKey: "unlockedAchievements")

        let backup = try RunMapExperienceBackup(routes: [workout], defaults: source)
        try backup.restorePreferences(defaults: target)
        try backup.restorePreferences(defaults: target)

        let plans = try JSONDecoder().decode([SavedRoutePlan].self, from: #require(target.data(forKey: "routePlanner.savedPlans.v1")))
        let achievements = try JSONDecoder().decode([String: AchievementsManager.AchievementSaveData].self, from: #require(target.data(forKey: "unlockedAchievements")))
        #expect(plans.map(\.id) == [phonePlan.id, localPlan.id])
        #expect(achievements["distance"]?.tier == "Gold")
        #expect(achievements["distance"]?.date == early)
    }

    @Test func futureBackupVersionDoesNotChangePreferences() throws {
        let (name, target) = defaults()
        defer { target.removePersistentDomain(forName: name) }
        target.set(2, forKey: "mapType")
        let data = try JSONEncoder().encode(RunMapExperienceBackup(routes: [route()], defaults: target))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        object["mapType"] = 1
        let future = try JSONDecoder().decode(RunMapExperienceBackup.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(throws: RunMapExperienceBackup.BackupError.self) {
            try future.restorePreferences(defaults: target)
        }
        #expect(target.integer(forKey: "mapType") == 2)
        #expect(target.data(forKey: "unlockedAchievements") == nil)
    }

    @Test func legacyRouteExportsStillImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = RouteStorage(directoryURL: directory)
        let workout = route()
        let file = directory.appendingPathComponent("Explore_routes.json")
        try storage.exportData(for: [workout]).write(to: file)

        let imported = try storage.importExperience(from: file)
        #expect(imported.backup == nil)
        #expect(imported.routes.map(\.id) == [workout.id])
    }

    @Test func invalidCoordinatesAreRejected() throws {
        let (name, source) = defaults()
        defer { source.removePersistentDomain(forName: name) }
        let invalid = Route(
            coordinates: [
                CLLocationCoordinate2D(latitude: 100, longitude: 13),
                CLLocationCoordinate2D(latitude: 101, longitude: 13)
            ],
            date: Date(), workoutType: .walking, durationSec: 10
        )
        #expect(throws: RunMapExperienceBackup.BackupError.self) {
            try RunMapExperienceBackup(routes: [invalid], defaults: source)
        }
    }

    @Test func syncingLongRoutesPreservesTraceAndDistance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinates = (0..<1_201).map { index in
            CLLocationCoordinate2D(latitude: 52.52 + (index.isMultiple(of: 2) ? 0 : 0.00001),
                                   longitude: 13.405 + Double(index) * 0.00001)
        }
        let workout = Route(coordinates: coordinates, date: Date(), workoutType: .walking,
                            durationSec: 1_200, sourceWorkoutID: UUID(), sourceRouteID: UUID())
        let storage = RouteStorage(directoryURL: directory)
        storage.saveRoutes([workout])
        let firstLoad = try #require(storage.loadRoutes().first)
        #expect(firstLoad.coordinates.count == coordinates.count)
        #expect(abs(firstLoad.distanceKm - workout.distanceKm) < 0.000001)

        _ = try storage.mergeSyncedRoutes([firstLoad])
        let afterSync = storage.loadRoutes()
        #expect(afterSync.count == 1)
        #expect(afterSync.first?.coordinates.count == coordinates.count)
        #expect(afterSync.first?.sourceRouteID == workout.sourceRouteID)
        #expect(abs(try #require(afterSync.first).distanceKm - workout.distanceKm) < 0.000001)
    }

    @Test func authenticatedWireReceiptsDoNotRequireIdenticalFoundationJSONEncoding() throws {
        let (name, source) = defaults()
        defer { source.removePersistentDomain(forName: name) }
        var message = RunMapSyncMessage(.backup)
        message.backup = try RunMapExperienceBackup(routes: [route()], defaults: source)
        let senderReceipt = String(repeating: "a", count: 64)
        message.fingerprint = senderReceipt
        let decoded = try JSONDecoder().decode(RunMapSyncMessage.self, from: JSONEncoder().encode(message))
        let (_, receipt) = try decoded.validatedBackup()
        #expect(receipt == senderReceipt)

        message.fingerprint = "invalid"
        #expect(throws: RunMapExperienceBackup.BackupError.self) { try message.validatedBackup() }
    }
}
