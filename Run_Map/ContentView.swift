import SwiftUI
import MapKit
import CoreLocation
import HealthKit
import UniformTypeIdentifiers

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocation?
    private let locationManager = CLLocationManager()
    private var hasStarted = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            DispatchQueue.main.async {
                self.currentLocation = location
            }
        }
    }
}

// MARK: - Route Model

final class Route: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let date: Date
    let workoutType: HKWorkoutActivityType
    let durationSec: Double
    let sourceWorkoutID: UUID?
    let sourceRouteID: UUID?
    let segmentIndex: Int

    var persistenceKey: String {
        if let sourceWorkoutID, let sourceRouteID {
            return "health|\(sourceWorkoutID.uuidString)|\(sourceRouteID.uuidString)|\(segmentIndex)"
        }
        return "route|\(id.uuidString)"
    }

    lazy var averageSpeedKmH: Double = {
        guard durationSec > 0 else { return 0 }
        return distanceKm / (durationSec / 3600)
    }()
    
    /// Cached length in kilometres (computed only once).
    lazy var distanceKm: Double = {
        guard coordinates.count > 1 else { return 0.0 }
        return coordinates.adjacentPairs()
            .map { from, to in
                CLLocation(latitude: from.latitude, longitude: from.longitude)
                    .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            }
            .reduce(0, +) / 1_000
    }()
    
    init(id: UUID = UUID(),
         coordinates: [CLLocationCoordinate2D],
         date: Date,
         workoutType: HKWorkoutActivityType,
         durationSec: Double,
         sourceWorkoutID: UUID? = nil,
         sourceRouteID: UUID? = nil,
         segmentIndex: Int = 0) {
        self.id = id
        self.coordinates = coordinates
        self.date = date
        self.workoutType = workoutType
        self.durationSec = durationSec
        self.sourceWorkoutID = sourceWorkoutID
        self.sourceRouteID = sourceRouteID
        self.segmentIndex = segmentIndex
    }
}

enum RouteCoordinateSimplifier {
    static let maxStoredCoordinates = 600

    static func simplified(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxStoredCoordinates else { return coordinates }

        let step = max(1, coordinates.count / maxStoredCoordinates)
        var sampled: [CLLocationCoordinate2D] = []
        sampled.reserveCapacity(maxStoredCoordinates + 2)

        for index in stride(from: 0, to: coordinates.count, by: step) {
            sampled.append(coordinates[index])
        }

        if let last = coordinates.last,
           let sampledLast = sampled.last,
           !sampledLast.isEqual(to: last, tolerance: 0.000001) {
            sampled.append(last)
        }

        return sampled
    }
}

enum RouteRenderCoordinateSimplifier {
    static let maxRenderedCoordinates = 220

    static func simplified(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxRenderedCoordinates else { return coordinates }

        let step = Int(ceil(Double(coordinates.count - 1) / Double(maxRenderedCoordinates - 1)))
        var sampled: [CLLocationCoordinate2D] = []
        sampled.reserveCapacity(maxRenderedCoordinates)
        for index in stride(from: 0, to: coordinates.count, by: step) {
            sampled.append(coordinates[index])
        }
        if let last = coordinates.last,
           sampled.last?.isEqual(to: last, tolerance: 0.000001) != true {
            sampled.append(last)
        }
        return sampled
    }
}

// MARK: - Persistable Route Data

struct PersistedCoordinate: Codable {
    let lat: Double
    let lon: Double
}

struct PersistedRoute: Codable {
    let id: UUID
    let coordinates: [PersistedCoordinate]
    let date: Date
    let workoutType: UInt
    let durationSec: Double
    let sourceWorkoutID: UUID?
    let sourceRouteID: UUID?
    let segmentIndex: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case coordinates
        case date
        case workoutType
        case durationSec
        case sourceWorkoutID
        case sourceRouteID
        case segmentIndex
    }
    
    init(from route: Route) {
        self.id = route.id
        self.coordinates = route.coordinates.map { PersistedCoordinate(lat: $0.latitude, lon: $0.longitude) }
        self.date = route.date
        self.workoutType = route.workoutType.rawValue
        self.durationSec = route.durationSec
        self.sourceWorkoutID = route.sourceWorkoutID
        self.sourceRouteID = route.sourceRouteID
        self.segmentIndex = route.segmentIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        workoutType = try container.decode(UInt.self, forKey: .workoutType)
        durationSec = try container.decode(Double.self, forKey: .durationSec)
        sourceWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .sourceWorkoutID)
        sourceRouteID = try container.decodeIfPresent(UUID.self, forKey: .sourceRouteID)
        segmentIndex = try container.decodeIfPresent(Int.self, forKey: .segmentIndex) ?? 0

        if let compact = try? container.decode([PersistedCoordinate].self, forKey: .coordinates) {
            coordinates = compact
            return
        }

        let legacy = try container.decode([[String: Double]].self, forKey: .coordinates)
        coordinates = legacy.compactMap { dict in
            guard let lat = dict["lat"], let lon = dict["lon"] else { return nil }
            return PersistedCoordinate(lat: lat, lon: lon)
        }
    }
    
    func toRoute() -> Route {
        let coords = coordinates.map { coordinate in
            CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lon)
        }
        return Route(
            id: id,
            coordinates: RouteCoordinateSimplifier.simplified(coords),
            date: date,
            workoutType: HKWorkoutActivityType(rawValue: workoutType) ?? .other,
            durationSec: durationSec,
            sourceWorkoutID: sourceWorkoutID,
            sourceRouteID: sourceRouteID,
            segmentIndex: segmentIndex
        )
    }
}

// MARK: - Route Persistence Manager

final class RouteStorage {
    enum ArchiveError: Error {
        case malformedRouteLine(Int)
    }

    static let shared = RouteStorage()

    private static let ioQueue = DispatchQueue(label: "runmap.routes.store", qos: .utility)
    private let fileManager = FileManager.default
    private let fileName = "cached_routes.json"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let directoryURL: URL
    private var primaryNeedsRecovery = false

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }
    
    func saveRoutes(_ routes: [Route]) {
        Self.ioQueue.sync {
            _ = mergeAndSaveUnlocked(routes)
        }
    }

    @discardableResult
    func mergeRoutes(_ routes: [Route]) -> [Route] {
        Self.ioQueue.sync {
            mergeAndSaveUnlocked(routes)
        }
    }

    private func mergeAndSaveUnlocked(_ routes: [Route]) -> [Route] {
        let merged = deduplicatedRoutes(loadRoutesUnlocked(logResult: false) + routes)
            .sorted { $0.date > $1.date }
        saveRoutesUnlocked(merged)
        return merged
    }

    private func saveRoutesUnlocked(_ routes: [Route]) {
        let tempURL = fileURL.appendingPathExtension("tmp")
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: tempURL)
            fileManager.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }

            for route in routes {
                let data = try encoder.encode(PersistedRoute(from: route))
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
            }

            if fileManager.fileExists(atPath: fileURL.path) {
                // Never replace a known-good backup with a corrupt primary archive.
                if !primaryNeedsRecovery {
                    try? fileManager.removeItem(at: backupURL)
                    try fileManager.copyItem(at: fileURL, to: backupURL)
                }
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
            primaryNeedsRecovery = false
            print("✅ Saved \(routes.count) routes to cache")
        } catch {
            try? fileManager.removeItem(at: tempURL)
            print("❌ Failed to save routes: \(error.localizedDescription)")
        }
    }

    func saveRoutesAsync(_ routes: [Route], completion: (() -> Void)? = nil) {
        Self.ioQueue.async {
            _ = self.mergeAndSaveUnlocked(routes)
            DispatchQueue.main.async {
                completion?()
            }
        }
    }
    
    func loadRoutes() -> [Route] {
        Self.ioQueue.sync { loadRoutesUnlocked(logResult: true) }
    }

    private func loadRoutesUnlocked(logResult: Bool) -> [Route] {
        for candidateURL in [fileURL, backupURL] where fileManager.fileExists(atPath: candidateURL.path) {
            do {
                let routes = try RunMapPerformanceMetrics.measure("route_cache_decode") {
                    let data = try Data(contentsOf: candidateURL, options: .mappedIfSafe)
                    return validRoutes(from: try decodePersistedRoutes(from: data))
                }
                if logResult {
                    let source = candidateURL == fileURL ? "cache" : "backup"
                    print("✅ Loaded \(routes.count) routes from \(source)")
                }
                primaryNeedsRecovery = candidateURL == backupURL
                return routes
            } catch {
                if candidateURL == fileURL {
                    primaryNeedsRecovery = true
                }
                print("⚠️ Route archive read failed at \(candidateURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if logResult { print("ℹ️ No cached routes found") }
        return []
    }

    func exportData(for routes: [Route]) throws -> Data {
        let persistedRoutes = routes.map(PersistedRoute.init)
        return try encoder.encode(persistedRoutes)
    }

    func importRoutes(from url: URL) throws -> [Route] {
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let persistedRoutes = try decodePersistedRoutes(from: data)
        return validRoutes(from: persistedRoutes)
    }

    private func decodePersistedRoutes(from data: Data) throws -> [PersistedRoute] {
        if data.first == UInt8(ascii: "[") {
            return try decoder.decode([PersistedRoute].self, from: data)
        }

        var routes: [PersistedRoute] = []
        for (index, line) in data.split(separator: UInt8(ascii: "\n")).enumerated() {
            guard !line.isEmpty else { continue }
            guard let route = try? decoder.decode(PersistedRoute.self, from: Data(line)) else {
                throw ArchiveError.malformedRouteLine(index + 1)
            }
            routes.append(route)
        }
        return routes
    }

    private func validRoutes(from persistedRoutes: [PersistedRoute]) -> [Route] {
        persistedRoutes.compactMap { persistedRoute -> Route? in
            let route = persistedRoute.toRoute()
            guard !route.coordinates.isEmpty else {
                print("⚠️ Filtering out cached route with no coordinates: \(route.id)")
                return nil
            }
            return route
        }
    }

    func loadRoutesAsync(completion: @escaping ([Route]) -> Void) {
        Self.ioQueue.async {
            let routes = self.loadRoutesUnlocked(logResult: true)
            DispatchQueue.main.async {
                completion(routes)
            }
        }
    }
    
    func getLastSyncDate() -> Date? {
        return UserDefaults.standard.object(forKey: "lastRouteSyncDate") as? Date
    }
    
    func setLastSyncDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: "lastRouteSyncDate")
    }

    func needsFullHistoryAudit(now: Date = Date(), interval: TimeInterval = 7 * 24 * 60 * 60) -> Bool {
        guard let lastAudit = UserDefaults.standard.object(forKey: "lastFullRouteHistoryAudit") as? Date else {
            return true
        }
        return now.timeIntervalSince(lastAudit) >= interval
    }

    func setLastFullHistoryAudit(_ date: Date) {
        UserDefaults.standard.set(date, forKey: "lastFullRouteHistoryAudit")
    }

    func checkedWorkoutIDs() -> Set<UUID> {
        Self.ioQueue.sync { checkedWorkoutIDsUnlocked() }
    }

    func markWorkoutsChecked(_ workoutIDs: [UUID]) {
        guard !workoutIDs.isEmpty else { return }
        Self.ioQueue.sync {
            let merged = checkedWorkoutIDsUnlocked().union(workoutIDs)
            UserDefaults.standard.set(merged.map(\.uuidString).sorted(), forKey: "checkedHealthWorkoutIDs")
        }
    }

    private func checkedWorkoutIDsUnlocked() -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: "checkedHealthWorkoutIDs") ?? []).compactMap(UUID.init(uuidString:)))
    }
    
    func clearCache() {
        Self.ioQueue.sync {
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: backupURL)
        }
        UserDefaults.standard.removeObject(forKey: "lastRouteSyncDate")
        UserDefaults.standard.removeObject(forKey: "lastFullRouteHistoryAudit")
        UserDefaults.standard.removeObject(forKey: "checkedHealthWorkoutIDs")
        print("🗑️ Cleared route cache")
    }

    private func deduplicatedRoutes(_ routes: [Route]) -> [Route] {
        var sourceKeys = Set<String>()
        var geometryKeys = Set<String>()
        let preferred = routes.sorted {
            if ($0.sourceRouteID != nil) != ($1.sourceRouteID != nil) {
                return $0.sourceRouteID != nil
            }
            return $0.coordinates.count > $1.coordinates.count
        }

        return preferred.filter { route in
            if route.sourceRouteID != nil, !sourceKeys.insert(route.persistenceKey).inserted {
                return false
            }
            let first = route.coordinates.first
            let last = route.coordinates.last
            let geometryKey = [
                String(Int(route.date.timeIntervalSince1970.rounded())),
                String(route.workoutType.rawValue),
                String(route.coordinates.count),
                String(format: "%.6f", first?.latitude ?? 0),
                String(format: "%.6f", first?.longitude ?? 0),
                String(format: "%.6f", last?.latitude ?? 0),
                String(format: "%.6f", last?.longitude ?? 0)
            ].joined(separator: "|")
            return geometryKeys.insert(geometryKey).inserted
        }
    }
}

