import CryptoKit
import Foundation

struct RunMapExperienceBackup: Codable {
    static let formatName = "explore-experience"
    static let currentVersion = 1

    let format: String
    let version: Int
    var exportedAt: Date
    let routes: [PersistedRoute]
    let achievements: [String: AchievementsManager.AchievementSaveData]
    let monthlyGoals: MonthlyGoals?
    let savedPlans: [SavedRoutePlan]
    let mapType: Int?
    let preferences: [String: RunMapSyncedPreference]?

    enum BackupError: LocalizedError {
        case unsupportedVersion
        case invalidData

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion:
                return "This backup needs a newer version of Explore!."
            case .invalidData:
                return "The Explore! backup contains invalid data. Nothing was imported."
            }
        }
    }

    init(routes: [Route], defaults: UserDefaults = .standard) throws {
        format = Self.formatName
        version = Self.currentVersion
        exportedAt = Date()
        self.routes = routes.sorted { $0.id.uuidString < $1.id.uuidString }.map(PersistedRoute.init)
        let decoder = JSONDecoder()
        achievements = try defaults.data(forKey: "unlockedAchievements").map {
            try decoder.decode([String: AchievementsManager.AchievementSaveData].self, from: $0)
        } ?? [:]
        monthlyGoals = try defaults.data(forKey: "monthlyGoals.v1").map {
            try decoder.decode(MonthlyGoals.self, from: $0)
        }
        savedPlans = try defaults.data(forKey: "routePlanner.savedPlans.v1").map {
            try decoder.decode([SavedRoutePlan].self, from: $0)
        } ?? []
        mapType = defaults.object(forKey: "mapType") as? Int
        preferences = try RunMapSyncedPreferences.capture(defaults: defaults)
        try validate()
    }

    func fingerprint() throws -> String {
        var content = self
        content.exportedAt = Date(timeIntervalSinceReferenceDate: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(content)).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard format == Self.formatName, version == Self.currentVersion else {
            throw BackupError.unsupportedVersion
        }
        guard exportedAt.timeIntervalSinceReferenceDate.isFinite,
              routes.allSatisfy({ route in
                  route.date.timeIntervalSinceReferenceDate.isFinite &&
                  route.durationSec.isFinite && route.durationSec >= 0 &&
                  route.coordinates.count >= 2 &&
                  route.coordinates.allSatisfy { coordinate in
                      coordinate.lat.isFinite && coordinate.lon.isFinite &&
                      (-90...90).contains(coordinate.lat) && (-180...180).contains(coordinate.lon)
                  }
              }),
              achievements.values.allSatisfy({
                  AchievementTier(rawValue: $0.tier) != nil && $0.date.timeIntervalSinceReferenceDate.isFinite
              }),
              savedPlans.allSatisfy({ plan in
                  plan.createdAt.timeIntervalSinceReferenceDate.isFinite &&
                  plan.points.allSatisfy { point in
                      point.latitude.isFinite && point.longitude.isFinite &&
                      (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
                  }
              }) else { throw BackupError.invalidData }
        if let goals = monthlyGoals {
            guard goals.distanceKm.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  goals.newStreetCount.map({ $0 >= 0 }) ?? true,
                  goals.newDistrictCount.map({ $0 >= 0 }) ?? true else {
                throw BackupError.invalidData
            }
        }
        if let preferences { try RunMapSyncedPreferences.validate(preferences) }
    }

    func restorePreferences(defaults: UserDefaults = .standard, synchronizing: Bool = false) throws {
        try validate()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var mergedAchievements = try defaults.data(forKey: "unlockedAchievements").map {
            try decoder.decode([String: AchievementsManager.AchievementSaveData].self, from: $0)
        } ?? [:]
        for (id, incoming) in achievements {
            if let existing = mergedAchievements[id] {
                let existingTier = AchievementTier(rawValue: existing.tier) ?? .none
                let incomingTier = AchievementTier(rawValue: incoming.tier) ?? .none
                mergedAchievements[id] = AchievementsManager.AchievementSaveData(
                    tier: max(existingTier, incomingTier).rawValue,
                    date: min(existing.date, incoming.date)
                )
            } else {
                mergedAchievements[id] = incoming
            }
        }

        let existingPlans = try defaults.data(forKey: "routePlanner.savedPlans.v1").map {
            try decoder.decode([SavedRoutePlan].self, from: $0)
        } ?? []
        var plansByID: [UUID: SavedRoutePlan] = [:]
        for plan in existingPlans + savedPlans { plansByID[plan.id] = plan }
        let plans = plansByID.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt > $1.createdAt
        }

        // Encode every value before changing preferences, so malformed state cannot
        // leave a partially restored set of goals, plans, and achievements.
        let achievementData = try encoder.encode(mergedAchievements)
        let planData = try encoder.encode(plans)
        let goalData = try monthlyGoals.map { try encoder.encode($0) }
        if synchronizing, let preferences {
            try RunMapSyncedPreferences.merge(preferences, defaults: defaults)
        } else {
            defaults.set(planData, forKey: "routePlanner.savedPlans.v1")
            if let goalData { defaults.set(goalData, forKey: "monthlyGoals.v1") }
            if let mapType { defaults.set(mapType, forKey: "mapType") }
        }
        defaults.set(achievementData, forKey: "unlockedAchievements")
    }
}

struct RunMapImportedExperience {
    let routes: [Route]
    let backup: RunMapExperienceBackup?
}
