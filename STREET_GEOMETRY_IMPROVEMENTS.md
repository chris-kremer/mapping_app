# Street Geometry Improvements

## Current Situation

The street scoring system currently uses a **simplification factor of 2** when parsing the GeoJSON file (`AchievementsView.swift:357`). This means:

- Only every 2nd coordinate from the original GeoJSON is kept
- If the original GeoJSON has points every 10m, the simplified version has points every ~20m
- With a 15m detection radius, streets with sparse points might not be detected accurately

## Problem

Streets are checked using a 15-meter radius around each stored point. If points are too far apart (e.g., 40m), you might pass between two check points without being detected, missing streets you actually traversed.

## Solutions

### Option 1: Reduce Simplification Factor (Immediate, Memory Trade-off)

**File:** `AchievementsView.swift:357`

**Change:**
```swift
// OLD:
let simplificationFactor = 2

// NEW (no simplification):
let simplificationFactor = 1
```

**Pros:**
- Simple one-line change
- Uses original GeoJSON resolution
- More accurate street detection

**Cons:**
- Doubles memory usage for street data
- Doubles processing time for coverage checks
- About 2x more disk space for cached streets

---

### Option 2: Use Runtime Densification (Recommended)

Use the `GeometryDensification.swift` helper to add interpolated points at runtime.

**File:** `AchievementsView.swift` (around line 1537 in the coverage check loop)

**Change:**
```swift
// Before the coverage check loop, densify the street coordinates:
let streetCoords = GeometryDensification.densifyCoordinates(
    street.coordinates,
    maxDistanceMeters: 5.0
)

// Then use streetCoords instead of street.coordinates in the loop:
for range in uncoveredRanges {
    for i in range.0...range.1 {
        let streetPoint = CLLocation(
            latitude: streetCoords[i].lat,
            longitude: streetCoords[i].lon
        )
        // ... rest of the code
    }
}
```

**Pros:**
- No increased memory usage for cached data
- More granular checking (5m intervals instead of 20m+)
- Configurable resolution (adjust maxDistanceMeters as needed)

**Cons:**
- Adds computation time during coverage checks
- More complex than Option 1

---

### Option 3: Hybrid Approach (Best Balance)

Combine both: use a moderate simplification factor (1.5x instead of 2x) and apply light densification.

**File:** `AchievementsView.swift:357`
```swift
let simplificationFactor = 1.5  // Keep more points than current, but not all
```

**Then in coverage check:**
```swift
let streetCoords = GeometryDensification.densifyCoordinates(
    street.coordinates,
    maxDistanceMeters: 10.0  // Less aggressive than 5m
)
```

---

## Debug View Usage

The new `StreetDebugView` helps you visualize and understand the coverage:

1. **Access:** Tap the bug icon (🐜) in the Achievements view
2. **Load Streets:** Tap "Load Mitte Streets" to load only Mitte district (faster)
3. **Select a Street:** Tap any street to analyze it
4. **Toggle Densification:** Use the toggle to compare current vs. densified geometry

### What You'll See:

- **Purple line:** The street geometry (polyline connecting all check points)
- **Blue lines:** Your actual routes from HealthKit
- **Green dots:** Street check points you've covered (within 15m of a route)
- **Red dots:** Street check points you haven't covered
- **Green circle with "S":** Start of street
- **Red circle with "E":** End of street

### Interpretation:

- If you see red dots between blue routes, the check points are too sparse
- If you see mostly green dots, the current resolution is working well
- Toggle densification ON to see how many more check points would be added

---

## Recommended Next Steps

1. **Test with Debug View:**
   - Pick a street you know you've run on
   - See if current geometry detects it correctly
   - Toggle densification and compare results

2. **If Coverage is Inaccurate:**
   - Start with Option 2 (Runtime Densification) at 5-10m intervals
   - Measure performance impact
   - Adjust maxDistanceMeters if needed

3. **If Performance is Acceptable:**
   - Consider Option 1 (simplificationFactor = 1) for maximum accuracy

4. **Monitor:**
   - Check memory usage in Xcode Instruments
   - Monitor processing time for new routes
   - Adjust based on real-world performance

---

## Technical Details

### Current Storage per Street (simplificationFactor = 2):
- Average: ~10-20 points per street
- Memory: ~200-400 bytes per street
- Total for all Berlin: ~50-100 MB

### After Densification (5m intervals):
- Average: ~50-100 points per street
- Memory: ~1-2 KB per street
- Total for all Berlin: ~250-500 MB

### Performance Impact:
- Current nested loop: O(uncovered_points × route_points)
- With 5m densification: ~5x more street points = ~5x longer processing
- Mitigation: Only densify candidate streets (already filtered by location)

---

## Files Created

1. **StreetDebugView.swift** - Debug visualization tool
2. **GeometryDensification.swift** - Helper functions for adding interpolated points
3. **STREET_GEOMETRY_IMPROVEMENTS.md** - This document

## Related Code Locations

- Street parsing: `AchievementsView.swift:298-397`
- Simplification: `AchievementsView.swift:357`
- Coverage checking: `AchievementsView.swift:1534-1559`
- Distance threshold: `AchievementsView.swift:1546` (15 meters)
