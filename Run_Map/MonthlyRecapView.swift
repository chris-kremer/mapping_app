import SwiftUI
import MapKit
import HealthKit
import UserNotifications

struct MonthlyGoals: Codable, Equatable {
    var distanceKm: Double?
    var newStreetCount: Int?
    var newDistrictCount: Int?

    var hasAnyGoal: Bool {
        distanceKm != nil || newStreetCount != nil || newDistrictCount != nil
    }
}

enum MonthlyGoalStore {
    private static let key = "monthlyGoals.v1"

    static func load() -> MonthlyGoals {
        guard let data = UserDefaults.standard.data(forKey: key),
              let goals = try? JSONDecoder().decode(MonthlyGoals.self, from: data) else {
            return MonthlyGoals()
        }
        return goals
    }

    static func save(_ goals: MonthlyGoals) {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum MonthlyRecapNotificationScheduler {
    static func configure() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("⚠️ Monthly recap notification permission failed: \(error.localizedDescription)")
            }
            guard granted else { return }
            scheduleMonthlyRecapNotification()
        }
    }

    private static func scheduleMonthlyRecapNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Monthly Recap Ready"
        content.body = "Your Run Map monthly report is ready."
        content.sound = .default

        var components = DateComponents()
        components.day = 1
        components.hour = 10
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: "runmap.monthlyRecap.ready",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("⚠️ Monthly recap notification scheduling failed: \(error.localizedDescription)")
            }
        }
    }
}

struct MonthlyRecapReport {
    let title: String
    let interval: DateInterval
    let routes: [Route]
    let workoutCount: Int
    let runCount: Int
    let walkCount: Int
    let distanceKm: Double
    let usualDistanceKm: Double?
    let newCountries: [String]
    let newCities: [String]
    let newStreetNames: [String]
    let newDistrictNames: [String]
    let newStadtteilNames: [String]
    let achievementsUnlocked: [Achievement]
    let goals: MonthlyGoals

    var distanceComparisonText: String? {
        guard let usualDistanceKm, usualDistanceKm > 0 else { return nil }
        let delta = distanceKm - usualDistanceKm
        let absoluteDelta = abs(delta)
        guard absoluteDelta >= 0.1 else { return "About your usual distance" }
        let direction = delta >= 0 ? "more" : "less"
        return String(format: "%.1f km %@ than usual", absoluteDelta, direction)
    }
}

