import Foundation
import CoreLocation

// MARK: - Local Geocoding System

struct LocalGeocoder {

    // MARK: - Country Boundaries from GeoJSON

    private static var countryPolygons: [CountryPolygon] = []
    private static var cachedWorldMapBoundaries: [CountryBoundary]?
    private static var isLoaded = false
    private static var cityGrid: [String: [CityInfo]] = [:]
    private static var isCityGazetteerLoaded = false
    private static let cityGridCellSize = 2.0

    // Load GeoJSON data once
    private static func loadCountryBoundaries() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let url = Bundle.main.url(forResource: "world-administrative-boundaries", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            print("⚠️ Failed to load world-administrative-boundaries.geojson")
            return
        }

        print("🌍 Loading country boundaries from GeoJSON...")
        var loaded = 0

        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let name = properties["name"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else {
                continue
            }

            // Extract coordinates based on geometry type
            var polygons: [[CLLocationCoordinate2D]] = []

            if type == "Polygon" {
                if let coords = geometry["coordinates"] as? [[[Double]]] {
                    // Polygon has one outer ring
                    for ring in coords {
                        let coordinates = ring.compactMap { coord -> CLLocationCoordinate2D? in
                            guard coord.count >= 2 else { return nil }
                            return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
                        }
                        if !coordinates.isEmpty {
                            polygons.append(coordinates)
                        }
                    }
                }
            } else if type == "MultiPolygon" {
                if let multiCoords = geometry["coordinates"] as? [[[[Double]]]] {
                    // MultiPolygon has multiple polygons
                    for polygonRings in multiCoords {
                        for ring in polygonRings {
                            let coordinates = ring.compactMap { coord -> CLLocationCoordinate2D? in
                                guard coord.count >= 2 else { return nil }
                                return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
                            }
                            if !coordinates.isEmpty {
                                polygons.append(coordinates)
                            }
                        }
                    }
                }
            }

            if !polygons.isEmpty {
                // Calculate bounding box for faster filtering
                let allLats = polygons.flatMap { $0.map { $0.latitude } }
                let allLons = polygons.flatMap { $0.map { $0.longitude } }

                let bounds = BoundingBox(
                    minLat: allLats.min() ?? 0,
                    maxLat: allLats.max() ?? 0,
                    minLon: allLons.min() ?? 0,
                    maxLon: allLons.max() ?? 0
                )

                countryPolygons.append(CountryPolygon(
                    name: name,
                    alpha2Code: properties["iso_3166_1_alpha_2_codes"] as? String,
                    polygons: polygons,
                    bounds: bounds,
                    majorCities: getMajorCities(for: name)
                ))
                loaded += 1
            }
        }

