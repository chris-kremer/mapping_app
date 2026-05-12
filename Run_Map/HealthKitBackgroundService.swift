import Foundation
import HealthKit
import CoreLocation

extension Notification.Name {
    static let runMapHealthKitBackgroundImportDidFinish = Notification.Name("runMapHealthKitBackgroundImportDidFinish")
}

final class RunMapHealthKitBackgroundService {
    static let shared = RunMapHealthKitBackgroundService()

    private let healthStore = HKHealthStore()
    private let routeStorage = RouteStorage()
    private let stateQueue = DispatchQueue(label: "runmap.healthkit.background.state")
    private var observerQuery: HKObserverQuery?
    private var isStarted = false
    private var isImporting = false
    private var pendingCompletionHandlers: [HKObserverQueryCompletionHandler] = []

    private init() {}

    func start() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let shouldStart: Bool = stateQueue.sync {
            guard !isStarted else { return false }
            isStarted = true
            return true
        }

        let workoutType = HKObjectType.workoutType()
        if shouldStart {
            let observer = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completionHandler, error in
                if let error {
                    print("⚠️ HealthKit background workout observer error: \(error.localizedDescription)")
                    completionHandler()
                    return
                }

                self?.handleWorkoutStoreChange(completionHandler: completionHandler)
            }

