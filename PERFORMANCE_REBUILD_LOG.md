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

## Current Architectural Baseline

| Area | Current State | Rebuild Target | Status |
| --- | --- | --- | --- |
| Route model | UI-facing `Route` class in `ContentView.swift` | Pure `RunMapRouteSnapshot` plus adapters | Foundation added. |
| GPS cleanup | Inline filtering in `RunViewModel.filterRoute` | Tested `RunMapRouteNormalizer` | Foundation added. |
| Street proximity | Existing `SpatialIndex` tied to app models | Pure `RunMapSpatialIndex` | Foundation added. |
| Street coverage | Full recomputation path still exists in legacy helpers | Delta-based `StreetCoverageDeltaProcessor` | Wired into `AchievementsManager.processStreetsFast`. |
| Persistence | Mixed `UserDefaults` route and coverage cache | File-backed state, later SQLite if needed | Incremental street coverage state is saved to app caches. |
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
| App build/test gate | Blocked before Xcode setup | Generic iOS build passes; unit tests pass on simulator | Full scheme including UI tests passes. |

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
- Generic iOS app build passes outside the sandbox with writable DerivedData.
- Simulator unit tests pass on `iphone 15` / iOS 18.3.1.
- Full-scheme test run was interrupted after hanging in UI-test launch; keep unit tests as the foundation gate until UI tests are repaired.