        print("✅ Loaded \(loaded) country boundaries from GeoJSON")
    }

    // MARK: - Supporting Structures

    private struct CountryPolygon {
        let name: String
        let alpha2Code: String?
        let polygons: [[CLLocationCoordinate2D]]
        let bounds: BoundingBox
        let majorCities: [CityInfo]
    }

    private struct BoundingBox {
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double

        func contains(lat: Double, lon: Double) -> Bool {
            return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }
    }

    private struct CityInfo {
        let name: String
        let lat: Double
        let lon: Double
        let countryCode: String?
        let population: Int
        let featureCode: String

        init(name: String, lat: Double, lon: Double, countryCode: String? = nil, population: Int = 0, featureCode: String = "") {
            self.name = name
            self.lat = lat
            self.lon = lon
            self.countryCode = countryCode
            self.population = population
            self.featureCode = featureCode
        }
    }

    // MARK: - Public Interface

    struct GeocodeResult {
        let country: String
        let city: String
        let confidence: Double // 0.0 to 1.0
    }

    struct CountryBoundary {
        let name: String
        let polygons: [[CLLocationCoordinate2D]]
    }

    static func isSpecificCityName(_ city: String) -> Bool {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed != "Unknown"
            && !trimmed.starts(with: "Other ")
            && !trimmed.starts(with: "Rural ")
    }

    static func worldMapBoundaries() -> [CountryBoundary] {
        loadCountryBoundaries()

        if let cachedWorldMapBoundaries {
            return cachedWorldMapBoundaries
        }

        let boundaries = countryPolygons.map { country in
            CountryBoundary(
                name: country.name,
                polygons: country.polygons.map(simplifiedForWorldMap)
            )
        }
        cachedWorldMapBoundaries = boundaries
        return boundaries
    }

    /// Fast offline geocoding using GeoJSON boundaries
    /// Returns country and city for given coordinates
    static func geocode(latitude: Double, longitude: Double) -> GeocodeResult {
        loadCountryBoundaries()

        // Quick bounding box filter first
        let candidateCountries = countryPolygons.filter { country in
            country.bounds.contains(lat: latitude, lon: longitude)
        }

        // Check point-in-polygon for candidates
        var matchedCountry: CountryPolygon?
        for country in candidateCountries {
            for polygon in country.polygons {
                if isPointInPolygon(lat: latitude, lon: longitude, polygon: polygon) {
                    matchedCountry = country
                    break
                }
            }
            if matchedCountry != nil {
                break
            }
        }

        guard let country = matchedCountry else {
            return GeocodeResult(
                country: "Unknown",
                city: "Unknown",
                confidence: 0.0
            )
        }

        let closestCity = findClosestCity(
            lat: latitude,
            lon: longitude,
            countryCode: country.alpha2Code,
            fallbackCities: country.majorCities
        )

        // Assign city based on distance
        let cityName: String
        let confidence: Double

        if closestCity.distance <= 10.0 {
            cityName = closestCity.city
            confidence = 0.95
        } else if closestCity.distance <= 25.0 {
            cityName = closestCity.city
            confidence = 0.80
        } else if closestCity.distance <= 50.0 {
            cityName = getRegionName(country: country.name, closestCity: closestCity.city)
            confidence = 0.70
        } else {
            cityName = "Other \(country.name)"
            confidence = 0.60
        }

        return GeocodeResult(
            country: country.name,
            city: cityName,
            confidence: confidence
        )
    }

    private static func simplifiedForWorldMap(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 160 else { return coordinates }

        let step = max(1, coordinates.count / 140)
        var simplified: [CLLocationCoordinate2D] = []
        simplified.reserveCapacity((coordinates.count / step) + 2)

        for index in stride(from: 0, to: coordinates.count, by: step) {
            simplified.append(coordinates[index])
        }

        if let last = coordinates.last,
           simplified.last?.latitude != last.latitude || simplified.last?.longitude != last.longitude {
            simplified.append(last)
        }

        return simplified
    }

    // MARK: - Point in Polygon Algorithm

    /// Ray casting algorithm for point-in-polygon test
    private static func isPointInPolygon(lat: Double, lon: Double, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let vi = polygon[i]
            let vj = polygon[j]

            if ((vi.longitude > lon) != (vj.longitude > lon)) &&
                (lat < (vj.latitude - vi.latitude) * (lon - vi.longitude) / (vj.longitude - vi.longitude) + vi.latitude) {
                inside = !inside
            }
            j = i
        }

        return inside
    }

    /// Get a region name for locations far from major cities
    private static func getRegionName(country: String, closestCity: String) -> String {
        return "Other \(country)"
    }

    // MARK: - Private Helpers

    private struct CityDistance {
        let city: String
        let distance: Double // in km
    }

    private static func loadCityGazetteer() {
        guard !isCityGazetteerLoaded else { return }
        isCityGazetteerLoaded = true

        guard let url = Bundle.main.url(forResource: "geonames_cities5000", withExtension: "tsv"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            print("⚠️ Failed to load geonames_cities5000.tsv; falling back to built-in major city list")
            return
        }

        var loadedCities = 0
        contents.enumerateLines { line, _ in
            guard !line.hasPrefix("name\t") else { return }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6,
                  let lat = Double(fields[1]),
                  let lon = Double(fields[2]) else {
                return
            }

            let city = CityInfo(
                name: String(fields[0]),
                lat: lat,
                lon: lon,
                countryCode: String(fields[3]).uppercased(),
                population: Int(fields[4]) ?? 0,
                featureCode: String(fields[5])
            )
            cityGrid[gridKey(lat: lat, lon: lon), default: []].append(city)
            loadedCities += 1
        }

        print("🏙️ Loaded \(loadedCities) cities into \(cityGrid.count) spatial cells")
    }

    private static func findClosestCity(lat: Double, lon: Double, countryCode: String?, fallbackCities: [CityInfo]) -> CityDistance {
        loadCityGazetteer()

        if let indexedMatch = findClosestIndexedCity(lat: lat, lon: lon, countryCode: countryCode) {
            return indexedMatch
        }

        return findClosestCity(lat: lat, lon: lon, in: fallbackCities)
    }

    private static func findClosestIndexedCity(lat: Double, lon: Double, countryCode: String?) -> CityDistance? {
        guard !cityGrid.isEmpty else { return nil }

        let normalizedCountryCode = countryCode?.uppercased()
        let latCell = cellIndex(for: lat, offset: 90)
        let lonCell = cellIndex(for: lon, offset: 180)
        var closestCity: CityInfo?
        var minDistance = Double.infinity

        for latOffset in -1...1 {
            for lonOffset in -1...1 {
                let key = "\(latCell + latOffset):\(lonCell + lonOffset)"
                guard let cities = cityGrid[key] else { continue }

                for city in cities {
                    if let normalizedCountryCode, city.countryCode != normalizedCountryCode {
                        continue
                    }

                    let dist = distance(from: (lat, lon), to: (city.lat, city.lon))
                    if dist < minDistance {
                        minDistance = dist
                        closestCity = city
                    }
                }
            }
        }

        guard let closestCity else { return nil }
        return CityDistance(city: closestCity.name, distance: minDistance)
    }

    private static func findClosestCity(lat: Double, lon: Double, in cities: [CityInfo]) -> CityDistance {
        guard !cities.isEmpty else {
            return CityDistance(city: "Unknown", distance: Double.infinity)
        }

        var closest = cities[0]
        var minDistance = distance(from: (lat, lon), to: (closest.lat, closest.lon))

        for city in cities.dropFirst() {
            let dist = distance(from: (lat, lon), to: (city.lat, city.lon))
            if dist < minDistance {
                minDistance = dist
                closest = city
            }
        }

        return CityDistance(city: closest.name, distance: minDistance)
    }

    private static func gridKey(lat: Double, lon: Double) -> String {
        "\(cellIndex(for: lat, offset: 90)):\(cellIndex(for: lon, offset: 180))"
    }

    private static func cellIndex(for value: Double, offset: Double) -> Int {
        Int(floor((value + offset) / cityGridCellSize))
    }

    /// Calculate distance between two coordinates using Haversine formula
    private static func distance(from coord1: (lat: Double, lon: Double), to coord2: (lat: Double, lon: Double)) -> Double {
        let R = 6371.0 // Earth's radius in kilometers

        let lat1Rad = coord1.lat * .pi / 180
        let lat2Rad = coord2.lat * .pi / 180
        let deltaLatRad = (coord2.lat - coord1.lat) * .pi / 180
        let deltaLonRad = (coord2.lon - coord1.lon) * .pi / 180

        let a = sin(deltaLatRad / 2) * sin(deltaLatRad / 2) +
                cos(lat1Rad) * cos(lat2Rad) *
                sin(deltaLonRad / 2) * sin(deltaLonRad / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return R * c
    }

    // MARK: - Major Cities Database

    private static func getMajorCities(for countryName: String) -> [CityInfo] {
        switch countryName {
        case "United States":
            return [
                CityInfo(name: "New York", lat: 40.7128, lon: -74.0060),
                CityInfo(name: "Los Angeles", lat: 34.0522, lon: -118.2437),
                CityInfo(name: "Chicago", lat: 41.8781, lon: -87.6298),
                CityInfo(name: "Houston", lat: 29.7604, lon: -95.3698),
                CityInfo(name: "Phoenix", lat: 33.4484, lon: -112.0740),
                CityInfo(name: "Philadelphia", lat: 39.9526, lon: -75.1652),
                CityInfo(name: "San Antonio", lat: 29.4241, lon: -98.4936),
                CityInfo(name: "San Diego", lat: 32.7157, lon: -117.1611),
                CityInfo(name: "Dallas", lat: 32.7767, lon: -96.7970),
                CityInfo(name: "San Francisco", lat: 37.7749, lon: -122.4194),
                CityInfo(name: "Austin", lat: 30.2672, lon: -97.7431),
                CityInfo(name: "Jacksonville", lat: 30.3322, lon: -81.6557),
                CityInfo(name: "Seattle", lat: 47.6062, lon: -122.3321),
                CityInfo(name: "Denver", lat: 39.7392, lon: -104.9903),
                CityInfo(name: "Boston", lat: 42.3601, lon: -71.0589),
                CityInfo(name: "Nashville", lat: 36.1627, lon: -86.7816),
                CityInfo(name: "Portland", lat: 45.5152, lon: -122.6784),
                CityInfo(name: "Las Vegas", lat: 36.1699, lon: -115.1398),
                CityInfo(name: "Miami", lat: 25.7617, lon: -80.1918)
            ]
        case "Canada":
            return [
                CityInfo(name: "Toronto", lat: 43.6532, lon: -79.3832),
                CityInfo(name: "Montreal", lat: 45.5017, lon: -73.5673),
                CityInfo(name: "Vancouver", lat: 49.2827, lon: -123.1207),
                CityInfo(name: "Calgary", lat: 51.0447, lon: -114.0719),
                CityInfo(name: "Ottawa", lat: 45.4215, lon: -75.6972),
                CityInfo(name: "Edmonton", lat: 53.5461, lon: -113.4938)
            ]
        case "Mexico":
            return [
                CityInfo(name: "Mexico City", lat: 19.4326, lon: -99.1332),
                CityInfo(name: "Guadalajara", lat: 20.6597, lon: -103.3496),
                CityInfo(name: "Monterrey", lat: 25.6866, lon: -100.3161),
                CityInfo(name: "Cancun", lat: 21.1619, lon: -86.8515)
            ]
        case "Germany":
            return [
                CityInfo(name: "Berlin", lat: 52.5200, lon: 13.4050),
                CityInfo(name: "Munich", lat: 48.1351, lon: 11.5820),
                CityInfo(name: "Hamburg", lat: 53.5511, lon: 9.9937),
                CityInfo(name: "Cologne", lat: 50.9375, lon: 6.9603),
                CityInfo(name: "Frankfurt", lat: 50.1109, lon: 8.6821),
                CityInfo(name: "Stuttgart", lat: 48.7758, lon: 9.1829),
                CityInfo(name: "Dusseldorf", lat: 51.2277, lon: 6.7735),
                CityInfo(name: "Leipzig", lat: 51.3397, lon: 12.3731)
            ]
        case "France":
            return [
                CityInfo(name: "Paris", lat: 48.8566, lon: 2.3522),
                CityInfo(name: "Marseille", lat: 43.2965, lon: 5.3698),
                CityInfo(name: "Lyon", lat: 45.7640, lon: 4.8357),
                CityInfo(name: "Toulouse", lat: 43.6047, lon: 1.4442),
                CityInfo(name: "Nice", lat: 43.7102, lon: 7.2620),
                CityInfo(name: "Bordeaux", lat: 44.8378, lon: -0.5792)
            ]
        case "United Kingdom":
            return [
                CityInfo(name: "London", lat: 51.5074, lon: -0.1278),
                CityInfo(name: "Birmingham", lat: 52.4862, lon: -1.8904),
                CityInfo(name: "Glasgow", lat: 55.8642, lon: -4.2518),
                CityInfo(name: "Liverpool", lat: 53.4084, lon: -2.9916),
                CityInfo(name: "Manchester", lat: 53.4808, lon: -2.2426),
                CityInfo(name: "Edinburgh", lat: 55.9533, lon: -3.1883)
            ]
        case "Spain":
            return [
                CityInfo(name: "Madrid", lat: 40.4168, lon: -3.7038),
                CityInfo(name: "Barcelona", lat: 41.3851, lon: 2.1734),
                CityInfo(name: "Valencia", lat: 39.4699, lon: -0.3763),
                CityInfo(name: "Seville", lat: 37.3891, lon: -5.9845),
                CityInfo(name: "Bilbao", lat: 43.2627, lon: -2.9253)
            ]
        case "Italy":
            return [
                CityInfo(name: "Rome", lat: 41.9028, lon: 12.4964),
                CityInfo(name: "Milan", lat: 45.4642, lon: 9.1900),
                CityInfo(name: "Naples", lat: 40.8518, lon: 14.2681),
                CityInfo(name: "Turin", lat: 45.0703, lon: 7.6869),
                CityInfo(name: "Florence", lat: 43.7696, lon: 11.2558)
            ]
        case "Netherlands":
            return [
                CityInfo(name: "Amsterdam", lat: 52.3676, lon: 4.9041),
                CityInfo(name: "Rotterdam", lat: 51.9244, lon: 4.4777),
                CityInfo(name: "The Hague", lat: 52.0705, lon: 4.3007),
                CityInfo(name: "Utrecht", lat: 52.0907, lon: 5.1214)
            ]
        case "Switzerland":
            return [
                CityInfo(name: "Zurich", lat: 47.3769, lon: 8.5417),
                CityInfo(name: "Geneva", lat: 46.2044, lon: 6.1432),
                CityInfo(name: "Basel", lat: 47.5596, lon: 7.5886),
                CityInfo(name: "Bern", lat: 46.9481, lon: 7.4474)
            ]
        case "Austria":
            return [
                CityInfo(name: "Vienna", lat: 48.2082, lon: 16.3738),
                CityInfo(name: "Graz", lat: 47.0707, lon: 15.4395),
                CityInfo(name: "Salzburg", lat: 47.8095, lon: 13.0550),
                CityInfo(name: "Innsbruck", lat: 47.2692, lon: 11.4041)
            ]
        case "Belgium":
            return [
                CityInfo(name: "Brussels", lat: 50.8503, lon: 4.3517),
                CityInfo(name: "Antwerp", lat: 51.2194, lon: 4.4025),
                CityInfo(name: "Ghent", lat: 51.0543, lon: 3.7174)
            ]
        case "Poland":
            return [
                CityInfo(name: "Warsaw", lat: 52.2297, lon: 21.0122),
                CityInfo(name: "Krakow", lat: 50.0647, lon: 19.9450),
                CityInfo(name: "Gdansk", lat: 54.3520, lon: 18.6466)
            ]
        case "Japan":
            return [
                CityInfo(name: "Tokyo", lat: 35.6762, lon: 139.6503),
                CityInfo(name: "Osaka", lat: 34.6937, lon: 135.5023),
                CityInfo(name: "Kyoto", lat: 35.0116, lon: 135.7681)
            ]
        case "Australia":
            return [
                CityInfo(name: "Sydney", lat: -33.8688, lon: 151.2093),
                CityInfo(name: "Melbourne", lat: -37.8136, lon: 144.9631),
                CityInfo(name: "Brisbane", lat: -27.4698, lon: 153.0251),
                CityInfo(name: "Perth", lat: -31.9505, lon: 115.8605)
            ]
        case "Brazil":
            return [
                CityInfo(name: "Sao Paulo", lat: -23.5558, lon: -46.6396),
                CityInfo(name: "Rio de Janeiro", lat: -22.9068, lon: -43.1729),
                CityInfo(name: "Brasilia", lat: -15.8267, lon: -47.9218)
            ]
        default:
            return []
        }
    }
}
