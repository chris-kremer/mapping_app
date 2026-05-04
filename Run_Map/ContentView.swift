import SwiftUI
import MapKit
import CoreLocation
import HealthKit

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocation?
    private let locationManager = CLLocationManager()
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            DispatchQueue.main.async {
                self.currentLocation = location
            }
        }
    }
}

// MARK: - Route Model

final class Route: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let date: Date
    let workoutType: HKWorkoutActivityType
    let durationSec: Double

    lazy var averageSpeedKmH: Double = {
        guard durationSec > 0 else { return 0 }
        return distanceKm / (durationSec / 3600)
    }()
    
    /// Cached length in kilometres (computed only once).
    lazy var distanceKm: Double = {
        guard coordinates.count > 1 else { return 0.0 }
        return coordinates.adjacentPairs()
            .map { from, to in
                CLLocation(latitude: from.latitude, longitude: from.longitude)
                    .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            }
            .reduce(0, +) / 1_000
    }()
    
    init(coordinates: [CLLocationCoordinate2D],
         date: Date,
         workoutType: HKWorkoutActivityType,
         durationSec: Double) {
        self.coordinates = coordinates
        self.date = date
        self.workoutType = workoutType
        self.durationSec = durationSec
    }
}

// MARK: - Persistable Route Data

struct PersistedRoute: Codable {
    let id: UUID
    let coordinates: [[String: Double]]
    let date: Date
    let workoutType: UInt
    let durationSec: Double
    
    init(from route: Route) {
        self.id = route.id
        self.coordinates = route.coordinates.map { ["lat": $0.latitude, "lon": $0.longitude] }
        self.date = route.date
        self.workoutType = route.workoutType.rawValue
        self.durationSec = route.durationSec
    }
    
    func toRoute() -> Route {
        let coords = coordinates.compactMap { dict -> CLLocationCoordinate2D? in
            guard let lat = dict["lat"], let lon = dict["lon"] else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return Route(
            coordinates: coords,
            date: date,
            workoutType: HKWorkoutActivityType(rawValue: workoutType) ?? .other,
            durationSec: durationSec
        )
    }
}

// MARK: - Route Persistence Manager

class RouteStorage {
    private let fileManager = FileManager.default
    private let fileName = "cached_routes.json"
    
    private var fileURL: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(fileName)
    }
    
    func saveRoutes(_ routes: [Route]) {
        do {
            let persistedRoutes = routes.map { PersistedRoute(from: $0) }
            let data = try JSONEncoder().encode(persistedRoutes)
            try data.write(to: fileURL)
            print("✅ Saved \(routes.count) routes to cache")
        } catch {
            print("❌ Failed to save routes: \(error.localizedDescription)")
        }
    }
    
    func loadRoutes() -> [Route] {
        do {
            let data = try Data(contentsOf: fileURL)
            let persistedRoutes = try JSONDecoder().decode([PersistedRoute].self, from: data)
            let routes = persistedRoutes.compactMap { persistedRoute -> Route? in
                let route = persistedRoute.toRoute()
                // Filter out routes with no coordinates
                guard !route.coordinates.isEmpty else {
                    print("⚠️ Filtering out cached route with no coordinates: \(route.id)")
                    return nil
                }
                return route
            }
            print("✅ Loaded \(routes.count) routes from cache")
            return routes
        } catch {
            print("ℹ️ No cached routes found or failed to load: \(error.localizedDescription)")
            return []
        }
    }
    
    func getLastSyncDate() -> Date? {
        return UserDefaults.standard.object(forKey: "lastRouteSyncDate") as? Date
    }
    
    func setLastSyncDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: "lastRouteSyncDate")
    }
    
    func clearCache() {
        try? fileManager.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: "lastRouteSyncDate")
        print("🗑️ Cleared route cache")
    }
}

// MARK: - ViewModel

class RunViewModel: ObservableObject {
    enum WorkoutFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case walking = "Walking"
        
