import Foundation

struct RunMapDailyDistance: Codable, Equatable {
    let day: Date
    let distanceKilometers: Double
}

struct RunMapAnalyzedRoute: Codable, Equatable {
    let id: String
    let startDate: Date
    let activity: RunMapRouteSnapshot.Activity
    let distanceKilometers: Double
    let durationSeconds: Double
}

struct RunMapRouteAnalysisSnapshot: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let generatedAt: Date
    let routeFingerprint: String
    let routeCount: Int
    let coordinateCount: Int
    let runningDistanceKilometers: Double
    let walkingDistanceKilometers: Double
    let otherDistanceKilometers: Double
    let totalDurationSeconds: Double
    let latestRouteDate: Date?
    let dailyDistances: [RunMapDailyDistance]
    let routes: [RunMapAnalyzedRoute]

    var totalDistanceKilometers: Double {
        runningDistanceKilometers + walkingDistanceKilometers + otherDistanceKilometers
    }
}

struct RunMapRouteAnalysisEngine {
    func makeSnapshot(
        routes: [RunMapRouteSnapshot],
        calendar: Calendar = .current,
        generatedAt: Date = Date()
    ) -> RunMapRouteAnalysisSnapshot {
        var runningDistance = 0.0
        var walkingDistance = 0.0
        var otherDistance = 0.0
        var totalDuration = 0.0
        var dailyDistances: [Date: Double] = [:]
        var analyzedRoutes: [RunMapAnalyzedRoute] = []
        analyzedRoutes.reserveCapacity(routes.count)

        for route in routes {
            let distanceKilometers = route.distanceMeters / 1_000.0
            switch route.activity {
            case .running:
                runningDistance += distanceKilometers
            case .walking:
                walkingDistance += distanceKilometers
            case .other:
                otherDistance += distanceKilometers
            }

            totalDuration += max(0, route.durationSeconds)
            let day = calendar.startOfDay(for: route.startDate)
            dailyDistances[day, default: 0] += distanceKilometers
            analyzedRoutes.append(RunMapAnalyzedRoute(
                id: route.id,
                startDate: route.startDate,
                activity: route.activity,
                distanceKilometers: distanceKilometers,
                durationSeconds: route.durationSeconds
            ))
        }

        return RunMapRouteAnalysisSnapshot(
            version: RunMapRouteAnalysisSnapshot.currentVersion,
            generatedAt: generatedAt,
            routeFingerprint: Self.fingerprint(routeIDs: routes.map(\.id)),
            routeCount: routes.count,
            coordinateCount: routes.reduce(0) { $0 + $1.coordinates.count },
            runningDistanceKilometers: runningDistance,
            walkingDistanceKilometers: walkingDistance,
            otherDistanceKilometers: otherDistance,
            totalDurationSeconds: totalDuration,
            latestRouteDate: routes.map(\.startDate).max(),
            dailyDistances: dailyDistances
                .map { RunMapDailyDistance(day: $0.key, distanceKilometers: $0.value) }
                .sorted { $0.day < $1.day },
            routes: analyzedRoutes
        )
    }

    /// A deterministic, compact identity used to decide whether precalculated data is current.
    static func fingerprint(routeIDs: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for routeID in routeIDs.sorted() {
            for byte in routeID.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct RunMapRouteAnalysisStore {
    enum StoreError: Error {
        case missingCachesDirectory
    }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func appCache(fileManager: FileManager = .default) throws -> RunMapRouteAnalysisStore {
        guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw StoreError.missingCachesDirectory
        }
        return RunMapRouteAnalysisStore(
            fileURL: cacheDirectory.appendingPathComponent("route_analysis_v1.json")
        )
    }

    func load() throws -> RunMapRouteAnalysisSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let snapshot = try JSONDecoder().decode(
            RunMapRouteAnalysisSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        guard snapshot.version == RunMapRouteAnalysisSnapshot.currentVersion else { return nil }
        return snapshot
    }

    func save(_ snapshot: RunMapRouteAnalysisSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: [.atomic])
    }
}
