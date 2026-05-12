import SwiftUI
import CoreLocation

struct StatsView: View {
    var routes: [Route]
    var onLocationSelected: ((String, String) -> Void)? // (country, city) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var totalKm: Double = 0
    @State private var countryTotals: [(String, Double)] = []
    @State private var cityTotals: [(String, Double)] = []
    @State private var loading = true
    @State private var routeTotal = 0
    @State private var processedRoutes = 0
    @State private var uniqueCoords = 0
    @State private var geocoded = 0
    @State private var heuristicallyClassified = 0
    @State private var showAllCountries = false
    @State private var showAllCities = false
    @State private var paceBins: [StatsFrequencyBin] = []
    @State private var distanceBins: [StatsFrequencyBin] = []
    @State private var dailyDistanceWeeks: [[DailyDistanceCell?]] = []
    @State private var maxDailyDistance: Double = 0

    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 760 : .infinity
    }

    var body: some View {
        NavigationView {
            ScrollView {
                statsContent
            }
            .navigationTitle("Stats")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: computeStats)
        .onChange(of: routes.count) { _ in
            computeStats()
        }
    }

    private var statsContent: some View {
        LazyVStack(spacing: 16) {
            if loading {
                loadingCard
            } else if totalKm == 0 {
                emptyStateCard
            } else {
                overviewCard

                if !paceBins.isEmpty {
                    frequencyCard(
                        title: "Pace Frequency",
                        subtitle: "Minutes per kilometer across workouts",
                        icon: "speedometer",
                        color: .blue,
                        bins: paceBins
                    )
                }

                if !distanceBins.isEmpty {
                    frequencyCard(
                        title: "Distance Frequency",
                        subtitle: "Workout distance buckets",
                        icon: "point.topleft.down.curvedto.point.bottomright.up",
                        color: .green,
                        bins: distanceBins
                    )
                }

                if !dailyDistanceWeeks.isEmpty {
                    dailyDistanceGridCard
                }
                
                if !countryTotals.isEmpty {
                    countriesCard
                }
                
                if !cityTotals.isEmpty {
                    citiesCard
                }
            }
        }
        .padding()
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
    }
    
    private var loadingCard: some View {
        VStack(spacing: 12) {
            let progress = routeTotal > 0 ? Double(processedRoutes) / Double(routeTotal) : 0.0
            let percentage = Int(progress * 100)
            
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
                Text("Analyzing Routes")
                    .font(.headline)
                Spacer()
            }
            
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
            
            Text("\(percentage)% complete")
                .font(.caption)
                    .foregroundColor(.secondary)

                if !countryTotals.isEmpty || !cityTotals.isEmpty {
                    Text("Showing partial results…")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private func frequencyCard(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        bins: [StatsFrequencyBin]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            let maxCount = max(bins.map(\.count).max() ?? 1, 1)
            VStack(spacing: 10) {
                ForEach(bins) { bin in
                    HStack(spacing: 10) {
                        Text(bin.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color.opacity(0.12))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color.opacity(0.72))
                                    .frame(width: proxy.size.width * CGFloat(Double(bin.count) / Double(maxCount)))
                            }
                        }
                        .frame(height: 16)

                        Text("\(bin.count)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private var dailyDistanceGridCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.mint)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Distance")
                        .font(.headline)
                    Text("Trailing 52 weeks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(String(format: "Max %.1f km", maxDailyDistance))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(Array(dailyDistanceWeeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: 4) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(dailyDistanceColor(for: cell?.distanceKm ?? 0))
                                    .frame(width: 12, height: 12)
                                    .accessibilityLabel(dailyDistanceAccessibilityLabel(for: cell))
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 6) {
                Text("Less")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(dailyDistanceLegendColor(level: level))
                        .frame(width: 12, height: 12)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    private var emptyStateCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text("Ready to Explore!")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Start running to see your stats here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.green)
                    .font(.title2)
                Text("Running Summary")
                    .font(.headline)
                Spacer()
            }
            
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(totalKm))")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                    Text("Total KM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(routes.count)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                    Text("Workouts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    private var countriesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(.purple)
                    .font(.title2)
                Text("Countries")
                    .font(.headline)
                Spacer()
                Text("\(countryTotals.filter { $0.1 > 0 }.count)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.purple)
            }
            
            let displayedCountries = showAllCountries ? countryTotals : Array(countryTotals.prefix(min(3, countryTotals.count)))
            
            ForEach(Array(displayedCountries.enumerated()), id: \.offset) { index, entry in
                if entry.1 > 0 {
                    Button(action: {
                        onLocationSelected?(entry.0, "")
                        dismiss()
                    }) {
                        HStack {
                            Text(countryFlag(for: entry.0))
                                .font(.title3)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.0)
                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text("\(Int(entry.1)) km")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text("#\(index + 1)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.purple)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.purple.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .padding(.vertical, 4)
                        .foregroundColor(.primary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            
                if countryTotals.count > 3 {
                Button(action: { showAllCountries.toggle() }) {
                    HStack {
                        Text(showAllCountries ? "Show less" : "Show all \(countryTotals.count) countries")
                        Image(systemName: showAllCountries ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .foregroundColor(.purple)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    private var citiesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "building.2")
                    .foregroundColor(.orange)
                    .font(.title2)
                Text("Cities")
                    .font(.headline)
                Spacer()
                Text("\(cityTotals.filter { $0.1 > 0 }.count)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
            }
            
            let displayedCities = showAllCities ? cityTotals : Array(cityTotals.prefix(min(3, cityTotals.count)))
            
            ForEach(Array(displayedCities.enumerated()), id: \.offset) { index, entry in
                if entry.1 > 0 {
                    Button(action: {
                        onLocationSelected?("", entry.0)
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: "location.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.0)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text("\(Int(entry.1)) km")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text("#\(index + 1)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .padding(.vertical, 4)
                        .foregroundColor(.primary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            
                if cityTotals.count > 3 {
                Button(action: { showAllCities.toggle() }) {
                    HStack {
                        Text(showAllCities ? "Show less" : "Show all \(cityTotals.count) cities")
                        Image(systemName: showAllCities ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .foregroundColor(.orange)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    private func countryFlag(for country: String) -> String {
        let flagMap: [String: String] = [
            "United States": "🇺🇸",
            "Canada": "🇨🇦",
            "Mexico": "🇲🇽",
            "United Kingdom": "🇬🇧",
            "Germany": "🇩🇪",
            "France": "🇫🇷",
            "Italy": "🇮🇹",
            "Spain": "🇪🇸",
            "Netherlands": "🇳🇱",
            "Belgium": "🇧🇪",
            "Switzerland": "🇨🇭",
            "Austria": "🇦🇹",
            "Portugal": "🇵🇹",
            "Denmark": "🇩🇰",
            "Sweden": "🇸🇪",
            "Norway": "🇳🇴",
            "Finland": "🇫🇮",
            "Poland": "🇵🇱",
            "Czech Republic": "🇨🇿",
            "Hungary": "🇭🇺",
            "Greece": "🇬🇷",
            "Turkey": "🇹🇷",
            "Russia": "🇷🇺",
            "Japan": "🇯🇵",
            "China": "🇨🇳",
            "South Korea": "🇰🇷",
            "Australia": "🇦🇺",
            "New Zealand": "🇳🇿",
            "Brazil": "🇧🇷",
            "Argentina": "🇦🇷",
            "Chile": "🇨🇱",
            "Colombia": "🇨🇴",
            "Peru": "🇵🇪",
            "India": "🇮🇳",
            "Thailand": "🇹🇭",
            "Singapore": "🇸🇬",
            "Malaysia": "🇲🇾",
            "Indonesia": "🇮🇩",
            "Philippines": "🇵🇭",
            "Vietnam": "🇻🇳",
            "South Africa": "🇿🇦",
            "Egypt": "🇪🇬",
            "Morocco": "🇲🇦",
            "Israel": "🇮🇱",
            "UAE": "🇦🇪",
            "Saudi Arabia": "🇸🇦"
        ]
        return flagMap[country] ?? "🌍"
    }

    private func computeStats() {
        print("📊 Starting computeStats with \(routes.count) routes")
        // Validate routes array first
        guard !routes.isEmpty else {
            print("⚠️ Empty routes array")
            loading = false
            return
        }
        let routesArray = routes
        print("📊 Processing \(routesArray.count) routes for stats")
        
        routeTotal = routesArray.count
        processedRoutes = 0
        uniqueCoords = 0
        geocoded = 0
        heuristicallyClassified = 0

        loading = true
        computeRouteCharts(from: routesArray)
        
        // Safely calculate total km with error handling
        totalKm = routesArray.compactMap { route in
            guard route.coordinates.count > 1 else {
                print("⚠️ Found route with insufficient coordinates: \(route.id) (count: \(route.coordinates.count))")
                return nil
            }
            // Safely access distanceKm with additional protection
            let distance = route.distanceKm
            guard distance.isFinite && distance >= 0 else {
                print("⚠️ Invalid distance calculated for route: \(route.id) (distance: \(distance))")
                return nil
            }
            return distance
        }.reduce(0, +)

        // Use fast local geocoding with fallback to network geocoding
        let serialQueue = DispatchQueue(label: "stats.processing", qos: .userInitiated)
        
        // Load existing caches and clean them up
        var coordCache: [String: String] = [:]
        var cityCache: [String: String] = [:]
        
        // Safely load cache with error handling
        if let rawCoordCache = UserDefaults.standard.object(forKey: "coordCountryCache") {
            if let validCache = rawCoordCache as? [String: String] {
                coordCache = validCache
            } else {
                print("⚠️ Invalid coordCountryCache type: \(type(of: rawCoordCache)), clearing")
                UserDefaults.standard.removeObject(forKey: "coordCountryCache")
            }
        }
        
        if let rawCityCache = UserDefaults.standard.object(forKey: "coordCityCache") {
            if let validCache = rawCityCache as? [String: String] {
                cityCache = validCache
            } else {
                print("⚠️ Invalid coordCityCache type: \(type(of: rawCityCache)), clearing")
                UserDefaults.standard.removeObject(forKey: "coordCityCache")
            }
        }
        
        // Clean up old cached data with inconsistent country names
        coordCache = cleanupCountryCache(coordCache)
        cityCache = cleanupCityCache(cityCache, coordCache: coordCache)
        
        // Process all routes using fast local geocoding
        serialQueue.async {
            let result = self.processAllRoutesWithLocalGeocoding(
                routes: routesArray, 
                coordCache: coordCache, 
                cityCache: cityCache
            )
            
            DispatchQueue.main.async {
                // Save updated caches
                UserDefaults.standard.set(result.coordCache, forKey: "coordCountryCache")
                UserDefaults.standard.set(result.cityCache, forKey: "coordCityCache")
                
                var countryDict = result.countryDict
                let knownKm = countryDict.values.reduce(0, +)
                let unknownKm = self.totalKm - knownKm
                if unknownKm > 0 {
                    countryDict["(Unknown)"] = unknownKm
                }
                
                // Safely validate dictionaries before sorting
                let safeCountryDict = self.validateDictionary(countryDict, name: "countryDict")
                let safeCityDict = self.validateDictionary(result.cityDict, name: "cityDict")
                
                // Safely sort dictionaries with validation
                self.countryTotals = self.safeSortDictionary(safeCountryDict)
                self.cityTotals = self.safeSortDictionary(safeCityDict)
                self.loading = false
                
            }
        }
    }

    private func computeRouteCharts(from routes: [Route]) {
        let validRoutes = routes.filter { route in
            route.coordinates.count > 1 &&
            route.distanceKm.isFinite &&
            route.distanceKm > 0
        }

        paceBins = makeFrequencyBins(
            values: validRoutes.compactMap { route in
                guard route.durationSec > 0 else { return nil }
                return route.durationSec / 60.0 / route.distanceKm
            },
            ranges: [
                (0, 4, "<4"),
                (4, 6, "4-6"),
                (6, 8, "6-8"),
                (8, 10, "8-10"),
                (10, 12, "10-12"),
                (12, 14, "12-14"),
                (14, 16, "14-16"),
                (16, .infinity, "16+")
            ]
        )

        distanceBins = makeFrequencyBins(
            values: validRoutes.map(\.distanceKm),
            ranges: [
                (0, 0.5, "<0.5"),
                (0.5, 1.0, "0.5-.99"),
                (1.0, 1.5, "1-1.49"),
                (1.5, 2.0, "1.5-1.99"),
                (2.0, 2.5, "2-2.49"),
                (2.5, 3.0, "2.5-2.99"),
                (3.0, 4.0, "3-3.99"),
                (4.0, 5.0, "4-4.99"),
                (5.0, 7.0, "5-6.99"),
                (7.0, 9.0, "7-8.99"),
                (9.0, 12.0, "9-11.99"),
                (12.0, 18.0, "12-17.99"),
                (18.0, .infinity, ">18")
            ]
        )

        let dailyTotals = Dictionary(grouping: validRoutes) { route in
            Calendar.current.startOfDay(for: route.date)
        }
        .mapValues { routes in
            routes.map(\.distanceKm).reduce(0, +)
        }

        dailyDistanceWeeks = makeDailyDistanceWeeks(dailyTotals: dailyTotals)
        maxDailyDistance = dailyDistanceWeeks
            .flatMap { $0 }
            .compactMap { $0?.distanceKm }
            .max() ?? 0
    }

    private func makeFrequencyBins(
        values: [Double],
        ranges: [(lower: Double, upper: Double, label: String)]
    ) -> [StatsFrequencyBin] {
        guard !values.isEmpty else { return [] }

        return ranges.map { range in
            StatsFrequencyBin(
                label: range.label,
                count: values.filter { value in
                    value >= range.lower && value < range.upper
                }.count
            )
        }
    }

    private func makeDailyDistanceWeeks(dailyTotals: [Date: Double]) -> [[DailyDistanceCell?]] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2

        let today = calendar.startOfDay(for: Date())
        let endWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let startWeek = calendar.date(byAdding: .day, value: -51 * 7, to: endWeek) ?? endWeek

        var weeks: [[DailyDistanceCell?]] = []
        var weekStart = startWeek

        while weekStart <= endWeek {
            var week: [DailyDistanceCell?] = []
            for dayOffset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else {
                    week.append(nil)
                    continue
                }

                if date > today {
                    week.append(nil)
                } else {
                    week.append(DailyDistanceCell(
                        date: date,
                        distanceKm: dailyTotals[date, default: 0]
                    ))
                }
            }
            weeks.append(week)

            guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = nextWeek
        }

        return weeks
    }

    private func dailyDistanceColor(for distance: Double) -> Color {
        guard distance > 0 else {
            return Color(.systemGray5)
        }
        let level = dailyDistanceLevel(for: distance)
        return dailyDistanceLegendColor(level: level)
    }

    private func dailyDistanceLegendColor(level: Int) -> Color {
        switch level {
        case 0:
            return Color(.systemGray5)
        case 1:
            return Color.green.opacity(0.28)
        case 2:
            return Color.green.opacity(0.48)
        case 3:
            return Color.green.opacity(0.68)
        default:
            return Color.green.opacity(0.9)
        }
    }

    private func dailyDistanceLevel(for distance: Double) -> Int {
        guard maxDailyDistance > 0, distance > 0 else { return 0 }
        let ratio = distance / maxDailyDistance
        switch ratio {
        case 0..<0.25:
            return 1
        case 0.25..<0.5:
            return 2
        case 0.5..<0.75:
            return 3
        default:
            return 4
        }
    }

    private func dailyDistanceAccessibilityLabel(for cell: DailyDistanceCell?) -> String {
        guard let cell else { return "No day" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "\(formatter.string(from: cell.date)): \(String(format: "%.1f", cell.distanceKm)) km"
    }
    
    private func cleanupCountryCache(_ cache: [String: String]) -> [String: String] {
        var cleanedCache: [String: String] = [:]
        
        for (key, country) in cache {
            let normalizedCountry = normalizeCountryName(country)
            cleanedCache[key] = normalizedCountry
        }
        
        return cleanedCache
    }
    
    private func cleanupCityCache(_ cityCache: [String: String], coordCache: [String: String]) -> [String: String] {
        var cleanedCache: [String: String] = [:]
        
        for (key, city) in cityCache {
            // Remove non-city fallback labels and orphaned city cache entries.
            if coordCache[key] != nil, LocalGeocoder.isSpecificCityName(city) {
                cleanedCache[key] = city
            } else {
                continue
            }
        }
        
        return cleanedCache
    }
    
    private struct ProcessingResult {
        var coordCache: [String: String]
        var cityCache: [String: String]
        var countryDict: [String: Double]
        var cityDict: [String: Double]
        var visitedCount: Int
        var localGeocodedCount: Int
        var networkGeocodedCount: Int
    }
    
    private func processAllRoutesWithLocalGeocoding(
        routes: [Route],
        coordCache: [String: String],
        cityCache: [String: String]
    ) -> ProcessingResult {
        print("🔄 Starting processAllRoutesWithLocalGeocoding with \(routes.count) routes")
        
        var mutableCoordCache = coordCache
        var mutableCityCache = cityCache
        var countryDict: [String: Double] = [:]
        var cityDict: [String: Double] = [:]
        var visited = Set<String>()
        var localGeocodedCount = 0
        let networkGeocodedCount = 0

        for (index, route) in routes.enumerated() {
            // Add safety check for route validity
            if index == 0 {
                print("🔄 Processing first route: \(route.id) with \(route.coordinates.count) coordinates")
            }
            
            // Update progress every 50 routes for better performance
            if index % 50 == 0 {
                DispatchQueue.main.async {
                    self.processedRoutes = index
                }
            }
            
            // Validate route before processing (skip invalid routes silently)
            guard !route.coordinates.isEmpty,
                  route.coordinates.allSatisfy({ coord in
                      coord.latitude.isFinite && coord.longitude.isFinite &&
                      coord.latitude >= -90 && coord.latitude <= 90 &&
                      coord.longitude >= -180 && coord.longitude <= 180
                  }) else {
                continue
            }

            // Process multiple points along the route for better accuracy
            let routeSegments = self.analyzeRouteGeography(route: route, 
                                                          coordCache: mutableCoordCache, 
                                                          cityCache: mutableCityCache)
            
            // Update caches with new geocoded locations
            for segment in routeSegments {
                if segment.isNewLocation {
                    mutableCoordCache[segment.key] = segment.country
                    mutableCityCache[segment.key] = segment.city
                    localGeocodedCount += 1
                }
                
                // Add distance to country/city (distributed across route)
                countryDict[segment.country, default: 0] += segment.distance
                if LocalGeocoder.isSpecificCityName(segment.city) {
                    cityDict[segment.city, default: 0] += segment.distance
                }
                
                // Track unique coordinates
                if !visited.contains(segment.key) {
                    visited.insert(segment.key)
                }
            }
            
            // Capture the count safely before dispatching
            let visitedCount = visited.count
            DispatchQueue.main.async {
                self.uniqueCoords = visitedCount
                self.geocoded = Int(localGeocodedCount)
            }
            
            // Update UI with current progress (less frequently for performance)
            if index % 100 == 0 {
                DispatchQueue.main.async {
                    // Safely validate dictionaries before sorting
                    let safeCountryDict = self.validateDictionary(countryDict, name: "countryDict_progress")
                    let safeCityDict = self.validateDictionary(cityDict, name: "cityDict_progress")
                    
                    self.countryTotals = self.safeSortDictionary(safeCountryDict)
                    self.cityTotals = self.safeSortDictionary(safeCityDict)
                }
            }
        }
        
        // Final progress update
        DispatchQueue.main.async {
            self.processedRoutes = routes.count
        }
        
        return ProcessingResult(
            coordCache: mutableCoordCache,
            cityCache: mutableCityCache,
            countryDict: countryDict,
            cityDict: cityDict,
            visitedCount: visited.count,
            localGeocodedCount: localGeocodedCount,
            networkGeocodedCount: networkGeocodedCount
        )
    }
    
    private struct RouteSegment {
        let key: String
        let country: String
        let city: String
        let distance: Double
        let isNewLocation: Bool
    }
    
    private func analyzeRouteGeography(route: Route, 
                                     coordCache: [String: String], 
                                     cityCache: [String: String]) -> [RouteSegment] {
        guard !route.coordinates.isEmpty else { return [] }
        
        var segments: [RouteSegment] = []
        
        // Sample points along the route (every ~1km or key points)
        let samplePoints = sampleRoutePoints(coordinates: route.coordinates, maxSamples: 10)
        guard !samplePoints.isEmpty else { return [] }
        
        // Safely calculate segment distance
        let totalDistance = route.distanceKm
        guard totalDistance.isFinite && totalDistance >= 0 else {
            print("⚠️ Invalid total distance for route: \(route.id) (distance: \(totalDistance))")
            return []
        }
        let segmentDistance = totalDistance / Double(samplePoints.count)
        
        for coordinate in samplePoints {
            let lat = Double(round(1000 * coordinate.latitude) / 1000)
            let lon = Double(round(1000 * coordinate.longitude) / 1000)
            let key = "\(lat),\(lon)"

            var country: String
            var city: String
            var isNewLocation = false
            
            // Check cache first
            if let cachedCountry = coordCache[key] {
                country = cachedCountry
                city = cityCache[key] ?? "Unknown"
            } else {
                // Use local geocoding for new location
                let geocodeResult = LocalGeocoder.geocode(latitude: coordinate.latitude, 
                                                        longitude: coordinate.longitude)
                country = geocodeResult.country
                city = geocodeResult.city
                isNewLocation = true
                
                // Normalize country names to avoid duplicates
                country = normalizeCountryName(country)
                
                // Validate results
                if country.isEmpty || city.isEmpty {
                    print("⚠️ Empty geocoding result for coordinate: \(coordinate)")
                    country = country.isEmpty ? "Unknown" : country
                    city = city.isEmpty ? "Unknown" : city
                }
            }
            
            segments.append(RouteSegment(
                key: key,
                country: country,
                city: city,
                distance: segmentDistance,
                isNewLocation: isNewLocation
            ))
        }
        
        return segments
    }
    
    private func sampleRoutePoints(coordinates: [CLLocationCoordinate2D], maxSamples: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxSamples else { return coordinates }
        
        var sampledPoints: [CLLocationCoordinate2D] = []
        let interval = max(1, coordinates.count / maxSamples) // Ensure interval is at least 1
        
        for i in stride(from: 0, to: coordinates.count, by: interval) {
            sampledPoints.append(coordinates[i])
        }
        
        // Always include the last point
        if let last = coordinates.last {
            if sampledPoints.isEmpty {
                sampledPoints.append(last)
            } else if let lastPoint = sampledPoints.last {
                // Use safe comparison for coordinates
                let latDiff = abs(lastPoint.latitude - last.latitude)
                let lonDiff = abs(lastPoint.longitude - last.longitude)
                if latDiff > 0.0001 || lonDiff > 0.0001 { // Different enough to include
                    sampledPoints.append(last)
                }
            }
        }
        
        return sampledPoints
    }
    
    private func normalizeCountryName(_ country: String) -> String {
        // Fix common country name variations to avoid duplicates
        switch country.lowercased() {
        case "usa", "us", "united states of america":
            return "United States"
        case "uk", "britain", "great britain", "england", "scotland", "wales":
            return "United Kingdom"
        case "deutschland":
            return "Germany"
        case "nederland", "holland":
            return "Netherlands"
        default:
            return country
        }
    }
    
    private func validateDictionary(_ dict: [String: Double], name: String) -> [String: Double] {
        var validDict: [String: Double] = [:]
        
        // Check if the dictionary is actually enumerable
        let mirror = Mirror(reflecting: dict)
        print("📊 Validating \(name): type=\(type(of: dict)), children=\(mirror.children.count)")
        
        // Try to safely access the dictionary
        if mirror.displayStyle == .dictionary {
            // It looks like a dictionary, try to enumerate safely
            var entryCount = 0
            for (key, value) in dict {
                entryCount += 1
                if value.isFinite && value >= 0 {
                    validDict[key] = value
                } else {
                    print("⚠️ Invalid entry in \(name): key=\(type(of: key)), value=\(type(of: value))")
                }
                
                // Safety limit to prevent infinite loops
                if entryCount > 10000 {
                    print("⚠️ Too many entries in \(name), truncating")
                    break
                }
            }
            print("📊 \(name) validation complete: \(entryCount) entries processed, \(validDict.count) valid")
        } else {
            print("⚠️ \(name) is not a proper dictionary: \(String(describing: mirror.displayStyle))")
        }
        
        return validDict
    }
    
    private func safeSortDictionary(_ dict: [String: Double]) -> [(String, Double)] {
        // Safely validate and convert the dictionary
        var validEntries: [(String, Double)] = []
        
        // Safely iterate and validate each entry
        for (key, value) in dict {
            // Validate the value is finite and non-negative
            guard value.isFinite && value >= 0 else {
                print("⚠️ Invalid value for key '\(key)': \(value)")
                continue
            }
            
            validEntries.append((key, value))
        }
        
        // Sort the valid entries
        return validEntries.sorted { $0.1 > $1.1 }
    }
    
    // Keep the old function for fallback if needed
    private func processAllRoutes(routes: [Route],
                                 coordCache: [String: String],
                                 cityCache: [String: String],
                                 geocoder: CLGeocoder) -> ProcessingResult {
        
        var mutableCoordCache = coordCache
        var mutableCityCache = cityCache
        var countryDict: [String: Double] = [:]
        var cityDict: [String: Double] = [:]
        var visited = Set<String>()
        var geocodedCount = 0
        
        let group = DispatchGroup()
        let lockQueue = DispatchQueue(label: "cache.lock", qos: .userInitiated)

        for route in routes {
            DispatchQueue.main.async {
                self.processedRoutes += 1
            }

            guard let first = route.coordinates.first else { continue }

            let lat = Double(round(1000 * first.latitude) / 1000)
            let lon = Double(round(1000 * first.longitude) / 1000)
            let key = "\(lat),\(lon)"

            // Check cache first
            if let cachedCountry = mutableCoordCache[key] {
                lockQueue.sync {
                    countryDict[cachedCountry, default: 0] += route.distanceKm
                    if let cachedCity = mutableCityCache[key], LocalGeocoder.isSpecificCityName(cachedCity) {
                        cityDict[cachedCity, default: 0] += route.distanceKm
                    }
                }
                continue
            }

            // Track unique coordinates
            if !visited.contains(key) {
                visited.insert(key)
                // Capture the count safely before dispatching
                let visitedCount = visited.count
                DispatchQueue.main.async {
                    self.uniqueCoords = visitedCount
                }
            }

            // Limit concurrent geocoding requests
            if geocodedCount >= 50 { continue }
            geocodedCount += 1

            group.enter()
            let loc = CLLocation(latitude: first.latitude, longitude: first.longitude)
            
            geocoder.reverseGeocodeLocation(loc) { placemarks, error in
                defer { group.leave() }
                
                if let error = error {
                    print("Geocoding error for \(lat), \(lon): \(error.localizedDescription)")
                    return
                }
                
                guard let placemark = placemarks?.first else {
                    print("No placemark found for \(lat), \(lon)")
                    return
                }
                
                let country = placemark.country ?? 
                             placemark.administrativeArea ?? 
                             placemark.isoCountryCode?.uppercased() ?? 
                             "Unknown"
                
                let city = placemark.locality ?? 
                          placemark.subAdministrativeArea ?? 
                          placemark.administrativeArea ?? 
                          "Unknown"
                
                // Thread-safe cache and dict updates
                lockQueue.sync {
                    mutableCoordCache[key] = country
                    mutableCityCache[key] = city
                        countryDict[country, default: 0] += route.distanceKm
                        if LocalGeocoder.isSpecificCityName(city) {
                            cityDict[city, default: 0] += route.distanceKm
                        }
                }
                
                DispatchQueue.main.async {
                    self.geocoded += 1
                    // Update UI with current progress
                    self.countryTotals = countryDict.sorted { $0.value > $1.value }
                    self.cityTotals = cityDict.sorted { $0.value > $1.value }
                }
            }
        }
        
        // Wait for all geocoding to complete
        group.wait()
        
        return ProcessingResult(
            coordCache: mutableCoordCache,
            cityCache: mutableCityCache,
            countryDict: countryDict,
            cityDict: cityDict,
            visitedCount: visited.count,
            localGeocodedCount: 0,
            networkGeocodedCount: geocodedCount
        )
    }

}

private struct StatsFrequencyBin: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
}

private struct DailyDistanceCell: Identifiable {
    let id = UUID()
    let date: Date
    let distanceKm: Double
}

// MARK: - Array Extension for Batching
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

struct StatsView_Previews: PreviewProvider {
    static var previews: some View {
        StatsView(routes: [], onLocationSelected: nil)
    }
}