        var id: String { rawValue }
    }

    @Published var routes: [Route] = []
    @Published var hasContent: Bool = false
    @Published var selectedFilter: WorkoutFilter = .all

    // Loading progress tracking
    @Published var loadProgress: Double = 0        // 0‥1
    private var totalToLoad: Int = 0
    private var loadedCount: Int = 0

    var displayedRoutes: [Route] {
        switch selectedFilter {
        case .all: return routes
        case .running: return routes.filter { $0.workoutType == .running }
        case .walking: return routes.filter { $0.workoutType == .walking }
        }
    }

    var totalDistanceKm: Double {
        displayedRoutes.map(\.distanceKm).reduce(0, +)
    }

    let healthManager = HealthKitManager()
    let routeStorage = RouteStorage()
    
    func loadRuns() {
        // First, load cached routes immediately for instant UI
        let cachedRoutes = routeStorage.loadRoutes()
        if !cachedRoutes.isEmpty {
            // Clean up any routes with insufficient coordinates
            let validRoutes = cachedRoutes.filter { route in
                if route.coordinates.count <= 1 {
                    print("🧹 Removing cached route with insufficient coordinates: \(route.id) (count: \(route.coordinates.count))")
                    return false
                }
                return true
            }
            
            DispatchQueue.main.async {
                self.routes = validRoutes
                self.hasContent = !validRoutes.isEmpty
                self.loadProgress = 1.0
            }
            
            // Save cleaned routes back to cache if we removed any
            if validRoutes.count != cachedRoutes.count {
                print("💾 Saving cleaned routes to cache: \(validRoutes.count) routes (removed \(cachedRoutes.count - validRoutes.count))")
                routeStorage.saveRoutes(validRoutes)
            }
        }
        
        // Then fetch new routes in background
        loadNewRuns()
    }
    
    func loadAllRunsFromScratch() {
        // Clear existing routes and cache
        DispatchQueue.main.async {
            self.routes.removeAll()
            self.hasContent = false
        }
        routeStorage.clearCache()
        
        healthManager.fetchRunningWorkouts { workouts in
            DispatchQueue.main.async {
                self.totalToLoad = workouts.count
                self.loadedCount = 0
                self.loadProgress = workouts.isEmpty ? 1 : 0
            }
            
            var newRoutes: [Route] = []
            let group = DispatchGroup()
            
            for workout in workouts {
                group.enter()
                self.healthManager.fetchRoute(for: workout) { locations in
                    let coordinates = locations.map { $0.coordinate }
                    
                    // Only process workouts that have GPS data
                    guard !coordinates.isEmpty else {
                        print("⚠️ Skipping workout with no GPS data: \(workout.startDate)")
                        group.leave()
                        return
                    }
                    
                    let segments = self.filterRoute(coordinates)
                    
                        for segment in segments {
                        // Only create routes with meaningful coordinate data
                        guard segment.count > 1 else { continue }
                        
                        let route = Route(coordinates: segment,
                                                     date: workout.startDate,
                                                     workoutType: workout.workoutActivityType,
                                        durationSec: workout.duration)
                        newRoutes.append(route)
                        }
                    
                    DispatchQueue.main.async {
                        self.loadedCount += 1
                        if self.totalToLoad > 0 {
                            self.loadProgress = Double(self.loadedCount) / Double(self.totalToLoad)
                        }
                    }
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                self.routes = newRoutes.sorted { $0.date > $1.date }
                self.hasContent = !self.routes.isEmpty
                self.routeStorage.saveRoutes(self.routes)
                self.routeStorage.setLastSyncDate(Date())
            }
        }
    }
    
    func loadNewRuns() {
        // Get all existing route IDs to avoid duplicates
        _ = Set(routes.map { route in
            // Create a unique identifier for each route based on date and coordinates
            "\(route.date.timeIntervalSince1970)_\(route.coordinates.count)"
        })
        
        healthManager.fetchRunningWorkouts { workouts in
            print("🔍 Checking \(workouts.count) total workouts against \(self.routes.count) existing routes")
            
            // Filter out workouts we already have, with some tolerance for date precision
            let newWorkouts = workouts.filter { workout in
                // Check if we already have this workout (allowing for small time differences)
                let hasExisting = self.routes.contains { route in
                    abs(route.date.timeIntervalSince1970 - workout.startDate.timeIntervalSince1970) < 1.0
                }
                return !hasExisting
            }
            
            print("🆕 Found \(newWorkouts.count) potentially new workouts to check")
            
            guard !newWorkouts.isEmpty else {
                DispatchQueue.main.async {
                    self.loadProgress = 1.0
                }
            return
        }
        
            DispatchQueue.main.async {
                self.totalToLoad = newWorkouts.count
                self.loadedCount = 0
                self.loadProgress = 0
            }
            
            var newRoutes: [Route] = []
            let group = DispatchGroup()
            
            for workout in newWorkouts {
                group.enter()
                self.healthManager.fetchRoute(for: workout) { locations in
                    let coordinates = locations.map { $0.coordinate }
                    
                    // Only process workouts that have GPS data
                    guard !coordinates.isEmpty else {
                        print("⚠️ Skipping workout with no GPS data: \(workout.startDate)")
                        group.leave()
                        return
                    }
                    
                    print("✅ Processing workout with GPS data: \(workout.startDate)")
                    
                    let segments = self.filterRoute(coordinates)
                    
                        for segment in segments {
                        // Only create routes with meaningful coordinate data
                        guard segment.count > 1 else { continue }
                        
                        let route = Route(coordinates: segment,
                                                     date: workout.startDate,
                                                     workoutType: workout.workoutActivityType,
                                        durationSec: workout.duration)
                        newRoutes.append(route)
                        }
                    
                    DispatchQueue.main.async {
                        self.loadedCount += 1
                        if self.totalToLoad > 0 {
                            self.loadProgress = Double(self.loadedCount) / Double(self.totalToLoad)
                        }
                    }
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                let skippedCount = newWorkouts.count - newRoutes.count
                print("📊 Processed \(newWorkouts.count) new workouts: \(newRoutes.count) with GPS data, \(skippedCount) skipped")
                if !newRoutes.isEmpty {
                    print("📍 Adding \(newRoutes.count) new routes to existing \(self.routes.count)")
                    self.routes.append(contentsOf: newRoutes)
                    self.routes.sort { $0.date > $1.date }
                        self.hasContent = !self.routes.isEmpty
                    
                    // Save updated routes to cache
                    self.routeStorage.saveRoutes(self.routes)
                    print("💾 Total routes after sync: \(self.routes.count)")
                } else {
                    if skippedCount > 0 {
                        print("ℹ️ No new routes added - all \(skippedCount) workouts lacked GPS data")
                    } else {
                        print("ℹ️ No new routes to add")
                    }
                }
                self.routeStorage.setLastSyncDate(Date())
                self.loadProgress = 1.0
            }
        }
    }
    
    func filterRoute(_ coordinates: [CLLocationCoordinate2D], maxDistance: CLLocationDistance = 20) -> [[CLLocationCoordinate2D]] {
        guard coordinates.count > 1 else { return [coordinates] }
        var segments: [[CLLocationCoordinate2D]] = []
        var currentSegment = [coordinates[0]]
        
        for i in 1..<coordinates.count {
            let prev = CLLocation(latitude: coordinates[i - 1].latitude,
                                  longitude: coordinates[i - 1].longitude)
            let curr = CLLocation(latitude: coordinates[i].latitude,
                                  longitude: coordinates[i].longitude)
            if prev.distance(from: curr) <= maxDistance {
                currentSegment.append(coordinates[i])
            } else {
                if currentSegment.count > 1 {
                    segments.append(currentSegment)
                }
                currentSegment = [coordinates[i]]
            }
        }
        if currentSegment.count > 1 {
            segments.append(currentSegment)
        }
        return segments
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count > 1 else { return [] }
        return (0..<(count-1)).map { (self[$0], self[$0+1]) }
    }
}

// MARK: - RoutePolyline

class RoutePolyline: MKPolyline {
    var routeID: UUID?
    var routeDate: Date?
    var workoutType: HKWorkoutActivityType?
    var isHighlighted: Bool = false
    var averageSpeed: Double?
}

// District polygon overlay with metadata for styling
class DistrictPolygon: MKPolygon {
    var districtName: String = ""
    var colorIndex: Int = 0
}

class DistrictAnnotation: MKPointAnnotation {}

private struct LiveRouteSignature: Equatable {
    let count: Int
    let firstLatitude: Double?
    let firstLongitude: Double?
    let lastLatitude: Double?
    let lastLongitude: Double?

    init(coordinates: [CLLocationCoordinate2D]) {
        count = coordinates.count
        firstLatitude = coordinates.first?.latitude
        firstLongitude = coordinates.first?.longitude
        lastLatitude = coordinates.last?.latitude
        lastLongitude = coordinates.last?.longitude
    }
}

private extension RoutePolyline {
    /// Convenience factory because `MKPolyline(coordinates:count:)`
    /// is a *convenience* initializer that isn’t inherited by subclasses.
    static func fromCoordinates(_ coords: [CLLocationCoordinate2D]) -> RoutePolyline {
        // MKPolyline (and subclasses) expose an initializer that takes an *array* directly.
        return RoutePolyline(coordinates: coords, count: coords.count)
    }
}

// MARK: - Map Region Computation

/// Computes an MKCoordinateRegion that fits all the given coordinates
func coordinateRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
    guard !coordinates.isEmpty else {
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
                                  span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))
    }
    
    let latitudes = coordinates.map { $0.latitude }
    let longitudes = coordinates.map { $0.longitude }
    
    let minLat = latitudes.min()!
    let maxLat = latitudes.max()!
    let minLon = longitudes.min()!
    let maxLon = longitudes.max()!
    
    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                        longitude: (minLon + maxLon) / 2)
    let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.3,
                                longitudeDelta: (maxLon - minLon) * 1.3)
    
    return MKCoordinateRegion(center: center, span: span)
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var viewModel = RunViewModel()
    @StateObject private var locationManager = LocationManager()

    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false
    @AppStorage("mapType") private var mapTypeRawValue: Int = Int(MKMapType.standard.rawValue)

    private var mapType: MKMapType {
        get { MKMapType(rawValue: UInt(mapTypeRawValue)) ?? .standard }
        set { mapTypeRawValue = Int(newValue.rawValue) }
    }

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0), // World view center
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180) // World view span
    )
    @State private var hasSetInitialLocation = false
    @State private var isLoading = true
    @State private var highlightedRouteIDs: Set<UUID> = []
    @State private var showLatestDayLabel = false
    @State private var showUserLocation = true
    @State private var showNoWorkouts = false
    @State private var showNewCountryAlert = false
    @State private var newCountriesFound: [String] = []

    // Tracking state variables
    @State private var isTracking = false
    @State private var liveCoordinates: [CLLocationCoordinate2D] = []
    @State private var trackingTimer: Timer?
    @State private var showControls = false
    @State private var showStats = false
    @State private var showAchievementsPage = false
    @StateObject private var achievementsManager = AchievementsManager()
    
    // District overlay state
    @State private var selectedDistrictOverlay: (name: String, lat: Double, lon: Double)? = nil
    @State private var showAllBerlinDistricts = false

    // Stats banner state
    @AppStorage("lastRunCount") private var lastRunCount = 0
    @AppStorage("lastDistanceKm") private var lastDistanceKm: Double = 0
    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false
    @State private var summaryMessage: String?
    @State private var showSummaryAlert = false
    @State private var hasShownSummary = false

    private func circleButton(icon: String, bg: Color = .blue) -> some View {
        Image(systemName: icon)
            .foregroundColor(.white)
            .padding()
            .background(bg)
            .clipShape(Circle())
    }


    var body: some View {
        ZStack {
            RouteMapView(routes: viewModel.displayedRoutes,
                         region: region,
                         highlightedRouteIDs: highlightedRouteIDs,
                         showUserLocation: showUserLocation,
                         liveCoordinates: liveCoordinates,
                         mapType: mapType,
                         districtOverlay: selectedDistrictOverlay,
                         showAllBerlinDistricts: showAllBerlinDistricts)
                .onReceive(locationManager.$currentLocation) { location in
                    // Center map on user's current location when first obtained
                    if let location = location, !hasSetInitialLocation {
                        withAnimation(.easeInOut(duration: 1.5)) {
                            region = MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05) // Closer zoom for current location
                            )
                            hasSetInitialLocation = true
                        }
                    }
                }
                .onReceive(viewModel.$routes) { routes in
                    // If no current location available, center on latest workout
                    if !hasSetInitialLocation && !routes.isEmpty {
                        if let latestRoute = routes.first, 
                           let firstCoord = latestRoute.coordinates.first,
                           firstCoord.latitude.isFinite && firstCoord.longitude.isFinite &&
                           abs(firstCoord.latitude) <= 90 && abs(firstCoord.longitude) <= 180 {
                            withAnimation(.easeInOut(duration: 1.5)) {
                                region = MKCoordinateRegion(
                                    center: firstCoord,
                                    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1) // Medium zoom for workout location
                                )
                                hasSetInitialLocation = true
                            }
                        }
                        // If no valid coordinates found, stay at world view (hasSetInitialLocation remains false)
                    }
                }
                .ignoresSafeArea()
            
            VStack {
                // Demo workout label
                if viewModel.routes.contains(where: { $0.date == Date.distantPast }) {
                    Text("Showing Demo Workout")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()
                if showLatestDayLabel {
                    Text("Latest Day")
                        .font(.headline).bold()
                        .padding(12)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                Spacer()

                .padding(.bottom, 8)
            }
            
            if isLoading {
                Text("Loading \(Int(viewModel.loadProgress * 100))%")
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    if showControls {
                        // Highlight button
                        circleButton(icon: "highlighter")
                            .onTapGesture {
                                if let latest = viewModel.routes.sorted(by: { $0.date > $1.date }).first {
                                    let calendar = Calendar.current

                                    // Find all routes from the same day
                                    let routesFromLatestDay = viewModel.routes.filter { route in
                                        calendar.isDate(route.date, inSameDayAs: latest.date)
                                    }

                                    highlightedRouteIDs = Set(routesFromLatestDay.map { $0.id })

                                    // Create region that encompasses all routes from that day
                                    let allCoordinates = routesFromLatestDay.flatMap { $0.coordinates }
                                    region = coordinateRegion(for: allCoordinates)

                                    showLatestDayLabel = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        showLatestDayLabel = false
                                    }
                                }
                            }
                            .onLongPressGesture {
                                highlightedRouteIDs.removeAll()
                                selectedDistrictOverlay = nil
                                showAllBerlinDistricts = false
                            }

                        // Tracking button
                        circleButton(icon: isTracking ? "pause.circle" : "dot.circle",
                                     bg: isTracking ? .red : .blue)
                            .onTapGesture { toggleTracking() }

                        // Update‑from‑HealthKit button
                        circleButton(icon: "arrow.clockwise")
                            .onTapGesture {
                                isLoading = true
                                viewModel.loadNewRuns()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isLoading = false }
                            }

                        // Re‑center to current location
                        circleButton(icon: "location.fill")
                            .onTapGesture {
                                // Short press: always go to current location
                                print("🎯 Location button tapped")
                                if let loc = locationManager.currentLocation {
                                    print("📍 Current location found: \(loc.coordinate)")
                                    
                                    // Add a tiny random offset to ensure the region always changes
                                    // This forces the map to update even if clicking the same location repeatedly
                                    let randomOffset = Double.random(in: -0.0001...0.0001)
                                    let adjustedCenter = CLLocationCoordinate2D(
                                        latitude: loc.coordinate.latitude + randomOffset,
                                        longitude: loc.coordinate.longitude + randomOffset
                                    )
                                    
                                    let newRegion = MKCoordinateRegion(
                                        center: adjustedCenter,
                                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
                                    print("🎯 Setting region to: \(newRegion)")
                                    withAnimation(.easeInOut(duration: 1.0)) {
                                        region = newRegion
                                    }
                                } else {
                                    print("⚠️ No current location available - check location permissions in Settings")
                                }
                            }
                            .onLongPressGesture {
                                // Long press: toggle user location dot
                                showUserLocation.toggle()
                            }

                        // Map style toggle button
                        circleButton(icon: mapType == .standard ? "globe" : "map")
                            .onTapGesture {
                                mapTypeRawValue = Int(
                                    (mapType == .standard ? MKMapType.satellite : MKMapType.standard).rawValue
                                )
                            }


                        // Stats button
                        circleButton(icon: "chart.bar")
                            .onTapGesture {
                                showStats = true
                            }

                        // Achievements button
                        circleButton(icon: "trophy.fill")
                            .onTapGesture {
                                showAchievementsPage = true
                            }

                    }

                    // Main FAB that toggles the stack
                    circleButton(icon: showControls ? "xmark" : "plus")
                        .rotationEffect(.degrees(showControls ? 45 : 0))
                        .onTapGesture {
                            withAnimation { showControls.toggle() }
                        }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onAppear {
            viewModel.healthManager.requestAuthorization { _ in
                viewModel.loadRuns()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let latest = viewModel.routes.sorted(by: { $0.date > $1.date }).first {
                        let calendar = Calendar.current
                        let routesFromLatestDay = viewModel.routes.filter { route in
                            calendar.isDate(route.date, inSameDayAs: latest.date)
                        }
                        highlightedRouteIDs = Set(routesFromLatestDay.map { $0.id })
                        let allCoordinates = routesFromLatestDay.flatMap { $0.coordinates }
                        region = coordinateRegion(for: allCoordinates)
                    }
                    isLoading = false
                }
            }
        }
        .onReceive(viewModel.$loadProgress) { progress in
            if progress >= 1 {
                // After all HealthKit queries finish decide whether to show the empty state
                showNoWorkouts = viewModel.routes.isEmpty
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isLoading = false
                    // Check for new countries after loading is complete
                    checkForNewCountries(routes: viewModel.routes)
                }
                if !hasShownSummary {
                    let newRuns = viewModel.routes.count - lastRunCount
                    let newDistance = viewModel.totalDistanceKm - lastDistanceKm
                    if hasLaunchedBefore {
                        if newRuns == 0 && newDistance == 0 {
                            summaryMessage = "Go explore!"
                            // Auto-close after 1 second
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                showSummaryAlert = false
                            }
                        } else {
                            // Get countries from new runs (ensure newRuns is not negative)
                            let safeNewRuns = max(0, newRuns)
                            let newRoutes = Array(viewModel.routes.prefix(safeNewRuns))
                            var newCountries = Set<String>()
                            
                            for route in newRoutes {
                                guard let firstCoord = route.coordinates.first else { continue }
                                let geocodeResult = LocalGeocoder.geocode(latitude: firstCoord.latitude, longitude: firstCoord.longitude)
                                if !geocodeResult.country.isEmpty && geocodeResult.country != "Unknown" {
                                    newCountries.insert(geocodeResult.country)
                                }
                            }
                            
                            var message = "You added \(newRuns) runs for " + String(format: "%.1f", newDistance) + " km"

                            // Check for new streets in Berlin
                            var newStreetNames: Set<String> = []
                            let isBerlinRun = newCountries.contains("Germany") && newRoutes.contains { route in
                                guard let first = route.coordinates.first else { return false }
                                return BerlinDistricts.getDistrict(lat: first.latitude, lon: first.longitude) != nil
                            }

                            if isBerlinRun {
                                // Get newly covered streets from the latest routes
                                let newRouteIDs = Set(newRoutes.map { "\($0.date.timeIntervalSince1970)" })
                                for (routeID, coverageData) in achievementsManager.processedRoutes {
                                    if newRouteIDs.contains(routeID) {
                                        // Get unique street names from this route's segments
                                        let streetNames = Set(coverageData.coveredSegments.map { $0.streetName })
                                        newStreetNames.formUnion(streetNames)
                                    }
                                }
                            }

                            if !newCountries.isEmpty {
                                let sortedCountries = Array(newCountries).sorted()
                                if sortedCountries.count == 1 {
                                    message += " in \(sortedCountries[0])"
                                } else {
                                    message += " in \(sortedCountries.joined(separator: ", "))"
                                }
                            }

                            // Add new streets info if any
                            if !newStreetNames.isEmpty {
                                let streetList = Array(newStreetNames.prefix(5)).sorted()
                                if streetList.count <= 3 {
                                    message += "\n\nNew streets covered: \(streetList.joined(separator: ", "))"
                                } else {
                                    message += "\n\nNew streets covered: \(streetList.prefix(3).joined(separator: ", ")) and \(newStreetNames.count - 3) more"
                                }
                            }

                            message += "\n\nGreat job!"
                            summaryMessage = message
                        }
                        showSummaryAlert = true
                    }
                    lastRunCount = viewModel.routes.count
                    lastDistanceKm = viewModel.totalDistanceKm
                    hasShownSummary = true
                    hasLaunchedBefore = true
                }
            } else {
                isLoading = true
            }
        }
    // end ZStack
        .fullScreenCover(isPresented: Binding(
            get: { !hasSeenTutorial },
            set: { _ in })) {
            OnboardingView {
                hasSeenTutorial = true
            }
        }
        .fullScreenCover(isPresented: $showNoWorkouts) {
            NoWorkoutsView {
                loadDemoWorkouts()
                showNoWorkouts = false
            }
        }
        .sheet(isPresented: $showStats) {
            StatsView(routes: viewModel.displayedRoutes) { country, city in
                navigateToLocation(country: country, city: city)
            }
        }
        .sheet(isPresented: $showAchievementsPage) {
            AchievementsView(
                achievementsManager: achievementsManager,
                routes: viewModel.routes,
                onDistrictSelected: { districtName, lat, lon in
                    selectedDistrictOverlay = (districtName, lat, lon)
                    showAllBerlinDistricts = false
                    let districtCenter = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    let newRegion = MKCoordinateRegion(
                        center: districtCenter,
                        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
                    )
                    withAnimation(.easeInOut(duration: 1.0)) {
                        region = newRegion
                    }
                },
                onShowAllDistricts: {
                    selectedDistrictOverlay = nil
                    showAllBerlinDistricts = true
                    let berlinCenter = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)
                    let newRegion = MKCoordinateRegion(
                        center: berlinCenter,
                        span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
                    )
                    withAnimation(.easeInOut(duration: 1.0)) {
                        region = newRegion
                    }
                },
                onLocationSelected: { country, city in
                    navigateToLocation(country: country, city: city)
                }
            )
        }
        .alert(summaryMessage ?? "", isPresented: $showSummaryAlert) {
            Button("OK", role: .cancel) { }
        }
        .alert("🎉 New Country Visited!", isPresented: $showNewCountryAlert) {
            Button("Awesome!", role: .cancel) { }
        } message: {
            if newCountriesFound.count == 1 {
                Text("Congratulations! You've explored a new country: \(newCountriesFound.first!)! 🌍")
            } else {
                Text("Congratulations! You've explored \(newCountriesFound.count) new countries: \(newCountriesFound.joined(separator: ", "))! 🌍")
            }
        }
    }   // ← closes the `var body: some View` property

    private func loadDemoWorkouts() {
        // To add additional demo workouts, drop more .gpx files into the app bundle
        // and list their base names in the `demoFiles` array below.
        let demoFiles = ["Outdoor Walk-Route-20240509_143723", "Outdoor Walk-Route-20241211_185505", "Outdoor Walk-Route-20241208_145435", "Outdoor Walk-Route-20241201_182250", "Outdoor Walk-Route-20241210_181825"]   // add more GPX names if desired
        for name in demoFiles {
            let coords = loadCoordinatesFromGPX(named: name)
            if !coords.isEmpty {
                viewModel.routes.append(
                    Route(coordinates: coords,
                          date: Date.distantPast,
                          workoutType: .walking,
                          durationSec: 0)
                )
            }
        }
        viewModel.hasContent = !viewModel.routes.isEmpty
    }

    private func toggleTracking() {
        if isTracking {
            trackingTimer?.invalidate()
            trackingTimer = nil
            isTracking = false
            if liveCoordinates.count > 1 {
                let est = Double(max(liveCoordinates.count - 1, 1)) * 5
                viewModel.routes.append(
                    Route(coordinates: liveCoordinates,
                          date: Date(),
                          workoutType: .other,
                          durationSec: est)
                )
            }
            liveCoordinates.removeAll()
        } else {
            isTracking = true
            liveCoordinates.removeAll()
            if let loc = locationManager.currentLocation?.coordinate {
                liveCoordinates.append(loc)
            }
            trackingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                if let loc = locationManager.currentLocation?.coordinate {
                    liveCoordinates.append(loc)
                }
            }
        }
    }

    private func checkForNewCountries(routes: [Route]) {
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        
        // Get routes from the last week
        let recentRoutes = routes.filter { $0.date >= oneWeekAgo }
        guard !recentRoutes.isEmpty else { return }
        
        // Get ALL historical countries from all routes (not just stored ones)
        var allHistoricalCountries = Set<String>()
        
        for route in routes {
            guard let firstCoord = route.coordinates.first else { continue }
            let geocodeResult = LocalGeocoder.geocode(latitude: firstCoord.latitude, longitude: firstCoord.longitude)
            if !geocodeResult.country.isEmpty && geocodeResult.country != "Unknown" {
                allHistoricalCountries.insert(geocodeResult.country)
            }
        }
        
        // Get countries from recent routes only
        var recentCountries = Set<String>()
        
        for route in recentRoutes {
            guard let firstCoord = route.coordinates.first else { continue }
            let geocodeResult = LocalGeocoder.geocode(latitude: firstCoord.latitude, longitude: firstCoord.longitude)
            if !geocodeResult.country.isEmpty && geocodeResult.country != "Unknown" {
                recentCountries.insert(geocodeResult.country)
            }
        }
        
        // Get previously stored countries (from last app run)
        let previouslyKnownCountries = Set(UserDefaults.standard.stringArray(forKey: "visitedCountries") ?? [])
        
        // Find truly new countries: countries from recent workouts that weren't known in the previous app session
        let newCountries = recentCountries.subtracting(previouslyKnownCountries)
        
        if !newCountries.isEmpty {
            newCountriesFound = Array(newCountries).sorted()
            showNewCountryAlert = true
        }
        
        // Update stored countries with all historical countries
        UserDefaults.standard.set(Array(allHistoricalCountries), forKey: "visitedCountries")
    }
    
    private func navigateToLocation(country: String, city: String) {
        print("🗺️ Navigating to: country='\(country)', city='\(city)'")
        
        // Find routes that match the selected location
        var matchingRoutes: [Route] = []
        
        // Safely iterate through routes
        for route in viewModel.routes {
            guard !route.coordinates.isEmpty else { continue }
            
            // Sample multiple points from the route for better accuracy
            let sampleCount = min(5, route.coordinates.count)
            let step = max(1, route.coordinates.count / sampleCount)
            
            var routeMatches = false
            for i in stride(from: 0, to: route.coordinates.count, by: step) {
                let coord = route.coordinates[i]
                guard coord.latitude.isFinite && coord.longitude.isFinite else { continue }
                
                let geocodeResult = LocalGeocoder.geocode(latitude: coord.latitude, longitude: coord.longitude)
                
                // Debug: print geocoding result for first sample point
                if i == 0 {
                    print("📍 Route \(route.id): geocoded as '\(geocodeResult.country)' / '\(geocodeResult.city)'")
                }
                
                // If we're looking for a specific city, match both country and city
                if !city.isEmpty && city != "Unknown" {
                    if !country.isEmpty && geocodeResult.country == country && geocodeResult.city == city {
                        print("✅ City match found: \(geocodeResult.country) / \(geocodeResult.city)")
                        routeMatches = true
                        break
                    } else if country.isEmpty && geocodeResult.city == city {
                        // City-only search (when country is empty)
                        print("✅ City-only match found: \(geocodeResult.city) in \(geocodeResult.country)")
                        routeMatches = true
                        break
                    }
                } else if !country.isEmpty {
                    // If only country is specified, match just the country
                    if geocodeResult.country == country {
                        print("✅ Country match found: \(geocodeResult.country)")
                        routeMatches = true
                        break
                    }
                }
            }
            
            if routeMatches {
                matchingRoutes.append(route)
            }
        }
        
        // Navigate to the matching routes
        print("🔍 Found \(matchingRoutes.count) matching routes")
        if !matchingRoutes.isEmpty {
            // Create a region that encompasses the entire country/city, not just the routes
            let targetRegion = createRegionForLocation(country: country, city: city, routes: matchingRoutes)
            print("🎯 Target region: center=\(targetRegion.center), span=\(targetRegion.span)")
            
            print("🔄 About to update region state from \(region.center) to \(targetRegion.center)")
            withAnimation(.easeInOut(duration: 1.0)) {
                region = targetRegion
            }
            print("🔄 Region state updated to \(region.center)")
            
            // Highlight the matching routes
            highlightedRouteIDs = Set(matchingRoutes.map { $0.id })
            print("✨ Highlighted \(highlightedRouteIDs.count) routes")
            
            // Show label briefly
            showLatestDayLabel = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                showLatestDayLabel = false
            }
        } else {
            print("⚠️ No matching routes found for country='\(country)', city='\(city)'")
        }
        
        // Dismiss the stats sheet
        showStats = false
    }
    
    private func createRegionForLocation(country: String, city: String, routes: [Route]) -> MKCoordinateRegion {
        // Get all coordinates from the routes to determine the center
        let allCoords = routes.flatMap { $0.coordinates }
        guard !allCoords.isEmpty else {
            // Fallback to world view if no coordinates
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)
            )
        }
        
        // Calculate the center from route coordinates
        let centerLat = allCoords.map { $0.latitude }.reduce(0, +) / Double(allCoords.count)
        let centerLon = allCoords.map { $0.longitude }.reduce(0, +) / Double(allCoords.count)
        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
        
        // Determine appropriate span based on location type
        let span: MKCoordinateSpan
        
        if !city.isEmpty && city != "Unknown" {
            // City view - smaller span
            span = MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        } else {
            // Country view - larger span based on country
            span = getCountrySpan(for: country, center: center)
        }
        
        return MKCoordinateRegion(center: center, span: span)
    }
    
    private func getCountrySpan(for country: String, center: CLLocationCoordinate2D) -> MKCoordinateSpan {
        // Define spans for different countries/regions
        switch country {
        case "United States":
            return MKCoordinateSpan(latitudeDelta: 25, longitudeDelta: 40)
        case "Canada":
            return MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 60)
        case "Russia":
            return MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 100)
        case "China":
            return MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40)
        case "Brazil":
            return MKCoordinateSpan(latitudeDelta: 25, longitudeDelta: 30)
        case "Australia":
            return MKCoordinateSpan(latitudeDelta: 25, longitudeDelta: 35)
        case "India":
            return MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 25)
        case "Germany", "France", "United Kingdom", "Italy", "Spain":
            return MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 10)
        case "Japan":
            return MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 15)
        default:
            // Default span for smaller countries or unknown countries
            return MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
        }
    }


}