struct RunMapRoutesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - ViewModel

class RunViewModel: ObservableObject {
    enum WorkoutFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case walking = "Walking"
        
        var id: String { rawValue }
    }

    @Published var routes: [Route] = []
    @Published var hasContent: Bool = false
    @Published var selectedFilter: WorkoutFilter = .all
    @Published var healthKitAccess: RunMapHealthKitAccess?
    @Published private(set) var hasLoadedRouteCache = false
    @Published private(set) var isSyncing = false
    private var hasRequestedHealthKitAccess = false

    // Loading progress tracking
    @Published var loadProgress: Double = 0        // 0‥1
    private var totalToLoad: Int = 0
    private var loadedCount: Int = 0

    var displayedRoutes: [Route] {
        switch selectedFilter {
        case .all: return routes
        case .running: return routes.filter { $0.workoutType == .running }
        case .walking: return routes.filter { $0.workoutType == .walking }
        }
    }

    var totalDistanceKm: Double {
        displayedRoutes.map(\.distanceKm).reduce(0, +)
    }

    let healthManager = HealthKitManager()
    let routeStorage = RouteStorage.shared
    
    func loadRuns(fetchHealthKit: Bool = true) {
        // First, load cached routes immediately for instant UI
        routeStorage.loadRoutesAsync { cachedRoutes in
            if !cachedRoutes.isEmpty {
                // Clean up any routes with insufficient coordinates
                let validRoutes = cachedRoutes.filter { route in
                    if route.coordinates.count <= 1 {
                        print("🧹 Removing cached route with insufficient coordinates: \(route.id) (count: \(route.coordinates.count))")
                        return false
                    }
                    return true
                }

                self.routes = validRoutes
                self.hasContent = !validRoutes.isEmpty
                // Save cleaned routes back to cache if we removed any
                if validRoutes.count != cachedRoutes.count {
                    print("💾 Saving cleaned routes to cache: \(validRoutes.count) routes (removed \(cachedRoutes.count - validRoutes.count))")
                    self.routeStorage.saveRoutesAsync(validRoutes)
                }
            }

            self.hasLoadedRouteCache = true

            // Then fetch new routes in background, when HealthKit can be queried.
            if fetchHealthKit {
                if self.routeStorage.needsFullHistoryAudit() {
                    self.reloadAllHealthKitRoutesPreservingCache()
                } else {
                    self.loadNewRuns()
                }
            }
        }
    }

    /// Starts HealthKit only after cached content has reached the screen. This keeps
    /// authorization, a weekly history audit, and MapKit's first render from competing.
    func beginDeferredHealthKitSync() {
        guard !hasRequestedHealthKitAccess else { return }
        hasRequestedHealthKitAccess = true

        healthManager.requestAuthorization { [weak self] access in
            guard let self else { return }
            self.healthKitAccess = access

            guard access == .authorized else {
                self.loadProgress = 1.0
                return
            }

            RunMapHealthKitBackgroundService.shared.start()
            if self.routeStorage.needsFullHistoryAudit() {
                self.reloadAllHealthKitRoutesPreservingCache()
            } else {
                self.loadNewRuns()
            }
        }
    }

    func scheduleRouteAnalysis() {
        RunMapBackgroundAnalysisService.shared.schedule(routes: routes)
    }

    func reloadRoutesFromCache(completion: (() -> Void)? = nil) {
        routeStorage.loadRoutesAsync { cachedRoutes in
            let validRoutes = cachedRoutes
                .filter { $0.coordinates.count > 1 }
                .sorted { $0.date > $1.date }

            self.routes = validRoutes
            self.hasContent = !validRoutes.isEmpty
            RunMapBackgroundAnalysisService.shared.schedule(routes: validRoutes)
            completion?()
        }
    }
    
    func loadAllRunsFromScratch() {
        // Clear existing routes and cache
        DispatchQueue.main.async {
            self.routes.removeAll()
            self.hasContent = false
        }
        routeStorage.clearCache()
        
        healthManager.fetchRunningWorkouts { workouts in
            DispatchQueue.main.async {
                self.totalToLoad = workouts.count
                self.loadedCount = 0
                self.loadProgress = workouts.isEmpty ? 1 : 0
            }
            
            var newRoutes: [Route] = []
            let group = DispatchGroup()
            
            for workout in workouts {
                group.enter()
                self.healthManager.fetchRouteSamples(for: workout) { samples in
                    guard !samples.isEmpty else {
                        print("⚠️ Skipping workout with no GPS data: \(workout.startDate)")
                        group.leave()
                        return
                    }
                    newRoutes.append(contentsOf: self.routes(from: workout, samples: samples))
                    
                    DispatchQueue.main.async {
                        self.loadedCount += 1
                        if self.totalToLoad > 0 {
                            self.loadProgress = Double(self.loadedCount) / Double(self.totalToLoad)
                        }
                    }
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                self.routes = newRoutes.sorted { $0.date > $1.date }
                self.hasContent = !self.routes.isEmpty
                self.routeStorage.saveRoutesAsync(self.routes)
                self.routeStorage.setLastSyncDate(Date())
                self.routeStorage.setLastFullHistoryAudit(Date())
                self.routeStorage.markWorkoutsChecked(workouts.map(\.uuid))
                RunMapBackgroundAnalysisService.shared.schedule(routes: self.routes)
            }
        }
    }

    func refreshFromHealthKit() {
        guard !isSyncing else { return }
        DispatchQueue.main.async {
            self.totalToLoad = 0
            self.loadedCount = 0
            self.loadProgress = 0
        }

        healthManager.requestAuthorization { [weak self] access in
            guard let self = self else { return }
            self.healthKitAccess = access

            guard access == .authorized else {
                DispatchQueue.main.async {
                    self.loadProgress = 1.0
                }
                switch access {
                case .unavailable:
                    print("⚠️ HealthKit data is unavailable on this device; keeping cached routes")
                case .denied:
                    print("⚠️ HealthKit authorization was not granted; keeping cached routes")
                case .authorized:
                    break
                }
                return
            }

            self.reloadAllHealthKitRoutesPreservingCache()
        }
    }

    private func reloadAllHealthKitRoutesPreservingCache() {
        guard !isSyncing else { return }
        isSyncing = true
        let cachedRoutes = routes

        healthManager.fetchRunningWorkouts { workouts in
            DispatchQueue.main.async {
                self.totalToLoad = workouts.count
                self.loadedCount = 0
                self.loadProgress = workouts.isEmpty ? 1 : 0
            }

            guard !workouts.isEmpty else {
                print("ℹ️ HealthKit returned no running/walking workouts; keeping cached routes")
                DispatchQueue.main.async { self.isSyncing = false }
                return
            }

            var refreshedRoutes: [Route] = []
            var workoutsMissingRoutes: [HKWorkout] = []
            let group = DispatchGroup()
            var nextWorkoutIndex = 0

            func processNextWorkout() {
                guard nextWorkoutIndex < workouts.count else {
                    group.leave()
                    return
                }
                let workout = workouts[nextWorkoutIndex]
                nextWorkoutIndex += 1
                self.healthManager.fetchRouteSamples(for: workout) { samples in
                    if samples.isEmpty {
                        workoutsMissingRoutes.append(workout)
                    } else {
                        refreshedRoutes.append(contentsOf: self.routes(from: workout, samples: samples))
                    }

                    DispatchQueue.main.async {
                        self.loadedCount += 1
                        if self.totalToLoad > 0 {
                            self.loadProgress = Double(self.loadedCount) / Double(self.totalToLoad)
                        }
                    }
                    processNextWorkout()
                }
            }

            // A small worker pool completes a full audit quickly without flooding
            // HealthKit or competing with map rendering for CPU and memory.
            let workerCount = min(2, workouts.count)
            for _ in 0..<workerCount {
                group.enter()
                processNextWorkout()
            }

            group.notify(queue: .main) {
                // HealthKit is not authoritative for imported or temporarily unavailable
                // history. Always union a full audit with the local archive.
                let dedupedRoutes = self.deduplicatedRoutes(cachedRoutes + refreshedRoutes).sorted { $0.date > $1.date }

                if !dedupedRoutes.isEmpty {
                    self.routes = dedupedRoutes
                    self.hasContent = true
                    self.routeStorage.saveRoutesAsync(dedupedRoutes)
                    RunMapBackgroundAnalysisService.shared.schedule(routes: dedupedRoutes)
                    print("💾 Full HealthKit refresh saved \(dedupedRoutes.count) routes")
                } else {
                    print("ℹ️ Full HealthKit refresh found no route data; keeping existing cache")
                    self.hasContent = !self.routes.isEmpty
                }

                self.routeStorage.setLastSyncDate(Date())
                self.routeStorage.setLastFullHistoryAudit(Date())
                let missingIDs = Set(workoutsMissingRoutes.map(\.uuid))
                let checkedIDs = workouts.compactMap { workout -> UUID? in
                    if !missingIDs.contains(workout.uuid) { return workout.uuid }
                    return Date().timeIntervalSince(workout.endDate) > 24 * 60 * 60 ? workout.uuid : nil
                }
                self.routeStorage.markWorkoutsChecked(checkedIDs)
                self.loadProgress = 1.0
                self.isSyncing = false

                if !workoutsMissingRoutes.isEmpty {
                    print("⏳ \(workoutsMissingRoutes.count) workouts had no route samples yet; scheduling a follow-up check")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                        self?.loadNewRuns()
                    }
                }
            }
        }
    }

    private func deduplicatedRoutes(_ routes: [Route]) -> [Route] {
        var sourceKeys = Set<String>()
        var geometryKeys = Set<String>()
        let preferred = routes.sorted {
            if ($0.sourceRouteID != nil) != ($1.sourceRouteID != nil) {
                return $0.sourceRouteID != nil
            }
            return $0.coordinates.count > $1.coordinates.count
        }
        return preferred.filter { route in
            if route.sourceRouteID != nil, !sourceKeys.insert(route.persistenceKey).inserted {
                return false
            }
            let first = route.coordinates.first
            let last = route.coordinates.last
            let key = [
                String(Int(route.date.timeIntervalSince1970.rounded())),
                String(route.workoutType.rawValue),
                String(route.coordinates.count),
                String(format: "%.6f", first?.latitude ?? 0),
                String(format: "%.6f", first?.longitude ?? 0),
                String(format: "%.6f", last?.latitude ?? 0),
                String(format: "%.6f", last?.longitude ?? 0)
            ].joined(separator: "_")
            return geometryKeys.insert(key).inserted
        }
    }

    func importRoutes(_ importedRoutes: [Route]) {
        let mergedRoutes = deduplicatedRoutes(routes + importedRoutes).sorted { $0.date > $1.date }
        routes = mergedRoutes
        hasContent = !mergedRoutes.isEmpty
        routeStorage.saveRoutesAsync(mergedRoutes)
        RunMapBackgroundAnalysisService.shared.schedule(routes: mergedRoutes)
        loadProgress = 1.0
    }
    
    func loadNewRuns() {
        guard !isSyncing else { return }
        guard healthKitAccess == .authorized else {
            DispatchQueue.main.async {
                self.loadProgress = 1.0
            }
            return
        }
        isSyncing = true

        // Get all existing route IDs to avoid duplicates
        _ = Set(routes.map { route in
            // Create a unique identifier for each route based on date and coordinates
            "\(route.date.timeIntervalSince1970)_\(route.coordinates.count)"
        })
        
        healthManager.fetchRunningWorkouts { workouts in
            print("🔍 Checking \(workouts.count) total workouts against \(self.routes.count) existing routes")
            
            // Filter out workouts we already have, with some tolerance for date precision
            let sourceWorkoutIDs = Set(self.routes.compactMap(\.sourceWorkoutID))
            let checkedWorkoutIDs = self.routeStorage.checkedWorkoutIDs()
            let newWorkouts = workouts.filter { workout in
                if sourceWorkoutIDs.contains(workout.uuid) || checkedWorkoutIDs.contains(workout.uuid) {
                    return false
                }
                // Legacy archives predate HealthKit source identifiers.
                return !self.routes.contains { route in
                    route.sourceWorkoutID == nil &&
                    abs(route.date.timeIntervalSince1970 - workout.startDate.timeIntervalSince1970) < 1.0
                }
            }
            
            print("🆕 Found \(newWorkouts.count) potentially new workouts to check")
            
            guard !newWorkouts.isEmpty else {
                DispatchQueue.main.async {
                    self.loadProgress = 1.0
                    self.isSyncing = false
                }
            return
        }
        
            DispatchQueue.main.async {
                self.totalToLoad = newWorkouts.count
                self.loadedCount = 0
                self.loadProgress = 0
            }
            
            var newRoutes: [Route] = []
            var skippedCount = 0

            func processWorkout(at index: Int) {
                guard index < newWorkouts.count else {
                    DispatchQueue.main.async {
                        print("📊 Processed \(newWorkouts.count) new workouts: \(newRoutes.count) with GPS data, \(skippedCount) skipped")
                        if !newRoutes.isEmpty {
                            print("📍 Adding \(newRoutes.count) new routes to existing \(self.routes.count)")
                            self.routes.append(contentsOf: newRoutes)
                            self.routes.sort { $0.date > $1.date }
                            self.hasContent = !self.routes.isEmpty

                            // Save updated routes to cache
                            self.routeStorage.saveRoutesAsync(self.routes)
                            RunMapBackgroundAnalysisService.shared.schedule(routes: self.routes)
                            print("💾 Total routes after sync: \(self.routes.count)")
                        } else {
                            if skippedCount > 0 {
                                print("ℹ️ No new routes added - all \(skippedCount) workouts lacked GPS data")
                            } else {
                                print("ℹ️ No new routes to add")
                            }
                        }
                        self.routeStorage.setLastSyncDate(Date())
                        self.loadProgress = 1.0
                        self.isSyncing = false
                    }
                    return
                }

                let workout = newWorkouts[index]
                self.healthManager.fetchRouteSamples(for: workout) { samples in
                    
                    // Only process workouts that have GPS data
                    guard !samples.isEmpty else {
                        print("⚠️ Skipping workout with no GPS data: \(workout.startDate)")
                        skippedCount += 1
                        // Routes can arrive shortly after a workout. Retry recent workouts,
                        // but remember older GPS-less workouts until the next weekly audit.
                        if Date().timeIntervalSince(workout.endDate) > 24 * 60 * 60 {
                            self.routeStorage.markWorkoutsChecked([workout.uuid])
                        }
                        DispatchQueue.main.async {
                            self.loadedCount += 1
                            if self.totalToLoad > 0 {
                                self.loadProgress = Double(self.loadedCount) / Double(self.totalToLoad)
                            }
                        }
                        processWorkout(at: index + 1)
                        return
                    }
                    
                    print("✅ Processing workout with GPS data: \(workout.startDate)")
                    newRoutes.append(contentsOf: self.routes(from: workout, samples: samples))
                    self.routeStorage.markWorkoutsChecked([workout.uuid])
                    
                    DispatchQueue.main.async {
                        self.loadedCount += 1
                        if self.totalToLoad > 0 {
                            self.loadProgress = Double(self.loadedCount) / Double(self.totalToLoad)
                        }
                    }
                    processWorkout(at: index + 1)
                }
            }

            processWorkout(at: 0)
        }
    }

    private func routes(from workout: HKWorkout, samples: [RunMapHealthRouteSample]) -> [Route] {
        samples.enumerated().flatMap { sampleIndex, sample in
            let coordinates = sample.locations.map(\.coordinate)
            return filterRoute(coordinates).enumerated().compactMap { segmentIndex, segment -> Route? in
                guard segment.count > 1 else { return nil }
                return Route(
                    coordinates: RouteCoordinateSimplifier.simplified(segment),
                    date: workout.startDate,
                    workoutType: workout.workoutActivityType,
                    durationSec: workout.duration,
                    sourceWorkoutID: workout.uuid,
                    sourceRouteID: sample.id,
                    segmentIndex: sampleIndex * 10_000 + segmentIndex
                )
            }
        }
    }

    func filterRoute(_ coordinates: [CLLocationCoordinate2D], maxDistance: CLLocationDistance = 20) -> [[CLLocationCoordinate2D]] {
        guard coordinates.count > 1 else { return [coordinates] }
        var segments: [[CLLocationCoordinate2D]] = []
        var currentSegment = [coordinates[0]]
        
        for i in 1..<coordinates.count {
            let prev = CLLocation(latitude: coordinates[i - 1].latitude,
                                  longitude: coordinates[i - 1].longitude)
            let curr = CLLocation(latitude: coordinates[i].latitude,
                                  longitude: coordinates[i].longitude)
            if prev.distance(from: curr) <= maxDistance {
                currentSegment.append(coordinates[i])
            } else {
                if currentSegment.count > 1 {
                    segments.append(currentSegment)
                }
                currentSegment = [coordinates[i]]
            }
        }
        if currentSegment.count > 1 {
            segments.append(currentSegment)
        }
        return segments
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count > 1 else { return [] }
        return (0..<(count-1)).map { (self[$0], self[$0+1]) }
    }
}

