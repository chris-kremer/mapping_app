import Foundation

struct RunMapSpatialIndex {
    private struct IndexedPoint {
        let coordinate: RunMapCoordinate
    }

    private var grid: [Cell: [IndexedPoint]] = [:]
    private let metersPerCell: Double

    init(points: [RunMapCoordinate] = [], metersPerCell: Double = 40.0) {
        self.metersPerCell = metersPerCell
        for point in points where point.isValid {
            let cell = Self.cell(for: point, metersPerCell: metersPerCell)
            grid[cell, default: []].append(IndexedPoint(coordinate: point))
        }
    }

    func nearestDistance(to coordinate: RunMapCoordinate, thresholdMeters: Double) -> Double? {
        guard coordinate.isValid else { return nil }

        var nearest: Double?
        for cell in neighboringCells(for: coordinate) {
            guard let points = grid[cell] else { continue }
            for point in points {
                let distance = coordinate.distanceMeters(to: point.coordinate)
                if nearest == nil || distance < nearest! {
                    nearest = distance
                }
                if distance <= thresholdMeters {
                    return distance
                }
            }
        }
        return nearest
    }

    func containsPoint(near coordinate: RunMapCoordinate, thresholdMeters: Double) -> Bool {
        guard let distance = nearestDistance(to: coordinate, thresholdMeters: thresholdMeters) else {
            return false
        }
        return distance <= thresholdMeters
    }

    var pointCount: Int {
        grid.values.reduce(0) { $0 + $1.count }
    }

    var cellCount: Int {
        grid.count
    }

    private func neighboringCells(for coordinate: RunMapCoordinate) -> [Cell] {
        let center = Self.cell(for: coordinate, metersPerCell: metersPerCell)
        var cells: [Cell] = []
        cells.reserveCapacity(9)

        for latOffset in -1...1 {
            for lonOffset in -1...1 {
                cells.append(Cell(lat: center.lat + latOffset, lon: center.lon + lonOffset))
            }
        }

        return cells
    }

    private static func cell(for coordinate: RunMapCoordinate, metersPerCell: Double) -> Cell {
        let latitudeCellSize = metersPerCell / 111_000.0
        let longitudeMeters = max(1.0, 111_000.0 * cos(coordinate.latitude * .pi / 180.0))
        let longitudeCellSize = metersPerCell / longitudeMeters

        return Cell(
            lat: Int(floor(coordinate.latitude / latitudeCellSize)),
            lon: Int(floor(coordinate.longitude / longitudeCellSize))
        )
    }

    private struct Cell: Hashable {
        let lat: Int
        let lon: Int
    }
}

