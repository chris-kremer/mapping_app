import SwiftUI
import MapKit

struct DistrictStreetListView: View {
    let districtName: String
    let stadtteilName: String?
    let streets: [ConsolidatedStreet]
    let routes: [Route]
    let processor: FastStreetProcessor

    @State private var sortOrder: SortOrder = .percentageDescending
    @State private var selectedStreet: ConsolidatedStreet?
    @State private var showingMap = false
    @State private var coverageCache: [String: ConsolidatedStreet.CoverageResult] = [:]

    enum SortOrder: String, CaseIterable {
        case nameAscending = "Name (A-Z)"
        case nameDescending = "Name (Z-A)"
        case percentageAscending = "Coverage (Low-High)"
        case percentageDescending = "Coverage (High-Low)"
        case lengthAscending = "Length (Short-Long)"
        case lengthDescending = "Length (Long-Short)"
    }

    var sortedStreets: [ConsolidatedStreet] {
        streets.sorted { street1, street2 in
            let coverage1 = coverageCache[street1.id]
            let coverage2 = coverageCache[street2.id]

            switch sortOrder {
            case .nameAscending:
                return street1.name < street2.name
            case .nameDescending:
                return street1.name > street2.name
            case .percentageAscending:
                return (coverage1?.percentage ?? 0) < (coverage2?.percentage ?? 0)
            case .percentageDescending:
                return (coverage1?.percentage ?? 0) > (coverage2?.percentage ?? 0)
            case .lengthAscending:
                return street1.totalLength < street2.totalLength
            case .lengthDescending:
                return street1.totalLength > street2.totalLength
            }
        }
    }

