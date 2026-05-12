# Performance Rebuild Log

This file tracks measurable changes made during the rebuild. Keep entries factual: command, date, environment, baseline, result, and next action.

## Verification Environment

| Date | Check | Result | Notes |
| --- | --- | --- | --- |
| 2026-05-04 | `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` | Full Xcode is now selected. |
| 2026-05-04 | `xcodebuild -version` | Xcode 16.2, build 16C5032a | Toolchain available. |
| 2026-05-04 | `xcodebuild -list -project Run_Map.xcodeproj` | Scheme discovered | Targets: `Run_Map`, `Run_MapTests`, `Run_MapUITests`; scheme: `Run_Map`. |
| 2026-05-04 | `xcodebuild test -project Run_Map.xcodeproj -scheme Run_Map -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath /private/tmp/run_map_derived_data CODE_SIGNING_ALLOWED=NO` | Blocked | No concrete iOS simulator device/runtime available. |
| 2026-05-04 | `xcodebuild build -project Run_Map.xcodeproj -scheme Run_Map -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/run_map_derived_data CODE_SIGNING_ALLOWED=NO` | Passed outside sandbox | Full app compiles for generic iOS. New foundation files are included by the Xcode target. |
| 2026-05-04 | Same generic iOS build after adding `StreetCoverageStateStore` | Passed outside sandbox | File-backed coverage persistence compiles. |
| 2026-05-04 | `xcodebuild -showdestinations -project Run_Map.xcodeproj -scheme Run_Map` | Simulator available | `iphone 15`, iOS 18.3.1, id `5E00753F-DB2D-4EBF-89BD-0C9315897C3D`. |
| 2026-05-04 | `xcodebuild test -project Run_Map.xcodeproj -scheme Run_Map -destination 'id=5E00753F-DB2D-4EBF-89BD-0C9315897C3D' -derivedDataPath /private/tmp/run_map_derived_data CODE_SIGNING_ALLOWED=NO -only-testing:Run_MapTests` | Passed | 6 unit tests passed, including the new foundation tests. |
| 2026-05-04 | Same simulator unit-test command after wiring `AchievementsManager.processStreetsFast` to the incremental processor | Passed | 6 unit tests passed; test session elapsed 59.301 seconds. |
| 2026-05-04 | Same generic iOS build after wiring incremental street coverage into `AchievementsManager` | Passed | App target compiles for generic iOS in 12.592 seconds. |
| 2026-05-04 | Same generic iOS build after adding stable `RouteMapView` overlay reconciliation | Passed | App target compiles for generic iOS in 11.586 seconds. |
| 2026-05-04 | Same simulator unit-test command after stable `RouteMapView` overlay reconciliation | Passed | 6 unit tests passed; test session elapsed 60.434 seconds. |
| 2026-05-04 | Same generic iOS build after throttling achievement detail map circle overlays | Passed | App target compiles for generic iOS in 11.489 seconds. Existing Swift 6 warnings remain in legacy street-loading code. |
| 2026-05-04 | Same simulator unit-test command after throttling achievement detail map circle overlays | Passed | 6 unit tests passed; test session elapsed 58.564 seconds. |
| 2026-05-04 | Generic iOS build after extracting street achievement views | Blocked in sandbox | Escalated `xcodebuild` was blocked by the app usage-limit approval layer. Non-escalated build reached Swift compilation for `AchievementsStreetViews.swift`, then failed on an unrelated `#Preview` macro in `StreetDebugView.swift` because the sandboxed `swift-plugin-server` response was malformed. |
| 2026-05-04 | Non-escalated generic iOS build after legacy street cache migration guard | Blocked in sandbox | No errors reported in changed files before the same sandboxed `StreetDebugView.swift` `#Preview` macro failure. |
| 2026-05-04 | Escalated generic iOS build after extraction and cache guard | Passed | App target compiles for generic iOS in 17.100 seconds. |
| 2026-05-04 | Escalated simulator unit-test command after extraction and cache guard | Passed | 6 unit tests passed; test session elapsed 66.597 seconds. |
| 2026-05-11 | Generic iOS build after route-cache async load, district coverage batching, map reconciliation, backup removal, and warning cleanup | Passed | App target compiles for generic iOS with no captured warnings in `/tmp/run_map_build.log`. |
| 2026-05-11 | Simulator unit-test command after same optimization pass | Passed | 6 unit tests passed; test session elapsed 83.053 seconds. App code warnings cleaned; remaining warnings are test-target bundle identifier settings. |
| 2026-05-12 | Generic iOS build after adding Stadtteil map overlays and visited/unvisited styling | Passed | App target compiles for generic iOS with `CODE_SIGNING_ALLOWED=NO`; no signing prompt required. |
| 2026-05-12 | Generic iOS build after adding grouped Berlin street coverage map | Passed | App target compiles for generic iOS with `CODE_SIGNING_ALLOWED=NO`; the map uses two `MKMultiPolyline` overlays instead of thousands of individual street overlays. |
| 2026-05-12 | Generic iOS build after adding indexed GeoNames city gazetteer | Passed | App target compiles for generic iOS with `CODE_SIGNING_ALLOWED=NO`; city lookup now loads a 63,489-city TSV once and searches nearby 2-degree spatial cells instead of relying only on the hardcoded major-city switch. |

