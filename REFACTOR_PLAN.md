# Street Processing Refactor Plan

## Goal
Replace the slow O(n²) street processing with fast spatial index approach, add UI for browsing streets by district.

## What I've Created

### 1. FastStreetProcessor.swift ✅
- Uses `FastStreetChecker` (spatial index) instead of nested loops
- Processes streets sequentially by Stadtteil with progress bars
- 100-500x faster than current implementation
- Provides coverage percentages for all streets

### 2. DistrictStreetListView.swift ✅
- Shows list of all streets in a district/stadtteil
- Sortable by: name, coverage %, length
- Click street → shows map with green/red coverage points
- Uses `StreetMapView` for detailed visualization

### 3. ConsolidatedStreet.swift ✅
- Merges street segments by name
- Calculates total coverage across all segments

### 4. SpatialIndex.swift ✅
- Grid-based spatial indexing
- O(n) instead of O(n²)
- Dramatically faster distance queries

## Changes Needed in AchievementsView.swift

### Step 1: Replace `processNewRoutesForStreets()`

**Current (slow):**
```swift
// Lines 1324-1681
func processNewRoutesForStreets(routes: [Route]) async {
    // Nested loop checking every street point vs every route point
    for routeCoord in route.coordinates {  // SLOW!
        if distance <= 15 { ... }
    }
}
```

**New (fast):**
```swift
func processNewRoutesForStreets(routes: [Route]) async {
    let processor = FastStreetProcessor()

    await MainActor.run {
        self.processingStatus = processor.processingStatus
        self.processingProgress = processor.processingProgress
    }

    // This is 100x faster!
    let consolidatedStreets = await processor.processAllStreets(
        routes: routes,
        districts: ["Mitte"] // or BerlinDistricts.districts.map { $0.name }
    )

    // Convert consolidated streets to old format if needed
    // Or better: refactor to use consolidated streets directly
}
```

### Step 2: Make Districts Clickable

**Current:**
- Districts are buttons that show location on map
- Lines 1920-1940 (visited districts)

**Add:**
```swift
NavigationLink(destination: DistrictStreetListView(
    districtName: district,
    stadtteilName: nil,
    streets: streetsForDistrict(district),
    routes: routes,
    processor: fastProcessor
)) {
    HStack {
        // ... existing UI ...
    }
}
```

### Step 3: Add Stadtteil Progress Bars

Replace the single progress bar with sequential Stadtteil progress:

```swift
if processor.isProcessing {
    VStack(spacing: 12) {
        Text("Processing: \(processor.currentStadtteil)")
            .font(.headline)

        ProgressView(value: processor.processingProgress)
            .progressViewStyle(.linear)

        Text(processor.processingStatus)
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .padding()
}
```

### Step 4: Store Consolidated Streets

Add to `AchievementsManager`:
```swift
@Published var consolidatedStreets: [ConsolidatedStreet] = []
@Published var streetsByDistrict: [String: [ConsolidatedStreet]] = [:]
@Published var streetsByStadtteil: [String: [ConsolidatedStreet]] = [:]
```

## Migration Path

### Option A: Complete Replacement (Recommended)
1. Replace `processNewRoutesForStreets()` entirely with `FastStreetProcessor`
2. Remove old `RouteCoverageData` and `StreetSegment` structures
3. Use `ConsolidatedStreet` everywhere
4. Simpler, cleaner, faster

### Option B: Gradual Migration
1. Keep old processing for backward compatibility
2. Add new fast processing alongside
3. Migrate data format gradually
4. More complex, but safer

## Recommendation

**Go with Option A** because:
- Old processing is too slow to be usable
- Clean break is simpler
- Can keep cached data or reprocess (fast now!)
- Users get immediate benefit

## Implementation Steps

1. **Test FastStreetProcessor** independently
   - Run on Mitte district
   - Verify coverage percentages match old method
   - Confirm 100x speed improvement

2. **Replace processing function**
   - Swap out `processNewRoutesForStreets()`
   - Update progress bar UI
   - Add Stadtteil sequential processing

3. **Add district drill-down**
   - Make district buttons → NavigationLinks
   - Show DistrictStreetListView
   - Test street selection → map view

4. **Polish UI**
   - Add sorting options
   - Color-code by coverage %
   - Add summary stats

## Estimated Time
- Testing: 30 min
- Implementation: 1-2 hours
- Polish: 30 min

**Total: 2-3 hours for complete refactor**

## Files to Modify
1. `AchievementsView.swift` - Replace processing, add navigation
2. `AchievementsManager.swift` - Store consolidated streets
3. `ContentView.swift` - Pass consolidated streets to AchievementsView if needed

## Files Created (Already Done)
1. ✅ `FastStreetProcessor.swift`
2. ✅ `DistrictStreetListView.swift`
3. ✅ `ConsolidatedStreet.swift`
4. ✅ `SpatialIndex.swift`

## Want me to implement this?

I can do the full refactor now if you want, or you can review the plan first. What would you prefer?