    var title: String {
        if let stadtteil = stadtteilName {
            return stadtteil
        }
        return districtName
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sort picker
            Picker("Sort by", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .padding()

            List {
                ForEach(sortedStreets) { street in
                    Button(action: {
                        selectedStreet = street
                        showingMap = true
                    }) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(street.name)
                                    .font(.body)
                                    .foregroundColor(.primary)

                                Spacer()

                                if let coverage = coverageCache[street.id] {
                                    CoverageIndicator(coverage: coverage)
                                }
                            }

                            HStack {
                                Text("\(street.segments.count) segments")
                                Text("•")
                                Text(String(format: "%.0fm", street.totalLength))

                                if let coverage = coverageCache[street.id] {
                                    Text("•")
                                    Text(String(format: "%.1f%%", coverage.percentage))
                                        .foregroundColor(coverageColor(for: coverage.percentage))
                                        .bold()
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $selectedStreet) { street in
            StreetMapView(
                street: street,
                routes: routes,
                processor: processor
            )
        }
        .task {
            // Calculate coverage for all streets
            await calculateCoverage()
        }
    }

    private func calculateCoverage() async {
        let streets = self.streets
        let routes = self.routes

        let coverageByStreet = await Task.detached(priority: .userInitiated) {
            RunMapPerformanceMetrics.measure(
                "district_street_coverage",
                metadata: "streets=\(streets.count) routes=\(routes.count)"
            ) {
                let checker = FastStreetChecker(routes: routes)
                var results: [String: ConsolidatedStreet.CoverageResult] = [:]
                results.reserveCapacity(streets.count)

                for street in streets {
                    results[street.id] = street.calculateCoverage(using: checker, densify: false)
                }

                return results
            }
        }.value

        await MainActor.run {
            coverageCache = coverageByStreet
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
}

// MARK: - Street Map View

struct StreetMapView: View {
    let street: ConsolidatedStreet
    let routes: [Route]
    let processor: FastStreetProcessor

    @State private var coveragePoints: [StreetCoveragePoint] = []
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.520, longitude: 13.405),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    @State private var isLoading = true
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading coverage data...")
                } else {
                    StreetCoverageMapView(
                        region: region,
                        coveragePoints: coveragePoints,
                        streetCoordinates: street.allCoordinates.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        }
                    )
                    .ignoresSafeArea()

                    // Stats bar
                    VStack(spacing: 8) {
                        let covered = coveragePoints.filter { $0.isCovered }.count
                        let total = coveragePoints.count
                        let percentage = total > 0 ? (Double(covered) / Double(total)) * 100 : 0

                        Text(street.name)
                            .font(.headline)

                        HStack {
                            Text("\(covered)/\(total) points covered")
                            Text("•")
                            Text(String(format: "%.1f%%", percentage))
                                .bold()
                                .foregroundColor(coverageColor(for: percentage))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                }
            }
            .navigationTitle("Street Coverage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            await loadCoverageData()
        }
    }

    private func loadCoverageData() async {
        let (_, points) = processor.calculateStreetCoverage(
            street: street,
            routes: routes,
            densify: false
        )

        // Calculate bounds for map region
        let coords = street.allCoordinates
        guard !coords.isEmpty else { return }

        let lats = coords.map { $0.lat }
        let lons = coords.map { $0.lon }

        let minLat = lats.min() ?? 52.5
        let maxLat = lats.max() ?? 52.5
        let minLon = lons.min() ?? 13.4
        let maxLon = lons.max() ?? 13.4

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.5,
            longitudeDelta: (maxLon - minLon) * 1.5
        )

        await MainActor.run {
            coveragePoints = points
            region = MKCoordinateRegion(center: center, span: span)
            isLoading = false
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
}

// MARK: - Street Coverage Map

struct StreetCoverageMapView: UIViewRepresentable {
    let region: MKCoordinateRegion
    let coveragePoints: [StreetCoveragePoint]
    let streetCoordinates: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let signature = MapSignature(region: region, coveragePoints: coveragePoints, streetCoordinates: streetCoordinates)
        if context.coordinator.regionSignature != signature.regionSignature {
            mapView.setRegion(region, animated: context.coordinator.regionSignature != nil)
            context.coordinator.regionSignature = signature.regionSignature
        }

        guard context.coordinator.contentSignature != signature.contentSignature else {
            return
        }
        context.coordinator.contentSignature = signature.contentSignature

        // Remove old overlays/annotations
        mapView.removeOverlays(context.coordinator.overlays)
        mapView.removeAnnotations(context.coordinator.annotations)
        context.coordinator.overlays.removeAll(keepingCapacity: true)
        context.coordinator.annotations.removeAll(keepingCapacity: true)

        // Add street polyline
        if streetCoordinates.count >= 2 {
            let polyline = MKPolyline(coordinates: streetCoordinates, count: streetCoordinates.count)
            mapView.addOverlay(polyline)
            context.coordinator.overlays.append(polyline)
        }

        // Add coverage point annotations
        var annotations: [StreetPointAnnotation] = []
        annotations.reserveCapacity(coveragePoints.count)
        for point in coveragePoints {
            let annotation = StreetPointAnnotation()
            annotation.coordinate = point.coordinate
            annotation.isCovered = point.isCovered
            annotations.append(annotation)
        }
        mapView.addAnnotations(annotations)
        context.coordinator.annotations = annotations
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var regionSignature: String?
        var contentSignature: String?
        var overlays: [MKOverlay] = []
        var annotations: [MKAnnotation] = []
        private var coveredPointImage: UIImage?
        private var uncoveredPointImage: UIImage?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemPurple.withAlphaComponent(0.7)
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pointAnnotation = annotation as? StreetPointAnnotation else {
                return nil
            }

            let identifier = "CoveragePoint"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation

            view.image = pointAnnotation.isCovered ? coveredImage() : uncoveredImage()

            return view
        }

        private func coveredImage() -> UIImage? {
            if coveredPointImage == nil {
                coveredPointImage = makePointImage(color: .systemGreen.withAlphaComponent(0.7))
            }
            return coveredPointImage
        }

        private func uncoveredImage() -> UIImage? {
            if uncoveredPointImage == nil {
                uncoveredPointImage = makePointImage(color: .systemRed.withAlphaComponent(0.7))
            }
            return uncoveredPointImage
        }

        private func makePointImage(color: UIColor) -> UIImage? {
            let size: CGFloat = 8
            UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
            let context = UIGraphicsGetCurrentContext()
            context?.setFillColor(color.cgColor)
            context?.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            context?.setStrokeColor(UIColor.white.cgColor)
            context?.setLineWidth(1)
            context?.strokeEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return image
        }
    }

    private struct MapSignature {
        let regionSignature: String
        let contentSignature: String

        init(region: MKCoordinateRegion, coveragePoints: [StreetCoveragePoint], streetCoordinates: [CLLocationCoordinate2D]) {
            regionSignature = [
                region.center.latitude,
                region.center.longitude,
                region.span.latitudeDelta,
                region.span.longitudeDelta
            ]
            .map { String(format: "%.6f", $0) }
            .joined(separator: "|")

            let coveredCount = coveragePoints.reduce(0) { $0 + ($1.isCovered ? 1 : 0) }
            let firstPoint = coveragePoints.first?.coordinate.signatureValue ?? "none"
            let lastPoint = coveragePoints.last?.coordinate.signatureValue ?? "none"
            let firstStreet = streetCoordinates.first?.signatureValue ?? "none"
            let lastStreet = streetCoordinates.last?.signatureValue ?? "none"
            contentSignature = "\(coveragePoints.count)|\(coveredCount)|\(firstPoint)|\(lastPoint)|\(streetCoordinates.count)|\(firstStreet)|\(lastStreet)"
        }
    }
}

class StreetPointAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var isCovered: Bool = false

    init(coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()) {
        self.coordinate = coordinate
    }
}

private extension CLLocationCoordinate2D {
    var signatureValue: String {
        String(format: "%.6f,%.6f", latitude, longitude)
    }
}