## Current Architectural Baseline

| Area | Current State | Rebuild Target | Status |
| --- | --- | --- | --- |
| Route model | UI-facing `Route` class in `ContentView.swift` | Pure `RunMapRouteSnapshot` plus adapters | Foundation added. |
| GPS cleanup | Inline filtering in `RunViewModel.filterRoute` | Tested `RunMapRouteNormalizer` | Foundation added. |
| Street proximity | Existing `SpatialIndex` tied to app models | Pure `RunMapSpatialIndex` | Foundation added. |
| Street coverage | Full recomputation path still exists in legacy helpers | Delta-based `StreetCoverageDeltaProcessor` | Wired into `AchievementsManager.processStreetsFast`. |
| Persistence | Mixed `UserDefaults` route and coverage cache | File-backed state, later SQLite if needed | Incremental street coverage state is saved to app caches; legacy summary cache is ignored when rebuilt state is empty. |
| Map rendering | Repeated overlay scans in `RouteMapView.updateUIView` | Stable overlay reconciliation | Initial coordinator-backed diffing added for district, live route, and saved route overlays. |

## Metrics To Capture

| Metric | Baseline | Current | Target |
| --- | ---: | ---: | ---: |
| Cold route cache load | TBD | TBD | Under 200 ms for cached routes. |
| Street data load | TBD | TBD | No raw 30 MB GeoJSON parse on normal launch. |
| Full Berlin coverage rebuild | TBD | TBD | Background-only, bounded, cancellable. |
| New-route coverage delta | TBD | `StreetCoverageDeltaProcessor` skips ids in `StreetCoverageState.processedRouteIDs` | Process only unseen route ids. |
| Main map overlay reconciliation | Rebuilt district/live overlays on each update | Coordinator caches skip unchanged district/live overlays and track saved route overlays by route id | No remove/readd loop for unchanged overlays. |
| Achievement coverage maps | Up to one `MKCircle` overlay per street point | Dot views cap displayed circle overlays and add them in batches | Keep map drilldowns responsive while still showing coverage distribution. |
| Route cache load | Synchronous JSON read/decode in `RunViewModel.loadRuns()` | Cache decode runs on a user-initiated background queue and logs `[perf] route_cache_decode` | Keep app launch responsive while cached routes load. |
| District street list coverage | Built a new `FastStreetChecker` per street and updated SwiftUI state inside the loop | Builds one checker per district list, computes coverage off-main, assigns cache once, and logs `[perf] district_street_coverage` | Avoid O(streets * index build) work and reduce list invalidations. |
| Street/debug detail maps | Removed every overlay/annotation on each SwiftUI update and recreated annotation images per view | Coordinator signatures skip unchanged updates, remove only owned map objects, batch adds, and reuse generated marker images | Avoid visible map churn and per-update image allocation. |
| App bundle resources | Stale `AchievementsView.swift.bak` and `.bak2` lived inside the app directory | Removed both backup files; verified no `.bak` files are copied into the built app bundle | Keep accidental resources out of the app bundle. |
| App build/test gate | Blocked before Xcode setup | Generic iOS build passes; unit tests pass on simulator | Full scheme including UI tests passes. |
| Stadtteil achievement map | No all-Stadtteile map overlay | Derived, cached Stadtteil hull overlays from loaded street geometry; visited/unvisited state only changes overlay styling | Provide map context without adding a new GeoJSON parse or per-update polygon rebuild. |
| Berlin Streets achievement map | Point map rebuilt route proximity checks inside the sheet | Uses already computed street coverage and renders covered/uncovered streets as two grouped `MKMultiPolyline` overlays | Avoid external DB work and avoid one-overlay-per-street rendering churn. |
| City geocoding coverage | Hardcoded list of roughly 80-90 global major cities | Bundled 63,489-row GeoNames city gazetteer indexed into 2-degree spatial cells, with hardcoded list retained as fallback | Improve city achievement coverage without a linear scan across all cities per geocode. |

