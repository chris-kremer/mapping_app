import SwiftUI
import MapKit

struct StreetDebugView: View {
    let routes: [Route]
    @State private var streets: [BerlinStreets.Street] = []
    @State private var consolidatedStreets: [ConsolidatedStreet] = []
    @State private var selectedConsolidatedStreet: ConsolidatedStreet?
    @State private var selectedStreet: BerlinStreets.Street?
    @State private var isLoading = false
    @State private var debugInfo = ""
    @State private var coverageResults: [StreetPointDebugInfo] = []
    @State private var routePolylines: [DebugRoutePolyline] = []
    @State private var useDensification = true
    @State private var showConsolidatedView = true
    @State private var streetCoverageCache: [String: ConsolidatedStreet.CoverageResult] = [:]
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.520, longitude: 13.405), // Berlin Mitte
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Street Debug View - Mitte")
                    .font(.headline)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                if !debugInfo.isEmpty {
                    Text(debugInfo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemBackground))

            // Map showing street points and routes
            if let selected = selectedStreet {
                ZStack {
                    StreetDebugMapView(
                        region: region,
                        routePolylines: routePolylines,
                        coverageResults: coverageResults
                    )

                    // Legend
                    VStack {
                        Spacer()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                HStack(spacing: 4) {
                                    Rectangle().fill(Color.purple.opacity(0.7)).frame(width: 20, height: 3)
                                    Text("Street")
                                }
                                .padding(8)
                                .background(Color(.systemBackground).opacity(0.9))
                                .cornerRadius(8)

                                HStack(spacing: 4) {
                                    Rectangle().fill(Color.blue.opacity(0.5)).frame(width: 20, height: 3)
                                    Text("Routes")
                                }
                                .padding(8)
                                .background(Color(.systemBackground).opacity(0.9))
                                .cornerRadius(8)

                                HStack(spacing: 4) {
                                    Circle().fill(Color.green.opacity(0.7)).frame(width: 12, height: 12)
                                    Text("Covered")
                                }
                                .padding(8)
                                .background(Color(.systemBackground).opacity(0.9))
                                .cornerRadius(8)

                                HStack(spacing: 4) {
                                    Circle().fill(Color.red.opacity(0.7)).frame(width: 12, height: 12)
                                    Text("Uncovered")
                                }
                                .padding(8)
                                .background(Color(.systemBackground).opacity(0.9))
                                .cornerRadius(8)

                                HStack(spacing: 4) {
                                    ZStack {
                                        Circle().fill(Color.green).frame(width: 16, height: 16)
                                        Text("S").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                                    }
                                    Text("Start")
                                }
                                .padding(8)
                                .background(Color(.systemBackground).opacity(0.9))
                                .cornerRadius(8)

                                HStack(spacing: 4) {
                                    ZStack {
                                        Circle().fill(Color.red).frame(width: 16, height: 16)
                                        Text("E").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                                    }
                                    Text("End")
                                }
                                .padding(8)
                                .background(Color(.systemBackground).opacity(0.9))
                                .cornerRadius(8)
                            }
                            .padding(.horizontal)
                        }
                        .padding(.bottom)
                    }
                }
                .frame(height: 400)
            }

            // Street list
            List {
                Section {
                    Button("Load Mitte Streets") {
                        loadMitteStreets()
                    }
                    .disabled(isLoading)

                    Toggle("Consolidated View", isOn: $showConsolidatedView)
                        .onChange(of: showConsolidatedView) { _ in
                            // Clear selection when switching views
                            selectedConsolidatedStreet = nil
                            selectedStreet = nil
                            coverageResults = []
                        }

                    Toggle("Use Densified Geometry", isOn: $useDensification)
                        .onChange(of: useDensification) { _ in
                            // Clear cache when toggling densification
                            streetCoverageCache.removeAll()
                            if let consolidated = selectedConsolidatedStreet {
                                selectConsolidatedStreet(consolidated)
                            } else if let street = selectedStreet {
                                selectStreet(street)
                            }
                        }
                }

                if showConsolidatedView && !consolidatedStreets.isEmpty {
                    Section(header: Text("\(consolidatedStreets.count) Consolidated Streets in Mitte")) {
                        ForEach(consolidatedStreets) { consolidatedStreet in
                            Button(action: {
                                selectConsolidatedStreet(consolidatedStreet)
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(consolidatedStreet.name)
                                            .font(.body)
                                            .foregroundColor(selectedConsolidatedStreet?.id == consolidatedStreet.id ? .blue : .primary)

                                        Spacer()

                                        if let coverage = streetCoverageCache[consolidatedStreet.id] {
                                            CoverageIndicator(coverage: coverage)
                                        }
                                    }

                                    HStack {
                                        Text("\(consolidatedStreet.segments.count) segments")
                                        Text("•")
                                        Text("\(String(format: "%.0f", consolidatedStreet.totalLength))m")
                                        Text("•")
                                        Text("\(consolidatedStreet.totalPoints) points")

                                        if let coverage = streetCoverageCache[consolidatedStreet.id] {
                                            Text("•")
                                            Text("\(String(format: "%.1f", coverage.percentage))%")
                                                .foregroundColor(coverageColor(for: coverage.percentage))
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else if !showConsolidatedView && !streets.isEmpty {
                    Section(header: Text("\(streets.count) Street Segments in Mitte")) {
                        ForEach(streets, id: \.name) { street in
                            Button(action: {
                                selectStreet(street)
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(street.name)
                                        .font(.body)
                                        .foregroundColor(selectedStreet?.name == street.name ? .blue : .primary)
                                    Text("\(street.coordinates.count) points • \(String(format: "%.0f", street.lengthMeters))m")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                if let selected = selectedStreet {
                    Section(header: Text("Coverage Details")) {
                        let covered = coverageResults.filter { $0.isCovered }.count
                        let total = coverageResults.count

                        Text("Points: \(covered)/\(total) covered (\(String(format: "%.1f", Double(covered)/Double(total)*100))%)")

                        ForEach(Array(coverageResults.enumerated()), id: \.offset) { index, point in
                            HStack {
                                Circle()
                                    .fill(point.isCovered ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)

                                Text("Point \(index)")
                                    .font(.caption)

                                Spacer()

                                if point.isCovered {
                                    Text("✓ Covered")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else {
                                    Text("✗ Not Covered")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }

                                if let distance = point.closestDistance {
                                    Text(String(format: "%.1fm", distance))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Street Debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Functions

    private func loadMitteStreets() {
        isLoading = true
        debugInfo = "Loading streets..."

        Task {
            // Load only Mitte district
            let allStreets = await BerlinStreets.getStreets(forDistricts: ["Mitte"])

            // Further filter to just "Mitte" stadtteil if needed
            let mitteStreets = allStreets.filter { street in
                street.stadtteil.lowercased().contains("mitte") ||
                street.district.lowercased() == "mitte"
            }

            // Consolidate streets by name
            let consolidated = StreetConsolidator.consolidate(streets: mitteStreets)
            let stats = StreetConsolidator.getStats(streets: mitteStreets)

            await MainActor.run {
                self.streets = mitteStreets.sorted { $0.name < $1.name }
                self.consolidatedStreets = consolidated
                self.debugInfo = "Loaded \(consolidated.count) streets (\(mitteStreets.count) segments, avg \(stats.avgSegmentsPerStreet) per street)"
                self.isLoading = false
            }
        }
    }

    private func selectConsolidatedStreet(_ consolidatedStreet: ConsolidatedStreet) {
        selectedConsolidatedStreet = consolidatedStreet
        selectedStreet = nil
        isLoading = true
        debugInfo = "Analyzing \(consolidatedStreet.name) (\(consolidatedStreet.segments.count) segments)..."

        Task {
            let startTime = Date()

            // Build spatial index
            let checker = FastStreetChecker(routes: routes)

            // Calculate coverage for entire consolidated street
            let coverage = consolidatedStreet.calculateCoverage(using: checker, densify: useDensification)

            // Cache the result
            await MainActor.run {
                streetCoverageCache[consolidatedStreet.id] = coverage
            }

            // Build detailed results for all segments
            var allResults: [StreetPointDebugInfo] = []
            var nearbyRoutes: [DebugRoutePolyline] = []
            var allStreetBounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?

            for segment in consolidatedStreet.segments {
                let coords = useDensification
                    ? GeometryDensification.densifyCoordinates(segment.coordinates, maxDistanceMeters: 5.0)
                    : segment.coordinates

                let segmentCoverage = checker.checkStreetCoverageDetailed(streetCoords: coords)

                for (index, (isCovered, closestDistance)) in segmentCoverage.enumerated() {
                    allResults.append(StreetPointDebugInfo(
                        index: allResults.count,
                        coordinate: CLLocationCoordinate2D(latitude: coords[index].lat, longitude: coords[index].lon),
                        isCovered: isCovered,
                        closestDistance: closestDistance
                    ))
                }

                // Update bounds
                let segmentBounds = calculateBounds(for: coords)
                if let existing = allStreetBounds {
                    allStreetBounds = (
                        minLat: min(existing.minLat, segmentBounds.minLat),
                        maxLat: max(existing.maxLat, segmentBounds.maxLat),
                        minLon: min(existing.minLon, segmentBounds.minLon),
                        maxLon: max(existing.maxLon, segmentBounds.maxLon)
                    )
                } else {
                    allStreetBounds = segmentBounds
                }
            }

            // Find nearby routes
            if let bounds = allStreetBounds {
                for route in routes {
                    let routeNearby = route.coordinates.contains { coord in
                        return coord.latitude >= bounds.minLat && coord.latitude <= bounds.maxLat &&
                               coord.longitude >= bounds.minLon && coord.longitude <= bounds.maxLon
                    }

                    if routeNearby {
                        nearbyRoutes.append(DebugRoutePolyline(
                            id: route.id,
                            coordinates: route.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                        ))
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(startTime)

            await MainActor.run {
                self.coverageResults = allResults
                self.routePolylines = nearbyRoutes

                // Center map on consolidated street
                if let bounds = allStreetBounds {
                    let center = CLLocationCoordinate2D(
                        latitude: (bounds.minLat + bounds.maxLat) / 2,
                        longitude: (bounds.minLon + bounds.maxLon) / 2
                    )
                    let span = MKCoordinateSpan(
                        latitudeDelta: (bounds.maxLat - bounds.minLat) * 1.3,
                        longitudeDelta: (bounds.maxLon - bounds.minLon) * 1.3
                    )
                    self.region = MKCoordinateRegion(center: center, span: span)
                }

                let densNote = useDensification ? " (densified)" : ""
                let timeNote = String(format: " • %.0fms", elapsed * 1000)
                self.debugInfo = "\(consolidatedStreet.name): \(String(format: "%.1f", coverage.percentage))% covered • \(consolidatedStreet.segments.count) segments\(densNote)\(timeNote)"
                self.isLoading = false
            }
        }
    }

    private func coverageColor(for percentage: Double) -> Color {
        if percentage >= 99 {
            return .green
        } else if percentage >= 50 {
            return .orange
        } else if percentage > 0 {
            return .red
        } else {
            return .gray
        }
    }

    private func selectStreet(_ street: BerlinStreets.Street) {
        selectedStreet = street
        isLoading = true
        debugInfo = "Analyzing \(street.name)..."

        Task {
            let startTime = Date()

            // Get street coordinates (optionally densified)
            let streetCoords = useDensification ? densifyCoordinates(street.coordinates, maxDistanceMeters: 5) : street.coordinates

            // Build route polylines for map display (only routes near this street)
            var nearbyRoutes: [DebugRoutePolyline] = []
            let streetBounds = calculateBounds(for: streetCoords)

            for route in routes {
                // Check if route is anywhere near this street
                let routeNearby = route.coordinates.contains { coord in
                    let lat = coord.latitude
                    let lon = coord.longitude
                    return lat >= streetBounds.minLat && lat <= streetBounds.maxLat &&
                           lon >= streetBounds.minLon && lon <= streetBounds.maxLon
                }

                if routeNearby {
                    nearbyRoutes.append(DebugRoutePolyline(
                        id: route.id,
                        coordinates: route.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    ))
                }
            }

            // FAST spatial index-based coverage check
            let checker = FastStreetChecker(routes: routes)
            let coverageDetails = checker.checkStreetCoverageDetailed(streetCoords: streetCoords)

            // Build results
            var results: [StreetPointDebugInfo] = []
            for (index, (isCovered, closestDistance)) in coverageDetails.enumerated() {
                results.append(StreetPointDebugInfo(
                    index: index,
                    coordinate: CLLocationCoordinate2D(latitude: streetCoords[index].lat, longitude: streetCoords[index].lon),
                    isCovered: isCovered,
                    closestDistance: closestDistance
                ))
            }

            let elapsed = Date().timeIntervalSince(startTime)

            await MainActor.run {
                self.coverageResults = results
                self.routePolylines = nearbyRoutes

                // Center map on street with padding to show nearby routes
                if let firstCoord = streetCoords.first {
                    self.region = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: firstCoord.lat, longitude: firstCoord.lon),
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                }

                let covered = results.filter { $0.isCovered }.count
                let densificationNote = useDensification ? " (densified to ~5m)" : ""
                let timeNote = String(format: " • %.1fms", elapsed * 1000)
                self.debugInfo = "\(street.name): \(covered)/\(results.count) covered\(densificationNote)\(timeNote)"
                self.isLoading = false
            }
        }
    }

    // MARK: - Geometry Helpers

    private func densifyCoordinates(_ coords: [BerlinStreets.SimpleCoordinate], maxDistanceMeters: Double) -> [BerlinStreets.SimpleCoordinate] {
        guard coords.count >= 2 else { return coords }

        var densified: [BerlinStreets.SimpleCoordinate] = []

        for i in 0..<(coords.count - 1) {
            let start = CLLocation(latitude: coords[i].lat, longitude: coords[i].lon)
            let end = CLLocation(latitude: coords[i + 1].lat, longitude: coords[i + 1].lon)
            let distance = start.distance(from: end)

            densified.append(coords[i])

            // If distance is larger than max, interpolate points
            if distance > maxDistanceMeters {
                let numIntermediatePoints = Int(ceil(distance / maxDistanceMeters)) - 1

                for j in 1...numIntermediatePoints {
                    let fraction = Double(j) / Double(numIntermediatePoints + 1)
                    let lat = coords[i].lat + (coords[i + 1].lat - coords[i].lat) * fraction
                    let lon = coords[i].lon + (coords[i + 1].lon - coords[i].lon) * fraction
                    densified.append(BerlinStreets.SimpleCoordinate(lat: lat, lon: lon))
                }
            }
        }

        // Add last point
        densified.append(coords[coords.count - 1])

        return densified
    }

    private func calculateBounds(for coords: [BerlinStreets.SimpleCoordinate]) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        guard !coords.isEmpty else {
            return (0, 0, 0, 0)
        }

        let lats = coords.map { $0.lat }
        let lons = coords.map { $0.lon }

        let buffer = 0.005 // ~500m buffer

        return (
            minLat: (lats.min() ?? 0) - buffer,
            maxLat: (lats.max() ?? 0) + buffer,
            minLon: (lons.min() ?? 0) - buffer,
            maxLon: (lons.max() ?? 0) + buffer
        )
    }
}

struct StreetPointDebugInfo: Identifiable {
    let id = UUID()
    let index: Int
    let coordinate: CLLocationCoordinate2D
    let isCovered: Bool
    let closestDistance: Double?
}

struct DebugRoutePolyline: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
}

// MARK: - Map View

struct StreetDebugMapView: UIViewRepresentable {
    let region: MKCoordinateRegion
    let routePolylines: [DebugRoutePolyline]
    let coverageResults: [StreetPointDebugInfo]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.region = region
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update region
        mapView.setRegion(region, animated: true)

        // Remove existing overlays and annotations
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        // Add route polylines (blue)
        for routePoly in routePolylines {
            let polyline = MKPolyline(coordinates: routePoly.coordinates, count: routePoly.coordinates.count)
            mapView.addOverlay(polyline)
        }

        // Add street polyline (purple)
        if !coverageResults.isEmpty {
            let streetCoords = coverageResults.map { $0.coordinate }
            let streetPolyline = MKPolyline(coordinates: streetCoords, count: streetCoords.count)
            mapView.addOverlay(streetPolyline)
        }

        // Add start marker
        if let first = coverageResults.first {
            let annotation = MKPointAnnotation()
            annotation.coordinate = first.coordinate
            annotation.title = "Start"
            mapView.addAnnotation(annotation)
        }

        // Add end marker
        if let last = coverageResults.last, coverageResults.count > 1 {
            let annotation = MKPointAnnotation()
            annotation.coordinate = last.coordinate
            annotation.title = "End"
            mapView.addAnnotation(annotation)
        }

        // Add coverage point annotations
        for point in coverageResults {
            let annotation = CoveragePointAnnotation()
            annotation.coordinate = point.coordinate
            annotation.isCovered = point.isCovered
            mapView.addAnnotation(annotation)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        let parent: StreetDebugMapView

        init(_ parent: StreetDebugMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)

            // Determine if this is the street polyline (last one added) or a route
            if mapView.overlays.last === overlay && !parent.coverageResults.isEmpty {
                // Street polyline - purple
                renderer.strokeColor = UIColor.systemPurple.withAlphaComponent(0.7)
                renderer.lineWidth = 4
            } else {
                // Route polyline - blue
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.5)
                renderer.lineWidth = 3
            }

            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let coverageAnnotation = annotation as? CoveragePointAnnotation {
                let identifier = "CoveragePoint"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation

                // Create a colored circle
                let size: CGFloat = 8
                let color: UIColor = coverageAnnotation.isCovered ? .systemGreen.withAlphaComponent(0.7) : .systemRed.withAlphaComponent(0.7)

                UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
                let context = UIGraphicsGetCurrentContext()
                context?.setFillColor(color.cgColor)
                context?.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
                context?.setStrokeColor(UIColor.white.cgColor)
                context?.setLineWidth(1)
                context?.strokeEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
                view.image = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()

                view.centerOffset = CGPoint(x: 0, y: 0)
                return view
            }

            if let pointAnnotation = annotation as? MKPointAnnotation {
                let identifier = "Marker"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation

                // Create start/end marker
                let size: CGFloat = 20
                let color: UIColor = pointAnnotation.title == "Start" ? .systemGreen : .systemRed
                let text = pointAnnotation.title == "Start" ? "S" : "E"

                UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
                let context = UIGraphicsGetCurrentContext()
                context?.setFillColor(color.cgColor)
                context?.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))

                let textStyle = NSMutableParagraphStyle()
                textStyle.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: textStyle
                ]
                (text as NSString).draw(in: CGRect(x: 0, y: 4, width: size, height: size), withAttributes: attrs)
                view.image = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()

                view.centerOffset = CGPoint(x: 0, y: -size/2)
                return view
            }

            return nil
        }
    }
}

class CoveragePointAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var isCovered: Bool = false

    init(coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()) {
        self.coordinate = coordinate
    }
}

// MARK: - Coverage Indicator

struct CoverageIndicator: View {
    let coverage: ConsolidatedStreet.CoverageResult

    var body: some View {
        HStack(spacing: 4) {
            if coverage.isFullyCovered {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if coverage.isPartiallyCovered {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundColor(.orange)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.gray)
            }
        }
        .font(.caption)
    }
}

#Preview {
    NavigationView {
        StreetDebugView(routes: [])
    }
}