// MARK: - RoutePolyline

class RoutePolyline: MKPolyline {
    var routeID: UUID?
    var routeDate: Date?
    var workoutType: HKWorkoutActivityType?
    var isHighlighted: Bool = false
    var averageSpeed: Double?
}

// District polygon overlay with metadata for styling
class DistrictPolygon: MKPolygon {
    var districtName: String = ""
    var colorIndex: Int = 0
    var isVisited: Bool = false
}

class DistrictAnnotation: MKPointAnnotation {}

class StadtteilPolygon: MKPolygon {
    var stadtteilName: String = ""
    var isVisited: Bool = false
}

class StadtteilAnnotation: MKPointAnnotation {
    var isVisited: Bool = false
}

private struct StadtteilBoundary {
    let name: String
    let center: CLLocationCoordinate2D
    let polygons: [[[CLLocationCoordinate2D]]]
}

private struct BoundaryPoint: Hashable, Comparable {
    let lon: Double
    let lat: Double

    static func < (lhs: BoundaryPoint, rhs: BoundaryPoint) -> Bool {
        if lhs.lon == rhs.lon { return lhs.lat < rhs.lat }
        return lhs.lon < rhs.lon
    }
}

private enum BerlinStadtteilBoundaryBuilder {
    private static var cachedSignature: String?
    private static var cachedBoundaries: [StadtteilBoundary] = []
    private static var cachedOfficialBoundaries: [StadtteilBoundary]?
    private static var cachedFallbackStreetsByStadtteil: [String: [ConsolidatedStreet]]?

    static func fallbackStreetsByStadtteil() -> [String: [ConsolidatedStreet]] {
        if let cachedFallbackStreetsByStadtteil {
            return cachedFallbackStreetsByStadtteil
        }

        let allDistricts = BerlinDistricts.districts.map { $0.name }
        let streets = BerlinStreets.getStreets(forDistricts: allDistricts)
        let consolidated = StreetConsolidator.consolidate(streets: streets)

        var grouped: [String: [ConsolidatedStreet]] = [:]
        for street in consolidated {
            guard let stadtteil = street.segments.first?.stadtteil, !stadtteil.isEmpty, stadtteil != "Unknown" else {
                continue
            }
            grouped[stadtteil, default: []].append(street)
        }

        cachedFallbackStreetsByStadtteil = grouped
        return grouped
    }