## Change Log

### 2026-05-04

- Added pure foundation models and services under `Run_Map/Foundation`.
- Added route/street adapters from existing app models into the new snapshot models.
- Added `StreetCoverageDeltaProcessor` to process only unseen routes and merge coverage snapshots.
- Added `StreetCoverageStateStore` for file-backed incremental coverage persistence.
- Added focused tests under `Run_MapTests/Foundation`.
- Wired `AchievementsManager.processStreetsFast` through the incremental processor and file-backed state store while keeping existing UI-facing achievement fields populated.
- Added coordinator-backed `RouteMapView` overlay reconciliation so unchanged district overlays, live overlays, and saved route overlays are not recreated on every SwiftUI update.
- Throttled achievement detail map circle overlays: district/stadtteil dot maps now sample to at most 2,500 displayed circles, and all-points coverage maps display at most 4,000 circles while preserving processed coverage counts.
- Extracted street achievement list/filter/map views from `AchievementsView.swift` into `AchievementsStreetViews.swift` to reduce the size and risk of the main achievement file.
- Added a migration guard so stale legacy `UserDefaults` street coverage summaries cannot mask an empty rebuilt file-backed coverage state.
- Generic iOS app build passes outside the sandbox with writable DerivedData.
- Simulator unit tests pass on `iphone 15` / iOS 18.3.1.
- Full-scheme test run was interrupted after hanging in UI-test launch; keep unit tests as the foundation gate until UI tests are repaired.

### 2026-05-11

- Added `RunMapPerformanceMetrics` for lightweight timing logs on expensive rebuild paths.
- Moved cached route loading off the caller thread and timed route cache decode.
- Reworked district street coverage lists to build one `FastStreetChecker`, compute coverage off-main, and publish one cache update.
- Added signature-based reconciliation to `StreetCoverageMapView` and `StreetDebugMapView`; unchanged SwiftUI updates now skip map object churn.
- Batched street/debug map overlay and annotation adds, and cached generated point/marker images.
- Removed stale `AchievementsView.swift.bak` and `AchievementsView.swift.bak2` files from the app source directory; the built app no longer receives those accidental resources.
- Cleaned Swift concurrency and unused-value warnings in the touched rebuild path.

### 2026-05-12

- Added a Stadtteile map action from the Berlin Stadtteile achievement detail view.
- Added cached Stadtteil boundary hull derivation from already-loaded street geometry, with a street-cache fallback when the achievement manager has not populated grouped streets yet.
- Added visited/unvisited overlay styling: visited Stadtteile render green, unvisited Stadtteile render gray with dashed borders.
- Generic iOS app build passes with signing disabled.
- Added a Berlin Streets achievement map that colors whole streets green when at least one stored coordinate is covered and red when zero coordinates are covered.
- Reused existing consolidated street geometry and `streetCoverageByID`, avoiding a fresh proximity pass or external database for the first version.
- Grouped rendered street geometry into covered/uncovered `MKMultiPolyline` overlays so MapKit manages two high-level overlays instead of thousands of separate street overlays.
- Generic iOS app build passes with signing disabled after the street coverage map change.
- Added a compact GeoNames `cities5000` TSV resource for offline city-level geocoding.
- Excluded GeoNames `PPLX` neighborhood/district rows so Berlin districts such as Kreuzberg or Pankow do not fragment the city-level achievement category.
- Added a lazy 2-degree spatial grid inside `LocalGeocoder`; city lookup now searches nearby cells filtered by matched country code, then falls back to the previous hardcoded major-city list.
- Generic iOS app build passes with signing disabled after the city gazetteer change.
