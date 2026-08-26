# Rebuild Execution Plan

## Direction

The rebuild should move expensive work out of SwiftUI-facing objects and into small, testable services. The current app can keep running while the new foundation is built alongside it.

## Foundation Added

The new `Run_Map/Foundation` layer starts the replacement path:

- `RunMapCoordinate`: pure coordinate model with validation and distance calculation.
- `RunMapRouteSnapshot`: stable route snapshot independent from HealthKit and MapKit.
- `RunMapRouteNormalizer`: filters invalid GPS points and splits large jumps into separate segments.
- `RunMapSpatialIndex`: lightweight grid index for fast proximity checks.
- `StreetCoverageEngine`: computes and merges street coverage snapshots incrementally.
- `StreetCoverageDeltaProcessor`: skips route ids that have already been processed and returns a merged coverage state.
- `StreetCoverageStateStore`: file-backed JSON persistence for the new incremental coverage state.
- `RunMapLegacyAdapters`: converts current `Route`, `BerlinStreets.Street`, and `ConsolidatedStreet` values into the new snapshot models.
- `RouteStorage`: now acts as a serialized merge-on-write repository with atomic replacement, backup recovery, and stable HealthKit source identities.
- `RunMapRouteAnalysis`: creates and persists versioned precalculated route/stat snapshots.
- `RunMapBackgroundAnalysisService`: coalesces analysis work at utility priority so it cannot stack up behind the UI.
- `RouteMapView`: renders all history in grouped `MKMultiPolyline` chunks instead of dropping every route after the newest 500.

This is intentionally separate from `Route`, `AchievementsManager`, `MKPolyline`, and `BerlinStreets` so it can become the core model without dragging UI state into processing.

## Next Implementation Steps

1. Continue moving large SwiftUI files into focused views/services, next by extracting graph and non-street achievement detail sections out of `AchievementsView.swift`.
2. Move street coverage persistence from JSON to SQLite if the dataset continues to grow.
3. Extend timing metrics from route-cache and district-list coverage into street data load, coverage delta processing, and overlay counts.
4. Replace remaining legacy `FastStreetProcessor` UI-progress mutation loops with a pure processing result stream or actor-backed progress model.
5. Add a build-phase guard or target-resource audit so backup/source-only files cannot be copied into the app bundle again.

## Verification Target

Use the test target as the primary compliance gate for the new foundation:

```sh
xcodebuild test -project Run_Map.xcodeproj -scheme Run_Map -destination 'id=5E00753F-DB2D-4EBF-89BD-0C9315897C3D' -derivedDataPath /private/tmp/run_map_derived_data CODE_SIGNING_ALLOWED=NO -only-testing:Run_MapTests
```

Also keep the generic app build green:

```sh
xcodebuild build -project Run_Map.xcodeproj -scheme Run_Map -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/run_map_derived_data CODE_SIGNING_ALLOWED=NO
```

Current status: both commands pass on this machine with Xcode 16.2. Generic iOS build is warning-clean in the captured log after the May 11 optimization pass. Full-scheme testing still needs UI-test launch cleanup.
