import Foundation
import CoreLocation
import HealthKit
import Testing
@testable import Run_Map

struct RunMapFoundationTests {
    @Test func routeRenderSimplifierBoundsWorkAndKeepsEndpoints() {
        let coordinates = (0..<2_000).map { index in
            CLLocationCoordinate2D(
                latitude: 52.0 + Double(index) * 0.00001,
                longitude: 13.0 + Double(index) * 0.00001
            )
        }

        let simplified = RouteRenderCoordinateSimplifier.simplified(coordinates)

        #expect(simplified.count <= RouteRenderCoordinateSimplifier.maxRenderedCoordinates)
        #expect(simplified.first?.latitude == coordinates.first?.latitude)
        #expect(simplified.last?.latitude == coordinates.last?.latitude)
    }

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

    @Test func routeStoreMergesWritesAndPreservesStableSourceIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RouteStorage(directoryURL: directory)
        let firstID = UUID()
        let workoutID = UUID()
        let healthRouteID = UUID()
        let first = Route(
            id: firstID,
            coordinates: [
                CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
                CLLocationCoordinate2D(latitude: 52.5201, longitude: 13.4051)
            ],
            date: Date(timeIntervalSince1970: 100),
            workoutType: .walking,
            durationSec: 60,
            sourceWorkoutID: workoutID,
            sourceRouteID: healthRouteID,
            segmentIndex: 2
        )
        let second = Route(
            coordinates: [
                CLLocationCoordinate2D(latitude: 48.13, longitude: 11.58),
                CLLocationCoordinate2D(latitude: 48.1301, longitude: 11.5801)
            ],
            date: Date(timeIntervalSince1970: 200),
            workoutType: .running,
            durationSec: 120
        )

        store.saveRoutes([first])
        store.saveRoutes([second])
        let loaded = store.loadRoutes()

        #expect(loaded.count == 2)
        let restored = loaded.first { $0.id == firstID }
        #expect(restored?.sourceWorkoutID == workoutID)
        #expect(restored?.sourceRouteID == healthRouteID)
        #expect(restored?.segmentIndex == 2)
        #expect(restored?.persistenceKey == first.persistenceKey)
    }

    @Test func precalculatedRouteAnalysisIsDeterministic() {
        let first = RunMapRouteSnapshot(
            id: "first",
            startDate: Date(timeIntervalSince1970: 10),
            activity: .walking,
            durationSeconds: 60,
            coordinates: [
                RunMapCoordinate(latitude: 52.52, longitude: 13.405),
                RunMapCoordinate(latitude: 52.521, longitude: 13.405)
            ]
        )
        let second = RunMapRouteSnapshot(
            id: "second",
            startDate: Date(timeIntervalSince1970: 20),
            activity: .running,
            durationSeconds: 120,
            coordinates: [
                RunMapCoordinate(latitude: 52.52, longitude: 13.405),
                RunMapCoordinate(latitude: 52.522, longitude: 13.405)
            ]
        )

        let snapshot = RunMapRouteAnalysisEngine().makeSnapshot(routes: [first, second])

        #expect(snapshot.routeCount == 2)
        #expect(snapshot.coordinateCount == 4)
        #expect(snapshot.walkingDistanceKilometers > 0)
        #expect(snapshot.runningDistanceKilometers > snapshot.walkingDistanceKilometers)
        #expect(snapshot.routeFingerprint == RunMapRouteAnalysisEngine.fingerprint(routeIDs: ["second", "first"]))
    }

    @Test func routeStoreRecoversFromKnownGoodBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RouteStorage(directoryURL: directory)
        let coordinateA = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)
        let coordinateB = CLLocationCoordinate2D(latitude: 52.5201, longitude: 13.4051)
        let first = Route(
            coordinates: [coordinateA, coordinateB],
            date: Date(timeIntervalSince1970: 1),
            workoutType: .walking,
            durationSec: 60
        )
        let second = Route(
            coordinates: [
                CLLocationCoordinate2D(latitude: 48.13, longitude: 11.58),
                CLLocationCoordinate2D(latitude: 48.1301, longitude: 11.5801)
            ],
            date: Date(timeIntervalSince1970: 2),
            workoutType: .running,
            durationSec: 60
        )

        store.saveRoutes([first])
        store.saveRoutes([second]) // rotates the one-route primary into the backup
        try Data("not a route archive".utf8).write(
            to: directory.appendingPathComponent("cached_routes.json"),
            options: .atomic
        )

        let recovered = store.loadRoutes()
        #expect(recovered.map(\.id) == [first.id])

        store.saveRoutes([second])
        #expect(Set(store.loadRoutes().map(\.id)) == Set([first.id, second.id]))
    }
}
