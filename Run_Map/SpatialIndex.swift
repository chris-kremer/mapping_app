import Foundation
import CoreLocation

/// Ultra-fast spatial index using grid-based bucketing
/// Reduces O(n²) to O(n) for distance queries
class SpatialIndex {
    private var grid: [String: [IndexedPoint]] = [:]
    private let cellSize: Double // in degrees

    struct IndexedPoint {
        let coordinate: CLLocationCoordinate2D
        let index: Int
    }

    /// Initialize spatial index with grid cell size
    /// - Parameter metersPerCell: Approximate size of each grid cell in meters (default 50m)
    init(metersPerCell: Double = 50) {
        // Convert meters to approximate degrees (at latitude ~52° Berlin)
        // 1 degree latitude ≈ 111,000 meters
        // 1 degree longitude at 52° ≈ 69,400 meters
        self.cellSize = metersPerCell / 70000.0 // Conservative estimate
    }

    /// Add route coordinates to the spatial index
    func addRoute(_ coordinates: [(latitude: Double, longitude: Double)]) {
        for (index, coord) in coordinates.enumerated() {
            let cell = getCellKey(lat: coord.latitude, lon: coord.longitude)
            let point = IndexedPoint(
                coordinate: CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude),
                index: index
            )
            grid[cell, default: []].append(point)
        }
    }

    /// Check if a point is within threshold distance of any indexed route point
    /// - Returns: true if within threshold, false otherwise
    func isNearRoute(lat: Double, lon: Double, thresholdMeters: Double = 20) -> (isNear: Bool, closestDistance: Double?) {
        let location = CLLocation(latitude: lat, longitude: lon)

        // Check the cell and all 8 surrounding cells
        let cells = getSurroundingCells(lat: lat, lon: lon)

        var closestDistance: Double?

        for cell in cells {
            guard let points = grid[cell] else { continue }

            for point in points {
                let routeLocation = CLLocation(
                    latitude: point.coordinate.latitude,
                    longitude: point.coordinate.longitude
                )
                let distance = location.distance(from: routeLocation)

                if closestDistance == nil || distance < closestDistance! {
                    closestDistance = distance
                }

                if distance <= thresholdMeters {
                    return (true, distance)
                }
            }
        }

        return (false, closestDistance)
    }

    /// Get cell key for a coordinate
    private func getCellKey(lat: Double, lon: Double) -> String {
        let cellLat = Int(lat / cellSize)
        let cellLon = Int(lon / cellSize)
        return "\(cellLat),\(cellLon)"
    }

    /// Get the cell and all 8 surrounding cells
    private func getSurroundingCells(lat: Double, lon: Double) -> [String] {
        let cellLat = Int(lat / cellSize)
        let cellLon = Int(lon / cellSize)

        var cells: [String] = []
        for dLat in -1...1 {
            for dLon in -1...1 {
                cells.append("\(cellLat + dLat),\(cellLon + dLon)")
            }
        }
        return cells
    }

    /// Get statistics about the index
    func getStats() -> (totalPoints: Int, cellsUsed: Int, avgPointsPerCell: Double) {
        let total = grid.values.reduce(0) { $0 + $1.count }
        let cells = grid.count
        let avg = cells > 0 ? Double(total) / Double(cells) : 0
        return (total, cells, avg)
    }

    /// Clear the index
    func clear() {
        grid.removeAll()
    }
}

/// Faster version specifically optimized for the debug view
class FastStreetChecker {
    private let spatialIndex: SpatialIndex

    init(routes: [Route]) {
        spatialIndex = SpatialIndex(metersPerCell: 40) // 40m cells for 20m threshold

        // Build index from all routes
        for route in routes {
            let coords = route.coordinates.map { ($0.latitude, $0.longitude) }
            spatialIndex.addRoute(coords)
        }

        let stats = spatialIndex.getStats()
        print("📊 Spatial Index: \(stats.totalPoints) points in \(stats.cellsUsed) cells (avg \(String(format: "%.1f", stats.avgPointsPerCell)) pts/cell)")
    }

    /// Check coverage for an entire street - FAST!
    func checkStreetCoverage(streetCoords: [BerlinStreets.SimpleCoordinate]) -> [Bool] {
        var coverage: [Bool] = []
        coverage.reserveCapacity(streetCoords.count)

        for coord in streetCoords {
            let result = spatialIndex.isNearRoute(lat: coord.lat, lon: coord.lon)
            coverage.append(result.isNear)
        }

        return coverage
    }

    /// Check coverage with distance info - slightly slower but more detailed
    func checkStreetCoverageDetailed(streetCoords: [BerlinStreets.SimpleCoordinate]) -> [(isCovered: Bool, closestDistance: Double?)] {
        var results: [(Bool, Double?)] = []
        results.reserveCapacity(streetCoords.count)

        for coord in streetCoords {
            let result = spatialIndex.isNearRoute(lat: coord.lat, lon: coord.lon)
            results.append((result.isNear, result.closestDistance))
        }

        return results
    }
}
