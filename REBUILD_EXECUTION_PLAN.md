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

This is intentionally separate from `Route`, `AchievementsManager`, `MKPolyline`, and `BerlinStreets` so it can become the core model without dragging UI state into processing.

## Next Implementation Steps

1. Add first-run migration/clear-state controls for the new street coverage cache so stale legacy `UserDefaults` coverage cannot mask rebuilt state.
2. Continue moving large SwiftUI files into focused views/services, next by extracting graph and non-street achievement detail sections out of `AchievementsView.swift`.
3. Move street coverage persistence from JSON to SQLite if the dataset continues to grow.

## Verification Target

Use the test target as the primary compliance gate for the new foundation:

```sh
xcodebuild test -project Run_Map.xcodeproj -scheme Run_Map -destination 'id=5E00753F-DB2D-4EBF-89BD-0C9315897C3D' -derivedDataPath /private/tmp/run_map_derived_data CODE_SIGNING_ALLOWED=NO -only-testing:Run_MapTests
```

Also keep the generic app build green:

```sh
xcodebuild build -project Run_Map.xcodeproj -scheme Run_Map -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/run_map_derived_data CODE_SIGNING_ALLOWED=NO
```

Current status: both commands pass on this machine with Xcode 16.2. Full-scheme testing still needs UI-test launch cleanup.
