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
        for street in streets {
            let coverage = street.calculateCoverage(
                using: FastStreetChecker(routes: routes),
                densify: false
            )

            await MainActor.run {
                coverageCache[street.id] = coverage
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
        .task {
            await loadCoverageData()
        }
    }

    private func loadCoverageData() async {
        let (coverage, points) = processor.calculateStreetCoverage(
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
        mapView.setRegion(region, animated: true)

        // Remove old overlays/annotations
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        // Add street polyline
        if streetCoordinates.count >= 2 {
            let polyline = MKPolyline(coordinates: streetCoordinates, count: streetCoordinates.count)
            mapView.addOverlay(polyline)
        }

        // Add coverage point annotations
        for point in coveragePoints {
            let annotation = StreetPointAnnotation()
            annotation.coordinate = point.coordinate
            annotation.isCovered = point.isCovered
            mapView.addAnnotation(annotation)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
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

            let size: CGFloat = 8
            let color: UIColor = pointAnnotation.isCovered
                ? .systemGreen.withAlphaComponent(0.7)
                : .systemRed.withAlphaComponent(0.7)

            UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
            let context = UIGraphicsGetCurrentContext()
            context?.setFillColor(color.cgColor)
            context?.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            context?.setStrokeColor(UIColor.white.cgColor)
            context?.setLineWidth(1)
            context?.strokeEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            view.image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            return view
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
