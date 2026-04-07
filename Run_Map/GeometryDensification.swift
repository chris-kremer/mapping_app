import Foundation
import CoreLocation

/// Helper utilities for densifying street geometry to improve coverage detection accuracy
struct GeometryDensification {

    /// Densifies a sequence of coordinates by adding interpolated points between existing ones
    /// - Parameters:
    ///   - coords: Original coordinates
    ///   - maxDistanceMeters: Maximum distance between consecutive points (default 5m)
    /// - Returns: Densified coordinate array with interpolated points
    static func densifyCoordinates(_ coords: [BerlinStreets.SimpleCoordinate], maxDistanceMeters: Double = 5.0) -> [BerlinStreets.SimpleCoordinate] {
        guard coords.count >= 2 else { return coords }

        var densified: [BerlinStreets.SimpleCoordinate] = []

        for i in 0..<(coords.count - 1) {
            let start = CLLocation(latitude: coords[i].lat, longitude: coords[i].lon)
            let end = CLLocation(latitude: coords[i + 1].lat, longitude: coords[i + 1].lon)
            let distance = start.distance(from: end)

            // Always add the current point
            densified.append(coords[i])

            // If distance is larger than max, add interpolated points
            if distance > maxDistanceMeters {
                let numIntermediatePoints = Int(ceil(distance / maxDistanceMeters)) - 1

                for j in 1...numIntermediatePoints {
                    let fraction = Double(j) / Double(numIntermediatePoints + 1)
                    let lat = coords[i].lat + (coords[i + 1].lat - coords[i].lat) * fraction
                    let lon = coords[i].lon + (coords[i + 1].lon - coords[i].lon) * fraction
                    densified.append(BerlinStreets.SimpleCoordinate(lat: lat, lon: lon))
                }
            }
        }

        // Add last point
        densified.append(coords[coords.count - 1])

        return densified
    }

    /// Calculate statistics about coordinate spacing
    static func analyzeCoordinateSpacing(_ coords: [BerlinStreets.SimpleCoordinate]) -> (min: Double, max: Double, avg: Double, total: Int) {
        guard coords.count >= 2 else {
            return (0, 0, 0, coords.count)
        }

        var distances: [Double] = []

        for i in 0..<(coords.count - 1) {
            let start = CLLocation(latitude: coords[i].lat, longitude: coords[i].lon)
            let end = CLLocation(latitude: coords[i + 1].lat, longitude: coords[i + 1].lon)
            distances.append(start.distance(from: end))
        }

        return (
            min: distances.min() ?? 0,
            max: distances.max() ?? 0,
            avg: distances.isEmpty ? 0 : distances.reduce(0, +) / Double(distances.count),
            total: coords.count
        )
    }

    /// Explains the current simplification factor used in parsing
    static func explainSimplificationImpact() -> String {
        """
        CURRENT GEOMETRY SIMPLIFICATION:

        In AchievementsView.swift:357, streets are parsed with simplificationFactor = 2
        This means only every 2nd coordinate from the GeoJSON is kept.

        IMPACT:
        - If GeoJSON has points every 10m, simplified version has points every 20m
        - If GeoJSON has points every 20m, simplified version has points every 40m
        - With a 20m detection radius, gaps of 40m could miss some streets

        SOLUTION OPTIONS:
        1. Reduce simplificationFactor from 2 to 1 (no simplification) - doubles memory usage
        2. Use densification (this module) to add points at runtime - adds computation time
        3. Change simplificationFactor to use max distance instead of skip count

        RECOMMENDATION:
        Use densification at 5-10m intervals for more accurate coverage detection.
        """
    }
}
