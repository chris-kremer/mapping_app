import Foundation
import CoreLocation

/// Represents a complete street merged from multiple segments
struct ConsolidatedStreet: Identifiable {
    let id: String // street name + district
    let name: String
    let district: String
    let segments: [BerlinStreets.Street] // All the individual straight-line segments

    var totalLength: Double {
        segments.reduce(0) { $0 + $1.lengthMeters }
    }

    var totalPoints: Int {
        segments.reduce(0) { $0 + $1.coordinates.count }
    }

    var allCoordinates: [BerlinStreets.SimpleCoordinate] {
        segments.flatMap { $0.coordinates }
    }

    /// Calculate coverage percentage for this consolidated street
    func calculateCoverage(using checker: FastStreetChecker, densify: Bool = false) -> CoverageResult {
        var totalCovered = 0
        var totalPoints = 0

        for segment in segments {
            let coords = densify
                ? GeometryDensification.densifyCoordinates(segment.coordinates, maxDistanceMeters: 5.0)
                : segment.coordinates

            let coverage = checker.checkStreetCoverage(streetCoords: coords)
            totalCovered += coverage.filter { $0 }.count
            totalPoints += coverage.count
        }

        let percentage = totalPoints > 0 ? (Double(totalCovered) / Double(totalPoints)) * 100.0 : 0.0

        return CoverageResult(
            coveredPoints: totalCovered,
            totalPoints: totalPoints,
            percentage: percentage,
            segmentCount: segments.count
        )
    }

    struct CoverageResult: Codable {
        let coveredPoints: Int
        let totalPoints: Int
        let percentage: Double
        let segmentCount: Int

        var isFullyCovered: Bool {
            percentage >= 99.0 // Allow small rounding errors
        }

        var isPartiallyCovered: Bool {
            percentage > 0 && percentage < 99.0
        }

        var isUncovered: Bool {
            percentage == 0
        }
    }
}

/// Helper to consolidate streets by name
class StreetConsolidator {

    /// Consolidate a list of street segments by name
    static func consolidate(streets: [BerlinStreets.Street]) -> [ConsolidatedStreet] {
        var consolidated: [String: [BerlinStreets.Street]] = [:]

        // Group by name + district (some streets exist in multiple districts)
        for street in streets {
            let key = "\(street.name)_\(street.district)"
            consolidated[key, default: []].append(street)
        }

        // Create consolidated streets
        return consolidated.map { key, segments in
            guard let first = segments.first else {
                fatalError("Empty segment list")
            }

            return ConsolidatedStreet(
                id: key,
                name: first.name,
                district: first.district,
                segments: segments.sorted { seg1, seg2 in
                    // Sort segments spatially (rough approximation)
                    guard let coord1 = seg1.coordinates.first,
                          let coord2 = seg2.coordinates.first else {
                        return false
                    }
                    return coord1.lat < coord2.lat
                }
            )
        }.sorted { $0.name < $1.name }
    }

    /// Get statistics about consolidation
    static func getStats(streets: [BerlinStreets.Street]) -> ConsolidationStats {
        let consolidated = consolidate(streets: streets)

        let segmentsPerStreet = consolidated.map { $0.segments.count }
        let avgSegments = segmentsPerStreet.isEmpty ? 0 : segmentsPerStreet.reduce(0, +) / segmentsPerStreet.count
        let maxSegments = segmentsPerStreet.max() ?? 0
        let minSegments = segmentsPerStreet.min() ?? 0

        return ConsolidationStats(
            originalSegmentCount: streets.count,
            consolidatedStreetCount: consolidated.count,
            avgSegmentsPerStreet: avgSegments,
            minSegmentsPerStreet: minSegments,
            maxSegmentsPerStreet: maxSegments
        )
    }

    struct ConsolidationStats {
        let originalSegmentCount: Int
        let consolidatedStreetCount: Int
        let avgSegmentsPerStreet: Int
        let minSegmentsPerStreet: Int
        let maxSegmentsPerStreet: Int

        var consolidationRatio: Double {
            guard consolidatedStreetCount > 0 else { return 0 }
            return Double(originalSegmentCount) / Double(consolidatedStreetCount)
        }
    }
}
