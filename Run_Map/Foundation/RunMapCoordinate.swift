import Foundation

struct RunMapCoordinate: Codable, Equatable, Hashable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite &&
        longitude.isFinite &&
        (-90.0...90.0).contains(latitude) &&
        (-180.0...180.0).contains(longitude)
    }

    func distanceMeters(to other: RunMapCoordinate) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = latitude * .pi / 180.0
        let lat2 = other.latitude * .pi / 180.0
        let deltaLat = (other.latitude - latitude) * .pi / 180.0
        let deltaLon = (other.longitude - longitude) * .pi / 180.0

        let a = sin(deltaLat / 2.0) * sin(deltaLat / 2.0) +
            cos(lat1) * cos(lat2) * sin(deltaLon / 2.0) * sin(deltaLon / 2.0)
        let c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
        return earthRadiusMeters * c
    }
}

