# Run Map Architecture Foundation

## Product guarantees

The app now treats the local route archive as durable user data and HealthKit as a source that is reconciled into it. A HealthKit refresh never replaces the archive wholesale. This preserves imported routes and cached history when HealthKit temporarily returns an incomplete result.

Normal launch follows a cache-first path:

1. Decode the local archive away from the main thread.
2. Show the map as soon as cached routes are available.
3. Reconcile HealthKit in the background.
4. Coalesce and precalculate route statistics at utility priority.
5. Incrementally process street coverage only for route identities not already in the coverage state.

## Route integrity

- HealthKit workout and route UUIDs plus a segment index form a stable source identity.
- Every `HKWorkoutRoute` sample is loaded; the old implementation read only the first sample.
- The archive keeps its existing JSON-lines migration compatibility, but malformed lines now fail the primary archive instead of silently dropping routes.
- Saves are serialized, merge with the latest archive, rotate a known-good backup, and atomically replace the primary file.
- A failed or incomplete HealthKit response cannot delete locally known routes.
- Incremental sync remembers workouts already checked so GPS-less workouts do not create work on every launch.
- A bounded full-history audit runs weekly and whenever no previous audit exists. Route queries use a small worker pool to avoid flooding HealthKit.

## Rendering all history

The former 500-route rendering limit was removed. Routes are grouped by workout type into `MKMultiPolyline` chunks. This keeps every route visible while reducing thousands of MapKit overlays to a small number of renderers. Highlighted routes remain individual overlays so the latest-day and location highlighting features continue to work.

## Background analysis and rewards

Route-level totals, per-route distance/pace inputs, and daily distance totals are precalculated into a versioned cache. Requests are coalesced so only the newest route library is analyzed. The Stats screen consumes a matching snapshot immediately, while geographic enrichment continues off the main thread.

Achievement analysis now ignores duplicate requests for the same route-library fingerprint. Berlin street coverage continues to use the file-backed incremental state and spatial index, so only unseen routes contribute a delta.

## Backend decision

No external account is required for this foundation. A CrowdStrike account is not needed for route storage or analysis.

For a later cross-device and disaster-recovery phase, use one of these deliberately:

- **CloudKit** for an Apple-only product with private per-user route records and minimal account friction.
- **A dedicated API plus object/database storage** if Android/web, team features, server-side aggregate analysis, or operational control are planned.

Server-side precalculation should store versioned, reproducible derived snapshots. Raw routes remain the source of truth; an analysis-version change can rebuild rewards and statistics without risking route history.

## Verification gates

- Generic iOS build with signing disabled.
- Foundation unit tests for normalization, spatial indexing, incremental street coverage, coverage persistence, transactional route merging/stable identities, and deterministic analysis snapshots.
- Before release: test a real device with a large HealthKit library, interrupt a sync mid-import, relaunch offline, and compare archive counts before and after the weekly full audit.

