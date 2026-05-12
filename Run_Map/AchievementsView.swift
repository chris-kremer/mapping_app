import SwiftUI
import HealthKit
import CoreLocation
import MapKit

// MARK: - Achievement Model

enum AchievementTier: String, Codable, Comparable {
    case none = "Locked"
    case bronze = "Bronze"
    case silver = "Silver"
    case gold = "Gold"
    case platinum = "Platinum"

    var color: Color {
        switch self {
        case .none: return Color.gray
        case .bronze: return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .silver: return Color(red: 0.75, green: 0.75, blue: 0.75)
        case .gold: return Color(red: 1.0, green: 0.84, blue: 0.0)
        case .platinum: return Color(red: 0.4, green: 0.8, blue: 1.0) // Bright cyan/sky blue
        }
    }

    // Numeric value for comparison
    var numericValue: Int {
        switch self {
        case .none: return 0
        case .bronze: return 1
        case .silver: return 2
        case .gold: return 3
        case .platinum: return 4
        }
    }

    static func < (lhs: AchievementTier, rhs: AchievementTier) -> Bool {
        return lhs.numericValue < rhs.numericValue
    }
}

struct Achievement: Identifiable {
    let id: String
    let title: String
    let iconName: String
    let category: AchievementCategory
    let tiers: [AchievementTier: String] // tier -> description
    var currentTier: AchievementTier
    var unlockedDate: Date?
    var currentProgress: Double = 0 // Current user progress value
    var nextTierGoal: Double = 0 // Goal for next tier

    enum AchievementCategory: String, Codable {
        case distance = "Exploring distance"
        case country = "Countries"
        case city = "Cities"
        case daily = "Daily"
        case exploration = "Exploration"
        case specials = "Explore Berlin"
    }

    var isUnlocked: Bool {
        return currentTier != .none
    }

    func description(for tier: AchievementTier) -> String {
        return tiers[tier] ?? ""
    }

    var currentDescription: String {
        return description(for: currentTier)
    }

    var progressMessage: String {
        if currentTier == .platinum {
            return "Max tier achieved!"
        }

        let remaining = nextTierGoal - currentProgress
        if remaining <= 0 {
            return "Ready to upgrade!"
        }

        // Format based on achievement type
        if id.contains("distance") && !id.contains("daily") {
            // For cumulative distance achievements
            return String(format: "%.0f km to next tier", remaining)
        } else if id.contains("visited") || id.contains("explored") || id.contains("mastered") {
            return String(format: "%.0f more to next tier", remaining)
        } else if id == "daily_distance" || id == "daily_running" {
            // For daily achievements, show what's needed today
            return String(format: "%.0f km today for next tier", nextTierGoal)
        } else if id == "berlin_streets" || id == "mauerweg" {
            // For Berlin route/street coverage - show percentage
            return String(format: "%.1f%% to next tier", remaining)
        } else if id == "berlin_districts" || id == "berlin_stadtteile" {
            // For Berlin districts/stadtteile - show count
            return String(format: "%.0f to next tier", remaining)
        }

        return ""
    }
}

// MARK: - Street Coverage Data Models

struct RouteCoverageData: Codable {
    let routeID: String // Using date string as ID
    let districts: [String]
    let coveredSegments: [StreetSegment]
}

struct StreetSegment: Codable, Hashable {
    let streetName: String
    let district: String
    let stadtteil: String?  // Optional for backward compatibility
    let startIndex: Int
    let endIndex: Int
}

struct StreetCoverageCache: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let totalStreetCount: Int
    let coveredStreetCount: Int
    let fullyCoveredStreetCount: Int
    let coveredPoints: Int
    let totalPoints: Int
    let overallCoveragePercentage: Double
    let coverageByStreetID: [String: ConsolidatedStreet.CoverageResult]
    let districtStats: [DistrictCoverageStats]
    let stadtteilStats: [StadtteilCoverageStats]
}

// MARK: - Berlin Mauerweg Helper

struct BerlinMauerweg {
    struct LandmarkSticker: Identifiable {
        let id: String
        let title: String
        let iconName: String
        let coordinate: CLLocationCoordinate2D
    }

    private static let routeFileNames = [
        "Mauerweg 1 - Stadtroute",
        "Mauerweg 2 - Suedroute",
        "Mauerweg 3 - Westroute"
    ]

    private static var cachedCoordinates: [BerlinStreets.SimpleCoordinate]?
    private static var cachedCoordinateSegments: [[BerlinStreets.SimpleCoordinate]]?

    private static let landmarkStickers = [
        LandmarkSticker(
            id: "checkpoint_charlie",
            title: "Checkpoint Charlie",
            iconName: "flag.checkered",
            coordinate: CLLocationCoordinate2D(latitude: 52.50751, longitude: 13.39037)
        ),
        LandmarkSticker(
            id: "brandenburg_gate",
            title: "Brandenburg Gate",
            iconName: "building.columns.fill",
            coordinate: CLLocationCoordinate2D(latitude: 52.51628, longitude: 13.37770)
        ),
        LandmarkSticker(
            id: "bernauerstrasse",
            title: "Bernauerstrasse",
            iconName: "mappin.and.ellipse",
            coordinate: CLLocationCoordinate2D(latitude: 52.53510, longitude: 13.39025)
        )
    ]

    static func coordinates() -> [BerlinStreets.SimpleCoordinate] {
        if let cachedCoordinates {
            return cachedCoordinates
        }

        let coordinates = coordinateSegments().flatMap { $0 }

        cachedCoordinates = coordinates
        return coordinates
    }

    static func coordinateSegments() -> [[BerlinStreets.SimpleCoordinate]] {
        if let cachedCoordinateSegments {
            return cachedCoordinateSegments
        }

        let segments = routeFileNames
            .map { loadCoordinatesFromGPX(named: $0) }
            .map { coordinates in
                coordinates.map { BerlinStreets.SimpleCoordinate(lat: $0.latitude, lon: $0.longitude) }
            }
            .filter { $0.count >= 2 }

        cachedCoordinateSegments = segments
        return segments
    }

    static func completedLandmarkStickers(routes: [Route], thresholdMeters: CLLocationDistance = 90) -> [LandmarkSticker] {
        landmarkStickers.filter { sticker in
            let stickerLocation = CLLocation(latitude: sticker.coordinate.latitude, longitude: sticker.coordinate.longitude)

            for route in routes {
                for coordinate in route.coordinates {
                    let routeLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    if routeLocation.distance(from: stickerLocation) <= thresholdMeters {
                        return true
                    }
                }
            }

            return false
        }
    }
}

// MARK: - Berlin Streets Helper

struct BerlinStreets {
    struct Street: Codable {
        let name: String
        let district: String
        let stadtteil: String  // Neighborhood within district
        let coordinates: [SimpleCoordinate]
        let lengthMeters: Double

        // Convert to CLLocationCoordinate2D when needed
        var clCoordinates: [CLLocationCoordinate2D] {
            coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
    }

    struct SimpleCoordinate: Codable {
        let lat: Double
        let lon: Double
    }

    private static var _streetsByDistrict: [String: [Street]] = [:]
    private static var loadingDistricts: Set<String> = []
    private static var loadedDistricts: Set<String> = []

    // Get streets for specific districts (lazy loads only those districts)
    static func getStreets(forDistricts districts: [String]) -> [Street] {
        var result: [Street] = []

        for district in districts {
            // Return cached if already loaded
            if let streets = _streetsByDistrict[district] {
                result.append(contentsOf: streets)
                continue
            }

            // Try to load from cache
            if let cached = loadDistrictFromCache(district) {
                _streetsByDistrict[district] = cached
                loadedDistricts.insert(district)
                result.append(contentsOf: cached)
                print("✅ Loaded \(cached.count) streets for \(district) from cache")
                continue
            }
        }

        return result
    }

    // Filter streets by Stadtteil - much more efficient than district filtering
    static func filterStreets(_ streets: [Street], byStadtteile stadtteile: Set<String>) -> [Street] {
        return streets.filter { stadtteile.contains($0.stadtteil) }
    }

    // Get unique Stadtteile from a set of coordinates
    static func getStadtteileFromCoordinates(_ coordinates: [CLLocationCoordinate2D]) -> Set<String> {
        var stadtteile = Set<String>()

        // Sample coordinates to determine which Stadtteile are touched
        let samplingInterval = max(10, coordinates.count / 20)
        for i in stride(from: 0, to: coordinates.count, by: samplingInterval) {
            let coord = coordinates[i]
            // First get district, then find streets at this location to get Stadtteil
            if let district = BerlinDistricts.getDistrict(lat: coord.latitude, lon: coord.longitude) {
                // Check cached streets for this district to find Stadtteil
                if let streets = _streetsByDistrict[district] {
                    // Find closest street to this coordinate to determine Stadtteil
                    let coordLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    var closestDistance = Double.infinity
                    var closestStadtteil: String?

                    for street in streets {
                        for streetCoord in street.coordinates {
                            let streetLocation = CLLocation(latitude: streetCoord.lat, longitude: streetCoord.lon)
                            let distance = coordLocation.distance(from: streetLocation)
                            if distance < closestDistance {
                                closestDistance = distance
                                closestStadtteil = street.stadtteil
                            }
                            // If within 100m, that's close enough
                            if distance < 100 {
                                break
                            }
                        }
                    }

                    if let stadtteil = closestStadtteil, closestDistance < 500 {
                        stadtteile.insert(stadtteil)
                    }
                }
            }
        }

        return stadtteile
    }

    // Load specific districts in background
    static func loadDistrictsInBackground(_ districts: [String], completion: @escaping ([String: [Street]]) -> Void) {
        let districtsToLoad = districts.filter { !loadedDistricts.contains($0) && !loadingDistricts.contains($0) }
        guard !districtsToLoad.isEmpty else {
            // All already loaded
            var result: [String: [Street]] = [:]
            for district in districts {
                result[district] = _streetsByDistrict[district] ?? []
            }
            completion(result)
            return
        }

        for district in districtsToLoad {
            loadingDistricts.insert(district)
        }

        Task.detached(priority: .utility) {
            var loadedStreets: [String: [Street]] = [:]
            var needsGeoJSONParse = false

            // First check cache for all districts
            for district in districtsToLoad {
                if let cached = loadDistrictFromCache(district) {
                    loadedStreets[district] = cached
                    await MainActor.run {
                        _streetsByDistrict[district] = cached
                        loadedDistricts.insert(district)
                        loadingDistricts.remove(district)
                    }
                    print("✅ Loaded \(cached.count) streets for \(district) from cache")
                } else {
                    needsGeoJSONParse = true
                }
            }

            // If any district needs parsing, parse ALL districts at once
            if needsGeoJSONParse {
                print("🔄 Parsing GeoJSON for all districts (one-time operation)...")
                let allDistrictStreets = await Task.detached(priority: .utility) {
                    parseAllDistrictsFromGeoJSON()
                }.value

                // Save each district to cache
                for (district, streets) in allDistrictStreets {
                    saveDistrictToCache(district, streets: streets)
                    print("💾 Cached \(streets.count) streets for \(district)")
                }

                // Update loaded streets and state
                await MainActor.run {
                    for (district, streets) in allDistrictStreets {
                        _streetsByDistrict[district] = streets
                        loadedDistricts.insert(district)
                        loadingDistricts.remove(district)
                    }
                }

                // Add to result
                for district in districtsToLoad {
                    loadedStreets[district] = allDistrictStreets[district] ?? []
                }

                print("✅ Parsed and cached all districts from GeoJSON")
            }

            // Also return any already-loaded districts
            let cachedMainActorStreets = await MainActor.run {
                var cached: [String: [Street]] = [:]
                for district in districts {
                    cached[district] = _streetsByDistrict[district] ?? []
                }
                return cached
            }

            var finalStreets = loadedStreets
            for (district, streets) in cachedMainActorStreets where finalStreets[district] == nil {
                finalStreets[district] = streets
            }

            let finalStreetsForCompletion = finalStreets
            await MainActor.run {
                completion(finalStreetsForCompletion)
            }
        }
    }

    // Legacy method for backward compatibility (loads all streets)
    private static var _allStreets: [Street]?
    private static var isLoadingAll = false

    static var streets: [Street] {
        if let cached = _allStreets {
            return cached
        }

        // Return all loaded streets so far
        return _streetsByDistrict.values.flatMap { $0 }
    }

    static func loadStreetsInBackground(completion: @escaping () -> Void) {
        // Deprecated - use loadDistrictsInBackground instead
        completion()
    }

    private static func parseAllDistrictsFromGeoJSON() -> [String: [Street]] {
        guard let url = Bundle.main.url(forResource: "Detailnetz-Strassenabschnitte", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            print("⚠️ Failed to load Detailnetz-Strassenabschnitte.geojson")
            return [:]
        }

        print("📦 Parsing \(features.count) street features from GeoJSON...")
        var streetsByDistrict: [String: [Street]] = [:]
        var processedCount = 0

        for (index, feature) in features.enumerated() {
            // Progress update every 5000 streets
            if index % 5000 == 0 && index > 0 {
                print("   ... \(index)/\(features.count) streets processed")
            }
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else {
                continue
            }

            // Extract street name (Berlin uses "strassenna")
            let name = (properties["strassenna"] as? String) ??
                      (properties["name"] as? String) ??
                      (properties["NAME"] as? String) ??
                      (properties["street_name"] as? String) ??
                      "Unnamed Street"

            // Extract stadtteil (neighborhood)
            let stadtteil = (properties["stadtteil"] as? String) ?? "Unknown"

            var coords: [CLLocationCoordinate2D] = []

            if type == "LineString", let coordinates = geometry["coordinates"] as? [[Double]] {
                coords = coordinates.compactMap { coord -> CLLocationCoordinate2D? in
                    guard coord.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
                }
            } else if type == "MultiLineString", let multiCoords = geometry["coordinates"] as? [[[Double]]] {
                var longestSegment: [CLLocationCoordinate2D] = []
                for segment in multiCoords {
                    let segmentCoords = segment.compactMap { coord -> CLLocationCoordinate2D? in
                        guard coord.count >= 2 else { return nil }
                        return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
                    }
                    if segmentCoords.count > longestSegment.count {
                        longestSegment = segmentCoords
                    }
                }
                coords = longestSegment
            }

            guard coords.count >= 2 else { continue }

            // SIMPLIFY: Keep every 5th coordinate (reduces size by 80%)
            let simplificationFactor = 5
            var simplifiedCoords: [SimpleCoordinate] = []
            for i in stride(from: 0, to: coords.count, by: simplificationFactor) {
                simplifiedCoords.append(SimpleCoordinate(lat: coords[i].latitude, lon: coords[i].longitude))
            }
            // Always include last point
            if coords.count % simplificationFactor != 1 {
                let last = coords[coords.count - 1]
                simplifiedCoords.append(SimpleCoordinate(lat: last.latitude, lon: last.longitude))
            }

            // Quick length estimate (just straight-line distance, no point-by-point calculation)
            let firstLoc = CLLocation(latitude: coords[0].latitude, longitude: coords[0].longitude)
            let lastLoc = CLLocation(latitude: coords[coords.count - 1].latitude, longitude: coords[coords.count - 1].longitude)
            let length = firstLoc.distance(from: lastLoc) * 1.3 // Rough estimate with 30% buffer for curves

            // Determine district (using first coordinate)
            let district = BerlinDistricts.getDistrict(lat: coords[0].latitude, lon: coords[0].longitude) ?? "Unknown"

            let street = Street(name: name, district: district, stadtteil: stadtteil, coordinates: simplifiedCoords, lengthMeters: length)
            streetsByDistrict[district, default: []].append(street)
            processedCount += 1
        }

        print("✅ Parsed \(processedCount) streets into \(streetsByDistrict.count) districts")
        for (district, streets) in streetsByDistrict.sorted(by: { $0.key < $1.key }) {
            print("   - \(district): \(streets.count) streets")
        }

        return streetsByDistrict
    }

