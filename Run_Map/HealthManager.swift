import Foundation
import HealthKit
import CoreLocation

enum RunMapHealthKitAccess: Equatable {
    case authorized
    case denied
    case unavailable
}

struct RunMapHealthRouteSample {
    let id: UUID
    let startDate: Date
    let locations: [CLLocation]
}

class HealthKitManager: ObservableObject {
    private let healthStore = HKHealthStore()
    
    @Published var workouts: [HKWorkout] = []

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }
    
    func requestAuthorization(completion: @escaping (RunMapHealthKitAccess) -> Void) {
        guard isHealthDataAvailable else {
            DispatchQueue.main.async {
                completion(.unavailable)
            }
            return
        }
        
        let readTypes: Set = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        
        healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
            if let error = error {
                print("❌ Authorization failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                completion(success ? .authorized : .denied)
            }
        }
    }
    
    func fetchWorkouts() {
        let type = HKObjectType.workoutType()
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 30, sortDescriptors: [sort]) { [weak self] _, samples, error in
            if let error = error {
                print("❌ Failed to fetch workouts: \(error.localizedDescription)")
                return
            }
            guard let workouts = samples as? [HKWorkout] else { return }
            DispatchQueue.main.async {
                self?.workouts = workouts
            }
        }
        healthStore.execute(query)
    }
    
    func fetchRoute(for workout: HKWorkout, completion: @escaping ([CLLocation]) -> Void) {
        fetchRouteSamples(for: workout) { samples in
            completion(samples.flatMap(\.locations))
        }
    }

    /// Loads every route sample attached to a workout. HealthKit may split one workout
    /// into multiple `HKWorkoutRoute` samples, so reading only the first loses history.
    func fetchRouteSamples(
        for workout: HKWorkout,
        completion: @escaping ([RunMapHealthRouteSample]) -> Void
    ) {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let routeQuery = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, error in
            if let error = error {
                print("❌ Failed to fetch workout route: \(error.localizedDescription)")
            }
            let workoutRoutes = samples as? [HKWorkoutRoute] ?? []
            guard !workoutRoutes.isEmpty else {
                DispatchQueue.main.async {
                    completion([])
                }
                return
            }
            guard let self else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let group = DispatchGroup()
            let lock = NSLock()
            var loaded: [RunMapHealthRouteSample] = []

            for route in workoutRoutes {
                group.enter()
                self.loadRouteLocations(from: route) { locations in
                    lock.lock()
                    loaded.append(RunMapHealthRouteSample(
                        id: route.uuid,
                        startDate: route.startDate,
                        locations: locations
                    ))
                    lock.unlock()
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                completion(loaded.sorted { $0.startDate < $1.startDate })
            }
        }
        healthStore.execute(routeQuery)
    }
    
    private func loadRouteLocations(from route: HKWorkoutRoute, completion: @escaping ([CLLocation]) -> Void) {
        var allLocations: [CLLocation] = []
        let routeQuery = HKWorkoutRouteQuery(route: route) { _, locationsOrNil, done, error in
            if let locations = locationsOrNil {
                allLocations.append(contentsOf: locations)
            }
            if done {
                DispatchQueue.main.async {
                    completion(allLocations)
                }
            }
        }
        healthStore.execute(routeQuery)
    }
    /// Fetch running and walking workouts from HealthKit.
    func fetchRunningWorkouts(limit: Int = 100,
                              completion: @escaping ([HKWorkout]) -> Void) {
        let workoutType = HKObjectType.workoutType()
        
        // Predicates for running and walking
        let running = HKQuery.predicateForWorkouts(with: .running)
        let walking = HKQuery.predicateForWorkouts(with: .walking)
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [running, walking])
        
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let query = HKSampleQuery(sampleType: workoutType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, samples, error in
            if let error = error {
                print("❌ Failed to fetch running/walking workouts: \(error.localizedDescription)")
                DispatchQueue.main.async { completion([]) }
                return
            }
            let workouts = samples as? [HKWorkout] ?? []
            DispatchQueue.main.async { completion(workouts) }
        }
        
        healthStore.execute(query)
    }
}
