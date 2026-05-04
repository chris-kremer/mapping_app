import Foundation
import Testing
@testable import Run_Map

struct RunMapFoundationTests {
    @Test func routeNormalizerDropsInvalidCoordinatesAndSplitsLargeGaps() {
        let berlinA = RunMapCoordinate(latitude: 52.520000, longitude: 13.405000)
        let berlinB = RunMapCoordinate(latitude: 52.520050, longitude: 13.405050)
        let invalid = RunMapCoordinate(latitude: 120.0, longitude: 13.0)
        let farAway = RunMapCoordinate(latitude: 52.530000, longitude: 13.415000)
        let farAwayNext = RunMapCoordinate(latitude: 52.530050, longitude: 13.415050)

        let segments = RunMapRouteNormalizer.splitValidSegments(
            coordinates: [berlinA, berlinB, invalid, farAway, farAwayNext],
            maxGapMeters: 20.0
        )

        #expect(segments.count == 2)
        #expect(segments[0] == [berlinA, berlinB])
        #expect(segments[1] == [farAway, farAwayNext])
    }

    @Test func spatialIndexFindsNearbyPointsOnlyInsideThreshold() {
        let indexed = RunMapCoordinate(latitude: 52.520000, longitude: 13.405000)
        let nearby = RunMapCoordinate(latitude: 52.520010, longitude: 13.405010)
        let distant = RunMapCoordinate(latitude: 52.521000, longitude: 13.406000)
        let index = RunMapSpatialIndex(points: [indexed], metersPerCell: 40.0)

        #expect(index.pointCount == 1)
        #expect(index.containsPoint(near: nearby, thresholdMeters: 20.0))
        #expect(!index.containsPoint(near: distant, thresholdMeters: 20.0))
    }

    @Test func streetCoverageEngineMergesIncrementalRouteDeltas() {
        let street = StreetGeometrySnapshot(
            id: "alexanderplatz-mitte",
            name: "Alexanderplatz",
            district: "Mitte",
            stadtteil: "Mitte",
            coordinates: [
                RunMapCoordinate(latitude: 52.521900, longitude: 13.413200),
                RunMapCoordinate(latitude: 52.522000, longitude: 13.413300),
                RunMapCoordinate(latitude: 52.522100, longitude: 13.413400)
            ]
        )

        let firstRoute = RunMapRouteSnapshot(
            id: "route-1",
            startDate: Date(timeIntervalSince1970: 1),
            activity: .walking,
            durationSeconds: 60,
            coordinates: [street.coordinates[0]]
        )
        let secondRoute = RunMapRouteSnapshot(
            id: "route-2",
            startDate: Date(timeIntervalSince1970: 2),
            activity: .walking,
            durationSeconds: 60,
            coordinates: [street.coordinates[2]]
        )

        let engine = StreetCoverageEngine(thresholdMeters: 3.0)
        let firstCoverage = engine.coverage(streets: [street], routes: [firstRoute])
        let secondCoverage = engine.coverage(streets: [street], routes: [secondRoute])
        let merged = engine.merge(existing: firstCoverage, delta: secondCoverage)
        let summary = engine.summarize(merged)

        #expect(merged[street.id]?.coveredPointIndexes == [0, 2])
        #expect(summary.totalStreets == 1)
        #expect(summary.coveredStreets == 1)
        #expect(summary.coveredPoints == 2)
        #expect(summary.totalPoints == 3)
    }

    @Test func deltaProcessorSkipsAlreadyProcessedRoutes() {
        let street = StreetGeometrySnapshot(
            id: "street-1",
            name: "Street",
            district: "Mitte",
            stadtteil: "Mitte",
            coordinates: [
                RunMapCoordinate(latitude: 52.520000, longitude: 13.405000),
                RunMapCoordinate(latitude: 52.520100, longitude: 13.405100)
            ]
        )
        let route = RunMapRouteSnapshot(
            id: "route-1",
            startDate: Date(timeIntervalSince1970: 1),
            activity: .running,
            durationSeconds: 60,
            coordinates: [street.coordinates[0]]
        )

        let processor = StreetCoverageDeltaProcessor(engine: StreetCoverageEngine(thresholdMeters: 3.0))
        let first = processor.process(streets: [street], routes: [route], existingState: .empty)
        let second = processor.process(streets: [street], routes: [route], existingState: first.state)

        #expect(first.processedRouteCount == 1)
        #expect(first.summary.coveredPoints == 1)
        #expect(second.processedRouteCount == 0)
        #expect(second.state == first.state)
    }

    @Test func coverageStateStoreRoundTripsState() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("coverage.json")
        let store = StreetCoverageStateStore(fileURL: fileURL)
        let state = StreetCoverageState(
            processedRouteIDs: ["route-1"],
            coverageByStreetID: [
                "street-1": StreetCoverageSnapshot(
                    streetID: "street-1",
                    coveredPointIndexes: [0, 2],
                    totalPointCount: 3
                )
            ]
        )

        try store.save(state)
        let loaded = try store.load()
        try store.clear()

        #expect(loaded == state)
        #expect(try store.load() == .empty)
    }
}