    private static func parseDistrictFromGeoJSON(_ targetDistrict: String) -> [Street] {
        guard let url = Bundle.main.url(forResource: "Detailnetz-Strassenabschnitte", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            print("⚠️ Failed to load Detailnetz-Strassenabschnitte.geojson")
            return []
        }

        var streets: [Street] = []

        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else {
                continue
            }

            // Extract street name (Berlin uses "strassenna")
            let name = (properties["strassenna"] as? String) ??
                      (properties["name"] as? String) ??
                      (properties["NAME"] as? String) ??
                      (properties["street_name"] as? String) ??
                      "Unnamed Street"

            // Extract stadtteil (neighborhood)
            let stadtteil = (properties["stadtteil"] as? String) ?? "Unknown"

            var coords: [CLLocationCoordinate2D] = []

            if type == "LineString", let coordinates = geometry["coordinates"] as? [[Double]] {
                coords = coordinates.compactMap { coord -> CLLocationCoordinate2D? in
                    guard coord.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
                }
            } else if type == "MultiLineString", let multiCoords = geometry["coordinates"] as? [[[Double]]] {
                var longestSegment: [CLLocationCoordinate2D] = []
                for segment in multiCoords {
                    let segmentCoords = segment.compactMap { coord -> CLLocationCoordinate2D? in
                        guard coord.count >= 2 else { return nil }
                        return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
                    }
                    if segmentCoords.count > longestSegment.count {
                        longestSegment = segmentCoords
                    }
                }
                coords = longestSegment
            }

            guard coords.count >= 2 else { continue }

            // SIMPLIFY: Only keep every 5th coordinate (reduces size by 80%)
            let simplificationFactor = 5
            var simplifiedCoords: [SimpleCoordinate] = []
            for i in stride(from: 0, to: coords.count, by: simplificationFactor) {
                simplifiedCoords.append(SimpleCoordinate(lat: coords[i].latitude, lon: coords[i].longitude))
            }
            // Always include last point
            if coords.count % simplificationFactor != 1 {
                let last = coords[coords.count - 1]
                simplifiedCoords.append(SimpleCoordinate(lat: last.latitude, lon: last.longitude))
            }

            // Calculate street length from original coords
            var length: Double = 0
            for i in 1..<coords.count {
                let loc1 = CLLocation(latitude: coords[i-1].latitude, longitude: coords[i-1].longitude)
                let loc2 = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                length += loc1.distance(from: loc2)
            }

            // Determine district (using first coordinate)
            let district = BerlinDistricts.getDistrict(lat: coords[0].latitude, lon: coords[0].longitude) ?? "Unknown"

            // Only include streets from target district
            if district == targetDistrict {
                streets.append(Street(name: name, district: district, stadtteil: stadtteil, coordinates: simplifiedCoords, lengthMeters: length))
            }
        }

        return streets
    }

    private static func districtCacheURL(_ district: String) -> URL? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let sanitized = district.replacingOccurrences(of: "/", with: "_")
        return cacheDir.appendingPathComponent("berlin_streets_\(sanitized).json")
    }

    private static func saveDistrictToCache(_ district: String, streets: [Street]) {
        guard let url = districtCacheURL(district),
              let data = try? JSONEncoder().encode(streets) else {
            return
        }
        try? data.write(to: url)
        print("💾 Cached \(streets.count) streets for \(district) to disk")
    }

    private static func loadDistrictFromCache(_ district: String) -> [Street]? {
        guard let url = districtCacheURL(district),
              let data = try? Data(contentsOf: url),
              let streets = try? JSONDecoder().decode([Street].self, from: data) else {
            return nil
        }
        return streets
    }

}

// MARK: - Berlin Districts Helper

struct BerlinDistricts {
    struct DistrictBoundary {
        let name: String
        let polygons: [[[CLLocationCoordinate2D]]] // MultiPolygon structure
    }
    
    static let boundaries: [DistrictBoundary] = {
        guard let url = Bundle.main.url(forResource: "bezirksgrenzen", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            print("⚠️ Failed to load bezirksgrenzen.geojson")
            return []
        }
        
        var districts: [DistrictBoundary] = []
        
        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let name = properties["Gemeinde_name"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else {
                continue
            }
            
            var polygons: [[[CLLocationCoordinate2D]]] = []
            if type == "MultiPolygon", let coordinates = geometry["coordinates"] as? [[[[Double]]]] {
                // Parse MultiPolygon coordinates
                for polygon in coordinates {
                    var rings: [[CLLocationCoordinate2D]] = []
                    for ring in polygon {
                        let coords = ring.compactMap { coord -> CLLocationCoordinate2D? in
                            guard coord.count >= 2 else { return nil }
                            return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
                        }
                        if coords.count >= 3 { rings.append(coords) }
                    }
                    if !rings.isEmpty { polygons.append(rings) }
                }
            } else if type == "Polygon", let coordinates = geometry["coordinates"] as? [[[Double]]] {
                // Wrap Polygon as a single MultiPolygon
                var rings: [[CLLocationCoordinate2D]] = []
                for ring in coordinates {
                    let coords = ring.compactMap { coord -> CLLocationCoordinate2D? in
                        guard coord.count >= 2 else { return nil }
                        return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
                    }
                    if coords.count >= 3 { rings.append(coords) }
                }
                if !rings.isEmpty { polygons.append(rings) }
            } else {
                // Unsupported geometry type
                continue
            }
            
            if !polygons.isEmpty {
                districts.append(DistrictBoundary(name: name, polygons: polygons))
            }
        }
        
        print("✅ Loaded \(districts.count) Berlin district boundaries")
        return districts
    }()
    
    // Map display center points for labels
    static let districts: [(name: String, lat: Double, lon: Double)] = [
        ("Mitte", 52.5200, 13.4050),
        ("Friedrichshain-Kreuzberg", 52.5065, 13.4255),
        ("Pankow", 52.5690, 13.4010),
        ("Charlottenburg-Wilmersdorf", 52.5065, 13.2985),
        ("Spandau", 52.5370, 13.2005),
        ("Steglitz-Zehlendorf", 52.4380, 13.2595),
        ("Tempelhof-Schöneberg", 52.4745, 13.3750),
        ("Neukölln", 52.4815, 13.4370),
        ("Treptow-Köpenick", 52.4457, 13.5765),
        ("Marzahn-Hellersdorf", 52.5465, 13.5915),
        ("Lichtenberg", 52.5154, 13.4980),
        ("Reinickendorf", 52.5695, 13.3385)
    ]
    
    static func getDistrict(lat: Double, lon: Double) -> String? {
        let point = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        // Check each district boundary
        for district in boundaries {
            if isPointInDistrict(point: point, district: district) {
                return district.name
            }
        }
        
        return nil
    }
    
    private static func isPointInDistrict(point: CLLocationCoordinate2D, district: DistrictBoundary) -> Bool {
        // Check if point is in any of the polygons (outer rings only)
        for polygon in district.polygons {
            guard let outerRing = polygon.first, outerRing.count >= 3 else { continue }
            if isPointInPolygon(point: point, polygon: outerRing) {
                return true
            }
        }
        return false
    }
    
    // Ray casting algorithm for point-in-polygon test (robust against horizontal edges)
    private static func isPointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        // Quick bounding-box reject to avoid heavy math
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        for p in polygon {
            minLat = min(minLat, p.latitude)
            maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude)
            maxLon = max(maxLon, p.longitude)
        }
        if point.latitude < minLat || point.latitude > maxLat || point.longitude < minLon || point.longitude > maxLon {
            return false
        }

        var inside = false
        var j = polygon.count - 1
        let y = point.latitude
        let x = point.longitude
        let epsilon = 1e-12

        for i in 0..<polygon.count {
            let xi = polygon[i].longitude
            let yi = polygon[i].latitude
            let xj = polygon[j].longitude
            let yj = polygon[j].latitude

            // Check if edge crosses the horizontal ray; skip horizontal edges to avoid division by ~0
            let yiAbove = yi > y
            let yjAbove = yj > y
            if yiAbove != yjAbove {
                let denom = (yj - yi)
                if abs(denom) > epsilon {
                    let xIntersect = (xj - xi) * (y - yi) / denom + xi
                    if x < xIntersect {
                        inside.toggle()
                    }
                }
            }
            j = i
        }
        return inside
    }
}

// MARK: - Achievements Manager

class AchievementsManager: ObservableObject {
    @Published var achievements: [Achievement] = []
    @Published var berlinDistrictsVisitedCached: Set<String> = []
    @Published var berlinStadtteileVisitedCached: Set<String> = []
    @Published var processedRoutes: [String: RouteCoverageData] = [:] // routeID -> coverage data
    @Published var streetSegmentsCovered: Set<StreetSegment> = [] // All covered segments
    @Published var processingStatus = ""
    @Published var processingProgress: Double = 0
    @Published var achievementMessage: String? = nil
    @Published var showAchievementAlert = false

    // NEW: Fast street processing
    @Published var consolidatedStreets: [ConsolidatedStreet] = []
    @Published var streetsByDistrict: [String: [ConsolidatedStreet]] = [:]
    @Published var streetsByStadtteil: [String: [ConsolidatedStreet]] = [:]
    @Published var currentStadtteil = ""
    @Published var currentStadtteilProgressInfo: StadtteilProgressInfo?
    @Published var streetCoverageByID: [String: ConsolidatedStreet.CoverageResult] = [:]
    @Published var districtCoverageStats: [DistrictCoverageStats] = []
    @Published var stadtteilCoverageStats: [StadtteilCoverageStats] = []
    @Published var overallStreetCoverage: Double = 0
    @Published var totalBerlinStreets: Int = 0
    @Published var processedBerlinStreets: Int = 0
    @Published var coveredBerlinStreets: Int = 0
    @Published var fullyCoveredBerlinStreets: Int = 0
    @Published var coveredBerlinPoints: Int = 0
    @Published var totalBerlinPoints: Int = 0
    @Published var streetCoverageLastUpdated: Date?
    @Published var newlyCoveredStreetNames: [String] = []
    @Published var newlyVisitedDistrictNames: [String] = []
    @Published var newlyVisitedStadtteilNames: [String] = []
    var fastProcessor: FastStreetProcessor?
    
    private let storageKey = "unlockedAchievements"
    private let streetCoverageCacheKey = "berlinStreetCoverageCache"
    private let visitedBerlinStreetIDsKey = "visitedBerlinStreetIDs"
    private let streetCoverageFormatVersion = 2
    private var berlinVisitedFingerprint: String = ""
    private var streetCoverageStateStoreHasProcessedRoutes = false
    
    init() {
        loadAchievements()
        loadCachedData()
        
        // Start loading streets in background
        BerlinStreets.loadStreetsInBackground {
            // Streets are now loaded, trigger any pending processing
            print("✅ Streets loaded, ready for processing")
        }
    }
    
