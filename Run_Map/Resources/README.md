# Resources Folder

This folder contains app resources that are bundled with the application.

## Contents

### Example GPX Routes (Demo Data)
These GPX files are loaded as demo data when the app first launches (if no HealthKit data is available):

- `Outdoor Walk-Route-20240509_143723.gpx` (3.7 MB)
- `Outdoor Walk-Route-20241201_182250.gpx` (2.0 MB)
- `Outdoor Walk-Route-20241208_145435.gpx` (1.7 MB)
- `Outdoor Walk-Route-20241210_181825.gpx` (1.7 MB)
- `Outdoor Walk-Route-20241211_185505.gpx` (1.9 MB)

**Total:** ~11 MB of demo route data

These files are referenced in `ContentView.swift` (line 876) in the `demoFiles` array.

## How to Add Resources to Xcode

For these files to be included in the app bundle, they must be added to the Xcode project:

1. In Xcode, right-click on the `Run_Map` folder
2. Select "Add Files to Run_Map..."
3. Navigate to this `Resources` folder
4. Select all `.gpx` files
5. Make sure these options are checked:
   - ✅ "Copy items if needed" (optional, already in project)
   - ✅ "Add to targets: Run_Map"
   - ✅ "Create folder references" (keeps folder structure)
6. Click "Add"

## Verifying Files Are Included

To verify the GPX files will be bundled:

1. Select your project in Xcode
2. Select the "Run_Map" target
3. Go to "Build Phases"
4. Expand "Copy Bundle Resources"
5. All `.gpx` files should be listed here

If they're not listed, drag them from Project Navigator into "Copy Bundle Resources".

## Adding New Demo Routes

To add more demo GPX files:

1. Place the `.gpx` file in this `Resources` folder
2. Add the file to Xcode (follow steps above)
3. Update the `demoFiles` array in `ContentView.swift` (line 876)
4. Add the filename WITHOUT the `.gpx` extension

Example:
```swift
let demoFiles = [
    "Outdoor Walk-Route-20240509_143723",
    "Your New Route Name Here"  // Add new routes here
]
```

## File Format

The GPX files must follow the standard GPX format with `<trkpt>` elements:

```xml
<gpx>
  <trk>
    <trkseg>
      <trkpt lat="52.520" lon="13.405">
        <ele>34.2</ele>
        <time>2024-01-01T12:00:00Z</time>
      </trkpt>
      <!-- more points... -->
    </trkseg>
  </trk>
</gpx>
```

The app parses these files using `loadCoordinatesFromGPX()` in `ContentView.swift`.

## Why These Files?

These demo routes cover various Berlin districts and are used to:
- Test the street coverage algorithm
- Demonstrate the app's features
- Provide sample data when HealthKit has no data

They can be removed or replaced with your own routes if desired.
