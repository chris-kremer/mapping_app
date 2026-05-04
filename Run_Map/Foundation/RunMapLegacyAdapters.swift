import Foundation
import HealthKit

extension RunMapRouteSnapshot.Activity {
    init(workoutType: HKWorkoutActivityType) {
        switch workoutType {
        case .running:
            self = .running
        case .walking:
            self = .walking
        default:
            self = .other
        }
    }
}

extension RunMapRouteSnapshot {
    init(route: Route) {
        let coordinates = route.coordinates.map {
            RunMapCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        let activity = Activity(workoutType: route.workoutType)

        self.init(
            id: RunMapRouteNormalizer.stableID(
                startDate: route.date,
                activity: activity,
                coordinateCount: coordinates.count
            ),
            startDate: route.date,
            activity: activity,
            durationSeconds: route.durationSec,
            coordinates: coordinates
        )
    }
}

extension StreetGeometrySnapshot {
    init(consolidatedStreet: ConsolidatedStreet) {
        let stadtteil = consolidatedStreet.segments.first?.stadtteil ?? "Unknown"
        self.init(
            id: consolidatedStreet.id,
            name: consolidatedStreet.name,
            district: consolidatedStreet.district,
            stadtteil: stadtteil,
            coordinates: consolidatedStreet.segments.flatMap { segment in
                segment.coordinates.map {
                    RunMapCoordinate(latitude: $0.lat, longitude: $0.lon)
                }
            }
        )
    }

    init(street: BerlinStreets.Street) {
        self.init(
            id: "\(street.name)_\(street.district)_\(street.stadtteil)",
            name: street.name,
            district: street.district,
            stadtteil: street.stadtteil,
            coordinates: street.coordinates.map {
                RunMapCoordinate(latitude: $0.lat, longitude: $0.lon)
            }
        )
    }
}

