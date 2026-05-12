import SwiftUI
import MapKit
import CoreLocation
import HealthKit

struct RoutePlannerView: View {
    let initialRegion: MKCoordinateRegion
    let consolidatedStreets: [ConsolidatedStreet]
    let streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]

    @Environment(\.dismiss) private var dismiss
    @State private var waypoints: [CLLocationCoordinate2D] = []
    @State private var stats = PlannedRouteStats.empty
    @State private var isComputingStats = false
    @State private var savedPlans: [SavedRoutePlan] = []
    @State private var showSavePlanDialog = false
    @State private var planTitle = ""
    @State private var showCurrentStreetCoverage = false

    private var waypointSignature: String {
        waypoints
            .map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" }
            .joined(separator: "|")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                PlannerMapView(
                    waypoints: waypoints,
                    initialRegion: initialRegion,
                    showCurrentStreetCoverage: showCurrentStreetCoverage,
                    consolidatedStreets: consolidatedStreets,
                    streetCoverageByID: streetCoverageByID,
                    onAddWaypoint: { coordinate in
                        waypoints.append(coordinate)
                    }
                )
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Text("Tap the map to add waypoints")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                }

                plannerSummary
                    .background(Color(.systemBackground))
            }
            .navigationTitle("Plan Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Save Plan", systemImage: "square.and.arrow.down") {
                            planTitle = defaultPlanTitle
                            showSavePlanDialog = true
                        }
                        .disabled(waypoints.count < 2)

                        Button("Undo Last", systemImage: "arrow.uturn.backward") {
                            if !waypoints.isEmpty {
                                waypoints.removeLast()
                            }
                        }
                        .disabled(waypoints.isEmpty)

                        Button("Clear", systemImage: "trash", role: .destructive) {
                            waypoints.removeAll()
                        }
                        .disabled(waypoints.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            savedPlans = SavedRoutePlanStore.load()
            recalculateStats()
        }
        .onChange(of: waypointSignature) { _ in
            recalculateStats()
        }
        .alert("Save Plan", isPresented: $showSavePlanDialog) {
            TextField("Title", text: $planTitle)
            Button("Save") {
                saveCurrentPlan()
            }
            .disabled(planTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Name this planned route so you can reopen it later.")
        }
    }

    private var plannerSummary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.2f km", stats.distanceKm))
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    if isComputingStats {
                        ProgressView()
                    }
                }

                HStack(spacing: 10) {
                    metricPill(title: "Walk", value: stats.walkDurationText, color: .blue)
                    metricPill(title: "Run", value: stats.runDurationText, color: .green)
                    metricPill(title: "Points", value: "\(waypoints.count)", color: .orange)
                }

                HStack(spacing: 12) {
                    Button {
                        planTitle = defaultPlanTitle
                        showSavePlanDialog = true
                    } label: {
                        Label("Save Plan", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(waypoints.count < 2)

                    Toggle(isOn: $showCurrentStreetCoverage) {
                        Label("Street Coverage", systemImage: "map")
                    }
                    .toggleStyle(.switch)
                    .font(.subheadline)
                    .disabled(consolidatedStreets.isEmpty || streetCoverageByID.isEmpty)
                }

                if waypoints.count < 2 {
                    Text("Add at least two waypoints to preview route stats.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    statsSection(title: "Places", items: stats.placeLines)
                    statsSection(title: "Berlin", items: stats.berlinLines)
                    newStreetSection
                }

                savedPlansSection
            }
            .padding()
        }
        .frame(maxHeight: 340)
    }

    private var savedPlansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !savedPlans.isEmpty {
                Text("Saved Plans")
                    .font(.headline)

                ForEach(savedPlans.prefix(5)) { plan in
                    HStack(spacing: 10) {
                        Button {
                            waypoints = plan.coordinates
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text("\(plan.coordinates.count) points")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            deletePlan(plan)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var newStreetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projected Street Coverage")
                .font(.headline)

            if consolidatedStreets.isEmpty {
                Text("Street coverage data is still loading. Open Achievements once to build the street cache, then this planner can estimate new Berlin streets.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if stats.newStreetNames.isEmpty {
                Text("No new Berlin streets detected for this plan.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("\(stats.newStreetNames.count) likely new streets")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                ForEach(stats.newStreetNames.prefix(6), id: \.self) { street in
                    Text(street)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if stats.newStreetNames.count > 6 {
                    Text("and \(stats.newStreetNames.count - 6) others")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func metricPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statsSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            if items.isEmpty {
                Text("No matches yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func recalculateStats() {
        let plannedCoordinates = waypoints
        let streets = consolidatedStreets
        let existingCoverage = streetCoverageByID

        guard !plannedCoordinates.isEmpty else {
            stats = .empty
            isComputingStats = false
            return
        }

        isComputingStats = true
        DispatchQueue.global(qos: .userInitiated).async {
            let calculated = PlannedRouteStats.calculate(
                coordinates: plannedCoordinates,
                consolidatedStreets: streets,
                existingCoverage: existingCoverage
            )

            DispatchQueue.main.async {
                stats = calculated
                isComputingStats = false
            }
        }
    }

    private var defaultPlanTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Plan \(formatter.string(from: Date()))"
    }

    private func saveCurrentPlan() {
        let trimmedTitle = planTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard waypoints.count >= 2, !trimmedTitle.isEmpty else { return }

        let plan = SavedRoutePlan(title: trimmedTitle, createdAt: Date(), coordinates: waypoints)
        savedPlans.insert(plan, at: 0)
        SavedRoutePlanStore.save(savedPlans)
    }

    private func deletePlan(_ plan: SavedRoutePlan) {
        savedPlans.removeAll { $0.id == plan.id }
        SavedRoutePlanStore.save(savedPlans)
    }
}

private struct PlannerMapView: UIViewRepresentable {
    let waypoints: [CLLocationCoordinate2D]
    let initialRegion: MKCoordinateRegion
    let showCurrentStreetCoverage: Bool
    let consolidatedStreets: [ConsolidatedStreet]
    let streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]
    let onAddWaypoint: (CLLocationCoordinate2D) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = initialRegion
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTapMap(_:)))
        tapGesture.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tapGesture)
        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.renderStreetCoverage(
            showCurrentStreetCoverage: showCurrentStreetCoverage,
            consolidatedStreets: consolidatedStreets,
            streetCoverageByID: streetCoverageByID,
            on: mapView
        )
        context.coordinator.render(waypoints: waypoints, on: mapView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PlannerMapView
        weak var mapView: MKMapView?
        private var renderedSignature = ""
        private var renderedCoverageSignature = ""
        private var overlays: [MKOverlay] = []
        private var coverageOverlays: [MKOverlay] = []
        private var annotations: [MKAnnotation] = []

        init(parent: PlannerMapView) {
            self.parent = parent
        }

        @objc func didTapMap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let mapView else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onAddWaypoint(coordinate)
        }

        func renderStreetCoverage(
            showCurrentStreetCoverage: Bool,
            consolidatedStreets: [ConsolidatedStreet],
            streetCoverageByID: [String: ConsolidatedStreet.CoverageResult],
            on mapView: MKMapView
        ) {
            let coveredStreetCount = streetCoverageByID.values.filter { $0.coveredPoints > 0 }.count
            let signature = showCurrentStreetCoverage
                ? "on:\(consolidatedStreets.count):\(streetCoverageByID.count):\(coveredStreetCount)"
                : "off"
            guard signature != renderedCoverageSignature else { return }
            renderedCoverageSignature = signature

            if !coverageOverlays.isEmpty {
                mapView.removeOverlays(coverageOverlays)
                coverageOverlays.removeAll(keepingCapacity: true)
            }

            guard showCurrentStreetCoverage else { return }

            var coveredPolylines: [MKPolyline] = []
            coveredPolylines.reserveCapacity(coveredStreetCount)

            for street in consolidatedStreets {
                guard (streetCoverageByID[street.id]?.coveredPoints ?? 0) > 0 else { continue }

                for segment in street.segments {
                    let coordinates = segment.clCoordinates
                    guard coordinates.count >= 2 else { continue }
                    coveredPolylines.append(MKPolyline(coordinates: coordinates, count: coordinates.count))
                }
            }

            guard !coveredPolylines.isEmpty else { return }
            let overlay = MKMultiPolyline(coveredPolylines)
            coverageOverlays = [overlay]
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        func render(waypoints: [CLLocationCoordinate2D], on mapView: MKMapView) {
            let signature = waypoints
                .map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" }
                .joined(separator: "|")
            guard signature != renderedSignature else { return }
            renderedSignature = signature

            if !overlays.isEmpty {
                mapView.removeOverlays(overlays)
                overlays.removeAll(keepingCapacity: true)
            }
            if !annotations.isEmpty {
                mapView.removeAnnotations(annotations)
                annotations.removeAll(keepingCapacity: true)
            }

            if waypoints.count >= 2 {
                let polyline = PlannedRoutePolyline(coordinates: waypoints, count: waypoints.count)
                overlays.append(polyline)
                mapView.addOverlay(polyline)
            }

            for (index, coordinate) in waypoints.enumerated() {
                let annotation = PlanWaypointAnnotation()
                annotation.coordinate = coordinate
                annotation.title = "\(index + 1)"
                annotations.append(annotation)
            }

            if !annotations.isEmpty {
                mapView.addAnnotations(annotations)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multiPolyline = overlay as? MKMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
                renderer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.35)
                renderer.lineWidth = 2
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            guard let polyline = overlay as? PlannedRoutePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.systemPurple.withAlphaComponent(0.9)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is PlanWaypointAnnotation else { return nil }
            let identifier = "PlanWaypoint"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = .systemPurple
            view.glyphText = annotation.title ?? ""
            view.canShowCallout = false
            return view
        }
    }
}

private final class PlanWaypointAnnotation: MKPointAnnotation {}
private final class PlannedRoutePolyline: MKPolyline {}

private struct SavedRoutePlan: Identifiable, Codable {
    let id: UUID
    let title: String
    let createdAt: Date
    let points: [SavedRoutePlanPoint]

    init(id: UUID = UUID(), title: String, createdAt: Date, coordinates: [CLLocationCoordinate2D]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.points = coordinates.map { SavedRoutePlanPoint(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

private struct SavedRoutePlanPoint: Codable {
    let latitude: Double
    let longitude: Double
}

private enum SavedRoutePlanStore {
    private static let key = "routePlanner.savedPlans.v1"

    static func load() -> [SavedRoutePlan] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let plans = try? JSONDecoder().decode([SavedRoutePlan].self, from: data) else {
            return []
        }
        return plans.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ plans: [SavedRoutePlan]) {
        let sortedPlans = plans.sorted { $0.createdAt > $1.createdAt }
        guard let data = try? JSONEncoder().encode(sortedPlans) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct PlannedRouteStats {
    let distanceKm: Double
    let countries: [String]
    let cities: [String]
    let districts: [String]
    let stadtteile: [String]
    let newStreetNames: [String]

    static let empty = PlannedRouteStats(
        distanceKm: 0,
        countries: [],
        cities: [],
        districts: [],
        stadtteile: [],
        newStreetNames: []
    )

    var walkDurationText: String {
        durationText(hours: distanceKm / 5.0)
    }

    var runDurationText: String {
        durationText(hours: distanceKm / 9.5)
    }

    var placeLines: [String] {
        [
            listLine(label: "Countries", values: countries),
            listLine(label: "Cities", values: cities)
        ].compactMap { $0 }
    }

    var berlinLines: [String] {
        [
            listLine(label: "Districts", values: districts),
            listLine(label: "Stadtteile", values: stadtteile)
        ].compactMap { $0 }
    }

    static func calculate(
        coordinates: [CLLocationCoordinate2D],
        consolidatedStreets: [ConsolidatedStreet],
        existingCoverage: [String: ConsolidatedStreet.CoverageResult]
    ) -> PlannedRouteStats {
        let samples = sampledPath(from: coordinates, maxStepMeters: 300)
        let distanceKm = totalDistanceKm(for: coordinates)

        var countries = Set<String>()
        var cities = Set<String>()
        var districts = Set<String>()

        for coordinate in samples {
            let geocode = LocalGeocoder.geocode(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if geocode.country != "Unknown", !geocode.country.isEmpty {
                countries.insert(geocode.country)
            }
            if LocalGeocoder.isSpecificCityName(geocode.city) {
                cities.insert(geocode.city)
            }
            if let district = BerlinDistricts.getDistrict(lat: coordinate.latitude, lon: coordinate.longitude) {
                districts.insert(district)
            }
        }

        let stadtteile = BerlinStreets.getStadtteileFromCoordinates(samples)
        let newStreetNames = projectedNewStreetNames(
            coordinates: coordinates,
            consolidatedStreets: consolidatedStreets,
            existingCoverage: existingCoverage
        )

        return PlannedRouteStats(
            distanceKm: distanceKm,
            countries: sorted(countries),
            cities: sorted(cities),
            districts: sorted(districts),
            stadtteile: sorted(stadtteile),
            newStreetNames: newStreetNames
        )
    }

    private static func projectedNewStreetNames(
        coordinates: [CLLocationCoordinate2D],
        consolidatedStreets: [ConsolidatedStreet],
        existingCoverage: [String: ConsolidatedStreet.CoverageResult]
    ) -> [String] {
        guard coordinates.count >= 2, !consolidatedStreets.isEmpty else { return [] }

        let plannedRoute = Route(
            coordinates: sampledPath(from: coordinates, maxStepMeters: 25),
            date: Date(),
            workoutType: .walking,
            durationSec: 0
        )
        let checker = FastStreetChecker(routes: [plannedRoute])

        var names = Set<String>()
        for street in consolidatedStreets {
            let wasCovered = (existingCoverage[street.id]?.coveredPoints ?? 0) > 0
            guard !wasCovered else { continue }

            let plannedCoverage = street.calculateCoverage(using: checker, densify: false)
            if plannedCoverage.coveredPoints > 0 {
                names.insert(street.name)
            }
        }

        return sorted(names)
    }

    private static func sampledPath(from coordinates: [CLLocationCoordinate2D], maxStepMeters: Double) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }

        var samples: [CLLocationCoordinate2D] = []
        samples.reserveCapacity(coordinates.count * 4)

        for index in 0..<(coordinates.count - 1) {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            samples.append(start)

            let segmentMeters = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            let steps = max(1, Int(ceil(segmentMeters / maxStepMeters)))
            guard steps > 1 else { continue }

            for step in 1..<steps {
                let fraction = Double(step) / Double(steps)
                samples.append(CLLocationCoordinate2D(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                ))
            }
        }

        if let last = coordinates.last {
            samples.append(last)
        }

        return samples
    }

    private static func totalDistanceKm(for coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var totalMeters = 0.0
        for index in 0..<(coordinates.count - 1) {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            totalMeters +=
                CLLocation(latitude: start.latitude, longitude: start.longitude)
                    .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        }
        return totalMeters / 1_000
    }

    private static func sorted(_ values: Set<String>) -> [String] {
        values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func listLine(label: String, values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        let shown = values.prefix(4).joined(separator: ", ")
        if values.count > 4 {
            return "\(label): \(shown), and \(values.count - 4) others"
        }
        return "\(label): \(shown)"
    }

    private func durationText(hours: Double) -> String {
        guard hours.isFinite, hours > 0 else { return "0 min" }
        let minutes = Int((hours * 60).rounded())
        if minutes < 60 {
            return "\(minutes) min"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