// MARK: - RouteMapView

struct RouteMapView: UIViewRepresentable {
    var routes: [Route]
    var region: MKCoordinateRegion
    var highlightedRouteIDs: Set<UUID>
    var showUserLocation: Bool
    var liveCoordinates: [CLLocationCoordinate2D]
    var mapType: MKMapType
    var districtOverlay: (name: String, lat: Double, lon: Double)? = nil
    var showAllBerlinDistricts: Bool = false
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.region = region
        mapView.showsUserLocation = showUserLocation
        mapView.mapType = mapType
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Update region when it changes (use larger tolerance to ensure updates work)
        if !mapView.region.center.isEqual(to: region.center, tolerance: 0.01) ||
           abs(mapView.region.span.latitudeDelta - region.span.latitudeDelta) > 0.01 ||
           abs(mapView.region.span.longitudeDelta - region.span.longitudeDelta) > 0.01 {
            mapView.setRegion(region, animated: true)
        }

        if mapView.showsUserLocation != showUserLocation {
            mapView.showsUserLocation = showUserLocation
        }

        if mapView.mapType != mapType {
            mapView.mapType = mapType
        }

        context.coordinator.reconcileDistrictOverlays(
            on: mapView,
            districtOverlay: districtOverlay,
            showAllBerlinDistricts: showAllBerlinDistricts
        )