enum MonthlyRecapGenerator {
    static func previousMonthReport(
        routes: [Route],
        achievements: [Achievement],
        consolidatedStreets: [ConsolidatedStreet],
        streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]
    ) -> MonthlyRecapReport {
        makeReport(
            interval: previousMonthInterval(),
            routes: routes,
            achievements: achievements,
            consolidatedStreets: consolidatedStreets,
            streetCoverageByID: streetCoverageByID
        )
    }

    static func currentMonthReport(
        routes: [Route],
        achievements: [Achievement],
        consolidatedStreets: [ConsolidatedStreet],
        streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]
    ) -> MonthlyRecapReport {
        makeReport(
            interval: currentMonthInterval(),
            routes: routes,
            achievements: achievements,
            consolidatedStreets: consolidatedStreets,
            streetCoverageByID: streetCoverageByID
        )
    }

    private static func makeReport(
        interval: DateInterval,
        routes: [Route],
        achievements: [Achievement],
        consolidatedStreets: [ConsolidatedStreet],
        streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]
    ) -> MonthlyRecapReport {
        let monthRoutes = routes.filter { interval.contains($0.date) }.sorted { $0.date > $1.date }
        let priorRoutes = routes.filter { $0.date < interval.start }
        let monthDistance = monthRoutes.map(\.distanceKm).reduce(0, +)
        let streets = consolidatedStreets.isEmpty ? loadFallbackConsolidatedStreets() : consolidatedStreets
        let berlinProgress = berlinMonthProgress(
            monthRoutes: monthRoutes,
            priorRoutes: priorRoutes,
            streets: streets
        )
        let locationProgress = newLocations(monthRoutes: monthRoutes, priorRoutes: priorRoutes)

        return MonthlyRecapReport(
            title: monthTitle(for: interval),
            interval: interval,
            routes: monthRoutes,
            workoutCount: monthRoutes.count,
            runCount: monthRoutes.filter { $0.workoutType == .running }.count,
            walkCount: monthRoutes.filter { $0.workoutType == .walking }.count,
            distanceKm: monthDistance,
            usualDistanceKm: usualMonthlyDistance(routes: routes, before: interval.start),
            newCountries: locationProgress.countries,
            newCities: locationProgress.cities,
            newStreetNames: berlinProgress.streetNames,
            newDistrictNames: berlinProgress.districts,
            newStadtteilNames: berlinProgress.stadtteile,
            achievementsUnlocked: achievements
                .filter { achievement in
                    guard let date = achievement.unlockedDate else { return false }
                    return interval.contains(date)
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
            goals: MonthlyGoalStore.load()
        )
    }

    private static func currentMonthInterval() -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? Date()
        return DateInterval(start: start, end: end)
    }

    private static func previousMonthInterval() -> DateInterval {
        let calendar = Calendar.current
        let currentStart = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let previousStart = calendar.date(byAdding: .month, value: -1, to: currentStart) ?? currentStart
        return DateInterval(start: previousStart, end: currentStart)
    }

    private static func monthTitle(for interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: interval.start)
    }

    private static func usualMonthlyDistance(routes: [Route], before date: Date) -> Double? {
        let calendar = Calendar.current
        guard let currentMonthStart = calendar.dateInterval(of: .month, for: date)?.start else { return nil }

        var totals: [Double] = []
        for offset in 1...3 {
            guard let start = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            let interval = DateInterval(start: start, end: end)
            let total = routes
                .filter { interval.contains($0.date) }
                .map(\.distanceKm)
                .reduce(0, +)
            if total > 0 {
                totals.append(total)
            }
        }

        guard !totals.isEmpty else { return nil }
        return totals.reduce(0, +) / Double(totals.count)
    }

    private static func newLocations(
        monthRoutes: [Route],
        priorRoutes: [Route]
    ) -> (countries: [String], cities: [String]) {
        let prior = locationSets(for: priorRoutes)
        let current = locationSets(for: monthRoutes)

        return (
            countries: current.countries.subtracting(prior.countries).sorted(),
            cities: current.cities.subtracting(prior.cities).sorted()
        )
    }

    private static func locationSets(for routes: [Route]) -> (countries: Set<String>, cities: Set<String>) {
        var countries = Set<String>()
        var cities = Set<String>()

        for route in routes {
            let samples = sampleCoordinates(route.coordinates, maxCount: 16)
            for coordinate in samples {
                let result = LocalGeocoder.geocode(latitude: coordinate.latitude, longitude: coordinate.longitude)
                if !result.country.isEmpty, result.country != "Unknown" {
                    countries.insert(result.country)
                }
                if LocalGeocoder.isSpecificCityName(result.city) {
                    cities.insert(result.city)
                }
            }
        }

        return (countries, cities)
    }

    private static func berlinMonthProgress(
        monthRoutes: [Route],
        priorRoutes: [Route],
        streets: [ConsolidatedStreet]
    ) -> (streetNames: [String], districts: [String], stadtteile: [String]) {
        let priorStreetIDs = coveredStreetIDs(routes: priorRoutes, streets: streets)
        let currentStreetIDs = coveredStreetIDs(routes: monthRoutes, streets: streets)
        let newStreetIDs = currentStreetIDs.subtracting(priorStreetIDs)

        let streetsByID = Dictionary(uniqueKeysWithValues: streets.map { ($0.id, $0) })
        let newStreets = newStreetIDs.compactMap { streetsByID[$0] }

        let streetNames = Set(newStreets.map(\.name)).sorted()
        let districts = Set(newStreets.map(\.district)).sorted()
        let stadtteile = Set(newStreets.compactMap { $0.segments.first?.stadtteil }.filter { !$0.isEmpty && $0 != "Unknown" }).sorted()

        return (streetNames, districts, stadtteile)
    }

    private static func coveredStreetIDs(routes: [Route], streets: [ConsolidatedStreet]) -> Set<String> {
        guard !routes.isEmpty, !streets.isEmpty else { return [] }
        let checker = FastStreetChecker(routes: routes)
        var ids = Set<String>()

        for street in streets {
            let coverage = street.calculateCoverage(using: checker, densify: false)
            if coverage.coveredPoints > 0 {
                ids.insert(street.id)
            }
        }

        return ids
    }

    private static func sampleCoordinates(_ coordinates: [CLLocationCoordinate2D], maxCount: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxCount else { return coordinates }
        let step = max(1, coordinates.count / maxCount)
        return stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
    }

    private static func loadFallbackConsolidatedStreets() -> [ConsolidatedStreet] {
        let streets = BerlinStreets.getStreets(forDistricts: BerlinDistricts.districts.map(\.name))
        guard !streets.isEmpty else { return [] }
        return StreetConsolidator.consolidate(streets: streets)
    }
}