            observerQuery = observer
            healthStore.execute(observer)
        }

        healthStore.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { success, error in
            if let error {
                print("⚠️ Failed to enable HealthKit workout background delivery: \(error.localizedDescription)")
            } else {
                print(success ? "✅ HealthKit workout background delivery enabled" : "⚠️ HealthKit workout background delivery not enabled")
            }
        }
    }

    private func handleWorkoutStoreChange(completionHandler: @escaping HKObserverQueryCompletionHandler) {
        let shouldImport: Bool = stateQueue.sync {
            pendingCompletionHandlers.append(completionHandler)
            guard !isImporting else { return false }
            isImporting = true
            return true
        }

        guard shouldImport else { return }

        importNewWorkoutRoutes(reason: "healthkit_background") { [weak self] summary in
            guard let self else { return }
            self.finishImport(summary: summary)
        }
    }

    private func finishImport(summary: RunMapBackgroundImportSummary) {
        if summary.addedRouteCount > 0 {
            NotificationCenter.default.post(
                name: .runMapHealthKitBackgroundImportDidFinish,
                object: self,
                userInfo: [
                    "addedRouteCount": summary.addedRouteCount,
                    "totalRouteCount": summary.totalRouteCount
                ]
            )
            processAchievementsInBackground(routes: summary.routes)
        }

        let completions: [HKObserverQueryCompletionHandler] = stateQueue.sync {
            isImporting = false
            let completions = pendingCompletionHandlers
            pendingCompletionHandlers.removeAll(keepingCapacity: true)
            return completions
        }

        completions.forEach { $0() }
    }

    private func importNewWorkoutRoutes(
        reason: String,
        completion: @escaping (RunMapBackgroundImportSummary) -> Void
    ) {
        let cachedRoutes = routeStorage.loadRoutes()
        fetchRunningAndWalkingWorkouts { [weak self] workouts in
            guard let self else {
                completion(.empty)
                return
            }

            let newWorkouts = workouts.filter { workout in
                !cachedRoutes.contains { route in
                    abs(route.date.timeIntervalSince1970 - workout.startDate.timeIntervalSince1970) < 1.0
                }
            }

            guard !newWorkouts.isEmpty else {
                print("ℹ️ HealthKit background import found no new workouts")
                completion(RunMapBackgroundImportSummary(
                    addedRouteCount: 0,
                    totalRouteCount: cachedRoutes.count,
                    routes: cachedRoutes
                ))
                return
            }

            print("🆕 HealthKit background import checking \(newWorkouts.count) new workouts (\(reason))")
            var importedRoutes: [Route] = []
            let group = DispatchGroup()
            let lock = NSLock()

            for workout in newWorkouts {
                group.enter()
                self.fetchRoute(for: workout) { locations in
                    defer { group.leave() }

                    let coordinates = locations.map(\.coordinate)
                    guard !coordinates.isEmpty else {
                        print("⚠️ Background import skipped workout with no route: \(workout.startDate)")
                        return
                    }

                    let routes = Self.filterRoute(coordinates).compactMap { segment -> Route? in
                        guard segment.count > 1 else { return nil }
                        return Route(
                            coordinates: segment,
                            date: workout.startDate,
                            workoutType: workout.workoutActivityType,
                            durationSec: workout.duration
                        )
                    }

                    lock.lock()
                    importedRoutes.append(contentsOf: routes)
                    lock.unlock()
                }
            }

            group.notify(queue: .global(qos: .utility)) {
                let mergedRoutes = self.deduplicatedRoutes(cachedRoutes + importedRoutes).sorted { $0.date > $1.date }
                if !importedRoutes.isEmpty {
                    self.routeStorage.saveRoutes(mergedRoutes)
                    self.routeStorage.setLastSyncDate(Date())
                    print("✅ HealthKit background import saved \(importedRoutes.count) new routes")
                }

                completion(RunMapBackgroundImportSummary(
                    addedRouteCount: importedRoutes.count,
                    totalRouteCount: mergedRoutes.count,
                    routes: mergedRoutes
                ))
            }
        }
    }

    private func fetchRunningAndWalkingWorkouts(completion: @escaping ([HKWorkout]) -> Void) {
        let workoutType = HKObjectType.workoutType()
        let running = HKQuery.predicateForWorkouts(with: .running)
        let walking = HKQuery.predicateForWorkouts(with: .walking)
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [running, walking])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sort]
        ) { _, samples, error in
            if let error {
                print("⚠️ HealthKit background workout fetch failed: \(error.localizedDescription)")
                completion([])
                return
            }

            completion(samples as? [HKWorkout] ?? [])
        }

        healthStore.execute(query)
    }

    private func fetchRoute(for workout: HKWorkout, completion: @escaping ([CLLocation]) -> Void) {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let query = HKSampleQuery(
            sampleType: HKSeriesType.workoutRoute(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { [weak self] _, samples, error in
            if let error {
                print("⚠️ HealthKit background route fetch failed: \(error.localizedDescription)")
            }

            guard let route = samples?.first as? HKWorkoutRoute else {
                completion([])
                return
            }

            self?.loadRouteLocations(from: route, completion: completion)
        }

        healthStore.execute(query)
    }

    private func loadRouteLocations(from route: HKWorkoutRoute, completion: @escaping ([CLLocation]) -> Void) {
        var locations: [CLLocation] = []
        let query = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
            if let error {
                print("⚠️ HealthKit background route location load failed: \(error.localizedDescription)")
            }

            if let batch {
                locations.append(contentsOf: batch)
            }

            if done {
                completion(locations)
            }
        }

        healthStore.execute(query)
    }

    private func processAchievementsInBackground(routes: [Route]) {
        guard !routes.isEmpty else { return }
        let manager = AchievementsManager()
        manager.checkAndUnlockAchievementsInBackground(routes: routes)
    }

    private func deduplicatedRoutes(_ routes: [Route]) -> [Route] {
        var seen = Set<String>()
        return routes.filter { route in
            let first = route.coordinates.first
            let last = route.coordinates.last
            let key = [
                String(Int(route.date.timeIntervalSince1970.rounded())),
                String(route.coordinates.count),
                String(format: "%.6f", first?.latitude ?? 0),
                String(format: "%.6f", first?.longitude ?? 0),
                String(format: "%.6f", last?.latitude ?? 0),
                String(format: "%.6f", last?.longitude ?? 0)
            ].joined(separator: "_")
            return seen.insert(key).inserted
        }
    }

    private static func filterRoute(
        _ coordinates: [CLLocationCoordinate2D],
        maxDistance: CLLocationDistance = 20
    ) -> [[CLLocationCoordinate2D]] {
        guard coordinates.count > 1 else { return [coordinates] }

        var segments: [[CLLocationCoordinate2D]] = []
        var currentSegment = [coordinates[0]]

        for index in 1..<coordinates.count {
            let previous = CLLocation(latitude: coordinates[index - 1].latitude, longitude: coordinates[index - 1].longitude)
            let current = CLLocation(latitude: coordinates[index].latitude, longitude: coordinates[index].longitude)

            if previous.distance(from: current) <= maxDistance {
                currentSegment.append(coordinates[index])
            } else {
                if currentSegment.count > 1 {
                    segments.append(currentSegment)
                }
                currentSegment = [coordinates[index]]
            }
        }

        if currentSegment.count > 1 {
            segments.append(currentSegment)
        }

        return segments
    }
}

private struct RunMapBackgroundImportSummary {
    let addedRouteCount: Int
    let totalRouteCount: Int
    let routes: [Route]

    static let empty = RunMapBackgroundImportSummary(
        addedRouteCount: 0,
        totalRouteCount: 0,
        routes: []
    )
}