        context.coordinator.reconcileLiveRoute(on: mapView, coordinates: liveCoordinates)

        let existingIDs = Set(context.coordinator.routeOverlaysByID.keys)
        let desiredIDs = Set(routes.map(\.id))

        let staleIDs = existingIDs.subtracting(desiredIDs)
        let staleOverlays = staleIDs.compactMap { context.coordinator.routeOverlaysByID.removeValue(forKey: $0) }
        if !staleOverlays.isEmpty {
            mapView.removeOverlays(staleOverlays)
        }

        var toAdd: [MKOverlay] = []
        for route in routes where !existingIDs.contains(route.id) {
            let pl = RoutePolyline.fromCoordinates(route.coordinates)
            pl.routeID = route.id
            pl.routeDate = route.date
            pl.workoutType = route.workoutType
            pl.isHighlighted = highlightedRouteIDs.contains(route.id)
            pl.averageSpeed = route.averageSpeedKmH
            context.coordinator.routeOverlaysByID[route.id] = pl
            toAdd.append(pl)
        }
        if !toAdd.isEmpty { mapView.addOverlays(toAdd) }

        for (routeID, pl) in context.coordinator.routeOverlaysByID {
            let shouldHighlight = highlightedRouteIDs.contains(routeID)
            if pl.isHighlighted != shouldHighlight {
                pl.isHighlighted = shouldHighlight
                if let r = mapView.renderer(for: pl) as? MKPolylineRenderer {
                    r.strokeColor = shouldHighlight ? .orange :
                        (pl.workoutType == .running ? UIColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 1.0) :
                         pl.workoutType == .walking ? .systemBlue : .systemGreen)
                    r.setNeedsDisplay()
                }
            }
        }
    }

    // Create the coordinator that acts as MKMapViewDelegate
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        private var districtOverlayKey: String?
        private var districtOverlays: [MKOverlay] = []
        private var districtAnnotations: [MKAnnotation] = []
        private var liveRouteSignature: LiveRouteSignature?
        private var liveRouteOverlay: RoutePolyline?
        private var liveStartAnnotation: MKPointAnnotation?
        var routeOverlaysByID: [UUID: RoutePolyline] = [:]

        init(_ parent: RouteMapView) { self.parent = parent }

        func reconcileDistrictOverlays(
            on mapView: MKMapView,
            districtOverlay: (name: String, lat: Double, lon: Double)?,
            showAllBerlinDistricts: Bool
        ) {
            let nextKey: String
            if showAllBerlinDistricts {
                nextKey = "all"
            } else if let districtOverlay {
                nextKey = "single:\(districtOverlay.name)"
            } else {
                nextKey = "none"
            }

            guard nextKey != districtOverlayKey else { return }

            if !districtOverlays.isEmpty {
                mapView.removeOverlays(districtOverlays)
                districtOverlays.removeAll(keepingCapacity: true)
            }
            if !districtAnnotations.isEmpty {
                mapView.removeAnnotations(districtAnnotations)
                districtAnnotations.removeAll(keepingCapacity: true)
            }

            districtOverlayKey = nextKey
            guard nextKey != "none" else { return }

            let districtsToRender: [(name: String, lat: Double, lon: Double)]
            if showAllBerlinDistricts {
                districtsToRender = BerlinDistricts.districts.map { ($0.name, $0.lat, $0.lon) }
            } else if let districtOverlay {
                districtsToRender = [districtOverlay]
            } else {
                districtsToRender = []
            }

            for district in districtsToRender {
                let center = CLLocationCoordinate2D(latitude: district.lat, longitude: district.lon)
                let ann = DistrictAnnotation()
                ann.coordinate = center
                ann.title = district.name
                ann.subtitle = "District Label"
                districtAnnotations.append(ann)

                if let boundary = BerlinDistricts.boundaries.first(where: { $0.name == district.name }) {
                    for polygon in boundary.polygons {
                        if let outer = polygon.first, outer.count >= 3 {
                            let mkPolygon = DistrictPolygon(coordinates: outer, count: outer.count)
                            mkPolygon.districtName = district.name
                            mkPolygon.colorIndex = BerlinDistricts.districts.firstIndex(where: { $0.name == district.name }) ?? 0
                            districtOverlays.append(mkPolygon)
                        }
                    }
                }
            }

            if !districtAnnotations.isEmpty {
                mapView.addAnnotations(districtAnnotations)
            }
            if !districtOverlays.isEmpty {
                mapView.addOverlays(districtOverlays)
            }
        }

        func reconcileLiveRoute(on mapView: MKMapView, coordinates: [CLLocationCoordinate2D]) {
            let nextSignature = LiveRouteSignature(coordinates: coordinates)
            guard nextSignature != liveRouteSignature else { return }

            if let liveRouteOverlay {
                mapView.removeOverlay(liveRouteOverlay)
                self.liveRouteOverlay = nil
            }
            if let liveStartAnnotation {
                mapView.removeAnnotation(liveStartAnnotation)
                self.liveStartAnnotation = nil
            }

            liveRouteSignature = nextSignature
            guard coordinates.count > 1 else { return }

            let live = RoutePolyline.fromCoordinates(coordinates)
            liveRouteOverlay = live
            mapView.addOverlay(live)

            if let start = coordinates.first {
                let pin = MKPointAnnotation()
                pin.coordinate = start
                pin.title = "Start"
                liveStartAnnotation = pin
                mapView.addAnnotation(pin)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? DistrictPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                // Black dotted borders
                renderer.strokeColor = .black
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
                // Pastel fill color based on index
                let palette: [UIColor] = [
                    UIColor(red: 0.90, green: 0.49, blue: 0.47, alpha: 0.3),
                    UIColor(red: 0.99, green: 0.76, blue: 0.38, alpha: 0.3),
                    UIColor(red: 0.99, green: 0.94, blue: 0.60, alpha: 0.3),
                    UIColor(red: 0.70, green: 0.87, blue: 0.54, alpha: 0.3),
                    UIColor(red: 0.54, green: 0.80, blue: 0.94, alpha: 0.3),
                    UIColor(red: 0.80, green: 0.67, blue: 0.94, alpha: 0.3),
                    UIColor(red: 0.95, green: 0.66, blue: 0.88, alpha: 0.3),
                    UIColor(red: 0.95, green: 0.84, blue: 0.70, alpha: 0.3),
                    UIColor(red: 0.66, green: 0.88, blue: 0.80, alpha: 0.3),
                    UIColor(red: 0.80, green: 0.88, blue: 0.99, alpha: 0.3),
                    UIColor(red: 0.88, green: 0.80, blue: 0.99, alpha: 0.3),
                    UIColor(red: 0.99, green: 0.80, blue: 0.88, alpha: 0.3)
                ]
                let idx = max(0, min(polygon.colorIndex % palette.count, palette.count - 1))
                renderer.fillColor = palette[idx]
                return renderer
            }
            guard let polyline = overlay as? RoutePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            
            let renderer = MKPolylineRenderer(polyline: polyline)
            if polyline.isHighlighted {
                renderer.strokeColor = .orange
            } else {
                switch polyline.workoutType {
                case .running:
                    renderer.strokeColor = UIColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 1.0) // Bright blue
                case .walking:
                    renderer.strokeColor = .systemBlue
                default:
                    renderer.strokeColor = .systemGreen
                }
            }
            renderer.lineWidth = 4
            return renderer
        }
        
        // Custom label-only annotation views for district labels
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation else { return nil }
            guard point.subtitle == "District Label" else { return nil }
            let identifier = "DistrictLabelView"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = false
            view.image = nil
            // Remove previous subviews
            view.subviews.forEach { $0.removeFromSuperview() }
            // Add a label
            let label = UILabel()
            label.text = point.title ?? ""
            label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            label.textColor = UIColor.systemBlue
            label.backgroundColor = UIColor.white.withAlphaComponent(0.6)
            label.layer.cornerRadius = 4
            label.layer.masksToBounds = true
            label.sizeToFit()
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }
    }
}


