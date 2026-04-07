# How to Add New Swift Files to Xcode Project

## The Problem
You're seeing errors like:
```
Cannot find type 'ConsolidatedStreet' in scope
Cannot find type 'FastStreetProcessor' in scope
```

This happens because the new Swift files exist on disk but aren't added to your Xcode project target.

## Solution: Add Files to Xcode

### Method 1: Drag and Drop (Easiest)

1. Open your project in Xcode
2. In the left sidebar (Project Navigator), find the `Run_Map` folder
3. Open Finder and navigate to `/Users/chris/Desktop/Run_Map/Run_Map/`
4. Drag these files from Finder into Xcode's Project Navigator:
   - `ConsolidatedStreet.swift`
   - `FastStreetProcessor.swift`
   - `FastStreetChecker.swift` (if exists)
   - `SpatialIndex.swift`
   - `GeometryDensification.swift`
   - `DistrictStreetListView.swift`
   - `AchievementsManagerFast.swift`

5. When the dialog appears:
   - ✅ Check "Copy items if needed" (if not already in project)
   - ✅ Check "Add to targets: Run_Map"
   - ✅ Check "Create groups"
   - Click "Finish"

### Method 2: Right-Click Add Files

1. In Xcode, right-click on the `Run_Map` folder in Project Navigator
2. Select "Add Files to Run_Map..."
3. Navigate to `/Users/chris/Desktop/Run_Map/Run_Map/`
4. Select all the new files:
   - `ConsolidatedStreet.swift`
   - `FastStreetProcessor.swift`
   - `SpatialIndex.swift`
   - `GeometryDensification.swift`
   - `DistrictStreetListView.swift`
   - `AchievementsManagerFast.swift`
5. Make sure "Add to targets: Run_Map" is checked
6. Click "Add"

## Files to Add

Here's the complete list of new files that need to be added:

```
✅ ConsolidatedStreet.swift
✅ FastStreetProcessor.swift
✅ SpatialIndex.swift
✅ GeometryDensification.swift
✅ DistrictStreetListView.swift
✅ AchievementsManagerFast.swift
```

Already in project:
```
✅ StreetDebugView.swift (already added)
✅ AchievementsView.swift (already exists)
```

## Verify Files Are Added

1. Click on your project name at the top of Project Navigator
2. Select the "Run_Map" target
3. Go to "Build Phases" tab
4. Expand "Compile Sources"
5. Check that all the new `.swift` files are listed there
6. If any are missing, click the "+" button and add them

## Alternative: If Xcode Still Can't Find Types

If you've added the files but still see errors:

1. Clean Build Folder: `Cmd + Shift + K`
2. Delete Derived Data:
   - Xcode → Preferences → Locations
   - Click arrow next to Derived Data path
   - Delete the folder for your project
3. Close and reopen Xcode
4. Build again: `Cmd + B`

## Quick Fix Script

If you prefer, run this command to see which files are in your directory but might not be in Xcode:

```bash
cd /Users/chris/Desktop/Run_Map/Run_Map/
ls -1 *.swift | sort
```

Compare this list with what you see in Xcode Project Navigator.

## Expected Result

After adding files, you should be able to:
- Build without "Cannot find type" errors
- See all new files in Project Navigator
- Use the new fast processing system

## Still Having Issues?

If errors persist after adding files:

1. Check for typos in import statements
2. Make sure all files are in the same module (Run_Map)
3. Verify files have the correct target membership
4. Try cleaning and rebuilding

Let me know if you need help with any of these steps!