struct MonthlyRecapView: View {
    let routes: [Route]
    let achievements: [Achievement]
    let consolidatedStreets: [ConsolidatedStreet]
    let streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]

    @Environment(\.dismiss) private var dismiss
    @State private var goals = MonthlyGoalStore.load()
    @State private var draftDistance = ""
    @State private var draftStreets = ""
    @State private var draftDistricts = ""

    private var report: MonthlyRecapReport {
        MonthlyRecapGenerator.previousMonthReport(
            routes: routes,
            achievements: achievements,
            consolidatedStreets: consolidatedStreets,
            streetCoverageByID: streetCoverageByID
        )
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if !report.routes.isEmpty {
                        MonthlyRecapRouteMap(routes: report.routes)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if report.workoutCount > 0 {
                        workoutSummary
                    } else {
                        Text("No workouts recorded for this month.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    comparisonSection
                    locationSection(title: "New Countries", values: report.newCountries)
                    locationSection(title: "New Cities", values: report.newCities)
                    locationSection(title: "New Berlin Districts", values: report.newDistrictNames)
                    locationSection(title: "New Berlin Stadtteile", values: report.newStadtteilNames)
                    locationSection(title: "New Berlin Streets", values: report.newStreetNames, limit: 10)
                    achievementSection
                    goalsEditor
                }
                .padding()
            }
            .navigationTitle("Monthly Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                draftDistance = goals.distanceKm.map { String(format: "%.0f", $0) } ?? ""
                draftStreets = goals.newStreetCount.map(String.init) ?? ""
                draftDistricts = goals.newDistrictCount.map(String.init) ?? ""
            }
        }
        .navigationViewStyle(.stack)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(report.title)
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Full monthly report")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var workoutSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workouts")
                .font(.headline)
            HStack(spacing: 10) {
                metric(title: "Total", value: "\(report.workoutCount)", color: .blue)
                if report.runCount > 0 {
                    metric(title: "Runs", value: "\(report.runCount)", color: .green)
                }
                if report.walkCount > 0 {
                    metric(title: "Walks", value: "\(report.walkCount)", color: .cyan)
                }
                if report.distanceKm > 0 {
                    metric(title: "Distance", value: String(format: "%.1f km", report.distanceKm), color: .purple)
                }
            }
        }
    }

    @ViewBuilder
    private var comparisonSection: some View {
        if let text = report.distanceComparisonText {
            Text(text)
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func locationSection(title: String, values: [String], limit: Int = 8) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                let shown = values.prefix(limit)
                ForEach(Array(shown), id: \.self) { value in
                    Text(value)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if values.count > limit {
                    Text("and \(values.count - limit) others")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var achievementSection: some View {
        if !report.achievementsUnlocked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Achievements")
                    .font(.headline)
                ForEach(report.achievementsUnlocked) { achievement in
                    Label(achievement.title, systemImage: achievement.iconName)
                        .font(.subheadline)
                        .foregroundColor(achievement.currentTier.color)
                }
            }
        }
    }

    private var goalsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly Goals")
                .font(.headline)

            goalField(title: "Distance km", text: $draftDistance, keyboard: .decimalPad)
            goalField(title: "New Berlin streets", text: $draftStreets, keyboard: .numberPad)
            goalField(title: "New Berlin districts", text: $draftDistricts, keyboard: .numberPad)

            Button {
                goals = MonthlyGoals(
                    distanceKm: Double(draftDistance.trimmingCharacters(in: .whitespacesAndNewlines)),
                    newStreetCount: Int(draftStreets.trimmingCharacters(in: .whitespacesAndNewlines)),
                    newDistrictCount: Int(draftDistricts.trimmingCharacters(in: .whitespacesAndNewlines))
                )
                MonthlyGoalStore.save(goals)
            } label: {
                Label("Save Goals", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func metric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func goalField(title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            TextField("Optional", text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
        }
    }
}

struct MonthlyGoalProgressSection: View {
    let routes: [Route]
    let achievements: [Achievement]
    let consolidatedStreets: [ConsolidatedStreet]
    let streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]

    @State private var goals = MonthlyGoalStore.load()

    private var report: MonthlyRecapReport {
        MonthlyRecapGenerator.currentMonthReport(
            routes: routes,
            achievements: achievements,
            consolidatedStreets: consolidatedStreets,
            streetCoverageByID: streetCoverageByID
        )
    }

    var body: some View {
        if goals.hasAnyGoal {
            VStack(alignment: .leading, spacing: 12) {
                Text("Monthly Goals")
                    .font(.title2)
                    .fontWeight(.bold)

                if let target = goals.distanceKm {
                    progressRow(title: "Distance", current: report.distanceKm, target: target, suffix: "km")
                }
                if let target = goals.newStreetCount {
                    progressRow(title: "New streets", current: Double(report.newStreetNames.count), target: Double(target), suffix: "")
                }
                if let target = goals.newDistrictCount {
                    progressRow(title: "New districts", current: Double(report.newDistrictNames.count), target: Double(target), suffix: "")
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal)
            .onAppear {
                goals = MonthlyGoalStore.load()
            }
        }
    }

    private func progressRow(title: String, current: Double, target: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(valueText(current: current, target: target, suffix: suffix))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ProgressView(value: min(current / max(target, 1), 1))
        }
    }

    private func valueText(current: Double, target: Double, suffix: String) -> String {
        if suffix.isEmpty {
            return "\(Int(current)) / \(Int(target))"
        }
        return String(format: "%.1f / %.0f %@", current, target, suffix)
    }
}

private struct MonthlyRecapRouteMap: UIViewRepresentable {
    let routes: [Route]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsUserLocation = false
        mapView.pointOfInterestFilter = .excludingAll
        render(routes: routes, on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        render(routes: routes, on: mapView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func render(routes: [Route], on mapView: MKMapView) {
        mapView.removeOverlays(mapView.overlays)

        let polylines = routes
            .filter { $0.coordinates.count > 1 }
            .map { route in
                let polyline = MonthlyRecapPolyline(coordinates: route.coordinates, count: route.coordinates.count)
                polyline.workoutType = route.workoutType
                return polyline
            }

        if !polylines.isEmpty {
            mapView.addOverlays(polylines, level: .aboveRoads)
        }

        let coordinates = routes.flatMap(\.coordinates)
        if !coordinates.isEmpty {
            mapView.setRegion(coordinateRegion(for: coordinates), animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MonthlyRecapPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = polyline.workoutType == .running ? UIColor.systemGreen : UIColor.systemBlue
            renderer.lineWidth = 4
            renderer.alpha = 0.9
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}

private final class MonthlyRecapPolyline: MKPolyline {
    var workoutType: HKWorkoutActivityType?
}