    static func boundaries(from streetsByStadtteil: [String: [ConsolidatedStreet]]) -> [StadtteilBoundary] {
        if let official = officialBoundaries(), !official.isEmpty {
            return official
        }

        let signature = streetsByStadtteil
            .map { key, streets in "\(key):\(streets.count):\(streets.reduce(0) { $0 + $1.totalPoints })" }
            .sorted()
            .joined(separator: "|")

        if signature == cachedSignature {
            return cachedBoundaries
        }

        let boundaries = streetsByStadtteil.compactMap { stadtteil, streets -> StadtteilBoundary? in
            let trimmedName = stadtteil.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, trimmedName != "Unknown" else { return nil }

            let totalPoints = streets.reduce(0) { $0 + $1.totalPoints }
            guard totalPoints >= 3 else { return nil }

            let sampleStride = max(1, totalPoints / 900)
            var seen = Set<BoundaryPoint>()
            var points: [BoundaryPoint] = []
            points.reserveCapacity(min(totalPoints, 900))

            var index = 0
            for street in streets {
                for coordinate in street.allCoordinates {
                    defer { index += 1 }
                    guard index % sampleStride == 0 else { continue }
                    guard coordinate.lat.isFinite, coordinate.lon.isFinite else { continue }
                    guard abs(coordinate.lat) <= 90, abs(coordinate.lon) <= 180 else { continue }

                    let point = BoundaryPoint(lon: coordinate.lon, lat: coordinate.lat)
                    if seen.insert(point).inserted {
                        points.append(point)
                    }
                }
            }

            guard points.count >= 3 else { return nil }
            let hullPoints = convexHull(points.sorted())
            guard hullPoints.count >= 3 else { return nil }

            let hull = hullPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let center = CLLocationCoordinate2D(
                latitude: hullPoints.reduce(0) { $0 + $1.lat } / Double(hullPoints.count),
                longitude: hullPoints.reduce(0) { $0 + $1.lon } / Double(hullPoints.count)
            )

            return StadtteilBoundary(name: trimmedName, center: center, polygons: [[hull]])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        cachedSignature = signature
        cachedBoundaries = boundaries
        return boundaries
    }

    private static func officialBoundaries() -> [StadtteilBoundary]? {
        if let cachedOfficialBoundaries {
            return cachedOfficialBoundaries
        }

        guard let url = Bundle.main.url(forResource: "alkis_ortsteile", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            return nil
        }

        let boundaries = features.compactMap { feature -> StadtteilBoundary? in
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else {
                return nil
            }

            let name = ((properties["OTEIL"] as? String) ?? (properties["spatial_alias"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }

            let polygons = parsePolygons(type: type, geometry: geometry)
            guard !polygons.isEmpty else { return nil }

            let centerPoints = polygons.flatMap { polygon in polygon.first ?? [] }
            guard !centerPoints.isEmpty else { return nil }
            let center = CLLocationCoordinate2D(
                latitude: centerPoints.reduce(0) { $0 + $1.latitude } / Double(centerPoints.count),
                longitude: centerPoints.reduce(0) { $0 + $1.longitude } / Double(centerPoints.count)
            )

            return StadtteilBoundary(name: name, center: center, polygons: polygons)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        cachedOfficialBoundaries = boundaries
        print("✅ Loaded \(boundaries.count) official Berlin Ortsteil boundaries")
        return boundaries
    }

    private static func parsePolygons(type: String, geometry: [String: Any]) -> [[[CLLocationCoordinate2D]]] {
        if type == "MultiPolygon", let coordinates = geometry["coordinates"] as? [[[[Double]]]] {
            return coordinates.compactMap { polygon in
                parseRings(polygon)
            }
        }

        if type == "Polygon", let coordinates = geometry["coordinates"] as? [[[Double]]] {
            return parseRings(coordinates).map { [$0] } ?? []
        }

        return []
    }

    private static func parseRings(_ rings: [[[Double]]]) -> [[CLLocationCoordinate2D]]? {
        let parsed = rings.compactMap { ring -> [CLLocationCoordinate2D]? in
            let coordinates = ring.compactMap { coordinate -> CLLocationCoordinate2D? in
                guard coordinate.count >= 2 else { return nil }
                let longitude = coordinate[0]
                let latitude = coordinate[1]
                guard latitude.isFinite, longitude.isFinite else { return nil }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            return coordinates.count >= 3 ? coordinates : nil
        }
        return parsed.isEmpty ? nil : parsed
    }

    private static func convexHull(_ points: [BoundaryPoint]) -> [BoundaryPoint] {
        guard points.count > 1 else { return points }

        var lower: [BoundaryPoint] = []
        for point in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper: [BoundaryPoint] = []
        for point in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func cross(_ origin: BoundaryPoint, _ a: BoundaryPoint, _ b: BoundaryPoint) -> Double {
        (a.lon - origin.lon) * (b.lat - origin.lat) - (a.lat - origin.lat) * (b.lon - origin.lon)
    }
}

private extension RoutePolyline {
    /// Convenience factory because `MKPolyline(coordinates:count:)`
    /// is a *convenience* initializer that isn’t inherited by subclasses.
    static func fromCoordinates(_ coords: [CLLocationCoordinate2D]) -> RoutePolyline {
        // MKPolyline (and subclasses) expose an initializer that takes an *array* directly.
        return RoutePolyline(coordinates: coords, count: coords.count)
    }
}

// MARK: - Map Region Computation

/// Computes an MKCoordinateRegion that fits all the given coordinates
func coordinateRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
    guard !coordinates.isEmpty else {
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
                                  span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))
    }
    
    let latitudes = coordinates.map { $0.latitude }
    let longitudes = coordinates.map { $0.longitude }
    
    let minLat = latitudes.min()!
    let maxLat = latitudes.max()!
    let minLon = longitudes.min()!
    let maxLon = longitudes.max()!
    
    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                        longitude: (minLon + maxLon) / 2)
    let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.3,
                                longitudeDelta: (maxLon - minLon) * 1.3)
    
    return MKCoordinateRegion(center: center, span: span)
}

private struct LaunchSummaryData: Identifiable {
    let id = UUID()
    let newWalkCount: Int
    let newDistanceKm: Double
    let newRoutes: [Route]
    let runningKPI: LaunchWorkoutKPI
    let walkingKPI: LaunchWorkoutKPI
    let newStreetNames: [String]
    let newDistrictNames: [String]
    let newStadtteilNames: [String]
    let touchedAreaCount: Int

    var hasNewRoutes: Bool {
        newWalkCount > 0 || newDistanceKm > 0
    }

    var newAreaNames: [String] {
        (newDistrictNames + newStadtteilNames).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var newAreaPercentage: Double {
        let denominator = max(touchedAreaCount, newAreaNames.count)
        guard denominator > 0 else { return 0 }
        return min(100, Double(newAreaNames.count) / Double(denominator) * 100)
    }

    var areaPercentageDetail: String {
        let denominator = max(touchedAreaCount, newAreaNames.count)
        return "\(newAreaNames.count) of \(denominator)"
    }
}

private struct PendingLaunchSummary {
    let newWalkCount: Int
    let newDistanceKm: Double
    let newRoutes: [Route]
    let runningKPI: LaunchWorkoutKPI
    let walkingKPI: LaunchWorkoutKPI
    let touchedAreaCount: Int
}

private struct LaunchWorkoutKPI {
    let count: Int
    let distanceKm: Double
    let durationSec: Double

    static let empty = LaunchWorkoutKPI(count: 0, distanceKm: 0, durationSec: 0)

    var hasRoutes: Bool {
        count > 0
    }

    var routeNoun: String {
        count == 1 ? "route" : "routes"
    }

