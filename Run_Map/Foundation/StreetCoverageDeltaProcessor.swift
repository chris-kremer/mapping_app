import Foundation

struct StreetCoverageState: Codable, Equatable {
    var processedRouteIDs: Set<String>
    var coverageByStreetID: [String: StreetCoverageSnapshot]

    static let empty = StreetCoverageState(processedRouteIDs: [], coverageByStreetID: [:])
}

struct StreetCoverageDeltaResult: Equatable {
    let state: StreetCoverageState
    let processedRouteCount: Int
    let summary: StreetCoverageSummary
}

struct StreetCoverageDeltaProcessor {
    let engine: StreetCoverageEngine

    init(engine: StreetCoverageEngine = StreetCoverageEngine()) {
        self.engine = engine
    }

    func process(
        streets: [StreetGeometrySnapshot],
        routes: [RunMapRouteSnapshot],
        existingState: StreetCoverageState
    ) -> StreetCoverageDeltaResult {
        let newRoutes = routes.filter { !existingState.processedRouteIDs.contains($0.id) }

        guard !newRoutes.isEmpty else {
            return StreetCoverageDeltaResult(
                state: existingState,
                processedRouteCount: 0,
                summary: engine.summarize(existingState.coverageByStreetID)
            )
        }

        let delta = engine.coverage(streets: streets, routes: newRoutes)
        let mergedCoverage = engine.merge(existing: existingState.coverageByStreetID, delta: delta)
        let mergedRouteIDs = existingState.processedRouteIDs.union(newRoutes.map(\.id))
        let state = StreetCoverageState(processedRouteIDs: mergedRouteIDs, coverageByStreetID: mergedCoverage)

        return StreetCoverageDeltaResult(
            state: state,
            processedRouteCount: newRoutes.count,
            summary: engine.summarize(mergedCoverage)
        )
    }
}

