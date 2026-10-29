import Foundation

struct RunMapSyncedPreference: Codable {
    let modifiedAt: Date
    let data: Data?
}

enum RunMapSyncedPreferences {
    private static let lock = NSRecursiveLock()
    private static let storageKey = "deviceSync.preferenceState.v1"
    private static let goalsKey = "monthlyGoals.v1"
    private static let plansKey = "routePlanner.savedPlans.v1"

    static func capture(defaults: UserDefaults) throws -> [String: RunMapSyncedPreference] {
        lock.lock()
        defer { lock.unlock() }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var state = try defaults.data(forKey: storageKey).map {
            try decoder.decode([String: RunMapSyncedPreference].self, from: $0)
        } ?? [:]
        for (key, record) in state {
            state[key] = RunMapSyncedPreference(modifiedAt: record.modifiedAt, data: try canonicalData(record.data, key: key))
        }
        var current: [String: Data] = [:]
        if let data = defaults.data(forKey: goalsKey) {
            current[goalsKey] = try encoder.encode(decoder.decode(MonthlyGoals.self, from: data))
        }
        if let mapType = defaults.object(forKey: "mapType") as? Int {
            current["mapType"] = try encoder.encode(mapType)
        }
        let plans = try defaults.data(forKey: plansKey).map {
            try decoder.decode([SavedRoutePlan].self, from: $0)
        } ?? []
        for plan in plans { current["plan:\(plan.id.uuidString)"] = try encoder.encode(plan) }

        for key in Set(state.keys).union(current.keys) where state[key]?.data != current[key] {
            state[key] = RunMapSyncedPreference(modifiedAt: Date(), data: current[key])
        }
        try validate(state)
        let encoded = try encoder.encode(state)
        if defaults.data(forKey: storageKey) != encoded { defaults.set(encoded, forKey: storageKey) }
        return state
    }

    static func validate(_ state: [String: RunMapSyncedPreference]) throws {
        let decoder = JSONDecoder()
        for (key, value) in state {
            guard value.modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw RunMapExperienceBackup.BackupError.invalidData
            }
            switch key {
            case goalsKey:
                if let data = value.data {
                    let goals = try decoder.decode(MonthlyGoals.self, from: data)
                    guard goals.distanceKm.map({ $0.isFinite && $0 >= 0 }) ?? true,
                          goals.newStreetCount.map({ $0 >= 0 }) ?? true,
                          goals.newDistrictCount.map({ $0 >= 0 }) ?? true else {
                        throw RunMapExperienceBackup.BackupError.invalidData
                    }
                }
            case "mapType":
                if let data = value.data { _ = try decoder.decode(Int.self, from: data) }
            default:
                guard key.hasPrefix("plan:"), let id = UUID(uuidString: String(key.dropFirst(5))) else {
                    throw RunMapExperienceBackup.BackupError.invalidData
                }
                if let data = value.data {
                    let plan = try decoder.decode(SavedRoutePlan.self, from: data)
                    guard plan.id == id, plan.createdAt.timeIntervalSinceReferenceDate.isFinite,
                          plan.points.allSatisfy({ point in
                              point.latitude.isFinite && point.longitude.isFinite &&
                              (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
                          }) else { throw RunMapExperienceBackup.BackupError.invalidData }
                }
            }
        }
    }

    static func merge(_ incoming: [String: RunMapSyncedPreference], defaults: UserDefaults) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(incoming)
        var merged = try capture(defaults: defaults)
        for (key, record) in incoming {
            let value = RunMapSyncedPreference(modifiedAt: record.modifiedAt, data: try canonicalData(record.data, key: key))
            if let existing = merged[key] {
                guard value.modifiedAt > existing.modifiedAt ||
                        (value.modifiedAt == existing.modifiedAt &&
                         (existing.data ?? Data()).lexicographicallyPrecedes(value.data ?? Data())) else { continue }
            }
            merged[key] = value
        }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plans = try merged.filter { $0.key.hasPrefix("plan:") }.values.compactMap { value in
            try value.data.map { try decoder.decode(SavedRoutePlan.self, from: $0) }
        }.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt > $1.createdAt
        }
        let plansData = try encoder.encode(plans)
        let stateData = try encoder.encode(merged)
        let mapType = try merged["mapType"]?.data.map { try decoder.decode(Int.self, from: $0) }

        defaults.set(plansData, forKey: plansKey)
        if let goals = merged[goalsKey] {
            if let data = goals.data { defaults.set(data, forKey: goalsKey) }
            else { defaults.removeObject(forKey: goalsKey) }
        }
        if merged["mapType"] != nil {
            if let mapType { defaults.set(mapType, forKey: "mapType") }
            else { defaults.removeObject(forKey: "mapType") }
        }
        defaults.set(stateData, forKey: storageKey)
    }

    private static func canonicalData(_ data: Data?, key: String) throws -> Data? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch key {
        case goalsKey: return try encoder.encode(decoder.decode(MonthlyGoals.self, from: data))
        case "mapType": return try encoder.encode(decoder.decode(Int.self, from: data))
        default:
            guard key.hasPrefix("plan:") else { throw RunMapExperienceBackup.BackupError.invalidData }
            return try encoder.encode(decoder.decode(SavedRoutePlan.self, from: data))
        }
    }
}
