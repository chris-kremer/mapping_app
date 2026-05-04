import Foundation

struct StreetGeometrySnapshot: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let district: String
    let stadtteil: String
    let coordinates: [RunMapCoordinate]
}

struct StreetCoverageSnapshot: Codable, Equatable {
    let streetID: String
    let coveredPointIndexes: Set<Int>
    let totalPointCount: Int

    var coveredPointCount: Int {
        coveredPointIndexes.count
    }

    var percentage: Double {
        guard totalPointCount > 0 else { return 0 }
        return Double(coveredPointCount) / Double(totalPointCount) * 100.0
    }
}

struct StreetCoverageSummary: Codable, Equatable {
    let totalStreets: Int
    let coveredStreets: Int
    let coveredPoints: Int
    let totalPoints: Int

    var percentage: Double {
        guard totalPoints > 0 else { return 0 }
        return Double(coveredPoints) / Double(totalPoints) * 100.0
    }
}

struct StreetCoverageEngine {
    let thresholdMeters: Double

    init(thresholdMeters: Double = 20.0) {
        self.thresholdMeters = thresholdMeters
    }

    func coverage(
        streets: [StreetGeometrySnapshot],
        routes: [RunMapRouteSnapshot]
    ) -> [String: StreetCoverageSnapshot] {
        let routePoints = routes.flatMap(\.coordinates)
        let index = RunMapSpatialIndex(points: routePoints, metersPerCell: thresholdMeters * 2.0)

        return coverage(streets: streets, spatialIndex: index)
    }

    func coverage(
        streets: [StreetGeometrySnapshot],
        spatialIndex: RunMapSpatialIndex
    ) -> [String: StreetCoverageSnapshot] {
        var result: [String: StreetCoverageSnapshot] = [:]
        result.reserveCapacity(streets.count)

        for street in streets {
            var covered = Set<Int>()
            for (index, coordinate) in street.coordinates.enumerated() {
                if spatialIndex.containsPoint(near: coordinate, thresholdMeters: thresholdMeters) {
                    covered.insert(index)
                }
            }

            result[street.id] = StreetCoverageSnapshot(
                streetID: street.id,
                coveredPointIndexes: covered,
                totalPointCount: street.coordinates.count
            )
        }

        return result
    }

    func merge(
        existing: [String: StreetCoverageSnapshot],
        delta: [String: StreetCoverageSnapshot]
    ) -> [String: StreetCoverageSnapshot] {
        var merged = existing

        for (streetID, deltaSnapshot) in delta {
            guard let existingSnapshot = merged[streetID] else {
                merged[streetID] = deltaSnapshot
                continue
            }

            merged[streetID] = StreetCoverageSnapshot(
                streetID: streetID,
                coveredPointIndexes: existingSnapshot.coveredPointIndexes.union(deltaSnapshot.coveredPointIndexes),
                totalPointCount: max(existingSnapshot.totalPointCount, deltaSnapshot.totalPointCount)
            )
        }

        return merged
    }

    func summarize(_ snapshots: [String: StreetCoverageSnapshot]) -> StreetCoverageSummary {
        let values = snapshots.values
        return StreetCoverageSummary(
            totalStreets: values.count,
            coveredStreets: values.filter { !$0.coveredPointIndexes.isEmpty }.count,
            coveredPoints: values.reduce(0) { $0 + $1.coveredPointCount },
            totalPoints: values.reduce(0) { $0 + $1.totalPointCount }
        )
    }
}