    var paceText: String {
        guard distanceKm > 0, durationSec > 0 else { return "-" }
        let secondsPerKm = Int((durationSec / distanceKm).rounded())
        return "\(secondsPerKm / 60):\(String(format: "%02d", secondsPerKm % 60))/km"
    }
}

private struct LaunchSummarySheet: View {
    let summary: LaunchSummaryData
    let onShowRoutes: ([Route]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showAllStreets = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !summary.hasNewRoutes {
                        Text("Go explore!")
                            .font(.title2)
                            .fontWeight(.semibold)
                    } else {
                        Text(String(format: "You added %d %@ for %.1f kilometers.", summary.newWalkCount, summary.workoutNoun, summary.newDistanceKm))
                            .font(.title3)
                            .fontWeight(.semibold)

                        launchKPISection

                        if !summary.newRoutes.isEmpty {
                            Button {
                                onShowRoutes(summary.newRoutes)
                                dismiss()
                            } label: {
                                LaunchSummaryRouteMap(routes: summary.newRoutes)
                                    .frame(height: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)

                            Button {
                                onShowRoutes(summary.newRoutes)
                                dismiss()
                            } label: {
                                Label("Show on map", systemImage: "map")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if !summary.newStreetNames.isEmpty {
                            if summary.newAreaNames.isEmpty {
                                Text("This was your first time visiting \(compactList(summary.newStreetNames, limit: 5)).")
                                    .font(.body)
                            } else {
                                Text("This was your first time visiting \(compactList(summary.newAreaNames, limit: 5)).")
                                    .font(.body)
                                Text("You covered \(summary.newStreetNames.count) new streets:")
                                    .font(.headline)
                            }

                            streetList
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Nice work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var launchKPISection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                workoutKPICard(title: "Runs", kpi: summary.runningKPI, color: .green)
                workoutKPICard(title: "Walks", kpi: summary.walkingKPI, color: .blue)
            }

            HStack(spacing: 10) {
                metricCard(
                    title: "New Areas",
                    value: String(format: "%.0f%%", summary.newAreaPercentage),
                    detail: summary.areaPercentageDetail,
                    color: .orange
                )
                metricCard(
                    title: "New Streets",
                    value: "\(summary.newStreetNames.count)",
                    detail: summary.newStreetNames.count == 1 ? "street" : "streets",
                    color: .purple
                )
            }
        }
    }

    private func workoutKPICard(title: String, kpi: LaunchWorkoutKPI, color: Color) -> some View {
        metricCard(
            title: title,
            value: String(format: "%.1f km", kpi.distanceKm),
            detail: kpi.hasRoutes ? "\(kpi.count) \(kpi.routeNoun) · \(kpi.paceText)" : "No routes",
            color: color
        )
    }

    private func metricCard(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var streetList: some View {
        if summary.newStreetNames.count > 5 {
            VStack(alignment: .leading, spacing: 8) {
                Text(compactList(summary.newStreetNames, limit: 4))
                    .font(.body)
                DisclosureGroup("Show all \(summary.newStreetNames.count) streets", isExpanded: $showAllStreets) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.newStreetNames, id: \.self) { street in
                            Text(street)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        } else {
            Text(summary.newStreetNames.joined(separator: ", "))
                .font(.body)
        }
    }

    private func compactList(_ names: [String], limit: Int) -> String {
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard sorted.count > limit else {
            return sorted.joined(separator: ", ")
        }

        let shown = sorted.prefix(limit).joined(separator: ", ")
        return "\(shown), and \(sorted.count - limit) others"
    }
}

private extension LaunchSummaryData {
    var workoutNoun: String {
        newWalkCount == 1 ? "workout" : "workouts"
    }
}

private struct LaunchSummaryRouteMap: UIViewRepresentable {
    let routes: [Route]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsUserLocation = false
        mapView.pointOfInterestFilter = .excludingAll
        render(routes: routes, on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        render(routes: routes, on: mapView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func render(routes: [Route], on mapView: MKMapView) {
        mapView.removeOverlays(mapView.overlays)

        let polylines = routes
            .filter { $0.coordinates.count > 1 }
            .map { route in
                let polyline = RoutePolyline.fromCoordinates(route.coordinates)
                polyline.workoutType = route.workoutType
                return polyline
            }

        if !polylines.isEmpty {
            mapView.addOverlays(polylines, level: .aboveRoads)
        }

        let coordinates = routes.flatMap(\.coordinates)
        if !coordinates.isEmpty {
            mapView.setRegion(coordinateRegion(for: coordinates), animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? RoutePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = polyline.workoutType == .walking ? UIColor.systemBlue : UIColor.systemGreen
            renderer.lineWidth = 4
            renderer.alpha = 0.9
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}

private struct RotatingLaunchStatusView: View {
    private static let updateInterval: TimeInterval = 0.3
    private static let routeHistoryMessages = [
        "Loading route history…",
        "Adding cities…",
        "Analysing latest…",
        "Adding runs…",
        "Calculating pace…",
        "Loading data…",
        "Mapping globe…",
        "Updating achievements…",
        "Creating goals…",
        "Fixing bugs…"
    ]
    private static let mapMessages = [
        "Preparing map…",
        "Mapping globe…",
        "Adding cities…",
        "Adding runs…",
        "Calculating pace…",
        "Updating achievements…",
        "Creating goals…",
        "Loading data…",
        "Fixing bugs…"
    ]

    let isLoadingRouteHistory: Bool
    @State private var phaseStartedAt = Date()

    private var messages: [String] {
        isLoadingRouteHistory ? Self.routeHistoryMessages : Self.mapMessages
    }

    var body: some View {
        TimelineView(.periodic(from: phaseStartedAt, by: Self.updateInterval)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(phaseStartedAt))
            let index = Int(elapsed / Self.updateInterval) % messages.count
            Text(messages[index])
                .fontWeight(.semibold)
                .frame(width: 205, alignment: .leading)
        }
        .onChange(of: isLoadingRouteHistory) { _ in
            phaseStartedAt = Date()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoadingRouteHistory ? "Loading route history" : "Preparing map")
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var viewModel = RunViewModel()
    @StateObject private var locationManager = LocationManager()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false
    @AppStorage("mapType") private var mapTypeRawValue: Int = Int(MKMapType.standard.rawValue)

    private var mapType: MKMapType {
        get { MKMapType(rawValue: UInt(mapTypeRawValue)) ?? .standard }
        set { mapTypeRawValue = Int(newValue.rawValue) }
    }

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0), // World view center
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180) // World view span
    )
    @State private var hasSetInitialLocation = false
    @State private var isLoading = true
    @State private var highlightedRouteIDs: Set<UUID> = []
    @State private var showLatestDayLabel = false
    @State private var showUserLocation = true
    @State private var showNoWorkouts = false
    @State private var showNewCountryAlert = false
    @State private var newCountriesFound: [String] = []

    @State private var showControls = false
    @State private var showStats = false
    @State private var showAchievementsPage = false
    @State private var showRoutePlanner = false
    @State private var showMonthlyRecap = false
    @State private var showRouteExporter = false
    @State private var showRouteImporter = false
    @State private var routeExportDocument = RunMapRoutesDocument()
    @State private var routeTransferMessage: String?
    @StateObject private var achievementsManager = AchievementsManager()
    @State private var showUpdatedMessage = false
    @State private var didStartLaunch = false
    @State private var didStartDeferredServices = false
    @State private var launchStartedAt = CFAbsoluteTimeGetCurrent()
    @State private var shouldMountMap = false
    @State private var isMapReady = false
    
    // District overlay state
    @State private var selectedDistrictOverlay: (name: String, lat: Double, lon: Double)? = nil
    @State private var showAllBerlinDistricts = false
    @State private var showAllBerlinStadtteile = false

    // Stats banner state
    @AppStorage("lastRunCount") private var lastRunCount = 0
    @AppStorage("lastDistanceKm") private var lastDistanceKm: Double = 0
    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false
    @State private var launchSummary: LaunchSummaryData?
    @State private var pendingLaunchSummary: PendingLaunchSummary?
    @State private var hasShownSummary = false

    private var usesRegularWidthLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var mapControlSize: CGFloat {
        usesRegularWidthLayout ? 58 : 48
    }

    private var hasMapMarks: Bool {
        !highlightedRouteIDs.isEmpty ||
        selectedDistrictOverlay != nil ||
        showAllBerlinDistricts ||
        showAllBerlinStadtteile
    }

    private func circleButton(icon: String, bg: Color = .blue) -> some View {
        Image(systemName: icon)
            .font(.system(size: usesRegularWidthLayout ? 21 : 17, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: mapControlSize, height: mapControlSize)
            .background(bg)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 3)
    }

    private func beginDeferredServicesIfReady() {
        guard hasSeenTutorial,
              viewModel.hasLoadedRouteCache,
              !didStartDeferredServices else { return }
        didStartDeferredServices = true
        locationManager.start()

        // Give MapKit one quiet turn to display the cached archive before HealthKit
        // reconciliation and precalculation start at background priority.
        let healthKitDelay = viewModel.routes.isEmpty ? 0.25 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + healthKitDelay) {
            viewModel.beginDeferredHealthKitSync()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            viewModel.scheduleRouteAnalysis()
        }
    }

    private func showUpdatedToast() {
        showUpdatedMessage = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            showUpdatedMessage = false
        }
    }

    private var noWorkoutsTitle: String {
        switch viewModel.healthKitAccess {
        case .unavailable:
            return "HealthKit unavailable"
        case .denied:
            return "Health permission needed"
        case .authorized, nil:
            return "No workouts found"
        }
    }

    private var noWorkoutsMessage: String {
        switch viewModel.healthKitAccess {
        case .unavailable:
            return "This Mac build cannot access HealthKit, so macOS will not show a Health permission prompt. Use the iPhone or iPad app to sync workouts, or load demo workouts to explore the app."
        case .denied:
            return "Health access was not granted. Open Settings, allow Explore! to read workouts and workout routes, then try syncing again."
        case .authorized, nil:
            return "Connect to Health and record a run or tap below to load a couple of demo workouts to see the app in action."
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.78), Color.cyan.opacity(0.38)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if shouldMountMap {
                RouteMapView(routes: viewModel.displayedRoutes,
                             region: region,
                             highlightedRouteIDs: highlightedRouteIDs,
                             showUserLocation: showUserLocation,
                             mapType: mapType,
                             districtOverlay: selectedDistrictOverlay,
                             showAllBerlinDistricts: showAllBerlinDistricts,
                             visitedBerlinDistricts: achievementsManager.berlinDistrictsVisitedCached,
                             showAllBerlinStadtteile: showAllBerlinStadtteile,
                             visitedBerlinStadtteile: achievementsManager.berlinStadtteileVisitedCached,
                             streetsByStadtteil: achievementsManager.streetsByStadtteil,
                             onMapReady: {
                                 isMapReady = true
                             })
                .onReceive(locationManager.$currentLocation) { location in
                    // Center map on user's current location when first obtained
                    if let location = location, !hasSetInitialLocation {
                        withAnimation(.easeInOut(duration: 1.5)) {
                            region = MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05) // Closer zoom for current location
                            )
                            hasSetInitialLocation = true
                        }
                    }
                }
                .onReceive(viewModel.$routes) { routes in
                    // If no current location available, center on latest workout
                    if !hasSetInitialLocation && !routes.isEmpty {
                        if let latestRoute = routes.first, 
                           let firstCoord = latestRoute.coordinates.first,
                           firstCoord.latitude.isFinite && firstCoord.longitude.isFinite &&
                           abs(firstCoord.latitude) <= 90 && abs(firstCoord.longitude) <= 180 {
                            withAnimation(.easeInOut(duration: 1.5)) {
                                region = MKCoordinateRegion(
                                    center: firstCoord,
                                    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1) // Medium zoom for workout location
                                )
                                hasSetInitialLocation = true
                            }
                        }
                        // If no valid coordinates found, stay at world view (hasSetInitialLocation remains false)
                    }
                }
                .ignoresSafeArea()
            }
            
            VStack {
                // Demo workout label
                if viewModel.routes.contains(where: { $0.date == Date.distantPast }) {
                    Text("Showing Demo Workout")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()
                if showLatestDayLabel {
                    Text("Latest Day")
                        .font(.headline).bold()
                        .padding(12)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                Spacer()

                .padding(.bottom, 8)
            }
            
            if isLoading || !isMapReady {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    RotatingLaunchStatusView(isLoadingRouteHistory: isLoading)
                }
                .padding()
                .background(Color.black.opacity(0.68))
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal, 28)
            }

            if viewModel.isSyncing && !isLoading {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating routes in the background")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 10)
                    Spacer()
                }
            }

            if showUpdatedMessage {
                Text("Updated!")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .transition(.opacity)
            }

            if let routeTransferMessage {
                Text(routeTransferMessage)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(.horizontal, 28)
                    .transition(.opacity)
            }
            
            VStack {
                Spacer()
                VStack(spacing: usesRegularWidthLayout ? 16 : 12) {
                    if showControls {
                        Menu {
                            Button {
                                viewModel.refreshFromHealthKit()
                            } label: {
                                Label("Update from Health", systemImage: "arrow.clockwise")
                            }

                            Menu {
                                Button {
                                    prepareRouteExport()
                                } label: {
                                    Label("Export Routes", systemImage: "square.and.arrow.up")
                                }

                                Button {
                                    showRouteImporter = true
                                } label: {
                                    Label("Import Routes", systemImage: "square.and.arrow.down")
                                }
                            } label: {
                                Label("Route Transfer", systemImage: "arrow.left.arrow.right")
                            }
                        } label: {
                            circleButton(icon: "externaldrive.fill")
                        }
                        .accessibilityLabel("Data")

                        Menu {
                            Button {
                                showStats = true
                            } label: {
                                Label("Statistics", systemImage: "chart.bar")
                            }

                            Button {
                                achievementsManager.prepareForFeatureUse(routes: viewModel.routes)
                                MonthlyRecapNotificationScheduler.configure()
                                showMonthlyRecap = true
                            } label: {
                                Label("Monthly Recap", systemImage: "calendar.badge.clock")
                            }

                            Button {
                                achievementsManager.prepareForFeatureUse(routes: viewModel.routes)
                                showAchievementsPage = true
                            } label: {
                                Label("Achievements", systemImage: "trophy.fill")
                            }
                        } label: {
                            circleButton(icon: "chart.bar.fill")
                        }
                        .accessibilityLabel("Progress")

                        Menu {
                            Button {
                                if hasMapMarks {
                                    clearMapMarks()
                                } else {
                                    markLatestDayRoutes()
                                }
                            } label: {
                                Label(
                                    hasMapMarks ? "Clear Map Marks" : "Highlight Latest Day",
                                    systemImage: hasMapMarks ? "eraser.fill" : "highlighter"
                                )
                            }

                            Button {
                                mapTypeRawValue = Int(
                                    (mapType == .standard ? MKMapType.satellite : MKMapType.standard).rawValue
                                )
                            } label: {
                                Label(
                                    mapType == .standard ? "Use Satellite Map" : "Use Standard Map",
                                    systemImage: mapType == .standard ? "globe" : "map"
                                )
                            }

                            Button {
                                showUserLocation.toggle()
                            } label: {
                                Label(
                                    showUserLocation ? "Hide My Location" : "Show My Location",
                                    systemImage: showUserLocation ? "location.slash" : "location"
                                )
                            }

                            Divider()

                            Button {
                                achievementsManager.prepareForFeatureUse(routes: viewModel.routes)
                                showRoutePlanner = true
                            } label: {
                                Label(
                                    "Route Planner",
                                    systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill"
                                )
                            }
                        } label: {
                            circleButton(icon: "map.fill")
                        }
                        .accessibilityLabel("Map tools")

                        // Keep the most common map action available with one tap.
                        circleButton(icon: "location.fill")
                            .onTapGesture {
                                print("🎯 Location button tapped")
                                if let loc = locationManager.currentLocation {
                                    print("📍 Current location found: \(loc.coordinate)")

                                    // Force a region update even when the same location is selected repeatedly.
                                    let randomOffset = Double.random(in: -0.0001...0.0001)
                                    let adjustedCenter = CLLocationCoordinate2D(
                                        latitude: loc.coordinate.latitude + randomOffset,
                                        longitude: loc.coordinate.longitude + randomOffset
                                    )

                                    let newRegion = MKCoordinateRegion(
                                        center: adjustedCenter,
                                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
                                    print("🎯 Setting region to: \(newRegion)")
                                    withAnimation(.easeInOut(duration: 1.0)) {
                                        region = newRegion
                                    }
                                } else {
                                    print("⚠️ No current location available - check location permissions in Settings")
                                }
                            }
                            .accessibilityLabel("Center on my location")

                    }

                    // Main FAB that toggles the stack
                    circleButton(icon: showControls ? "xmark" : "plus")
                        .onTapGesture {
                            withAnimation { showControls.toggle() }
                        }
                        .accessibilityLabel(showControls ? "Close controls" : "Open controls")
                }
                .padding(usesRegularWidthLayout ? 24 : 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onAppear {
            guard !didStartLaunch else { return }
            didStartLaunch = true
            isLoading = true
            viewModel.loadRuns(fetchHealthKit: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .runMapHealthKitBackgroundImportDidFinish)) { _ in
            viewModel.reloadRoutesFromCache {
                showUpdatedToast()
            }
        }
        .onReceive(viewModel.$hasLoadedRouteCache) { hasLoadedCache in
            guard hasLoadedCache else { return }
            RunMapPerformanceMetrics.log(
                "launch_cache_ready",
                seconds: CFAbsoluteTimeGetCurrent() - launchStartedAt,
                metadata: "routes=\(viewModel.routes.count)"
            )
            isLoading = false
            // Commit the lightweight SwiftUI shell first. MapKit is mounted on the
            // following run-loop turn so its renderer cannot delay the first frame.
            DispatchQueue.main.async {
                shouldMountMap = true
            }
            showNoWorkouts = false
            beginDeferredServicesIfReady()
        }
        .onReceive(viewModel.$loadProgress) { progress in
            if progress >= 1 {
                // After all HealthKit queries finish decide whether to show the empty state
                showNoWorkouts = viewModel.routes.isEmpty
                if !hasShownSummary {
                    let newRuns = max(0, viewModel.routes.count - lastRunCount)
                    let newlyAddedRoutes = Array(viewModel.routes.sorted { $0.date > $1.date }.prefix(newRuns))
                    let newDistance = newlyAddedRoutes.map(\.distanceKm).reduce(0, +)
                    if hasLaunchedBefore {
                        if newRuns > 0 {
                            pendingLaunchSummary = PendingLaunchSummary(
                                newWalkCount: newRuns,
                                newDistanceKm: newDistance,
                                newRoutes: newlyAddedRoutes,
                                runningKPI: launchWorkoutKPI(for: newlyAddedRoutes, type: .running),
                                walkingKPI: launchWorkoutKPI(for: newlyAddedRoutes, type: .walking),
                                touchedAreaCount: 0
                            )
                            presentPendingLaunchSummary()
                        }
                    }
                    lastRunCount = viewModel.routes.count
                    lastDistanceKm = viewModel.totalDistanceKm
                    hasShownSummary = true
                    hasLaunchedBefore = true
                }
            }
        }
        .onChange(of: hasSeenTutorial) { hasSeen in
            if hasSeen {
                beginDeferredServicesIfReady()
            }
        }
        .onReceive(achievementsManager.$newlyCoveredStreetNames) { _ in
            presentPendingLaunchSummary()
        }
        .onReceive(achievementsManager.$processingProgress) { progress in
            if progress >= 1 {
                presentPendingLaunchSummary()
            }
        }
    // end ZStack
        .fullScreenCover(isPresented: Binding(
            get: { !hasSeenTutorial },
            set: { _ in })) {
            OnboardingView {
                hasSeenTutorial = true
            }
        }
        .fullScreenCover(isPresented: $showNoWorkouts) {
            NoWorkoutsView(
                title: noWorkoutsTitle,
                message: noWorkoutsMessage
            ) {
                loadDemoWorkouts()
                showNoWorkouts = false
            }
        }
        .fileExporter(
            isPresented: $showRouteExporter,
            document: routeExportDocument,
            contentType: .json,
            defaultFilename: "Explore_routes"
        ) { result in
            switch result {
            case .success:
                showRouteTransferMessage("Routes exported")
            case .failure(let error):
                showRouteTransferMessage("Export failed: \(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $showRouteImporter,
            allowedContentTypes: [.json]
        ) { result in
            importRoutes(from: result)
        }
        .sheet(isPresented: $showStats) {
            StatsView(routes: viewModel.displayedRoutes) { country, city in
                navigateToLocation(country: country, city: city)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showRoutePlanner) {
            RoutePlannerView(
                initialRegion: region,
                routes: viewModel.routes,
                consolidatedStreets: achievementsManager.consolidatedStreets,
                streetCoverageByID: achievementsManager.streetCoverageByID
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showMonthlyRecap) {
            MonthlyRecapView(
                routes: viewModel.routes,
                achievements: achievementsManager.achievements,
                consolidatedStreets: achievementsManager.consolidatedStreets,
                streetCoverageByID: achievementsManager.streetCoverageByID
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showAchievementsPage) {
            AchievementsView(
                achievementsManager: achievementsManager,
                routes: viewModel.routes,
                onDistrictSelected: { districtName, lat, lon in
                    selectedDistrictOverlay = (districtName, lat, lon)
                    showAllBerlinDistricts = false
                    showAllBerlinStadtteile = false
                    let districtCenter = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    let newRegion = MKCoordinateRegion(
                        center: districtCenter,
                        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
                    )
                    withAnimation(.easeInOut(duration: 1.0)) {
                        region = newRegion
                    }
                },
                onShowAllDistricts: {
                    selectedDistrictOverlay = nil
                    showAllBerlinDistricts = true
                    showAllBerlinStadtteile = false
                    let berlinCenter = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)
                    let newRegion = MKCoordinateRegion(
                        center: berlinCenter,
                        span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
                    )
                    withAnimation(.easeInOut(duration: 1.0)) {
                        region = newRegion
                    }
                },
                onShowAllStadtteile: {
                    selectedDistrictOverlay = nil
                    showAllBerlinDistricts = false
                    showAllBerlinStadtteile = true
                    let berlinCenter = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)
                    let newRegion = MKCoordinateRegion(
                        center: berlinCenter,
                        span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
                    )
                    withAnimation(.easeInOut(duration: 1.0)) {
                        region = newRegion
                    }
                },
                onLocationSelected: { country, city in
                    navigateToLocation(country: country, city: city)
                }
            )
            .presentationDetents([.large])
        }
        .sheet(item: $launchSummary) { summary in
            LaunchSummarySheet(summary: summary) { routes in
                showLaunchRoutesOnMap(routes)
            }
        }
        .alert(isPresented: $achievementsManager.showAchievementAlert) {
            Alert(
                title: Text(achievementsManager.achievementMessage?.split(separator: "\n").first.map(String.init) ?? "Achievement"),
                message: Text(achievementsManager.achievementMessage?.split(separator: "\n").dropFirst().joined(separator: "\n") ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("🎉 New Country Visited!", isPresented: $showNewCountryAlert) {
            Button("Awesome!", role: .cancel) { }
        } message: {
            if newCountriesFound.count == 1 {
                Text("Congratulations! You've explored a new country: \(newCountriesFound.first!)! 🌍")
            } else {
                Text("Congratulations! You've explored \(newCountriesFound.count) new countries: \(newCountriesFound.joined(separator: ", "))! 🌍")
            }
        }
    }   // ← closes the `var body: some View` property

    private func loadDemoWorkouts() {
        // To add additional demo workouts, drop more .gpx files into the app bundle
        // and list their base names in the `demoFiles` array below.
        let demoFiles = ["Outdoor Walk-Route-20240509_143723", "Outdoor Walk-Route-20241211_185505", "Outdoor Walk-Route-20241208_145435", "Outdoor Walk-Route-20241201_182250", "Outdoor Walk-Route-20241210_181825"]   // add more GPX names if desired
        for name in demoFiles {
            let coords = loadCoordinatesFromGPX(named: name)
            if !coords.isEmpty {
                viewModel.routes.append(
                    Route(coordinates: coords,
                          date: Date.distantPast,
                          workoutType: .walking,
                          durationSec: 0)
                )
            }
        }
        viewModel.hasContent = !viewModel.routes.isEmpty
    }

    private func prepareRouteExport() {
        guard !viewModel.routes.isEmpty else {
            showRouteTransferMessage("No routes to export")
            return
        }

        do {
            routeExportDocument = RunMapRoutesDocument(
                data: try viewModel.routeStorage.exportData(for: viewModel.routes)
            )
            showRouteExporter = true
        } catch {
            showRouteTransferMessage("Export failed: \(error.localizedDescription)")
        }
    }

    private func importRoutes(from result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let importedRoutes = try viewModel.routeStorage.importRoutes(from: url)
                guard !importedRoutes.isEmpty else {
                    showRouteTransferMessage("No routes found in file")
                    return
                }

                viewModel.importRoutes(importedRoutes)
                showNoWorkouts = false
                showRouteTransferMessage("Imported \(importedRoutes.count) routes")
                achievementsManager.prepareForFeatureUse(routes: viewModel.routes)
            } catch {
                showRouteTransferMessage("Import failed: \(error.localizedDescription)")
            }
        case .failure(let error):
            showRouteTransferMessage("Import failed: \(error.localizedDescription)")
        }
    }

    private func showRouteTransferMessage(_ message: String) {
        withAnimation {
            routeTransferMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation {
                if routeTransferMessage == message {
                    routeTransferMessage = nil
                }
            }
        }
    }

    private func markLatestDayRoutes() {
        guard let latest = viewModel.routes.sorted(by: { $0.date > $1.date }).first else { return }
        let calendar = Calendar.current
        let routesFromLatestDay = viewModel.routes.filter { route in
            calendar.isDate(route.date, inSameDayAs: latest.date)
        }

        highlightedRouteIDs = Set(routesFromLatestDay.map { $0.id })
        selectedDistrictOverlay = nil
        showAllBerlinDistricts = false
        showAllBerlinStadtteile = false

        let allCoordinates = routesFromLatestDay.flatMap { $0.coordinates }
        region = coordinateRegion(for: allCoordinates)

        showLatestDayLabel = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showLatestDayLabel = false
        }
    }

    private func clearMapMarks() {
        highlightedRouteIDs.removeAll()
        selectedDistrictOverlay = nil
        showAllBerlinDistricts = false
        showAllBerlinStadtteile = false
        showLatestDayLabel = false
    }

    private func presentPendingLaunchSummary() {
        guard let pending = pendingLaunchSummary else { return }
        pendingLaunchSummary = nil

        launchSummary = LaunchSummaryData(
            newWalkCount: pending.newWalkCount,
            newDistanceKm: pending.newDistanceKm,
            newRoutes: pending.newRoutes,
            runningKPI: pending.runningKPI,
            walkingKPI: pending.walkingKPI,
            newStreetNames: achievementsManager.newlyCoveredStreetNames,
            newDistrictNames: achievementsManager.newlyVisitedDistrictNames,
            newStadtteilNames: achievementsManager.newlyVisitedStadtteilNames,
            touchedAreaCount: pending.touchedAreaCount
        )
    }

    private func showLaunchRoutesOnMap(_ routes: [Route]) {
        guard !routes.isEmpty else { return }
        highlightedRouteIDs = Set(routes.map(\.id))
        selectedDistrictOverlay = nil
        showAllBerlinDistricts = false
        showAllBerlinStadtteile = false

        let allCoordinates = routes.flatMap(\.coordinates)
        if !allCoordinates.isEmpty {
            withAnimation(.easeInOut(duration: 0.8)) {
                region = coordinateRegion(for: allCoordinates)
            }
        }
    }

    private func launchWorkoutKPI(for routes: [Route], type: HKWorkoutActivityType) -> LaunchWorkoutKPI {
        let matchingRoutes = routes.filter { $0.workoutType == type }
        return LaunchWorkoutKPI(
            count: matchingRoutes.count,
            distanceKm: matchingRoutes.map(\.distanceKm).reduce(0, +),
            durationSec: matchingRoutes.map(\.durationSec).reduce(0, +)
        )
    }

    private func navigateToLocation(country: String, city: String) {
        print("🗺️ Navigating to: country='\(country)', city='\(city)'")
        
        // Find routes that match the selected location
        var matchingRoutes: [Route] = []
        
        // Safely iterate through routes
        for route in viewModel.routes {
            guard !route.coordinates.isEmpty else { continue }
            
            // Sample multiple points from the route for better accuracy
            let sampleCount = min(5, route.coordinates.count)
            let step = max(1, route.coordinates.count / sampleCount)
            
            var routeMatches = false
            for i in stride(from: 0, to: route.coordinates.count, by: step) {
                let coord = route.coordinates[i]
                guard coord.latitude.isFinite && coord.longitude.isFinite else { continue }
                
                let geocodeResult = LocalGeocoder.geocode(latitude: coord.latitude, longitude: coord.longitude)
                
                // Debug: print geocoding result for first sample point
                if i == 0 {
                    print("📍 Route \(route.id): geocoded as '\(geocodeResult.country)' / '\(geocodeResult.city)'")
                }
                
                // If we're looking for a specific city, match both country and city
                if !city.isEmpty && city != "Unknown" {
                    if !country.isEmpty && geocodeResult.country == country && geocodeResult.city == city {
                        print("✅ City match found: \(geocodeResult.country) / \(geocodeResult.city)")
                        routeMatches = true
                        break
                    } else if country.isEmpty && geocodeResult.city == city {
                        // City-only search (when country is empty)
                        print("✅ City-only match found: \(geocodeResult.city) in \(geocodeResult.country)")
                        routeMatches = true
                        break
                    }
                } else if !country.isEmpty {
                    // If only country is specified, match just the country
                    if geocodeResult.country == country {
                        print("✅ Country match found: \(geocodeResult.country)")
                        routeMatches = true
                        break
                    }
                }
            }
            
            if routeMatches {
                matchingRoutes.append(route)
            }
        }
        
        // Navigate to the matching routes
        print("🔍 Found \(matchingRoutes.count) matching routes")
        if !matchingRoutes.isEmpty {
            // Create a region that encompasses the entire country/city, not just the routes
            let targetRegion = createRegionForLocation(country: country, city: city, routes: matchingRoutes)
            print("🎯 Target region: center=\(targetRegion.center), span=\(targetRegion.span)")
            
            print("🔄 About to update region state from \(region.center) to \(targetRegion.center)")
            withAnimation(.easeInOut(duration: 1.0)) {
                region = targetRegion
            }
            print("🔄 Region state updated to \(region.center)")
            
            // Highlight the matching routes
            highlightedRouteIDs = Set(matchingRoutes.map { $0.id })
            print("✨ Highlighted \(highlightedRouteIDs.count) routes")
            
            // Show label briefly
            showLatestDayLabel = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                showLatestDayLabel = false
            }
        } else {
            print("⚠️ No matching routes found for country='\(country)', city='\(city)'")
        }
        
        // Dismiss the stats sheet
        showStats = false
    }
    
    private func createRegionForLocation(country: String, city: String, routes: [Route]) -> MKCoordinateRegion {
        // Get all coordinates from the routes to determine the center
        let allCoords = routes.flatMap { $0.coordinates }
        guard !allCoords.isEmpty else {
            // Fallback to world view if no coordinates
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
            )
        }
        
        // Calculate the center from route coordinates
        let centerLat = allCoords.map { $0.latitude }.reduce(0, +) / Double(allCoords.count)
        let centerLon = allCoords.map { $0.longitude }.reduce(0, +) / Double(allCoords.count)
        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
        
        // Determine appropriate span based on location type
        let span: MKCoordinateSpan
        
        if !city.isEmpty && city != "Unknown" {
            // City view - smaller span
            span = MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        } else {
            // Country view - larger span based on country
            span = getCountrySpan(for: country, center: center)
        }
        
        return MKCoordinateRegion(center: center, span: span)
    }
    
    private func getCountrySpan(for country: String, center: CLLocationCoordinate2D) -> MKCoordinateSpan {
        // Define spans for different countries/regions
        switch country {
        case "United States":
            return MKCoordinateSpan(latitudeDelta: 25, longitudeDelta: 40)
        case "Canada":
            return MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 60)
        case "Russia":
            return MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 100)
        case "China":
            return MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40)
        case "Brazil":
            return MKCoordinateSpan(latitudeDelta: 25, longitudeDelta: 30)
        case "Australia":
            return MKCoordinateSpan(latitudeDelta: 25, longitudeDelta: 35)
        case "India":
            return MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 25)
        case "Germany", "France", "United Kingdom", "Italy", "Spain":
            return MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 10)
        case "Japan":
            return MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 15)
        default:
            // Default span for smaller countries or unknown countries
            return MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
        }
    }


}

// MARK: - RouteMapView

struct RouteMapView: UIViewRepresentable {
    var routes: [Route]
    var region: MKCoordinateRegion
    var highlightedRouteIDs: Set<UUID>
    var showUserLocation: Bool
    var mapType: MKMapType
    var districtOverlay: (name: String, lat: Double, lon: Double)? = nil
    var showAllBerlinDistricts: Bool = false
    var visitedBerlinDistricts: Set<String> = []
    var showAllBerlinStadtteile: Bool = false
    var visitedBerlinStadtteile: Set<String> = []
    var streetsByStadtteil: [String: [ConsolidatedStreet]] = [:]
    var onMapReady: () -> Void = {}
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.region = region
        mapView.showsUserLocation = showUserLocation
        mapView.mapType = mapType
        mapView.delegate = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onMapReady()
        }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Update region when it changes (use larger tolerance to ensure updates work)
        if !mapView.region.center.isEqual(to: region.center, tolerance: 0.01) ||
           abs(mapView.region.span.latitudeDelta - region.span.latitudeDelta) > 0.01 ||
           abs(mapView.region.span.longitudeDelta - region.span.longitudeDelta) > 0.01 {
            mapView.setRegion(region, animated: true)
        }