struct RouteListView: View {
    var routes: [Route]
    var select: (Route) -> Void
    
    var body: some View {
        NavigationView {
            List {
                ForEach(routes.sorted(by: { $0.date > $1.date })) { route in
                    Button {
                        select(route)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(route.date, style: .date)
                            Text(String(format: "%.2f km", route.distanceKm))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { }
                }
            }
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    var dismiss: () -> Void

    var body: some View {
        TabView {
            VStack(spacing: 24) {
                Image(systemName: "map")
                    .resizable().scaledToFit().frame(height: 120)
                Text("See all your runs and walks on a beautiful map.")
                    .font(.title3).multilineTextAlignment(.center)
            }
            .padding()

            VStack(spacing: 24) {
                Image(systemName: "record.circle")
                    .resizable().scaledToFit().frame(height: 120)
                Text("Record a live route with the • button.\nWe’ll plot it in real‑time.")
                    .font(.title3).multilineTextAlignment(.center)
            }
            .padding()

            VStack(spacing: 24) {
                Image(systemName: "highlighter")
                    .resizable().scaledToFit().frame(height: 120)
                Text("Tap the highlighter to jump to your latest day's workouts.\nLong‑press to clear the highlight.")
                    .font(.title3).multilineTextAlignment(.center)
            }
            .padding()

            VStack(spacing: 24) {
                Image(systemName: "plus.circle")
                    .resizable().scaledToFit().frame(height: 120)
                Text("All controls are tucked under the + button.\nTap to expand, tap × to hide.")
                    .font(.title3).multilineTextAlignment(.center)

                Button("Get Started") {
                    dismiss()
                }
                .font(.headline)
                .padding(.horizontal, 32).padding(.vertical, 12)
                .background(Color.blue).foregroundColor(.white)
                .clipShape(Capsule())
            }
            .padding()
        }
        .tabViewStyle(PageTabViewStyle())
    }
}

// MARK: - No Workouts View
struct NoWorkoutsView: View {
    var loadDemoAndDismiss: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "figure.walk.motion")
                .resizable().scaledToFit().frame(height: 120)
                .foregroundColor(.blue)

            Text("No workouts found")
                .font(.title).bold()

            Text("Connect to Health and record a run or tap below to load a couple of demo workouts to see the app in action.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Load Demo Workouts") {
                loadDemoAndDismiss()
            }
            .font(.headline)
            .padding(.horizontal, 32).padding(.vertical, 12)
            .background(Color.blue).foregroundColor(.white)
            .clipShape(Capsule())
        }
        .padding()
    }
}

// MARK: - GPX Parsing

import Foundation

func loadCoordinatesFromGPX(named fileName: String) -> [CLLocationCoordinate2D] {
    guard let url = Bundle.main.url(forResource: fileName, withExtension: "gpx"),
          let data = try? Data(contentsOf: url) else {
        return []
    }
    let xml = XMLParser(data: data)

    let delegate = GPXParserDelegate()
    xml.delegate = delegate
    xml.parse()
    return delegate.coordinates
}

private class GPXParserDelegate: NSObject, XMLParserDelegate {
    var coordinates: [CLLocationCoordinate2D] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        if elementName == "trkpt",
           let latStr = attributeDict["lat"],
           let lonStr = attributeDict["lon"],
           let lat = Double(latStr),
           let lon = Double(lonStr) {
            coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }
}

extension CLLocationCoordinate2D {
    func isEqual(to other: CLLocationCoordinate2D, tolerance: Double) -> Bool {
        return abs(latitude - other.latitude) < tolerance &&
               abs(longitude - other.longitude) < tolerance
    }
}