    private func loadCachedData() {
        // Version key for street data format - ONLY increment when you need to clear cache
        let currentVersion = "v16_radius_20m"  // Changed: increased detection radius from 15m to 20m
        let savedVersion = UserDefaults.standard.string(forKey: "berlinStreetsDataVersion") ?? ""
        
        // print("🔍 Checking cache version: saved='\(savedVersion)' current='\(currentVersion)'")
        
        // If version mismatch, clear ONLY street coverage data (not districts)
        if savedVersion != currentVersion {
            // TEMPORARY: Just update version without clearing cache (detail view fix doesn't need re-parse)
            if savedVersion == "v7_debug_grouping" {
                print("🔄 Updating version v7 -> v8 (no cache clear needed)")
                UserDefaults.standard.set(currentVersion, forKey: "berlinStreetsDataVersion")
            } else {
                print("🔄 Street data version changed (\(savedVersion) -> \(currentVersion)), clearing route processing only")
                
                // Clear ONLY route processing data from UserDefaults
                // DO NOT delete street geometry files - those don't need to change
                UserDefaults.standard.removeObject(forKey: "berlinProcessedRoutes")
                UserDefaults.standard.removeObject(forKey: "berlinCoveredSegments")
                UserDefaults.standard.removeObject(forKey: streetCoverageCacheKey)
                
                // Also reset the achievement tier so it recalculates with new formula
                if savedVersion == "v10_all_districts" {
                    print("   🔄 Resetting berlin_streets achievement tier for recalculation")
                    if let data = UserDefaults.standard.data(forKey: "achievements"),
                       var savedData = try? JSONDecoder().decode([String: AchievementSaveData].self, from: data) {
                        savedData.removeValue(forKey: "berlin_streets")
                        if let updatedData = try? JSONEncoder().encode(savedData) {
                            UserDefaults.standard.set(updatedData, forKey: "achievements")
                        }
                    }
                }
                
                // For v12/v13: Adding stadtteil field and more points requires re-parsing
                if savedVersion == "v11_overall_percentage" || savedVersion == "v12_add_stadtteil" {
                    print("   🔄 More points + stadtteil - need to re-parse GeoJSON")
                    if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                        do {
                            let files = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
                            let streetCacheFiles = files.filter { $0.lastPathComponent.hasPrefix("berlin_streets_") }
                            for file in streetCacheFiles {
                                try? FileManager.default.removeItem(at: file)
                            }
                            print("   🗑️ Deleted \(streetCacheFiles.count) street cache files for re-parse")
                        } catch {
                            print("   ⚠️ Error: \(error)")
                        }
                    }
                }
                
                // v13 → v14: Added optional stadtteil field (backward compatible, no cache clear needed)
                
                // v14 → v15: Changed simplification from every 5th to every 2nd coordinate
                if savedVersion == "v14_stadtteil_in_segment" {
                    print("   🔄 Density increased (2x more points) - clearing street geometry cache")
                    if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                        do {
                            let files = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
                            let streetCacheFiles = files.filter { $0.lastPathComponent.hasPrefix("berlin_streets_") }
                            for file in streetCacheFiles {
                                try? FileManager.default.removeItem(at: file)
                            }
                            print("   🗑️ Deleted \(streetCacheFiles.count) street cache files for higher density parsing")
                        } catch {
                            print("   ⚠️ Error: \(error)")
                        }
                    }
                }
                
                UserDefaults.standard.set(currentVersion, forKey: "berlinStreetsDataVersion")
                processedRoutes = [:]
                streetSegmentsCovered = []
                print("✅ Route processing cache cleared (street files and districts preserved)")
            }
        }
        
        // Load cached Berlin districts
        if let districtsData = UserDefaults.standard.data(forKey: "berlinDistrictsVisited"),
           let districts = try? JSONDecoder().decode([String].self, from: districtsData) {
            berlinDistrictsVisitedCached = Set(districts)
        }
        
        // Load cached Berlin stadtteile
        if let stadtteilData = UserDefaults.standard.data(forKey: "berlinStadtteileVisited"),
           let stadtteile = try? JSONDecoder().decode([String].self, from: stadtteilData) {
            berlinStadtteileVisitedCached = Set(stadtteile)
        }
        
        // Load processed routes
        if let routesData = UserDefaults.standard.data(forKey: "berlinProcessedRoutes"),
           let routes = try? JSONDecoder().decode([String: RouteCoverageData].self, from: routesData) {
            processedRoutes = routes
        }
        
        // Load covered segments
        if let segmentsData = UserDefaults.standard.data(forKey: "berlinCoveredSegments"),
           let segments = try? JSONDecoder().decode(Set<StreetSegment>.self, from: segmentsData) {
            streetSegmentsCovered = segments
        }

        streetCoverageStateStoreHasProcessedRoutes = hasIncrementalStreetCoverageState()

        // Load cached street coverage summaries only when the rebuilt incremental store exists.
        // This prevents stale UserDefaults summaries from masking an empty file-backed source of truth.
        if let coverageData = UserDefaults.standard.data(forKey: streetCoverageCacheKey),
           let cache = try? JSONDecoder().decode(StreetCoverageCache.self, from: coverageData),
           cache.formatVersion == streetCoverageFormatVersion,
           streetCoverageStateStoreHasProcessedRoutes {
            streetCoverageByID = cache.coverageByStreetID
            districtCoverageStats = cache.districtStats
            stadtteilCoverageStats = cache.stadtteilStats
            overallStreetCoverage = cache.overallCoveragePercentage
            totalBerlinStreets = cache.totalStreetCount
            processedBerlinStreets = cache.totalStreetCount
            coveredBerlinStreets = cache.coveredStreetCount
            fullyCoveredBerlinStreets = cache.fullyCoveredStreetCount
            coveredBerlinPoints = cache.coveredPoints
            totalBerlinPoints = cache.totalPoints
            streetCoverageLastUpdated = cache.generatedAt

            if berlinStadtteileVisitedCached.isEmpty {
                let visited = cache.stadtteilStats.filter { $0.coveredStreets > 0 }.map { $0.stadtteil }
                berlinStadtteileVisitedCached = Set(visited)
            }

            if UserDefaults.standard.object(forKey: visitedBerlinStreetIDsKey) == nil {
                let visitedStreetIDs = cache.coverageByStreetID.compactMap { streetID, coverage in
                    (coverage.coveredPoints > 0 || coverage.percentage > 0) ? streetID : nil
                }
                UserDefaults.standard.set(visitedStreetIDs, forKey: visitedBerlinStreetIDsKey)
            }

            // Initialize fastProcessor if we have cached data but no processor yet
            if fastProcessor == nil {
                print("🔧 Initializing fastProcessor from cached data")
                fastProcessor = FastStreetProcessor()

                // Load streets in background to populate consolidated streets
                Task {
                    // Load all Berlin districts
                    let allDistricts = BerlinDistricts.districts.map { $0.name }
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        BerlinStreets.loadDistrictsInBackground(allDistricts) { loadedStreets in
                            let allStreets = loadedStreets.values.flatMap { $0 }
                            let consolidated = StreetConsolidator.consolidate(streets: allStreets)
                            Task { @MainActor in
                                self.fastProcessor?.consolidatedStreets = consolidated
                                print("✅ Populated \(consolidated.count) consolidated streets")
                            }
                            continuation.resume()
                        }
                    }
                }
            }
        } else if UserDefaults.standard.object(forKey: streetCoverageCacheKey) != nil && !streetCoverageStateStoreHasProcessedRoutes {
            UserDefaults.standard.removeObject(forKey: streetCoverageCacheKey)
            print("🔄 Ignoring stale legacy street coverage summary; rebuilt coverage state will be generated on next processing pass")
        }
        
        // Load fingerprints
        berlinVisitedFingerprint = UserDefaults.standard.string(forKey: "berlinVisitedFingerprint") ?? ""
    }
    
    func saveCachedData() {
        // Save Berlin districts
        if let districtsData = try? JSONEncoder().encode(Array(berlinDistrictsVisitedCached)) {
            UserDefaults.standard.set(districtsData, forKey: "berlinDistrictsVisited")
        }
        
        // Save Berlin stadtteile
        if let stadtteilData = try? JSONEncoder().encode(Array(berlinStadtteileVisitedCached)) {
            UserDefaults.standard.set(stadtteilData, forKey: "berlinStadtteileVisited")
        }
        
        // Save processed routes
        if let routesData = try? JSONEncoder().encode(processedRoutes) {
            UserDefaults.standard.set(routesData, forKey: "berlinProcessedRoutes")
        }
        
        // Save covered segments
        if let segmentsData = try? JSONEncoder().encode(streetSegmentsCovered) {
            UserDefaults.standard.set(segmentsData, forKey: "berlinCoveredSegments")
        }

        if !streetCoverageByID.isEmpty {
            let cache = StreetCoverageCache(
                formatVersion: streetCoverageFormatVersion,
                generatedAt: streetCoverageLastUpdated ?? Date(),
                totalStreetCount: totalBerlinStreets,
                coveredStreetCount: coveredBerlinStreets,
                fullyCoveredStreetCount: fullyCoveredBerlinStreets,
                coveredPoints: coveredBerlinPoints,
                totalPoints: totalBerlinPoints,
                overallCoveragePercentage: overallStreetCoverage,
                coverageByStreetID: streetCoverageByID,
                districtStats: districtCoverageStats,
                stadtteilStats: stadtteilCoverageStats
            )
            if let coverageData = try? JSONEncoder().encode(cache) {
                UserDefaults.standard.set(coverageData, forKey: streetCoverageCacheKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: streetCoverageCacheKey)
        }
        
        // Save fingerprints
        UserDefaults.standard.set(berlinVisitedFingerprint, forKey: "berlinVisitedFingerprint")
    }

    private func hasIncrementalStreetCoverageState() -> Bool {
        do {
            let store = try StreetCoverageStateStore.appCache()
            let state = try store.load()
            return !state.processedRouteIDs.isEmpty
        } catch {
            return false
        }
    }
    
    // Define all possible achievements
    private func getAllAchievements() -> [Achievement] {
        return [
            // Running Distance
            Achievement(
                id: "running_distance",
                title: "Running Distance",
                iconName: "figure.run",
                category: .distance,
                tiers: [
                    .bronze: "Run 500km total",
                    .silver: "Run 1000km total",
                    .gold: "Run 2500km total",
                    .platinum: "Run 10000km total"
                ],
                currentTier: .none
            ),
            
            // Walking Distance
            Achievement(
                id: "walking_distance",
                title: "Walking Distance",
                iconName: "figure.walk",
                category: .distance,
                tiers: [
                    .bronze: "Walk 500km total",
                    .silver: "Walk 1000km total",
                    .gold: "Walk 2500km total",
                    .platinum: "Walk 10000km total"
                ],
                currentTier: .none
            ),
            
            // Countries Visited (at least 1km)
            Achievement(
                id: "countries_visited",
                title: "Countries Visited",
                iconName: "globe",
                category: .country,
                tiers: [
                    .bronze: "Visit 1 country",
                    .silver: "Visit 10 countries",
                    .gold: "Visit 25 countries",
                    .platinum: "Visit 50 countries"
                ],
                currentTier: .none
            ),
            
            // Countries Explored (at least 100km)
            Achievement(
                id: "countries_explored",
                title: "Countries Explored",
                iconName: "globe.americas.fill",
                category: .country,
                tiers: [
                    .bronze: "Cover 100km+ in 1 country",
                    .silver: "Cover 100km+ in 10 countries",
                    .gold: "Cover 100km+ in 25 countries",
                    .platinum: "Cover 100km+ in 50 countries"
                ],
                currentTier: .none
            ),
            
            // Countries Mastered (at least 1000km)
            Achievement(
                id: "countries_mastered",
                title: "Countries Mastered",
                iconName: "flag.fill",
                category: .country,
                tiers: [
                    .bronze: "Cover 1000km+ in 1 country",
                    .silver: "Cover 1000km+ in 10 countries",
                    .gold: "Cover 1000km+ in 25 countries",
                    .platinum: "Cover 1000km+ in 50 countries"
                ],
                currentTier: .none
            ),
            
            // Cities Visited (at least 1km)
            Achievement(
                id: "cities_visited",
                title: "Cities Visited",
                iconName: "building.2",
                category: .city,
                tiers: [
                    .bronze: "Visit 1 city",
                    .silver: "Visit 10 cities",
                    .gold: "Visit 25 cities",
                    .platinum: "Visit 50 cities"
                ],
                currentTier: .none
            ),
            
            // Cities Explored (at least 100km)
            Achievement(
                id: "cities_explored",
                title: "Cities Explored",
                iconName: "building.2.fill",
                category: .city,
                tiers: [
                    .bronze: "Cover 100km+ in 1 city",
                    .silver: "Cover 100km+ in 10 cities",
                    .gold: "Cover 100km+ in 25 cities",
                    .platinum: "Cover 100km+ in 50 cities"
                ],
                currentTier: .none
            ),
            
            // Cities Mastered (at least 1000km)
            Achievement(
                id: "cities_mastered",
                title: "Cities Mastered",
                iconName: "checkmark.circle.fill",
                category: .city,
                tiers: [
                    .bronze: "Cover 1000km+ in 1 city",
                    .silver: "Cover 1000km+ in 10 cities",
                    .gold: "Cover 1000km+ in 25 cities",
                    .platinum: "Cover 1000km+ in 50 cities"
                ],
                currentTier: .none
            ),
            
            // Daily Distance (all workouts)
            Achievement(
                id: "daily_distance",
                title: "Daily Distance",
                iconName: "calendar",
                category: .daily,
                tiers: [
                    .bronze: "Cover 10km in a single day",
                    .silver: "Cover 15km in a single day",
                    .gold: "Cover 20km in a single day",
                    .platinum: "Cover 30km in a single day"
                ],
                currentTier: .none
            ),
            
            // Daily Running Distance
            Achievement(
                id: "daily_running",
                title: "Daily Running",
                iconName: "figure.run.circle.fill",
                category: .daily,
                tiers: [
                    .bronze: "Run 5km in a single day",
                    .silver: "Run 10km in a single day",
                    .gold: "Run 21km in a single day",
                    .platinum: "Run 42km in a single day"
                ],
                currentTier: .none
            ),
            
            // Berlin Districts (there are 12 districts in Berlin)
            Achievement(
                id: "berlin_districts",
                title: "Berlin Districts",
                iconName: "building.columns.fill",
                category: .specials,
                tiers: [
                    .bronze: "Visit 3 Berlin districts",
                    .silver: "Visit 6 Berlin districts",
                    .gold: "Visit 9 Berlin districts",
                    .platinum: "Visit all 12 Berlin districts"
                ],
                currentTier: .none
            ),
            
            // Berlin Stadtteile (neighborhoods - there are 97 neighborhoods in Berlin)
            Achievement(
                id: "berlin_stadtteile",
                title: "Berlin Stadtteile",
                iconName: "house.fill",
                category: .specials,
                tiers: [
                    .bronze: "Visit 10 Berlin neighborhoods",
                    .silver: "Visit 25 Berlin neighborhoods",
                    .gold: "Visit 50 Berlin neighborhoods",
                    .platinum: "Visit 75 Berlin neighborhoods"
                ],
                currentTier: .none
            ),
            
            // Berlin Streets
            Achievement(
                id: "berlin_streets",
                title: "Berlin Streets",
                iconName: "map.fill",
                category: .specials,
                tiers: [
                    .bronze: "Cover 10% of Berlin streets",
                    .silver: "Cover 20% of Berlin streets",
                    .gold: "Cover 40% of Berlin streets",
                    .platinum: "Cover 80% of Berlin streets"
                ],
                currentTier: .none
            ),

            // Berlin Mauerweg
            Achievement(
                id: "mauerweg",
                title: "Mauerweg",
                iconName: "figure.walk.motion",
                category: .specials,
                tiers: [
                    .bronze: "Start the Berlin Mauerweg",
                    .silver: "Walk 10% of the Mauerweg",
                    .gold: "Walk 50% of the Mauerweg",
                    .platinum: "Walk the full Mauerweg"
                ],
                currentTier: .none
            ),
        ]
    }
    
    private struct AchievementSaveData: Codable {
        let tier: String
        let date: Date
    }
    
    private func loadAchievements() {
        var allAchievements = getAllAchievements()
        
        // Load tier status from UserDefaults
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let savedData = try? JSONDecoder().decode([String: AchievementSaveData].self, from: data) {
            for i in 0..<allAchievements.count {
                if let saveData = savedData[allAchievements[i].id],
                   let tier = AchievementTier(rawValue: saveData.tier) {
                    allAchievements[i].currentTier = tier
                    allAchievements[i].unlockedDate = saveData.date
                }
            }
        }
        
        achievements = allAchievements
    }
    
    func updateAchievementTier(id: String, tier: AchievementTier, currentProgress: Double, nextGoal: Double, extraContext: String? = nil) {
        guard let index = achievements.firstIndex(where: { $0.id == id }) else {
            return
        }

        // Update progress values
        achievements[index].currentProgress = currentProgress
        achievements[index].nextTierGoal = nextGoal

        // Special case: Allow downgrade to .none (e.g., when progress is 0)
        let shouldUpdate = tier > achievements[index].currentTier ||
        achievements[index].currentTier == .none ||
        tier == .none

        // Only update tier if the new tier is higher or resetting to none
        if shouldUpdate {
            let oldTier = achievements[index].currentTier
            achievements[index].currentTier = tier
            if achievements[index].unlockedDate == nil {
                achievements[index].unlockedDate = Date()
            }
            saveAchievements()

            // Show congratulatory message
            if tier != .none {
                let achievement = achievements[index]
                var message: String

                if oldTier == .none {
                    // First unlock
                    message = "🎉 Achievement Unlocked!\n\n\(achievement.title)\n\(tier.rawValue)"
                } else {
                    // Tier upgrade
                    message = "🎉 Achievement Upgraded!\n\n\(achievement.title)\n\(oldTier.rawValue) → \(tier.rawValue)"
                }

                // Add extra context if provided
                if let extra = extraContext {
                    message += "\n\n" + extra
                }

                achievementMessage = message
                showAchievementAlert = true
                print("🏆 \(message.replacingOccurrences(of: "\n", with: " "))")
            }
        }
    }
    
    private func saveAchievements() {
        let savedData = achievements
            .filter { $0.currentTier != .none }
            .reduce(into: [String: AchievementSaveData]()) { result, achievement in
                if let date = achievement.unlockedDate {
                    result[achievement.id] = AchievementSaveData(tier: achievement.currentTier.rawValue, date: date)
                }
            }
        
        if let data = try? JSONEncoder().encode(savedData) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    // Helper function to determine tier and next goal
    func getTierAndNext(for value: Double, tiers: [Double]) -> (AchievementTier, Double) {
        if value >= tiers[3] {
            return (.platinum, tiers[3])
        } else if value >= tiers[2] {
            return (.gold, tiers[3])
        } else if value >= tiers[1] {
            return (.silver, tiers[2])
        } else if value >= tiers[0] {
            return (.bronze, tiers[1])
        } else {
            return (.none, tiers[0])
        }
    }
    
    func getCountTierAndNext(for count: Int, tiers: [Int]) -> (AchievementTier, Double) {
        if count >= tiers[3] {
            return (.platinum, Double(tiers[3]))
        } else if count >= tiers[2] {
            return (.gold, Double(tiers[3]))
        } else if count >= tiers[1] {
            return (.silver, Double(tiers[2]))
        } else if count >= tiers[0] {
            return (.bronze, Double(tiers[1]))
        } else {
            return (.none, Double(tiers[0]))
        }
    }

    private func getMauerwegTierAndNext(for value: Double) -> (AchievementTier, Double) {
        if value >= 99.9 {
            return (.platinum, 100)
        } else if value >= 50 {
            return (.gold, 100)
        } else if value >= 10 {
            return (.silver, 50)
        } else if value > 0 {
            return (.bronze, 10)
        } else {
            return (.none, 0.1)
        }
    }

    private func calculateMauerwegCoverage(routes: [Route]) -> Double {
        let mauerwegCoordinates = BerlinMauerweg.coordinates()
        guard !routes.isEmpty, !mauerwegCoordinates.isEmpty else { return 0 }

        let checker = FastStreetChecker(routes: routes)
        let coveredPointCount = checker.checkStreetCoverage(streetCoords: mauerwegCoordinates).filter { $0 }.count
        return (Double(coveredPointCount) / Double(mauerwegCoordinates.count)) * 100.0
    }

    private struct BackgroundAchievementMetrics {
        let runningDistance: Double
        let walkingDistance: Double
        let countriesVisited: Int
        let countriesExplored: Int
        let countriesMastered: Int
        let citiesVisited: Int
        let citiesExplored: Int
        let citiesMastered: Int
        let maxDailyDistance: Double
        let todayDistance: Double
        let maxDailyRunning: Double
        let todayRunning: Double
        let visitedDistricts: Set<String>
        let didRecalculateDistricts: Bool
        let mauerwegCoverage: Double
        let fingerprint: String
    }

    private func calculateMauerwegCoverage(snapshots: [RunMapRouteSnapshot]) -> Double {
        let mauerwegCoordinates = BerlinMauerweg.coordinates()
        guard !snapshots.isEmpty, !mauerwegCoordinates.isEmpty else { return 0 }

        let spatialIndex = SpatialIndex(metersPerCell: 40)
        for snapshot in snapshots {
            spatialIndex.addRoute(snapshot.coordinates.map { ($0.latitude, $0.longitude) })
        }

        let coveredPointCount = mauerwegCoordinates.reduce(0) { count, coordinate in
            spatialIndex.isNearRoute(lat: coordinate.lat, lon: coordinate.lon).isNear ? count + 1 : count
        }
        return (Double(coveredPointCount) / Double(mauerwegCoordinates.count)) * 100.0
    }

    private func computeBackgroundAchievementMetrics(
        snapshots: [RunMapRouteSnapshot],
        previousFingerprint: String,
        cachedDistricts: Set<String>
    ) -> BackgroundAchievementMetrics {
        var runningDistance = 0.0
        var walkingDistance = 0.0
        var countryDistances: [String: Double] = [:]
        var cityDistances: [String: Double] = [:]
        var dailyDistances: [String: Double] = [:]
        var dailyRunningDistances: [String: Double] = [:]

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        for snapshot in snapshots {
            let distanceKm = snapshot.distanceMeters / 1_000
            switch snapshot.activity {
            case .running:
                runningDistance += distanceKm
            case .walking:
                walkingDistance += distanceKm
            case .other:
                break
            }

            if let firstCoord = snapshot.coordinates.first {
                let geocodeResult = LocalGeocoder.geocode(latitude: firstCoord.latitude, longitude: firstCoord.longitude)
                if !geocodeResult.country.isEmpty && geocodeResult.country != "Unknown" {
                    countryDistances[geocodeResult.country, default: 0] += distanceKm
                }
                if LocalGeocoder.isSpecificCityName(geocodeResult.city) {
                    cityDistances[geocodeResult.city, default: 0] += distanceKm
                }
            }

            let dateKey = dateFormatter.string(from: snapshot.startDate)
            dailyDistances[dateKey, default: 0] += distanceKm
            if snapshot.activity == .running {
                dailyRunningDistances[dateKey, default: 0] += distanceKm
            }
        }

        let latestDate = snapshots.map { $0.startDate.timeIntervalSince1970 }.max() ?? 0
        let fingerprint = "\(snapshots.count)_\(Int(latestDate))"
        let didRecalculateDistricts = fingerprint != previousFingerprint
        let visitedDistricts: Set<String>

        if didRecalculateDistricts {
            var visited = Set<String>()
            for snapshot in snapshots {
                guard let first = snapshot.coordinates.first else { continue }
                if let district = BerlinDistricts.getDistrict(lat: first.latitude, lon: first.longitude) {
                    visited.insert(district)
                }
                if let last = snapshot.coordinates.last,
                   let district = BerlinDistricts.getDistrict(lat: last.latitude, lon: last.longitude) {
                    visited.insert(district)
                }
            }

            for snapshot in snapshots {
                let coordinates = snapshot.coordinates
                if coordinates.isEmpty { continue }
                var routeLikelyCovered = false
                if let first = coordinates.first,
                   let district = BerlinDistricts.getDistrict(lat: first.latitude, lon: first.longitude),
                   visited.contains(district) {
                    routeLikelyCovered = true
                }
                if let last = coordinates.last,
                   let district = BerlinDistricts.getDistrict(lat: last.latitude, lon: last.longitude),
                   visited.contains(district) {
                    routeLikelyCovered = true
                }
                if routeLikelyCovered { continue }

                let step = max(1, coordinates.count / 10)
                var routeFound = false
                for index in stride(from: 0, to: coordinates.count, by: step) {
                    let coordinate = coordinates[index]
                    if let district = BerlinDistricts.getDistrict(lat: coordinate.latitude, lon: coordinate.longitude) {
                        visited.insert(district)
                        routeFound = true
                    }
                }
                if !routeFound {
                    let quarterIndices = [coordinates.count / 4, coordinates.count / 2, (3 * coordinates.count) / 4]
                        .filter { $0 >= 0 && $0 < coordinates.count }
                    for index in quarterIndices {
                        let coordinate = coordinates[index]
                        if let district = BerlinDistricts.getDistrict(lat: coordinate.latitude, lon: coordinate.longitude) {
                            visited.insert(district)
                        }
                    }
                }
            }
            visitedDistricts = visited
        } else {
            visitedDistricts = cachedDistricts
        }

        return BackgroundAchievementMetrics(
            runningDistance: runningDistance,
            walkingDistance: walkingDistance,
            countriesVisited: countryDistances.filter { $0.value >= 1 }.count,
            countriesExplored: countryDistances.filter { $0.value >= 100 }.count,
            countriesMastered: countryDistances.filter { $0.value >= 1000 }.count,
            citiesVisited: cityDistances.filter { $0.value >= 1 }.count,
            citiesExplored: cityDistances.filter { $0.value >= 100 }.count,
            citiesMastered: cityDistances.filter { $0.value >= 1000 }.count,
            maxDailyDistance: dailyDistances.values.max() ?? 0,
            todayDistance: dailyDistances[today] ?? 0,
            maxDailyRunning: dailyRunningDistances.values.max() ?? 0,
            todayRunning: dailyRunningDistances[today] ?? 0,
            visitedDistricts: visitedDistricts,
            didRecalculateDistricts: didRecalculateDistricts,
            mauerwegCoverage: calculateMauerwegCoverage(snapshots: snapshots),
            fingerprint: fingerprint
        )
    }

    func checkAndUnlockAchievementsInBackground(routes: [Route]) {
        let previousFingerprint = berlinVisitedFingerprint
        let previousDistricts = berlinDistrictsVisitedCached
        let previousStadtteile = berlinStadtteileVisitedCached
        let cachedStadtteilStats = stadtteilCoverageStats
        let cachedStreetSegments = streetSegmentsCovered
        let processedRouteIDs = Set(processedRoutes.keys)
        let hasStreetCoverage = !streetCoverageByID.isEmpty
        let hasIncrementalState = hasIncrementalStreetCoverageState()
        let cachedOverallStreetCoverage = overallStreetCoverage
        let cachedTotalBerlinStreets = totalBerlinStreets
        let needsStreetProcessing = routes.contains { route in
            processedRoutes["\(route.date.timeIntervalSince1970)"] == nil
        } || !hasStreetCoverage || !hasIncrementalState

        processingStatus = "Checking achievements..."
        processingProgress = 0.02

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let snapshots = routes.map(RunMapRouteSnapshot.init(route:))
            let metrics = self.computeBackgroundAchievementMetrics(
                snapshots: snapshots,
                previousFingerprint: previousFingerprint,
                cachedDistricts: previousDistricts
            )

            await MainActor.run {
                let (runningTier, runningNext) = self.getTierAndNext(for: metrics.runningDistance, tiers: [500, 1000, 2500, 10000])
                self.updateAchievementTier(id: "running_distance", tier: runningTier, currentProgress: metrics.runningDistance, nextGoal: runningNext)

                let (walkingTier, walkingNext) = self.getTierAndNext(for: metrics.walkingDistance, tiers: [500, 1000, 2500, 10000])
                self.updateAchievementTier(id: "walking_distance", tier: walkingTier, currentProgress: metrics.walkingDistance, nextGoal: walkingNext)

                let (countriesVisitedTier, countriesVisitedNext) = self.getCountTierAndNext(for: metrics.countriesVisited, tiers: [1, 10, 25, 50])
                self.updateAchievementTier(id: "countries_visited", tier: countriesVisitedTier, currentProgress: Double(metrics.countriesVisited), nextGoal: countriesVisitedNext)

                let (countriesExploredTier, countriesExploredNext) = self.getCountTierAndNext(for: metrics.countriesExplored, tiers: [1, 10, 25, 50])
                self.updateAchievementTier(id: "countries_explored", tier: countriesExploredTier, currentProgress: Double(metrics.countriesExplored), nextGoal: countriesExploredNext)

                let (countriesMasteredTier, countriesMasteredNext) = self.getCountTierAndNext(for: metrics.countriesMastered, tiers: [1, 10, 25, 50])
                self.updateAchievementTier(id: "countries_mastered", tier: countriesMasteredTier, currentProgress: Double(metrics.countriesMastered), nextGoal: countriesMasteredNext)

                let (citiesVisitedTier, citiesVisitedNext) = self.getCountTierAndNext(for: metrics.citiesVisited, tiers: [1, 10, 25, 50])
                self.updateAchievementTier(id: "cities_visited", tier: citiesVisitedTier, currentProgress: Double(metrics.citiesVisited), nextGoal: citiesVisitedNext)

                let (citiesExploredTier, citiesExploredNext) = self.getCountTierAndNext(for: metrics.citiesExplored, tiers: [1, 10, 25, 50])
                self.updateAchievementTier(id: "cities_explored", tier: citiesExploredTier, currentProgress: Double(metrics.citiesExplored), nextGoal: citiesExploredNext)

                let (citiesMasteredTier, citiesMasteredNext) = self.getCountTierAndNext(for: metrics.citiesMastered, tiers: [1, 10, 25, 50])
                self.updateAchievementTier(id: "cities_mastered", tier: citiesMasteredTier, currentProgress: Double(metrics.citiesMastered), nextGoal: citiesMasteredNext)

                let (dailyTier, dailyNext) = self.getTierAndNext(for: metrics.maxDailyDistance, tiers: [10, 15, 20, 30])
                self.updateAchievementTier(id: "daily_distance", tier: dailyTier, currentProgress: metrics.todayDistance, nextGoal: dailyNext)

                let (dailyRunningTier, dailyRunningNext) = self.getTierAndNext(for: metrics.maxDailyRunning, tiers: [5, 10, 21, 42])
                self.updateAchievementTier(id: "daily_running", tier: dailyRunningTier, currentProgress: metrics.todayRunning, nextGoal: dailyRunningNext)

                if metrics.didRecalculateDistricts {
                    self.berlinDistrictsVisitedCached = metrics.visitedDistricts
                    self.berlinVisitedFingerprint = metrics.fingerprint
                    self.newlyVisitedDistrictNames = metrics.visitedDistricts.subtracting(previousDistricts).sorted()
                } else {
                    self.newlyVisitedDistrictNames = []
                }
                let (berlinTier, berlinNext) = self.getCountTierAndNext(for: self.berlinDistrictsVisitedCached.count, tiers: [3, 6, 9, 12])
                self.updateAchievementTier(id: "berlin_districts", tier: berlinTier, currentProgress: Double(self.berlinDistrictsVisitedCached.count), nextGoal: berlinNext)

                let visitedStadtteile: Set<String>
                if !cachedStadtteilStats.isEmpty {
                    visitedStadtteile = Set(cachedStadtteilStats.filter { $0.coveredStreets > 0 }.map { $0.stadtteil })
                } else if !cachedStreetSegments.isEmpty {
                    visitedStadtteile = Set(cachedStreetSegments.compactMap { $0.stadtteil })
                } else {
                    visitedStadtteile = []
                }
                if !visitedStadtteile.isEmpty {
                    self.berlinStadtteileVisitedCached = visitedStadtteile
                    self.newlyVisitedStadtteilNames = visitedStadtteile.subtracting(previousStadtteile).sorted()
                }
                let (stadtteilTier, stadtteilNext) = self.getCountTierAndNext(for: self.berlinStadtteileVisitedCached.count, tiers: [10, 25, 50, 75])
                self.updateAchievementTier(id: "berlin_stadtteile", tier: stadtteilTier, currentProgress: Double(self.berlinStadtteileVisitedCached.count), nextGoal: stadtteilNext)

                let (mauerwegTier, mauerwegNext) = self.getMauerwegTierAndNext(for: metrics.mauerwegCoverage)
                self.updateAchievementTier(id: "mauerweg", tier: mauerwegTier, currentProgress: metrics.mauerwegCoverage, nextGoal: mauerwegNext)

                if !needsStreetProcessing {
                    self.processingStatus = "Streets up to date ✓"
                    self.processingProgress = 1.0
                    self.processedBerlinStreets = cachedTotalBerlinStreets
                    if cachedOverallStreetCoverage > 0 {
                        let (streetsTier, streetsNext) = self.getTierAndNext(for: cachedOverallStreetCoverage, tiers: [10, 20, 40, 80])
                        self.updateAchievementTier(id: "berlin_streets", tier: streetsTier, currentProgress: cachedOverallStreetCoverage, nextGoal: streetsNext)
                    }
                    for route in routes {
                        let routeID = "\(route.date.timeIntervalSince1970)"
                        if !processedRouteIDs.contains(routeID), self.processedRoutes[routeID] == nil {
                            self.processedRoutes[routeID] = RouteCoverageData(routeID: routeID, districts: [], coveredSegments: [])
                        }
                    }
                    self.saveCachedData()
                }
            }

            if needsStreetProcessing {
                await self.processStreetsFast(routes: routes)
            }
        }
    }
    
    // Helper functions for checking achievements based on stats
    func checkAndUnlockAchievements(routes: [Route]) {
        // Calculate running and walking distances
        let runningRoutes = routes.filter { $0.workoutType == .running }
        let runningDistance = runningRoutes.reduce(0.0) { $0 + $1.distanceKm }
        
        let walkingRoutes = routes.filter { $0.workoutType == .walking }
        let walkingDistance = walkingRoutes.reduce(0.0) { $0 + $1.distanceKm }
        
        // Check running distance tiers
        let (runningTier, runningNext) = getTierAndNext(for: runningDistance, tiers: [500, 1000, 2500, 10000])
        updateAchievementTier(id: "running_distance", tier: runningTier, currentProgress: runningDistance, nextGoal: runningNext)
        
        // Check walking distance tiers
        let (walkingTier, walkingNext) = getTierAndNext(for: walkingDistance, tiers: [500, 1000, 2500, 10000])
        updateAchievementTier(id: "walking_distance", tier: walkingTier, currentProgress: walkingDistance, nextGoal: walkingNext)
        
        // Calculate country and city stats
        var countryDistances: [String: Double] = [:]
        var cityDistances: [String: Double] = [:]
        
        for route in routes {
            guard let firstCoord = route.coordinates.first else { continue }
            let geocodeResult = LocalGeocoder.geocode(latitude: firstCoord.latitude, longitude: firstCoord.longitude)
            let country = geocodeResult.country
            let city = geocodeResult.city
            
            if !country.isEmpty && country != "Unknown" {
                countryDistances[country, default: 0] += route.distanceKm
            }
            if LocalGeocoder.isSpecificCityName(city) {
                cityDistances[city, default: 0] += route.distanceKm
            }
        }
        
        // Check countries visited (at least 1km)
        let countriesVisited = countryDistances.filter { $0.value >= 1 }.count
        let (countriesVisitedTier, countriesVisitedNext) = getCountTierAndNext(for: countriesVisited, tiers: [1, 10, 25, 50])
        updateAchievementTier(id: "countries_visited", tier: countriesVisitedTier, currentProgress: Double(countriesVisited), nextGoal: countriesVisitedNext)
        
        // Check countries explored (at least 100km)
        let countriesExplored = countryDistances.filter { $0.value >= 100 }.count
        let (countriesExploredTier, countriesExploredNext) = getCountTierAndNext(for: countriesExplored, tiers: [1, 10, 25, 50])
        updateAchievementTier(id: "countries_explored", tier: countriesExploredTier, currentProgress: Double(countriesExplored), nextGoal: countriesExploredNext)
        
        // Check countries mastered (at least 1000km)
        let countriesMastered = countryDistances.filter { $0.value >= 1000 }.count
        let (countriesMasteredTier, countriesMasteredNext) = getCountTierAndNext(for: countriesMastered, tiers: [1, 10, 25, 50])
        updateAchievementTier(id: "countries_mastered", tier: countriesMasteredTier, currentProgress: Double(countriesMastered), nextGoal: countriesMasteredNext)
        
        // Check cities visited (at least 1km)
        let citiesVisited = cityDistances.filter { $0.value >= 1 }.count
        let (citiesVisitedTier, citiesVisitedNext) = getCountTierAndNext(for: citiesVisited, tiers: [1, 10, 25, 50])
        updateAchievementTier(id: "cities_visited", tier: citiesVisitedTier, currentProgress: Double(citiesVisited), nextGoal: citiesVisitedNext)
        
        // Check cities explored (at least 100km)
        let citiesExplored = cityDistances.filter { $0.value >= 100 }.count
        let (citiesExploredTier, citiesExploredNext) = getCountTierAndNext(for: citiesExplored, tiers: [1, 10, 25, 50])
        updateAchievementTier(id: "cities_explored", tier: citiesExploredTier, currentProgress: Double(citiesExplored), nextGoal: citiesExploredNext)
        
        // Check cities mastered (at least 1000km)
        let citiesMastered = cityDistances.filter { $0.value >= 1000 }.count
        let (citiesMasteredTier, citiesMasteredNext) = getCountTierAndNext(for: citiesMastered, tiers: [1, 10, 25, 50])
        updateAchievementTier(id: "cities_mastered", tier: citiesMasteredTier, currentProgress: Double(citiesMastered), nextGoal: citiesMasteredNext)
        
        // Check daily distance (all workouts)
        var dailyDistances: [String: Double] = [:]
        var dailyRunningDistances: [String: Double] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        
        for route in routes {
            let dateKey = dateFormatter.string(from: route.date)
            dailyDistances[dateKey, default: 0] += route.distanceKm
            
            if route.workoutType == .running {
                dailyRunningDistances[dateKey, default: 0] += route.distanceKm
            }
        }
        
        // Get max distance ever achieved (for tier)
        let maxDailyDistance = dailyDistances.values.max() ?? 0
        let (dailyTier, dailyNext) = getTierAndNext(for: maxDailyDistance, tiers: [10, 15, 20, 30])
        
        // Get today's distance (for progress message)
        let todayDistance = dailyDistances[today] ?? 0
        updateAchievementTier(id: "daily_distance", tier: dailyTier, currentProgress: todayDistance, nextGoal: dailyNext)
        
        // Check daily running distance
        let maxDailyRunning = dailyRunningDistances.values.max() ?? 0
        let (dailyRunningTier, dailyRunningNext) = getTierAndNext(for: maxDailyRunning, tiers: [5, 10, 21, 42])
        
        // Get today's running distance (for progress message)
        let todayRunning = dailyRunningDistances[today] ?? 0
        updateAchievementTier(id: "daily_running", tier: dailyRunningTier, currentProgress: todayRunning, nextGoal: dailyRunningNext)
        
        // Check Berlin districts visited using actual polygon boundaries (cached)
        let latestDate = routes.map { $0.date.timeIntervalSince1970 }.max() ?? 0
        let fingerprint = "\(routes.count)_\(Int(latestDate))"

        // Track previous districts before updating
        let previousDistricts = berlinDistrictsVisitedCached

        let didRecalculateDistricts = fingerprint != berlinVisitedFingerprint
        if didRecalculateDistricts {
            var visited = Set<String>()
            // Phase 1: quick pass on start/end points for all routes
            for route in routes {
                guard let first = route.coordinates.first else { continue }
                if let d = BerlinDistricts.getDistrict(lat: first.latitude, lon: first.longitude) {
                    visited.insert(d)
                }
                if let last = route.coordinates.last {
                    if let d = BerlinDistricts.getDistrict(lat: last.latitude, lon: last.longitude) {
                        visited.insert(d)
                    }
                }
            }
            // Phase 2: sample points for routes that didn't hit yet
            for route in routes {
                let coords = route.coordinates
                if coords.isEmpty { continue }
                // Skip if start or end already yielded a district for this route's area (heuristic)
                var routeLikelyCovered = false
                if let first = coords.first, let d1 = BerlinDistricts.getDistrict(lat: first.latitude, lon: first.longitude), visited.contains(d1) {
                    routeLikelyCovered = true
                }
                if let last = coords.last, let d2 = BerlinDistricts.getDistrict(lat: last.latitude, lon: last.longitude), visited.contains(d2) {
                    routeLikelyCovered = true
                }
                if routeLikelyCovered { continue }
                let step = max(1, coords.count / 10)
                var routeFound = false
                for i in stride(from: 0, to: coords.count, by: step) {
                    let c = coords[i]
                    if let d = BerlinDistricts.getDistrict(lat: c.latitude, lon: c.longitude) {
                        visited.insert(d)
                        routeFound = true
                    }
                }
                if !routeFound {
                    // Optional deeper check on a few more points (quarters)
                    let quarterIndices = [coords.count/4, coords.count/2, (3*coords.count)/4].filter { $0 >= 0 && $0 < coords.count }
                    for idx in quarterIndices {
                        let c = coords[idx]
                        if let d = BerlinDistricts.getDistrict(lat: c.latitude, lon: c.longitude) {
                            visited.insert(d)
                        }
                    }
                }
            }
            berlinDistrictsVisitedCached = visited
            berlinVisitedFingerprint = fingerprint
            saveCachedData() // Save to persistent storage
        }
        
        let berlinDistrictsCount = berlinDistrictsVisitedCached.count
        let (berlinTier, berlinNext) = getCountTierAndNext(for: berlinDistrictsCount, tiers: [3, 6, 9, 12])

        // Generate contextual message for new districts
        var districtsContext: String? = nil
        if didRecalculateDistricts {
            let newDistricts = berlinDistrictsVisitedCached.subtracting(previousDistricts)
            newlyVisitedDistrictNames = newDistricts.sorted()
            if !newDistricts.isEmpty {
                let sortedNew = newDistricts.sorted()
                if sortedNew.count == 1 {
                    districtsContext = "This was your first walk in \(sortedNew[0])!"
                } else {
                    districtsContext = "New districts: \(sortedNew.joined(separator: ", "))"
                }

                // Add progress message
                let remaining = Int(berlinNext) - berlinDistrictsCount
                if remaining > 0 {
                    let tierName: String
                    if berlinNext == 6 {
                        tierName = "Silver"
                    } else if berlinNext == 9 {
                        tierName = "Gold"
                    } else if berlinNext == 12 {
                        tierName = "Platinum"
                    } else {
                        tierName = "next tier"
                    }
                    districtsContext! += "\nOnly \(remaining) more districts to reach \(tierName)!"
                }
            }
        } else {
            newlyVisitedDistrictNames = []
        }

        updateAchievementTier(id: "berlin_districts", tier: berlinTier, currentProgress: Double(berlinDistrictsCount), nextGoal: berlinNext, extraContext: districtsContext)

        print("🏙️ Berlin districts visited: \(berlinDistrictsCount) - \(berlinDistrictsVisitedCached)")
        
        // Determine visited Stadtteile (prefer fast cache if available)
        // Track previous stadtteile before updating
        let previousStadtteile = berlinStadtteileVisitedCached

        let visitedStadtteile: Set<String>
        if !stadtteilCoverageStats.isEmpty {
            visitedStadtteile = Set(stadtteilCoverageStats.filter { $0.coveredStreets > 0 }.map { $0.stadtteil })
        } else if !streetSegmentsCovered.isEmpty {
            visitedStadtteile = Set(streetSegmentsCovered.compactMap { $0.stadtteil })
        } else {
            visitedStadtteile = []
        }

        berlinStadtteileVisitedCached = visitedStadtteile
        let stadtteilCount = visitedStadtteile.count
        let (stadtteilTier, stadtteilNext) = getCountTierAndNext(for: stadtteilCount, tiers: [10, 25, 50, 75])

        // Generate contextual message for new stadtteile
        var stadtteileContext: String? = nil
        let newStadtteile = visitedStadtteile.subtracting(previousStadtteile)
        newlyVisitedStadtteilNames = newStadtteile.sorted()
        if !newStadtteile.isEmpty {
            let sortedNew = newStadtteile.sorted()
            if sortedNew.count == 1 {
                stadtteileContext = "This was your first walk in \(sortedNew[0])!"
            } else if sortedNew.count <= 3 {
                stadtteileContext = "New neighborhoods: \(sortedNew.joined(separator: ", "))"
            } else {
                stadtteileContext = "Explored \(sortedNew.count) new neighborhoods!"
            }

            // Add progress message
            let remaining = Int(stadtteilNext) - stadtteilCount
            if remaining > 0 {
                let tierName: String
                if stadtteilNext == 25 {
                    tierName = "Silver"
                } else if stadtteilNext == 50 {
                    tierName = "Gold"
                } else if stadtteilNext == 75 {
                    tierName = "Platinum"
                } else {
                    tierName = "next tier"
                }
                stadtteileContext! += "\nOnly \(remaining) more neighborhoods to reach \(tierName)!"
            }
        }

        updateAchievementTier(id: "berlin_stadtteile", tier: stadtteilTier, currentProgress: Double(stadtteilCount), nextGoal: stadtteilNext, extraContext: stadtteileContext)

        print("🏘️ Berlin Stadtteile visited: \(stadtteilCount)")

        let mauerwegCoverage = calculateMauerwegCoverage(routes: routes)
        let (mauerwegTier, mauerwegNext) = getMauerwegTierAndNext(for: mauerwegCoverage)
        updateAchievementTier(id: "mauerweg", tier: mauerwegTier, currentProgress: mauerwegCoverage, nextGoal: mauerwegNext)
        print("🧱 Mauerweg coverage: \(String(format: "%.2f", mauerwegCoverage))%")
        
        // Reset berlin_streets achievement if no coverage
        if streetSegmentsCovered.isEmpty && streetCoverageByID.isEmpty {
            updateAchievementTier(id: "berlin_streets", tier: .none, currentProgress: 0.0, nextGoal: 10.0)
        }
        
        // Check Berlin streets coverage - only process when new routes exist or cache is empty
        let newRoutes = routes.filter { route in
            let routeID = "\(route.date.timeIntervalSince1970)"
            return processedRoutes[routeID] == nil
        }

        streetCoverageStateStoreHasProcessedRoutes = hasIncrementalStreetCoverageState()
        let shouldProcessStreets = !newRoutes.isEmpty || streetCoverageByID.isEmpty || !streetCoverageStateStoreHasProcessedRoutes

        if shouldProcessStreets {
            Task.detached(priority: .background) {
                await self.processStreetsFast(routes: routes)
            }
        } else {
            processingStatus = "Streets up to date ✓"
            processingProgress = 1.0
            processedBerlinStreets = totalBerlinStreets

            // Update achievement tier based on current coverage
            if overallStreetCoverage > 0 {
                let (streetsTier, streetsNext) = getTierAndNext(for: overallStreetCoverage, tiers: [10, 20, 40, 80])
                updateAchievementTier(id: "berlin_streets", tier: streetsTier, currentProgress: overallStreetCoverage, nextGoal: streetsNext)
                print("🛣️ Streets achievement updated: \(String(format: "%.2f", overallStreetCoverage))% coverage, tier: \(streetsTier.rawValue)")
            }

            // Ensure processed routes cache contains current routes
            for route in routes {
                let routeID = "\(route.date.timeIntervalSince1970)"
                if processedRoutes[routeID] == nil {
                    processedRoutes[routeID] = RouteCoverageData(routeID: routeID, districts: [], coveredSegments: [])
                }
            }
            saveCachedData()
        }
    }
    
    // Use incremental street coverage processing backed by the rebuild foundation.
    func processStreetsFast(routes: [Route]) async {
        let startedAt = Date()
        print("🚀 Processing Berlin street coverage incrementally for \(routes.count) routes")

        let allDistricts = BerlinDistricts.districts.map { $0.name }

        await MainActor.run {
            processingStatus = "Loading Berlin streets..."
            processingProgress = 0
            currentStadtteilProgressInfo = nil
        }

        let allStreets = await loadStreetSegments(forDistricts: allDistricts)
        let consolidated = StreetConsolidator.consolidate(streets: allStreets)
        let streetSnapshots = consolidated.map(StreetGeometrySnapshot.init(consolidatedStreet:))
        let routeSnapshots = routes.map(RunMapRouteSnapshot.init(route:))

        guard !streetSnapshots.isEmpty else {
            await MainActor.run {
                processingStatus = "No Berlin street data available"
                processingProgress = 1.0
            }
            print("⚠️ Incremental street coverage skipped: no street geometry loaded")
            return
        }

        await MainActor.run {
            processingStatus = "Processing new route coverage..."
            processingProgress = 0.35
            totalBerlinStreets = streetSnapshots.count
            processedBerlinStreets = 0
        }

        let store: StreetCoverageStateStore?
        do {
            store = try StreetCoverageStateStore.appCache()
        } catch {
            store = nil
            print("⚠️ Street coverage state store unavailable: \(error)")
        }

        let existingState: StreetCoverageState
        do {
            existingState = try store?.load() ?? .empty
        } catch {
            existingState = .empty
            print("⚠️ Failed to load incremental street coverage state, rebuilding from empty: \(error)")
        }

        let processor = StreetCoverageDeltaProcessor(engine: StreetCoverageEngine(thresholdMeters: 20.0))
        let result = processor.process(
            streets: streetSnapshots,
            routes: routeSnapshots,
            existingState: existingState
        )

        do {
            try store?.save(result.state)
        } catch {
            print("⚠️ Failed to save incremental street coverage state: \(error)")
        }

        let output = makeStreetProcessingOutput(
            consolidatedStreets: consolidated,
            coverageByStreetID: result.state.coverageByStreetID
        )

        await MainActor.run {
            self.consolidatedStreets = output.consolidatedStreets
            self.streetCoverageByID = output.coverageByStreetID
            self.districtCoverageStats = output.districtStats
            self.stadtteilCoverageStats = output.stadtteilStats
            self.overallStreetCoverage = output.overallCoveragePercentage
            self.totalBerlinStreets = output.totalStreetCount
            self.processedBerlinStreets = output.totalStreetCount
            self.coveredBerlinStreets = output.coveredStreetCount
            self.fullyCoveredBerlinStreets = output.fullyCoveredStreetCount
            self.coveredBerlinPoints = output.coveredPoints
            self.totalBerlinPoints = output.totalPoints
            self.streetCoverageLastUpdated = Date()

            var byDistrict: [String: [ConsolidatedStreet]] = [:]
            var byStadtteil: [String: [ConsolidatedStreet]] = [:]
            for street in output.consolidatedStreets {
                byDistrict[street.district, default: []].append(street)
                if let stadtteil = street.segments.first?.stadtteil {
                    byStadtteil[stadtteil, default: []].append(street)
                }
            }
            self.streetsByDistrict = byDistrict
            self.streetsByStadtteil = byStadtteil

            let previousStadtteile = self.berlinStadtteileVisitedCached
            let visitedStadtteile = Set(output.stadtteilStats.filter { $0.coveredStreets > 0 }.map { $0.stadtteil })
            self.berlinStadtteileVisitedCached = visitedStadtteile
            self.newlyVisitedStadtteilNames = visitedStadtteile.subtracting(previousStadtteile).sorted()
            self.newlyCoveredStreetNames = newlyCoveredStreetNames(from: output)

            for route in routes {
                let legacyRouteID = "\(route.date.timeIntervalSince1970)"
                if processedRoutes[legacyRouteID] == nil {
                    processedRoutes[legacyRouteID] = RouteCoverageData(routeID: legacyRouteID, districts: [], coveredSegments: [])
                }
            }

            processingStatus = result.processedRouteCount == 0 ? "Streets up to date ✓" : "Complete!"
            processingProgress = 1.0

            // Update achievement
            let (streetsTier, streetsNext) = getTierAndNext(for: overallStreetCoverage, tiers: [10, 20, 40, 80])
            updateAchievementTier(id: "berlin_streets", tier: streetsTier, currentProgress: overallStreetCoverage, nextGoal: streetsNext)

            saveCachedData()
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        print("✅ Incremental street coverage complete: \(result.processedRouteCount) new routes, \(String(format: "%.2f", output.overallCoveragePercentage))% coverage, \(String(format: "%.2f", elapsed))s")
    }

    func newlyCoveredStreetNames(from output: StreetProcessingOutput) -> [String] {
        let visitedStreetIDs = Set(output.coverageByStreetID.compactMap { streetID, coverage in
            (coverage.coveredPoints > 0 || coverage.percentage > 0) ? streetID : nil
        })

        let previousStreetIDs = Set(UserDefaults.standard.stringArray(forKey: visitedBerlinStreetIDsKey) ?? [])
        UserDefaults.standard.set(Array(visitedStreetIDs), forKey: visitedBerlinStreetIDsKey)

        guard !previousStreetIDs.isEmpty else {
            return []
        }

        let streetsByID = Dictionary(uniqueKeysWithValues: output.consolidatedStreets.map { ($0.id, $0.name) })
        let newNames = visitedStreetIDs
            .subtracting(previousStreetIDs)
            .compactMap { streetsByID[$0] }

        return Array(Set(newNames)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func loadStreetSegments(forDistricts districts: [String]) async -> [BerlinStreets.Street] {
        let cached = BerlinStreets.getStreets(forDistricts: districts)
        if !cached.isEmpty {
            return cached
        }

        return await withCheckedContinuation { continuation in
            BerlinStreets.loadDistrictsInBackground(districts) { loaded in
                continuation.resume(returning: loaded.values.flatMap { $0 })
            }
        }
    }

    private func makeStreetProcessingOutput(
        consolidatedStreets: [ConsolidatedStreet],
        coverageByStreetID snapshots: [String: StreetCoverageSnapshot]
    ) -> StreetProcessingOutput {
        var coverageByStreet: [String: ConsolidatedStreet.CoverageResult] = [:]
        var districtAggregates: [String: CoverageAggregate] = [:]
        var stadtteilAggregates: [String: CoverageAggregate] = [:]
        var totalCoveredPoints = 0
        var totalPoints = 0
        var coveredStreetCount = 0
        var fullyCoveredStreetCount = 0

        for street in consolidatedStreets {
            let snapshot = snapshots[street.id] ?? StreetCoverageSnapshot(
                streetID: street.id,
                coveredPointIndexes: [],
                totalPointCount: street.totalPoints
            )

            let totalPointCount = max(snapshot.totalPointCount, street.totalPoints)
            let coveragePercentage = totalPointCount > 0
                ? Double(snapshot.coveredPointCount) / Double(totalPointCount) * 100.0
                : 0.0
            let coverage = ConsolidatedStreet.CoverageResult(
                coveredPoints: snapshot.coveredPointCount,
                totalPoints: totalPointCount,
                percentage: coveragePercentage,
                segmentCount: street.segments.count
            )
            coverageByStreet[street.id] = coverage

            totalCoveredPoints += coverage.coveredPoints
            totalPoints += coverage.totalPoints
            if coverage.coveredPoints > 0 {
                coveredStreetCount += 1
            }
            if coverage.isFullyCovered {
                fullyCoveredStreetCount += 1
            }

            var districtAggregate = districtAggregates[street.district] ?? CoverageAggregate(district: street.district, stadtteil: nil)
            districtAggregate.add(coverage)
            districtAggregates[street.district] = districtAggregate

            let stadtteil = street.segments.first?.stadtteil ?? "Unknown"
            let stadtteilKey = "\(street.district)|\(stadtteil)"
            var stadtteilAggregate = stadtteilAggregates[stadtteilKey] ?? CoverageAggregate(district: street.district, stadtteil: stadtteil)
            stadtteilAggregate.add(coverage)
            stadtteilAggregates[stadtteilKey] = stadtteilAggregate
        }

        let districtStats = districtAggregates.values
            .map { aggregate in
                DistrictCoverageStats(
                    district: aggregate.district,
                    totalStreets: aggregate.streetCount,
                    coveredStreets: aggregate.coveredStreetCount,
                    fullyCoveredStreets: aggregate.fullyCoveredStreetCount,
                    coveredPoints: aggregate.coveredPoints,
                    totalPoints: aggregate.totalPoints
                )
            }
            .sorted { $0.coveragePercentage > $1.coveragePercentage }
        let stadtteilStats = stadtteilAggregates.values
            .map { aggregate in
                StadtteilCoverageStats(
                    district: aggregate.district,
                    stadtteil: aggregate.stadtteil ?? "Unknown",
                    totalStreets: aggregate.streetCount,
                    coveredStreets: aggregate.coveredStreetCount,
                    fullyCoveredStreets: aggregate.fullyCoveredStreetCount,
                    coveredPoints: aggregate.coveredPoints,
                    totalPoints: aggregate.totalPoints
                )
            }
            .sorted { $0.coveragePercentage > $1.coveragePercentage }
        let overallPercentage = consolidatedStreets.isEmpty ? 0.0 : Double(coveredStreetCount) / Double(consolidatedStreets.count) * 100.0

        return StreetProcessingOutput(
            consolidatedStreets: consolidatedStreets,
            coverageByStreetID: coverageByStreet,
            districtStats: districtStats,
            stadtteilStats: stadtteilStats,
            overallCoveragePercentage: overallPercentage,
            totalStreetCount: consolidatedStreets.count,
            coveredStreetCount: coveredStreetCount,
            fullyCoveredStreetCount: fullyCoveredStreetCount,
            coveredPoints: totalCoveredPoints,
            totalPoints: totalPoints
        )
    }

    private struct CoverageAggregate {
        let district: String
        let stadtteil: String?
        var totalPoints: Int = 0
        var coveredPoints: Int = 0
        var streetCount: Int = 0
        var coveredStreetCount: Int = 0
        var fullyCoveredStreetCount: Int = 0

        mutating func add(_ coverage: ConsolidatedStreet.CoverageResult) {
            totalPoints += coverage.totalPoints
            coveredPoints += coverage.coveredPoints
            streetCount += 1
            if coverage.coveredPoints > 0 {
                coveredStreetCount += 1
            }
            if coverage.isFullyCovered {
                fullyCoveredStreetCount += 1
            }
        }
    }
        
        func updateStreetsAchievement() async {
            // Use fast processor data if available
            if !streetCoverageByID.isEmpty && overallStreetCoverage > 0 {
                await MainActor.run {
                    let (streetsTier, streetsNext) = getTierAndNext(for: overallStreetCoverage, tiers: [10, 20, 40, 80])
                    updateAchievementTier(id: "berlin_streets", tier: streetsTier, currentProgress: overallStreetCoverage, nextGoal: streetsNext)
                    objectWillChange.send()
                    print("🛣️ Streets achievement updated: \(String(format: "%.2f", overallStreetCoverage))% overall coverage, tier: \(streetsTier.rawValue)")
                }
                return
            }

            // No data yet - fast processor hasn't run or is still processing
            print("⚠️ No street coverage data yet - waiting for fast processor")
        }
    }

// MARK: - Achievement Detail View

struct AchievementDetailView: View {
    let achievement: Achievement
    let routes: [Route]
    var onDistrictSelected: ((String, Double, Double) -> Void)? = nil
    var onShowAllDistricts: (() -> Void)? = nil
    var onShowAllStadtteile: (() -> Void)? = nil
    var onLocationSelected: ((String, String) -> Void)? = nil
    var visitedBerlinDistricts: Set<String>? = nil
    var achievementsManager: AchievementsManager? = nil
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(achievement.isUnlocked ?
                                  LinearGradient(colors: [achievement.currentTier.color, achievement.currentTier.color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                                    LinearGradient(colors: [.gray.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 120, height: 120)
                        
                        Image(systemName: achievement.iconName)
                            .font(.system(size: 48))
                            .foregroundColor(achievement.isUnlocked ? .white : .gray)
                    }
                    
                    Text(achievement.title)
                        .font(.title)
                        .fontWeight(.bold)
                    
                    if achievement.isUnlocked {
                        Text(achievement.currentTier.rawValue)
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(achievement.currentTier.color)
                            .cornerRadius(8)
                    }
                    
                    Text(achievement.progressMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                
                // Content based on achievement type
                if achievement.id == "mauerweg" {
                    mauerwegView()
                } else if achievement.id == "berlin_districts" {
                    // Show Berlin districts list (uses cached set if available)
                    berlinDistrictsView()
                } else if achievement.id == "berlin_stadtteile" {
                    // Show Berlin Stadtteile list
                    berlinStadtteileView()
                } else if achievement.id == "berlin_streets" {
                    // Show Berlin streets list
                    berlinStreetsView()
                } else if achievement.id.contains("distance") && !achievement.id.contains("daily") {
                    // Show cumulative distance graph for running/walking
                    distanceGraphView(achievement: achievement)
                } else if achievement.id.contains("visited") || achievement.id.contains("explored") || achievement.id.contains("mastered") {
                    // Show list of countries/cities
                    locationListView(achievement: achievement)
                } else if achievement.id == "daily_distance" || achievement.id == "daily_running" {
                    dailyDistanceView()
                }
            }
            .padding()
        }
        .navigationTitle("Achievement Details")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private func distanceGraphView(achievement: Achievement) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Progress Over Time")
                .font(.headline)
                .padding(.horizontal)
            
            let workoutType: HKWorkoutActivityType = achievement.id.contains("running") ? .running : .walking
            let filteredRoutes = routes.filter { $0.workoutType == workoutType }.sorted { $0.date < $1.date }
            
            if !filteredRoutes.isEmpty {
                CumulativeDistanceGraph(routes: filteredRoutes, achievement: achievement)
                    .frame(height: 300)
                    .padding()
            } else {
                Text("No workouts recorded yet")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func locationListView(achievement: Achievement) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Qualified Locations")
                .font(.headline)
                .padding(.horizontal)
            
            let locations = getQualifiedLocations(achievement: achievement)
            let isCity = achievement.category == .city

            if !isCity {
                CountryWorldMapView(
                    countryDistances: getLocationDistances(isCity: false),
                    threshold: locationThreshold(for: achievement)
                )
                .frame(height: 260)
                .padding(.horizontal)
            } else {
                CityWorldMapView(
                    cities: getQualifiedCityLocations(achievement: achievement),
                    threshold: locationThreshold(for: achievement)
                )
                .frame(height: 260)
                .padding(.horizontal)
            }
            
            if !locations.isEmpty {
                ForEach(locations, id: \.name) { location in
                    Button(action: {
                        // Determine if this is a city or country achievement
                        if isCity {
                            onLocationSelected?("", location.name) // City only
                        } else {
                            onLocationSelected?(location.name, "") // Country only
                        }
                        dismiss()
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(location.name)
                                    .font(.body)
                                    .fontWeight(.semibold)
                                Text(String(format: "%.1f km", location.distance))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal)
            } else {
                Text("No qualified locations yet")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
    }

    private struct QualifiedCityLocation {
        let name: String
        let distance: Double
        let coordinate: CLLocationCoordinate2D
    }

    private struct CountryWorldMapView: View {
        let countryDistances: [String: Double]
        let threshold: Double

        private let boundaries = LocalGeocoder.worldMapBoundaries()

        private var qualifiedCountries: Set<String> {
            Set(countryDistances.filter { $0.value >= threshold }.map(\.key))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    Canvas { context, size in
                        let mapRect = CGRect(origin: .zero, size: size)

                        for country in boundaries {
                            var path = Path()
                            for polygon in country.polygons {
                                guard let first = polygon.first else { continue }
                                path.move(to: Self.project(first, in: mapRect))
                                for coordinate in polygon.dropFirst() {
                                    path.addLine(to: Self.project(coordinate, in: mapRect))
                                }
                                path.closeSubpath()
                            }

                            let isQualified = qualifiedCountries.contains(country.name)
                            let fill = isQualified
                                ? Color.green.opacity(0.72)
                                : Color.red.opacity(0.30)
                            context.fill(path, with: .color(fill))
                            context.stroke(path, with: .color(Color.white.opacity(0.55)), lineWidth: 0.35)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 14) {
                        legendItem(color: .green, title: "Visited")
                        legendItem(color: .red, title: "Not yet")
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .cornerRadius(8)
                    .padding(10)
                }

                Text("\(qualifiedCountries.count) countries at \(Self.thresholdLabel(threshold))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }

        private static func project(_ coordinate: CLLocationCoordinate2D, in rect: CGRect) -> CGPoint {
            let clampedLatitude = min(84.0, max(-60.0, coordinate.latitude))
            let x = (coordinate.longitude + 180.0) / 360.0 * rect.width
            let y = (84.0 - clampedLatitude) / 144.0 * rect.height
            return CGPoint(x: x, y: y)
        }

        private static func thresholdLabel(_ threshold: Double) -> String {
            if threshold >= 1000 {
                return "1000 km+"
            } else if threshold >= 100 {
                return "100 km+"
            } else {
                return "1 km+"
            }
        }

        private func legendItem(color: Color, title: String) -> some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private struct CityWorldMapView: View {
        let cities: [QualifiedCityLocation]
        let threshold: Double

        private let boundaries = LocalGeocoder.worldMapBoundaries()

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    Canvas { context, size in
                        let mapRect = CGRect(origin: .zero, size: size)

                        for country in boundaries {
                            var path = Path()
                            for polygon in country.polygons {
                                guard let first = polygon.first else { continue }
                                path.move(to: Self.project(first, in: mapRect))
                                for coordinate in polygon.dropFirst() {
                                    path.addLine(to: Self.project(coordinate, in: mapRect))
                                }
                                path.closeSubpath()
                            }

                            context.fill(path, with: .color(Color.gray.opacity(0.26)))
                            context.stroke(path, with: .color(Color.white.opacity(0.55)), lineWidth: 0.35)
                        }

                        for city in cities {
                            let point = Self.project(city.coordinate, in: mapRect)
                            let radius = Self.pinRadius(for: city.distance)
                            let pinRect = CGRect(
                                x: point.x - radius,
                                y: point.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )

                            context.fill(Path(ellipseIn: pinRect), with: .color(Color.blue.opacity(0.86)))
                            context.stroke(Path(ellipseIn: pinRect), with: .color(.white), lineWidth: 1.2)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 14) {
                        legendItem(color: .blue, title: "City")
                        Spacer()
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .cornerRadius(8)
                    .padding(10)
                }

                Text("\(cities.count) cities at \(Self.thresholdLabel(threshold))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }

        private static func project(_ coordinate: CLLocationCoordinate2D, in rect: CGRect) -> CGPoint {
            let clampedLatitude = min(84.0, max(-60.0, coordinate.latitude))
            let x = (coordinate.longitude + 180.0) / 360.0 * rect.width
            let y = (84.0 - clampedLatitude) / 144.0 * rect.height
            return CGPoint(x: x, y: y)
        }

        private static func pinRadius(for distance: Double) -> CGFloat {
            if distance >= 1000 {
                return 5.8
            } else if distance >= 100 {
                return 4.9
            } else {
                return 4.0
            }
        }

        private static func thresholdLabel(_ threshold: Double) -> String {
            if threshold >= 1000 {
                return "1000 km+"
            } else if threshold >= 100 {
                return "100 km+"
            } else {
                return "1 km+"
            }
        }

        private func legendItem(color: Color, title: String) -> some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func berlinDistrictsView() -> some View {
        BerlinDistrictsListView(
            routes: routes,
            cachedVisited: visitedBerlinDistricts,
            onDistrictSelected: onDistrictSelected,
            onShowAllDistricts: onShowAllDistricts,
            dismiss: dismiss,
            achievementsManager: achievementsManager)
    }
    
    @ViewBuilder
    private func berlinStadtteileView() -> some View {
        if let achievementsManager = achievementsManager {
            BerlinStadtteileListView(
                visitedStadtteile: achievementsManager.berlinStadtteileVisitedCached,
                streetSegments: achievementsManager.streetSegmentsCovered,
                onShowAllStadtteile: onShowAllStadtteile,
                dismiss: dismiss)
        } else {
            Text("Loading Stadtteile...")
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func mauerwegView() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let completedStickers = BerlinMauerweg.completedLandmarkStickers(routes: routes)

            Text("Mauerweg Progress")
                .font(.headline)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                Text(String(format: "%.1f%% covered", achievement.currentProgress))
                    .font(.title2)
                    .fontWeight(.bold)

                ProgressView(value: min(achievement.currentProgress, 100), total: 100)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Bronze: start the Mauerweg", systemImage: achievement.currentProgress > 0 ? "checkmark.circle.fill" : "circle")
                    Label("Silver: 10%", systemImage: achievement.currentProgress >= 10 ? "checkmark.circle.fill" : "circle")
                    Label("Gold: 50%", systemImage: achievement.currentProgress >= 50 ? "checkmark.circle.fill" : "circle")
                    Label("Platinum: 100%", systemImage: achievement.currentProgress >= 99.9 ? "checkmark.circle.fill" : "circle")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            MauerwegCoverageMap(routes: routes)
                .frame(height: 280)
                .cornerRadius(12)
                .padding(.horizontal)

            if !completedStickers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Stickers")
                        .font(.headline)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                        ForEach(completedStickers) { sticker in
                            VStack(spacing: 8) {
                                Image(systemName: sticker.iconName)
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.orange)
                                    .clipShape(Circle())

                                Text(sticker.title)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(12)
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }

    private struct MauerwegCoverageMap: View {
        let routes: [Route]

        @State private var isRendering = true

        var body: some View {
            ZStack(alignment: .bottom) {
                MauerwegCoverageMapRepresentable(
                    routes: routes,
                    onRenderComplete: {
                        isRendering = false
                    }
                )

                HStack(spacing: 14) {
                    legendItem(color: .green, title: "Covered")
                    legendItem(color: .red, title: "Open")
                    Spacer()
                    if isRendering {
                        ProgressView()
                    }
                }
                .padding(10)
                .background(.regularMaterial)
                .cornerRadius(8)
                .padding(10)
            }
            .overlay(alignment: .topLeading) {
                Text("Mauerweg Map")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial)
                    .cornerRadius(8)
                    .padding(10)
            }
        }

        private func legendItem(color: Color, title: String) -> some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private struct MauerwegCoverageMapRepresentable: UIViewRepresentable {
        let routes: [Route]
        let onRenderComplete: () -> Void

        func makeUIView(context: Context) -> MKMapView {
            let mapView = MKMapView()
            mapView.delegate = context.coordinator
            mapView.pointOfInterestFilter = .excludingAll
            mapView.isPitchEnabled = false
            mapView.showsUserLocation = false
            mapView.setRegion(Self.defaultRegion, animated: false)
            context.coordinator.render(routes: routes, on: mapView, onRenderComplete: onRenderComplete)
            return mapView
        }

        func updateUIView(_ mapView: MKMapView, context: Context) {
            context.coordinator.render(routes: routes, on: mapView, onRenderComplete: onRenderComplete)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        private static let defaultRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405),
            span: MKCoordinateSpan(latitudeDelta: 0.42, longitudeDelta: 0.56)
        )

        final class Coordinator: NSObject, MKMapViewDelegate {
            private var renderedSignature: String?
            private var renderGeneration = 0
            private weak var coveredOverlay: MKMultiPolyline?
            private weak var uncoveredOverlay: MKMultiPolyline?

            func render(
                routes: [Route],
                on mapView: MKMapView,
                onRenderComplete: @escaping () -> Void
            ) {
                let signature = Self.signature(for: routes)
                guard signature != renderedSignature else { return }

                renderedSignature = signature
                renderGeneration += 1
                let generation = renderGeneration

                let existing = mapView.overlays
                if !existing.isEmpty {
                    mapView.removeOverlays(existing)
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Self.makeCoveragePolylines(routes: routes)

                    DispatchQueue.main.async {
                        guard generation == self.renderGeneration else { return }

                        if !result.uncovered.isEmpty {
                            let overlay = MKMultiPolyline(result.uncovered)
                            self.uncoveredOverlay = overlay
                            mapView.addOverlay(overlay, level: .aboveRoads)
                        }

                        if !result.covered.isEmpty {
                            let overlay = MKMultiPolyline(result.covered)
                            self.coveredOverlay = overlay
                            mapView.addOverlay(overlay, level: .aboveRoads)
                        }

                        if !result.allCoordinates.isEmpty {
                            mapView.setRegion(coordinateRegion(for: result.allCoordinates), animated: false)
                        }

                        onRenderComplete()
                    }
                }
            }

            func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
                guard let multiPolyline = overlay as? MKMultiPolyline else {
                    return MKOverlayRenderer(overlay: overlay)
                }

                let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
                if multiPolyline === coveredOverlay {
                    renderer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9)
                    renderer.lineWidth = 4.0
                    renderer.alpha = 0.95
                } else if multiPolyline === uncoveredOverlay {
                    renderer.strokeColor = UIColor.systemRed.withAlphaComponent(0.55)
                    renderer.lineWidth = 3.0
                    renderer.alpha = 0.9
                } else {
                    renderer.strokeColor = UIColor.systemGray
                    renderer.lineWidth = 3.0
                }
                return renderer
            }

            private static func signature(for routes: [Route]) -> String {
                routes
                    .map { "\($0.id.uuidString):\($0.coordinates.count)" }
                    .sorted()
                    .joined(separator: "|")
            }

            private static func makeCoveragePolylines(
                routes: [Route]
            ) -> (covered: [MKPolyline], uncovered: [MKPolyline], allCoordinates: [CLLocationCoordinate2D]) {
                let mauerwegSegments = BerlinMauerweg.coordinateSegments()
                let allCoordinates = mauerwegSegments.flatMap { segment in
                    segment.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                }
                var coveredPolylines: [MKPolyline] = []
                var uncoveredPolylines: [MKPolyline] = []

                let checker = routes.isEmpty ? nil : FastStreetChecker(routes: routes)
                for segment in mauerwegSegments {
                    guard segment.count >= 2 else { continue }

                    let segmentCoordinates = segment.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }
                    let coveredPoints = checker?.checkStreetCoverage(streetCoords: segment)
                        ?? Array(repeating: false, count: segment.count)

                    var currentCoordinates: [CLLocationCoordinate2D] = [segmentCoordinates[0]]
                    var currentCovered = coveredPoints[0]

                    for index in 1..<segmentCoordinates.count {
                        let point = segmentCoordinates[index]
                        let isCovered = coveredPoints[index]

                        if isCovered == currentCovered {
                            currentCoordinates.append(point)
                        } else {
                            appendPolyline(
                                coordinates: currentCoordinates,
                                isCovered: currentCovered,
                                covered: &coveredPolylines,
                                uncovered: &uncoveredPolylines
                            )
                            currentCoordinates = [segmentCoordinates[index - 1], point]
                            currentCovered = isCovered
                        }
                    }

                    appendPolyline(
                        coordinates: currentCoordinates,
                        isCovered: currentCovered,
                        covered: &coveredPolylines,
                        uncovered: &uncoveredPolylines
                    )
                }

                return (coveredPolylines, uncoveredPolylines, allCoordinates)
            }

            private static func appendPolyline(
                coordinates: [CLLocationCoordinate2D],
                isCovered: Bool,
                covered: inout [MKPolyline],
                uncovered: inout [MKPolyline]
            ) {
                guard coordinates.count >= 2 else { return }
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                if isCovered {
                    covered.append(polyline)
                } else {
                    uncovered.append(polyline)
                }
            }
        }
    }
    
    private struct BerlinDistrictsListView: View {
        let routes: [Route]
        let cachedVisited: Set<String>?
        let onDistrictSelected: ((String, Double, Double) -> Void)?
        let onShowAllDistricts: (() -> Void)?
        let dismiss: DismissAction
        let achievementsManager: AchievementsManager?
        
        @State private var visitedDistricts: Set<String> = []
        @State private var isComputing = true
        @State private var totalRoutes: Int = 0
        @State private var processedRoutes: Int = 0
        @State private var totalCoords: Int = 0
        @State private var processedCoords: Int = 0
        
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                // Show All Districts button
                Button(action: {
                    onShowAllDistricts?()
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "map.circle.fill")
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text("Show All Districts")
                                .font(.headline)
                            Text("View all 12 Berlin districts on map")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                
                if isComputing {
                    VStack(spacing: 8) {
                        ProgressView(value: totalRoutes == 0 ? 0 : Double(processedRoutes) / Double(totalRoutes))
                        Text("Analyzing routes… \(processedRoutes)/\(totalRoutes)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if totalCoords > 0 {
                            Text(String(format: "Processed %.0f%% of coordinates", totalCoords == 0 ? 0 : 100.0 * Double(processedCoords) / Double(totalCoords)))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                } else {
                    let allDistricts = BerlinDistricts.districts.map { $0.name }
                    let missingDistricts = allDistricts.filter { !visitedDistricts.contains($0) }
                    
                    if !visitedDistricts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Visited Districts (\(visitedDistricts.count)/12)")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            ForEach(Array(visitedDistricts.sorted()), id: \.self) { district in
                                NavigationLink(destination: DistrictStreetListView(
                                    districtName: district,
                                    stadtteilName: nil,
                                    streets: achievementsManager?.streetsByDistrict[district] ?? [],
                                    routes: routes,
                                    processor: achievementsManager?.fastProcessor ?? FastStreetProcessor()
                                )) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text(district)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    }
                                    .padding()
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    if !missingDistricts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Not Yet Visited (\(missingDistricts.count)/12)")
                                .font(.headline)
                                .padding(.horizontal)
                                .padding(.top, 8)
                            
                            ForEach(missingDistricts.sorted(), id: \.self) { district in
                                NavigationLink(destination: DistrictStreetListView(
                                    districtName: district,
                                    stadtteilName: nil,
                                    streets: achievementsManager?.streetsByDistrict[district] ?? [],
                                    routes: routes,
                                    processor: achievementsManager?.fastProcessor ?? FastStreetProcessor()
                                )) {
                                    HStack {
                                        Image(systemName: "circle")
                                            .foregroundColor(.gray)
                                        Text(district)
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    }
                                    .padding()
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    if visitedDistricts.isEmpty && missingDistricts.count == 12 {
                        Text("No Berlin districts visited yet. Start exploring Berlin!")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
            }
            .task {
                if let cached = cachedVisited, !cached.isEmpty {
                    visitedDistricts = cached
                    isComputing = false
                } else {
                    await computeVisitedAsync()
                }
            }
        }
        
        private func computeVisitedAsync() async {
            await MainActor.run {
                isComputing = true
                totalRoutes = routes.count
                totalCoords = routes.reduce(0) { $0 + $1.coordinates.count }
                processedRoutes = 0
                processedCoords = 0
            }
            var found = Set<String>()
            // Phase 1: start/end for all routes
            for route in routes {
                let coords = route.coordinates
                if let first = coords.first, let d = BerlinDistricts.getDistrict(lat: first.latitude, lon: first.longitude) {
                    found.insert(d)
                }
                if let last = coords.last, let d = BerlinDistricts.getDistrict(lat: last.latitude, lon: last.longitude) {
                    found.insert(d)
                }
                await MainActor.run { processedRoutes += 1 }
            }
            // Phase 2: sample remaining routes
            processedRoutes = 0
            for route in routes {
                let coords = route.coordinates
                if coords.isEmpty { await MainActor.run { processedRoutes += 1 }; continue }
                var routeLikelyCovered = false
                if let first = coords.first, let d1 = BerlinDistricts.getDistrict(lat: first.latitude, lon: first.longitude), found.contains(d1) { routeLikelyCovered = true }
                if let last = coords.last, let d2 = BerlinDistricts.getDistrict(lat: last.latitude, lon: last.longitude), found.contains(d2) { routeLikelyCovered = true }
                if !routeLikelyCovered {
                    let step = max(1, coords.count / 10)
                    for i in stride(from: 0, to: coords.count, by: step) {
                        let c = coords[i]
                        if let d = BerlinDistricts.getDistrict(lat: c.latitude, lon: c.longitude) {
                            found.insert(d)
                        }
                        await MainActor.run { processedCoords += 1 }
                    }
                }
                await MainActor.run { processedRoutes += 1 }
            }
            await MainActor.run {
                visitedDistricts = found
                isComputing = false
            }
        }
    }
    
    private func getBerlinDistrictsVisited() -> Set<String> {
        var visitedDistricts = Set<String>()
        
        for route in routes {
            // Check multiple points along the route to catch all districts
            let checkPoints = stride(from: 0, to: route.coordinates.count, by: max(1, route.coordinates.count / 10))
            
            for i in checkPoints {
                let coord = route.coordinates[i]
                if let district = BerlinDistricts.getDistrict(lat: coord.latitude, lon: coord.longitude) {
                    visitedDistricts.insert(district)
                }
            }
        }
        
        return visitedDistricts
    }
    
    @ViewBuilder
    private func berlinStreetsView() -> some View {
        if let manager = achievementsManager {
            BerlinStreetsListView(achievementsManager: manager, routes: routes)
        } else {
            Text("Loading...")
        }
    }
    
    @ViewBuilder
    private func dailyDistanceView() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Determine if this is running-only or all workouts
            let isRunningOnly = achievement.id == "daily_running"
            let dailyDistances = calculateDailyDistances(runningOnly: isRunningOnly)
            let thresholds: (bronze: Double, silver: Double, gold: Double, platinum: Double) = isRunningOnly
                ? (5.0, 10.0, 21.0, 42.0)
                : (10.0, 15.0, 20.0, 30.0)
            
            // Count achievements by tier
            let bronzeCount = dailyDistances.filter { $0.value >= thresholds.bronze && $0.value < thresholds.silver }.count
            let silverCount = dailyDistances.filter { $0.value >= thresholds.silver && $0.value < thresholds.gold }.count
            let goldCount = dailyDistances.filter { $0.value >= thresholds.gold && $0.value < thresholds.platinum }.count
            let platinumCount = dailyDistances.filter { $0.value >= thresholds.platinum }.count
            
            // Tier summary
            HStack(spacing: 20) {
                if bronzeCount > 0 {
                    VStack {
                        Text("\(bronzeCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(AchievementTier.bronze.color)
                        Text("Bronze")
                            .font(.caption)
                    }
                }
                if silverCount > 0 {
                    VStack {
                        Text("\(silverCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(AchievementTier.silver.color)
                        Text("Silver")
                            .font(.caption)
                    }
                }
                if goldCount > 0 {
                    VStack {
                        Text("\(goldCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(AchievementTier.gold.color)
                        Text("Gold")
                            .font(.caption)
                    }
                }
                if platinumCount > 0 {
                    VStack {
                        Text("\(platinumCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(AchievementTier.platinum.color)
                        Text("Platinum")
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            
            Divider()
            
            Text("All Achievements (Highest to Lowest)")
                .font(.headline)
                .padding(.horizontal)
            
            let sortedDays = dailyDistances.filter { $0.value >= thresholds.bronze }.sorted { $0.value > $1.value }
            
            if !sortedDays.isEmpty {
                ForEach(sortedDays, id: \.key) { date, distance in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(formatDate(date))
                                .font(.body)
                                .fontWeight(.semibold)
                            Text(String(format: "%.1f km", distance))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if distance >= thresholds.platinum {
                            Image(systemName: "star.fill")
                                .foregroundColor(AchievementTier.platinum.color)
                        } else if distance >= thresholds.gold {
                            Image(systemName: "star.fill")
                                .foregroundColor(AchievementTier.gold.color)
                        } else if distance >= thresholds.silver {
                            Image(systemName: "star.fill")
                                .foregroundColor(AchievementTier.silver.color)
                        } else if distance >= thresholds.bronze {
                            Image(systemName: "star.fill")
                                .foregroundColor(AchievementTier.bronze.color)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.horizontal)
            } else {
                Text("No daily records yet")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
    }
    
    private func getQualifiedLocations(achievement: Achievement) -> [(name: String, distance: Double)] {
        let isCity = achievement.category == .city
        let locationDistances = getLocationDistances(isCity: isCity)

        return locationDistances
            .filter { $0.value >= locationThreshold(for: achievement) }
            .map { (name: $0.key, distance: $0.value) }
            .sorted { $0.distance > $1.distance }
    }

    private func getQualifiedCityLocations(achievement: Achievement) -> [QualifiedCityLocation] {
        let threshold = locationThreshold(for: achievement)
        var cityDistances: [String: Double] = [:]
        var cityCoordinates: [String: CLLocationCoordinate2D] = [:]

        for route in routes {
            guard let firstCoord = route.coordinates.first else { continue }
            let geocodeResult = LocalGeocoder.geocode(latitude: firstCoord.latitude, longitude: firstCoord.longitude)
            let cityName = geocodeResult.city

            guard LocalGeocoder.isSpecificCityName(cityName) else { continue }

            cityDistances[cityName, default: 0] += route.distanceKm
            if cityCoordinates[cityName] == nil {
                cityCoordinates[cityName] = firstCoord
            }
        }

        return cityDistances
            .compactMap { name, distance in
                guard distance >= threshold, let coordinate = cityCoordinates[name] else { return nil }
                return QualifiedCityLocation(name: name, distance: distance, coordinate: coordinate)
            }
            .sorted { $0.distance > $1.distance }
    }

    private func getLocationDistances(isCity: Bool) -> [String: Double] {
        var locationDistances: [String: Double] = [:]

        for route in routes {
            guard let firstCoord = route.coordinates.first else { continue }
            let geocodeResult = LocalGeocoder.geocode(latitude: firstCoord.latitude, longitude: firstCoord.longitude)
            let locationName = isCity ? geocodeResult.city : geocodeResult.country

            if !locationName.isEmpty && locationName != "Unknown" {
                if isCity && !LocalGeocoder.isSpecificCityName(locationName) {
                    continue
                }
                locationDistances[locationName, default: 0] += route.distanceKm
            }
        }

        return locationDistances
    }

    private func locationThreshold(for achievement: Achievement) -> Double {
        if achievement.id.contains("visited") {
            return 1.0
        } else if achievement.id.contains("explored") {
            return 100.0
        } else if achievement.id.contains("mastered") {
            return 1000.0
        }

        return 0.0
    }
    
    private func calculateDailyDistances(runningOnly: Bool = false) -> [String: Double] {
        var dailyDistances: [String: Double] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        for route in routes {
            if runningOnly && route.workoutType != .running {
                continue
            }
            let dateKey = dateFormatter.string(from: route.date)
            dailyDistances[dateKey, default: 0] += route.distanceKm
        }
        
        return dailyDistances
    }
    
    private func formatDate(_ dateString: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dateFormatter.date(from: dateString) {
            dateFormatter.dateStyle = .medium
            return dateFormatter.string(from: date)
        }
        return dateString
    }
    
    // Berlin Stadtteile List View
    private struct BerlinStadtteileListView: View {
        let visitedStadtteile: Set<String>
        let streetSegments: Set<StreetSegment>
        let onShowAllStadtteile: (() -> Void)?
        let dismiss: DismissAction
        
        @State private var allStadtteile: Set<String> = []
        @State private var isLoading = true
        
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                let missingStadtteile = allStadtteile.subtracting(visitedStadtteile)
                
                if !allStadtteile.isEmpty {
                    Button(action: {
                        onShowAllStadtteile?()
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: "map.circle.fill")
                                .font(.title2)
                            VStack(alignment: .leading) {
                                Text("Show Stadtteile Map")
                                    .font(.headline)
                                Text("Green visited, gray not yet visited")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)

                    // Summary
                    VStack(spacing: 8) {
                        Text("\(visitedStadtteile.count)/\(allStadtteile.count)")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(.blue)
                        Text("Stadtteile Visited")
                            .font(.headline)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    
                    // Visited Stadtteile
                    if !visitedStadtteile.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("✅ Visited (\(visitedStadtteile.count))")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            ForEach(Array(visitedStadtteile.sorted()), id: \.self) { stadtteil in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text(stadtteil)
                                        .font(.body)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Missing Stadtteile
                    if !missingStadtteile.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("❌ Not Yet Visited (\(missingStadtteile.count))")
                                .font(.headline)
                                .padding(.horizontal)
                                .padding(.top, 8)
                            
                            ForEach(Array(missingStadtteile.sorted()), id: \.self) { stadtteil in
                                HStack {
                                    Image(systemName: "circle")
                                        .foregroundColor(.gray)
                                    Text(stadtteil)
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .padding(.horizontal)
                        }
                    }
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading Stadtteile...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        Text("No Stadtteil data available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Street data needs to be loaded first")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .task {
                await loadAllStadtteile()
            }
        }
        
        private func loadAllStadtteile() async {
            // Load all Berlin districts to get all streets
            let allDistricts = BerlinDistricts.districts.map { $0.name }
            
            // Get all streets from all districts
            await withCheckedContinuation { continuation in
                BerlinStreets.loadDistrictsInBackground(allDistricts) { loadedStreets in
                    // Extract unique Stadtteile from all streets
                    let stadtteile = Set(loadedStreets.values.flatMap { streets in
                        streets.compactMap { $0.stadtteil }
                    }.filter { !$0.isEmpty && $0 != "Unknown" })
                    
                    Task { @MainActor in
                        allStadtteile = stadtteile
                        isLoading = false
                        print("📍 Loaded \(stadtteile.count) total Stadtteile in Berlin")
                    }
                    
                    continuation.resume()
                }
            }
        }
    }
    
    // Street achievement views live in AchievementsStreetViews.swift.
}

// MARK: - Cumulative Distance Graph
    
struct CumulativeDistanceGraph: View {
    let routes: [Route]
    let achievement: Achievement
    
    var body: some View {
        GeometryReader { geometry in
            let data = calculateCumulativeData()
            let _ = data.last?.cumulative ?? 0
            let thresholds = getThresholds()
            
            // Define margins for axes
            let leftMargin: CGFloat = 50
            let bottomMargin: CGFloat = 40
            let topMargin: CGFloat = 20
            let rightMargin: CGFloat = 80
            
            let graphWidth = geometry.size.width - leftMargin - rightMargin
            let graphHeight = geometry.size.height - topMargin - bottomMargin
            
            ZStack(alignment: .topLeading) {
                // Draw Y axis
                Path { path in
                    path.move(to: CGPoint(x: leftMargin, y: topMargin))
                    path.addLine(to: CGPoint(x: leftMargin, y: topMargin + graphHeight))
                }
                .stroke(Color.gray, lineWidth: 2)
                
                // Draw X axis
                Path { path in
                    path.move(to: CGPoint(x: leftMargin, y: topMargin + graphHeight))
                    path.addLine(to: CGPoint(x: leftMargin + graphWidth, y: topMargin + graphHeight))
                }
                .stroke(Color.gray, lineWidth: 2)
                
                // Calculate max Y value as 10% higher than highest threshold
                let maxYValue = (thresholds.last?.value ?? 100) * 1.1
                
                // Y-axis labels
                let ySteps = 5
                ForEach(0...ySteps, id: \.self) { i in
                    let value = maxYValue * Double(i) / Double(ySteps)
                    let y = topMargin + graphHeight - (CGFloat(i) / CGFloat(ySteps) * graphHeight)
                    
                    Text(String(format: "%.0f", value))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .position(x: leftMargin - 20, y: y)
                }
                
                // X-axis labels (dates)
                if !data.isEmpty {
                    let xSteps = min(4, data.count - 1)
                    ForEach(0...xSteps, id: \.self) { i in
                        let index = i * (data.count - 1) / xSteps
                        let date = data[index].date
                        let x = leftMargin + (CGFloat(i) / CGFloat(xSteps) * graphWidth)
                        
                        Text(formatDate(date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(-45))
                            .position(x: x, y: topMargin + graphHeight + 25)
                    }
                }
                
                // Draw threshold lines (without labels)
                ForEach(thresholds, id: \.value) { threshold in
                    let y = topMargin + graphHeight - (threshold.value / maxYValue * graphHeight)
                    
                    Path { path in
                        path.move(to: CGPoint(x: leftMargin, y: y))
                        path.addLine(to: CGPoint(x: leftMargin + graphWidth, y: y))
                    }
                    .stroke(threshold.color, style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                }
                
                // Draw cumulative distance line
                Path { path in
                    guard !data.isEmpty else { return }
                    
                    let xScale = graphWidth / CGFloat(data.count - 1)
                    let yScale = graphHeight / maxYValue
                    
                    path.move(to: CGPoint(x: leftMargin, y: topMargin + graphHeight - data[0].cumulative * yScale))
                    
                    for (index, point) in data.enumerated() {
                        let x = leftMargin + CGFloat(index) * xScale
                        let y = topMargin + graphHeight - point.cumulative * yScale
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(achievement.currentTier.color, lineWidth: 3)
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yy"
        return formatter.string(from: date)
    }
    
    private func calculateCumulativeData() -> [(date: Date, cumulative: Double)] {
        var cumulative: Double = 0
        return routes.map { route in
            cumulative += route.distanceKm
            return (date: route.date, cumulative: cumulative)
        }
    }
    
    private func getThresholds() -> [(value: Double, name: String, color: Color)] {
        let allThresholds = [
            (value: 500.0, name: "Bronze", color: AchievementTier.bronze.color),
            (value: 1000.0, name: "Silver", color: AchievementTier.silver.color),
            (value: 2500.0, name: "Gold", color: AchievementTier.gold.color),
            (value: 10000.0, name: "Platinum", color: AchievementTier.platinum.color)
        ]
        
        // Include up to current tier + 1
        let currentTierIndex: Int
        switch achievement.currentTier {
        case .none: currentTierIndex = 0
        case .bronze: currentTierIndex = 1
        case .silver: currentTierIndex = 2
        case .gold: currentTierIndex = 3
        case .platinum: currentTierIndex = 4
        }
        
        return Array(allThresholds.prefix(currentTierIndex + 1))
    }
}

// MARK: - Achievements View

struct AchievementsView: View {
    @ObservedObject var achievementsManager: AchievementsManager
    let routes: [Route]
    var onDistrictSelected: ((String, Double, Double) -> Void)? = nil
    var onShowAllDistricts: (() -> Void)? = nil
    var onShowAllStadtteile: (() -> Void)? = nil
    var onLocationSelected: ((String, String) -> Void)? = nil  // (country, city)
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 1120 : .infinity
    }

    private var achievementGridColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 18)]
        }
        return [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header stats - tier breakdown
                    HStack(spacing: horizontalSizeClass == .regular ? 28 : 15) {
                        VStack(spacing: 4) {
                            Text("\(achievementsManager.achievements.filter { $0.currentTier == .bronze }.count)")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(AchievementTier.bronze.color)
                            Text("Bronze")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(spacing: 4) {
                            Text("\(achievementsManager.achievements.filter { $0.currentTier == .silver }.count)")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(AchievementTier.silver.color)
                            Text("Silver")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(spacing: 4) {
                            Text("\(achievementsManager.achievements.filter { $0.currentTier == .gold }.count)")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(AchievementTier.gold.color)
                            Text("Gold")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(spacing: 4) {
                            Text("\(achievementsManager.achievements.filter { $0.currentTier == .platinum }.count)")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(AchievementTier.platinum.color)
                            Text("Platinum")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Divider()
                            .frame(height: 40)
                        
                        VStack(spacing: 4) {
                            Text("\(achievementsManager.achievements.count)")
                                .font(.system(size: 24, weight: .bold))
                            Text("Total")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    MonthlyGoalProgressSection(
                        routes: routes,
                        achievements: achievementsManager.achievements,
                        consolidatedStreets: achievementsManager.consolidatedStreets,
                        streetCoverageByID: achievementsManager.streetCoverageByID
                    )
                    
                    // Achievements grouped by category
                    ForEach(Achievement.AchievementCategory.allCases, id: \.self) { category in
                        let categoryAchievements = achievementsManager.achievements.filter { $0.category == category }
                        if !categoryAchievements.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(category.rawValue)
                                    .font(.title2)
                                    .bold()
                                    .padding(.horizontal)
                                
                                LazyVGrid(columns: achievementGridColumns, spacing: horizontalSizeClass == .regular ? 18 : 12) {
                                    ForEach(categoryAchievements) { achievement in
                                        NavigationLink(destination: AchievementDetailView(achievement: achievement, routes: routes, onDistrictSelected: onDistrictSelected, onShowAllDistricts: onShowAllDistricts, onShowAllStadtteile: onShowAllStadtteile, onLocationSelected: onLocationSelected, visitedBerlinDistricts: achievementsManager.berlinDistrictsVisitedCached, achievementsManager: achievementsManager)) {
                                            AchievementCard(achievement: achievement)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Achievements")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: StreetDebugView(routes: routes)) {
                        Image(systemName: "ant.fill")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            print("🎯 AchievementsView appeared, triggering background achievement check")
            achievementsManager.checkAndUnlockAchievementsInBackground(routes: routes)
        }
        .alert(isPresented: $achievementsManager.showAchievementAlert) {
            Alert(
                title: Text(achievementsManager.achievementMessage?.split(separator: "\n").first.map(String.init) ?? "Achievement"),
                message: Text(achievementsManager.achievementMessage?.split(separator: "\n").dropFirst().joined(separator: "\n") ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

// MARK: - Achievement Card

struct AchievementCard: View {
    let achievement: Achievement
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(achievement.isUnlocked ?
                          LinearGradient(colors: [achievement.currentTier.color, achievement.currentTier.color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                            LinearGradient(colors: [.gray.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)
                
                Image(systemName: achievement.iconName)
                    .font(.system(size: 32))
                    .foregroundColor(achievement.isUnlocked ? .white : .gray)
            }
            
            Text(achievement.title)
                .font(.caption)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 32)
            
            // Show current tier badge
            Group {
                if achievement.isUnlocked {
                    Text(achievement.currentTier.rawValue)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(achievement.currentTier.color)
                        .cornerRadius(4)
                } else {
                    Text(" ")
                        .font(.caption2)
                        .padding(.vertical, 2)
                }
            }
            .frame(height: 18)
            
            Text(achievement.currentDescription)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28)
            
            // Show tier progress indicators
            HStack(spacing: 4) {
                ForEach([AchievementTier.bronze, .silver, .gold, .platinum], id: \.self) { tier in
                    if achievement.tiers[tier] != nil {
                        Circle()
                            .fill(achievement.currentTier.rawValue >= tier.rawValue ? tier.color : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
            }
            
            // Show progress to next tier
            Text(achievement.progressMessage)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .frame(minHeight: 235)
        .background(achievement.isUnlocked ? achievement.currentTier.color.opacity(0.15) : Color.gray.opacity(0.05))
        .cornerRadius(12)
        .opacity(achievement.isUnlocked ? 1.0 : 0.5)
    }
}

// MARK: - Extension for CaseIterable

extension Achievement.AchievementCategory: CaseIterable {
    static var allCases: [Achievement.AchievementCategory] {
        return [.specials, .distance, .country, .city, .daily, .exploration]
    }
}