        if mapView.showsUserLocation != showUserLocation {
            mapView.showsUserLocation = showUserLocation
        }

        if mapView.mapType != mapType {
            mapView.mapType = mapType
        }

        context.coordinator.reconcileDistrictOverlays(
            on: mapView,
            districtOverlay: districtOverlay,
            showAllBerlinDistricts: showAllBerlinDistricts,
            visitedBerlinDistricts: visitedBerlinDistricts
        )

        context.coordinator.reconcileStadtteilOverlays(
            on: mapView,
            showAllBerlinStadtteile: showAllBerlinStadtteile,
            visitedBerlinStadtteile: visitedBerlinStadtteile,
            streetsByStadtteil: streetsByStadtteil
        )

        context.coordinator.reconcileRoutes(
            on: mapView,
            routes: routes,
            highlightedRouteIDs: highlightedRouteIDs
        )
    }

    // Create the coordinator that acts as MKMapViewDelegate
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.cancelRouteRendering()
        uiView.delegate = nil
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        private var districtOverlayKey: String?
        private var districtOverlays: [MKOverlay] = []
        private var districtAnnotations: [MKAnnotation] = []
        private var stadtteilOverlayKey: String?
        private var stadtteilOverlays: [MKOverlay] = []
        private var stadtteilAnnotations: [MKAnnotation] = []
        private var routeRenderKey: Int?
        private var routeRenderGeneration = 0
        private var routeRenderStartedAt = CFAbsoluteTimeGetCurrent()
        private var routeOverlays: [MKOverlay] = []
        private var routeGroupActivity: [ObjectIdentifier: HKWorkoutActivityType] = [:]

        init(_ parent: RouteMapView) { self.parent = parent }

        func reconcileRoutes(
            on mapView: MKMapView,
            routes: [Route],
            highlightedRouteIDs: Set<UUID>
        ) {
            var hasher = Hasher()
            hasher.combine(routes.count)
            for route in routes {
                hasher.combine(route.id)
                hasher.combine(route.workoutType.rawValue)
                hasher.combine(highlightedRouteIDs.contains(route.id))
            }
            let nextKey = hasher.finalize()
            guard nextKey != routeRenderKey else { return }
            routeRenderKey = nextKey
            routeRenderGeneration += 1
            let generation = routeRenderGeneration
            routeRenderStartedAt = CFAbsoluteTimeGetCurrent()

            if !routeOverlays.isEmpty {
                mapView.removeOverlays(routeOverlays)
                routeOverlays.removeAll(keepingCapacity: true)
                routeGroupActivity.removeAll(keepingCapacity: true)
            }

            let highlightedRoutes = routes.filter { highlightedRouteIDs.contains($0.id) }
            let regularRoutes = routes.filter { !highlightedRouteIDs.contains($0.id) }

            var immediateOverlays: [MKOverlay] = []
            for route in highlightedRoutes {
                let polyline = RoutePolyline.fromCoordinates(route.coordinates)
                polyline.routeID = route.id
                polyline.routeDate = route.date
                polyline.workoutType = route.workoutType
                polyline.isHighlighted = true
                polyline.averageSpeed = route.averageSpeedKmH
                routeOverlays.append(polyline)
                immediateOverlays.append(polyline)
            }

            if !immediateOverlays.isEmpty {
                mapView.addOverlays(immediateOverlays)
            }

            // Add all historical routes progressively. Each small batch yields to the
            // run loop so a large archive cannot trip the launch watchdog or freeze map
            // gestures. Geometry is display-simplified only; the stored route stays intact.
            appendRouteBatch(
                on: mapView,
                routes: regularRoutes,
                startIndex: 0,
                generation: generation
            )
            if regularRoutes.isEmpty {
                logCompletedRouteRender(routeCount: routes.count, generation: generation)
            }
        }

        func cancelRouteRendering() {
            routeRenderGeneration += 1
        }

        private func appendRouteBatch(
            on mapView: MKMapView,
            routes: [Route],
            startIndex: Int,
            generation: Int
        ) {
            guard generation == routeRenderGeneration, startIndex < routes.count else { return }

            let batchSize = 60
            let endIndex = min(startIndex + batchSize, routes.count)
            let grouped = Dictionary(grouping: routes[startIndex..<endIndex], by: { $0.workoutType.rawValue })
            var newOverlays: [MKOverlay] = []

            for (rawActivity, activityRoutes) in grouped {
                let polylines = activityRoutes.map { route -> MKPolyline in
                    let coordinates = RouteRenderCoordinateSimplifier.simplified(route.coordinates)
                    return MKPolyline(coordinates: coordinates, count: coordinates.count)
                }
                guard !polylines.isEmpty else { continue }
                let multiPolyline = MKMultiPolyline(polylines)
                routeGroupActivity[ObjectIdentifier(multiPolyline)] =
                    HKWorkoutActivityType(rawValue: rawActivity) ?? .other
                routeOverlays.append(multiPolyline)
                newOverlays.append(multiPolyline)
            }

            if !newOverlays.isEmpty {
                mapView.addOverlays(newOverlays)
            }

            guard endIndex < routes.count else {
                logCompletedRouteRender(routeCount: routes.count, generation: generation)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.appendRouteBatch(
                    on: mapView,
                    routes: routes,
                    startIndex: endIndex,
                    generation: generation
                )
            }
        }

        private func logCompletedRouteRender(routeCount: Int, generation: Int) {
            guard generation == routeRenderGeneration else { return }
            RunMapPerformanceMetrics.log(
                "route_map_progressive_render",
                seconds: CFAbsoluteTimeGetCurrent() - routeRenderStartedAt,
                metadata: "routes=\(routeCount) overlays=\(routeOverlays.count)"
            )
        }

        func reconcileDistrictOverlays(
            on mapView: MKMapView,
            districtOverlay: (name: String, lat: Double, lon: Double)?,
            showAllBerlinDistricts: Bool,
            visitedBerlinDistricts: Set<String>
        ) {
            let nextKey: String
            if showAllBerlinDistricts {
                nextKey = "all:\(visitedBerlinDistricts.sorted().joined(separator: "|"))"
            } else if let districtOverlay {
                let visitedFlag = visitedBerlinDistricts.contains(districtOverlay.name) ? "visited" : "notVisited"
                nextKey = "single:\(districtOverlay.name):\(visitedFlag)"
            } else {
                nextKey = "none"
            }

            guard nextKey != districtOverlayKey else { return }

            if !districtOverlays.isEmpty {
                mapView.removeOverlays(districtOverlays)
                districtOverlays.removeAll(keepingCapacity: true)
            }
            if !districtAnnotations.isEmpty {
                mapView.removeAnnotations(districtAnnotations)
                districtAnnotations.removeAll(keepingCapacity: true)
            }

            districtOverlayKey = nextKey
            guard nextKey != "none" else { return }

            let districtsToRender: [(name: String, lat: Double, lon: Double)]
            if showAllBerlinDistricts {
                districtsToRender = BerlinDistricts.districts.map { ($0.name, $0.lat, $0.lon) }
            } else if let districtOverlay {
                districtsToRender = [districtOverlay]
            } else {
                districtsToRender = []
            }

            for district in districtsToRender {
                let center = CLLocationCoordinate2D(latitude: district.lat, longitude: district.lon)
                let ann = DistrictAnnotation()
                ann.coordinate = center
                ann.title = district.name
                ann.subtitle = "District Label"
                districtAnnotations.append(ann)

                if let boundary = BerlinDistricts.boundaries.first(where: { $0.name == district.name }) {
                    for polygon in boundary.polygons {
                        if let outer = polygon.first, outer.count >= 3 {
                            let mkPolygon = DistrictPolygon(coordinates: outer, count: outer.count)
                            mkPolygon.districtName = district.name
                            mkPolygon.colorIndex = BerlinDistricts.districts.firstIndex(where: { $0.name == district.name }) ?? 0
                            mkPolygon.isVisited = visitedBerlinDistricts.contains(district.name)
                            districtOverlays.append(mkPolygon)
                        }
                    }
                }
            }

            if !districtAnnotations.isEmpty {
                mapView.addAnnotations(districtAnnotations)
            }
            if !districtOverlays.isEmpty {
                mapView.addOverlays(districtOverlays)
            }
        }

        func reconcileStadtteilOverlays(
            on mapView: MKMapView,
            showAllBerlinStadtteile: Bool,
            visitedBerlinStadtteile: Set<String>,
            streetsByStadtteil: [String: [ConsolidatedStreet]]
        ) {
            let nextKey: String
            if showAllBerlinStadtteile {
                nextKey = "all:\(streetsByStadtteil.count):\(visitedBerlinStadtteile.sorted().joined(separator: "|"))"
            } else {
                nextKey = "none"
            }

            guard nextKey != stadtteilOverlayKey else { return }

            if !stadtteilOverlays.isEmpty {
                mapView.removeOverlays(stadtteilOverlays)
                stadtteilOverlays.removeAll(keepingCapacity: true)
            }
            if !stadtteilAnnotations.isEmpty {
                mapView.removeAnnotations(stadtteilAnnotations)
                stadtteilAnnotations.removeAll(keepingCapacity: true)
            }

            stadtteilOverlayKey = nextKey
            guard showAllBerlinStadtteile else { return }

            let overlaySource = streetsByStadtteil.isEmpty
                ? BerlinStadtteilBoundaryBuilder.fallbackStreetsByStadtteil()
                : streetsByStadtteil
            let boundaries = BerlinStadtteilBoundaryBuilder.boundaries(from: overlaySource)
            for boundary in boundaries {
                let isVisited = visitedBerlinStadtteile.contains(boundary.name)

                let annotation = StadtteilAnnotation()
                annotation.coordinate = boundary.center
                annotation.title = boundary.name
                annotation.subtitle = "Stadtteil Label"
                annotation.isVisited = isVisited
                stadtteilAnnotations.append(annotation)

                for rings in boundary.polygons {
                    guard let outerRing = rings.first, outerRing.count >= 3 else { continue }
                    let holes = rings.dropFirst().map { hole in
                        MKPolygon(coordinates: hole, count: hole.count)
                    }
                    let polygon = StadtteilPolygon(
                        coordinates: outerRing,
                        count: outerRing.count,
                        interiorPolygons: holes.isEmpty ? nil : holes
                    )
                    polygon.stadtteilName = boundary.name
                    polygon.isVisited = isVisited
                    stadtteilOverlays.append(polygon)
                }
            }

            if !stadtteilAnnotations.isEmpty {
                mapView.addAnnotations(stadtteilAnnotations)
            }
            if !stadtteilOverlays.isEmpty {
                mapView.addOverlays(stadtteilOverlays)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? DistrictPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = polygon.isVisited
                    ? UIColor.systemGreen.withAlphaComponent(0.95)
                    : UIColor.systemRed.withAlphaComponent(0.95)
                renderer.fillColor = polygon.isVisited
                    ? UIColor.systemGreen.withAlphaComponent(0.30)
                    : UIColor.systemRed.withAlphaComponent(0.28)
                renderer.lineWidth = polygon.isVisited ? 2.4 : 2.8
                renderer.lineDashPattern = polygon.isVisited ? nil : [6, 4]
                return renderer
            }
            if let polygon = overlay as? StadtteilPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = polygon.isVisited
                    ? UIColor.systemGreen.withAlphaComponent(0.95)
                    : UIColor.systemRed.withAlphaComponent(0.90)
                renderer.fillColor = polygon.isVisited
                    ? UIColor.systemGreen.withAlphaComponent(0.24)
                    : UIColor.systemRed.withAlphaComponent(0.22)
                renderer.lineWidth = polygon.isVisited ? 2.2 : 2.4
                renderer.lineDashPattern = polygon.isVisited ? nil : [6, 4]
                return renderer
            }
            if let multiPolyline = overlay as? MKMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
                switch routeGroupActivity[ObjectIdentifier(multiPolyline)] ?? .other {
                case .running:
                    renderer.strokeColor = UIColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.82)
                case .walking:
                    renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.76)
                default:
                    renderer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.76)
                }
                renderer.lineWidth = 3
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            guard let polyline = overlay as? RoutePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            
            let renderer = MKPolylineRenderer(polyline: polyline)
            if polyline.isHighlighted {
                renderer.strokeColor = .orange
            } else {
                switch polyline.workoutType {
                case .running:
                    renderer.strokeColor = UIColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 1.0) // Bright blue
                case .walking:
                    renderer.strokeColor = .systemBlue
                default:
                    renderer.strokeColor = .systemGreen
                }
            }
            renderer.lineWidth = 4
            return renderer
        }
        
        // Custom label-only annotation views for district labels
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation else { return nil }
            guard point.subtitle == "District Label" || point.subtitle == "Stadtteil Label" else { return nil }
            let isStadtteil = point.subtitle == "Stadtteil Label"
            let isVisited = (point as? StadtteilAnnotation)?.isVisited ?? false
            let identifier = isStadtteil ? "StadtteilLabelView" : "DistrictLabelView"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = false
            view.image = nil
            // Remove previous subviews
            view.subviews.forEach { $0.removeFromSuperview() }
            // Add a label
            let label = UILabel()
            label.text = point.title ?? ""
            label.font = UIFont.systemFont(ofSize: isStadtteil ? 10 : 12, weight: .semibold)
            label.textColor = isStadtteil
                ? (isVisited ? UIColor.systemGreen : UIColor.secondaryLabel)
                : UIColor.systemBlue
            label.backgroundColor = UIColor.white.withAlphaComponent(isStadtteil ? 0.7 : 0.6)
            label.layer.cornerRadius = 4
            label.layer.masksToBounds = true
            label.numberOfLines = 1
            label.sizeToFit()
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }
    }
}


