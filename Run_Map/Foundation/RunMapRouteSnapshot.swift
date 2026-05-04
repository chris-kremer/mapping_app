import Foundation

struct RunMapRouteSnapshot: Codable, Equatable, Identifiable {
    enum Activity: String, Codable, Equatable {
        case running
        case walking
        case other
    }

    let id: String
    let startDate: Date
    let activity: Activity
    let durationSeconds: Double
    let coordinates: [RunMapCoordinate]

    var distanceMeters: Double {
        guard coordinates.count > 1 else { return 0 }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) { partial, pair in
            partial + pair.0.distanceMeters(to: pair.1)
        }
    }
}

enum RunMapRouteNormalizer {
    static func stableID(startDate: Date, activity: RunMapRouteSnapshot.Activity, coordinateCount: Int) -> String {
        "\(Int(startDate.timeIntervalSince1970))|\(activity.rawValue)|\(coordinateCount)"
    }

    static func splitValidSegments(
        coordinates: [RunMapCoordinate],
        maxGapMeters: Double = 20.0
    ) -> [[RunMapCoordinate]] {
        let valid = coordinates.filter(\.isValid)
        guard valid.count > 1 else { return valid.isEmpty ? [] : [valid] }

        var segments: [[RunMapCoordinate]] = []
        var current = [valid[0]]

        for coordinate in valid.dropFirst() {
            if let previous = current.last, previous.distanceMeters(to: coordinate) <= maxGapMeters {
                current.append(coordinate)
            } else {
                if current.count > 1 {
                    segments.append(current)
                }
                current = [coordinate]
            }
        }

        if current.count > 1 {
            segments.append(current)
        }

        return segments
    }
}