struct RouteListView: View {
    var routes: [Route]
    var select: (Route) -> Void
    
    var body: some View {
        NavigationView {
            List {
                ForEach(routes.sorted(by: { $0.date > $1.date })) { route in
                    Button {
                        select(route)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(route.date, style: .date)
                            Text(String(format: "%.2f km", route.distanceKm))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    var dismiss: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var maxContentWidth: CGFloat {
        horizontalSizeClass == .regular ? 520 : .infinity
    }

    private var iconHeight: CGFloat {
        horizontalSizeClass == .regular ? 150 : 120
    }

    var body: some View {
        TabView {
            VStack(spacing: 24) {
                Image(systemName: "map")
                    .resizable().scaledToFit().frame(height: iconHeight)
                Text("See all your runs and walks on a beautiful map.")
                    .font(.title3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: maxContentWidth)
            .padding()

            VStack(spacing: 24) {
                Image(systemName: "arrow.clockwise.circle")
                    .resizable().scaledToFit().frame(height: iconHeight)
                Text("Sync workouts from HealthKit and see your saved routes on the map.")
                    .font(.title3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: maxContentWidth)
            .padding()

            VStack(spacing: 24) {
                Image(systemName: "highlighter")
                    .resizable().scaledToFit().frame(height: iconHeight)
                Text("Tap the highlighter to jump to your latest day's workouts.\nLong‑press to clear the highlight.")
                    .font(.title3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: maxContentWidth)
            .padding()

            VStack(spacing: 24) {
                Image(systemName: "plus.circle")
                    .resizable().scaledToFit().frame(height: iconHeight)
                Text("All controls are tucked under the + button.\nTap to expand, tap × to hide.")
                    .font(.title3).multilineTextAlignment(.center)

                Button("Get Started") {
                    dismiss()
                }
                .font(.headline)
                .padding(.horizontal, 32).padding(.vertical, 12)
                .background(Color.blue).foregroundColor(.white)
                .clipShape(Capsule())
            }
            .frame(maxWidth: maxContentWidth)
            .padding()
        }
        .tabViewStyle(PageTabViewStyle())
    }
}

// MARK: - No Workouts View
struct NoWorkoutsView: View {
    var title: String = "No workouts found"
    var message: String = "Connect to Health and record a run or tap below to load a couple of demo workouts to see the app in action."
    var loadDemoAndDismiss: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var maxContentWidth: CGFloat {
        horizontalSizeClass == .regular ? 520 : .infinity
    }

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "figure.walk.motion")
                .resizable().scaledToFit().frame(height: 120)
                .foregroundColor(.blue)

            Text(title)
                .font(.title).bold()

            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Load Demo Workouts") {
                loadDemoAndDismiss()
            }
            .font(.headline)
            .padding(.horizontal, 32).padding(.vertical, 12)
            .background(Color.blue).foregroundColor(.white)
            .clipShape(Capsule())
        }
        .frame(maxWidth: maxContentWidth)
        .padding()
    }
}

// MARK: - GPX Parsing

import Foundation

func loadCoordinatesFromGPX(named fileName: String) -> [CLLocationCoordinate2D] {
    guard let url = Bundle.main.url(forResource: fileName, withExtension: "gpx"),
          let data = try? Data(contentsOf: url) else {
        return []
    }
    let xml = XMLParser(data: data)

    let delegate = GPXParserDelegate()
    xml.delegate = delegate
    xml.parse()
    return delegate.coordinates
}

private class GPXParserDelegate: NSObject, XMLParserDelegate {
    var coordinates: [CLLocationCoordinate2D] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        if elementName == "trkpt",
           let latStr = attributeDict["lat"],
           let lonStr = attributeDict["lon"],
           let lat = Double(latStr),
           let lon = Double(lonStr) {
            coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }
}

extension CLLocationCoordinate2D {
    func isEqual(to other: CLLocationCoordinate2D, tolerance: Double) -> Bool {
        return abs(latitude - other.latitude) < tolerance &&
               abs(longitude - other.longitude) < tolerance
    }
}
