import SwiftUI
import MapKit
import CoreLocation

// Berlin Streets List View
struct BerlinStreetsListView: View {
    @ObservedObject var achievementsManager: AchievementsManager
    let routes: [Route]

    @State private var streetCoverage: [(street: ConsolidatedStreet, coverage: ConsolidatedStreet.CoverageResult)] = []
    @State private var overallPercentage: Double = 0
    @State private var selectedStreet: ConsolidatedStreet?
    @State private var isTriggeringProcessing = false
    @State private var districtStats: [DistrictCoverageStats] = []
    @State private var stadtteilStats: [StadtteilCoverageStats] = []
    @State private var selectedDistrictFilter: String?
    @State private var selectedStadtteilFilter: String?
    @State private var showMissingStreetsMap: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView
            contentView
        }
        .padding()
        .task { await computeStreetCoverage() }
        .onReceive(achievementsManager.$streetCoverageByID) { _ in
            Task { await computeStreetCoverage() }
        }
        .sheet(item: Binding(
            get: { selectedStreet.map { IdentifiableStreet(street: $0) } },
            set: { selectedStreet = $0?.street }
        )) { identifiableStreet in
            StreetMapView(
                street: identifiableStreet.street,
                routes: routes,
                processor: achievementsManager.fastProcessor ?? FastStreetProcessor()
            )
        }
        .sheet(item: Binding(
            get: { selectedDistrictFilter.map { IdentifiableString(value: $0) } },
            set: { selectedDistrictFilter = $0?.value }
        )) { district in
            FilteredStreetListView(
                title: "Streets in \(district.value)",
                allStreets: streetCoverage,
                filterType: .district(district.value),
                routes: routes,
                processor: achievementsManager.fastProcessor ?? FastStreetProcessor()
            )
        }
        .sheet(item: Binding(
            get: { selectedStadtteilFilter.map { IdentifiableString(value: $0) } },
            set: { selectedStadtteilFilter = $0?.value }
        )) { stadtteil in
            FilteredStreetListView(
                title: "Streets in \(stadtteil.value)",
                allStreets: streetCoverage,
                filterType: .stadtteil(stadtteil.value),
                routes: routes,
                processor: achievementsManager.fastProcessor ?? FastStreetProcessor()
            )
        }
        .sheet(isPresented: $showMissingStreetsMap) {
            MissingStreetsMapView(
                allStreets: streetCoverage,
                routes: routes,
                processor: achievementsManager.fastProcessor ?? FastStreetProcessor()
            )
        }
    }

    struct IdentifiableString: Identifiable {
        let value: String
        var id: String { value }
    }

    // Data model for district coverage statistics
    struct DistrictCoverageStats: Identifiable {
        let id: String
        let district: String
        let totalStreets: Int
        let coveredStreets: Int
        let fullyCoveredStreets: Int
        let averageCoverage: Double

        var coveragePercentage: Double {
            totalStreets > 0 ? (Double(coveredStreets) / Double(totalStreets)) * 100.0 : 0.0
        }
    }

    // Data model for stadtteil coverage statistics
    struct StadtteilCoverageStats: Identifiable {
        let id: String
        let stadtteil: String
        let district: String
        let totalStreets: Int
        let coveredStreets: Int
        let fullyCoveredStreets: Int
        let averageCoverage: Double

        var coveragePercentage: Double {
            totalStreets > 0 ? (Double(coveredStreets) / Double(totalStreets)) * 100.0 : 0.0
        }
    }

    private func startProcessing() {
        guard !isTriggeringProcessing else { return }
        isTriggeringProcessing = true
        Task {
            // Clear the cache to force reprocessing
            await MainActor.run {
                achievementsManager.streetCoverageByID = [:]
                achievementsManager.processedRoutes = [:]
            }
            await achievementsManager.processStreetsFast(routes: routes)
            await MainActor.run { isTriggeringProcessing = false }
        }
    }
    private func computeStreetCoverage() async {
        if !achievementsManager.streetCoverageByID.isEmpty {
            let coverageDict = achievementsManager.streetCoverageByID
            let consolidated = achievementsManager.fastProcessor?.consolidatedStreets ?? []

            guard !consolidated.isEmpty else {
                await MainActor.run {
                    streetCoverage = []
                    overallPercentage = achievementsManager.overallStreetCoverage
                    districtStats = []
                    stadtteilStats = []
                }
                return
            }

            var entries: [(street: ConsolidatedStreet, coverage: ConsolidatedStreet.CoverageResult)] = []
            for street in consolidated {
                if let coverage = coverageDict[street.id] {
                    entries.append((street: street, coverage: coverage))
                }
            }

            // Compute district statistics
            var districtData: [String: (total: Int, covered: Int, fullyCovered: Int, totalCoverage: Double)] = [:]
            for entry in entries {
                let district = entry.street.district
                let current = districtData[district] ?? (total: 0, covered: 0, fullyCovered: 0, totalCoverage: 0.0)
                districtData[district] = (
                    total: current.total + 1,
                    covered: current.covered + (entry.coverage.percentage > 0 ? 1 : 0),
                    fullyCovered: current.fullyCovered + (entry.coverage.isFullyCovered ? 1 : 0),
                    totalCoverage: current.totalCoverage + entry.coverage.percentage
                )
            }

            let districtStatistics = districtData.map { district, data in
                DistrictCoverageStats(
                    id: district,
                    district: district,
                    totalStreets: data.total,
                    coveredStreets: data.covered,
                    fullyCoveredStreets: data.fullyCovered,
                    averageCoverage: data.total > 0 ? data.totalCoverage / Double(data.total) : 0.0
                )
            }.sorted { $0.averageCoverage > $1.averageCoverage }

            // Compute stadtteil statistics - get stadtteil from first segment of each street
            var stadtteilData: [String: (district: String, total: Int, covered: Int, fullyCovered: Int, totalCoverage: Double)] = [:]
            for entry in entries {
                if let firstSegment = entry.street.segments.first {
                    let stadtteil = firstSegment.stadtteil
                    let district = firstSegment.district
                    let current = stadtteilData[stadtteil] ?? (district: district, total: 0, covered: 0, fullyCovered: 0, totalCoverage: 0.0)
                    stadtteilData[stadtteil] = (
                        district: district,
                        total: current.total + 1,
                        covered: current.covered + (entry.coverage.percentage > 0 ? 1 : 0),
                        fullyCovered: current.fullyCovered + (entry.coverage.isFullyCovered ? 1 : 0),
                        totalCoverage: current.totalCoverage + entry.coverage.percentage
                    )
                }
            }

            let stadtteilStatistics = stadtteilData.map { stadtteil, data in
                StadtteilCoverageStats(
                    id: stadtteil,
                    stadtteil: stadtteil,
                    district: data.district,
                    totalStreets: data.total,
                    coveredStreets: data.covered,
                    fullyCoveredStreets: data.fullyCovered,
                    averageCoverage: data.total > 0 ? data.totalCoverage / Double(data.total) : 0.0
                )
            }.sorted { $0.averageCoverage > $1.averageCoverage }

            await MainActor.run {
                streetCoverage = entries.sorted { lhs, rhs in
                    if abs(lhs.coverage.percentage - rhs.coverage.percentage) < 0.1 {
                        return lhs.street.totalLength > rhs.street.totalLength
                    }
                    return lhs.coverage.percentage > rhs.coverage.percentage
                }
                overallPercentage = achievementsManager.overallStreetCoverage
                districtStats = districtStatistics
                stadtteilStats = stadtteilStatistics
            }
            return
        }
        await MainActor.run {
            streetCoverage = []
            overallPercentage = 0
            districtStats = []
            stadtteilStats = []
        }
    }

    private var headerView: some View {
        Text(String(format: "%.2f%% overall coverage", overallPercentage))
            .font(.system(size: 32, weight: .bold))
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var contentView: some View {
        if streetCoverage.isEmpty {
            processingPrompt
        } else {
            VStack(alignment: .leading, spacing: 12) {
                summaryLabel
                progressSection

                // Coverage map button
                Button {
                    showMissingStreetsMap = true
                } label: {
                    HStack {
                        Image(systemName: "map.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("View Coverage Map")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("See all street points colored by coverage")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                Text("Covered")
                                    .font(.caption2)
                            }
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                Text("Missing")
                                    .font(.caption2)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // District overview
                if !districtStats.isEmpty {
                    districtOverviewSection
                }

                // Stadtteil overview
                if !stadtteilStats.isEmpty {
                    stadtteilOverviewSection
                }

                streetList
            }
        }
    }

    private var processingPrompt: some View {
        VStack(spacing: 10) {
            Text("Street coverage not processed yet.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button(action: startProcessing) {
                if isTriggeringProcessing {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
                Text(isTriggeringProcessing ? "Processing…" : "Process Streets Now")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .disabled(isTriggeringProcessing)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryLabel: some View {
        let counts = streetCoverage.reduce(into: CoverageSummary()) { result, entry in
            if entry.coverage.percentage > 0 { result.covered += 1 }
            if entry.coverage.isFullyCovered { result.fullyCovered += 1 }
        }

        return Text("\(counts.covered) streets with coverage, \(counts.fullyCovered) fully covered")
            .font(.footnote)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var progressSection: some View {
        let value = achievementsManager.processingProgress
        let status = achievementsManager.processingStatus
        if !status.isEmpty && value < 1.0 {
            VStack(spacing: 6) {
                if let info = achievementsManager.currentStadtteilProgressInfo {
                    Text("Processing \(info.stadtteil)")
                        .font(.caption)
                }
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                Text(status)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private struct CoverageSummary {
        var covered: Int = 0
        var fullyCovered: Int = 0
    }

    private var districtOverviewSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(districtStats) { stat in
                    Button {
                        selectedDistrictFilter = stat.district
                    } label: {
                        VStack(spacing: 4) {
                            HStack {
                                Text(stat.district)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(String(format: "%.1f%%", stat.averageCoverage))
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(colorForCoverage(stat.averageCoverage))
                            }

                        HStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Image(systemName: "road.lanes")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(stat.totalStreets) streets")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text("\(stat.coveredStreets) covered")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if stat.fullyCoveredStreets > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                    Text("\(stat.fullyCoveredStreets) 100%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // Coverage bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(height: 6)
                                    .cornerRadius(3)

                                Rectangle()
                                    .fill(colorForCoverage(stat.averageCoverage))
                                    .frame(width: geometry.size.width * (stat.averageCoverage / 100.0), height: 6)
                                    .cornerRadius(3)
                            }
                        }
                        .frame(height: 6)
                        }
                        .padding(12)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Coverage by Bezirk (District)")
                    .font(.headline)
                Spacer()
                Text("(\(districtStats.count) districts)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var stadtteilOverviewSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(Array(stadtteilStats.prefix(10))) { stat in
                    Button {
                        selectedStadtteilFilter = stat.stadtteil
                    } label: {
                        VStack(spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stat.stadtteil)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text(stat.district)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1f%%", stat.averageCoverage))
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(colorForCoverage(stat.averageCoverage))
                            }

                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Image(systemName: "road.lanes")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(stat.totalStreets)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text("\(stat.coveredStreets)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if stat.fullyCoveredStreets > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                    Text("\(stat.fullyCoveredStreets)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // Coverage bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(height: 6)
                                    .cornerRadius(3)

                                Rectangle()
                                    .fill(colorForCoverage(stat.averageCoverage))
                                    .frame(width: geometry.size.width * (stat.averageCoverage / 100.0), height: 6)
                                    .cornerRadius(3)
                            }
                        }
                        .frame(height: 6)
                        }
                        .padding(12)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Coverage by Stadtteil (Neighborhood)")
                    .font(.headline)
                Spacer()
                Text("(top 10)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func colorForCoverage(_ percentage: Double) -> Color {
        if percentage >= 75 {
            return .green
        } else if percentage >= 50 {
            return .orange
        } else if percentage >= 25 {
            return .yellow
        } else {
            return .red
        }
    }

    private var streetList: some View {
        let limited = Array(streetCoverage.prefix(50))
        return DisclosureGroup(isExpanded: .constant(true)) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(limited, id: \.street.id) { item in
                    Button {
                        selectedStreet = item.street
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.street.name)
                                .font(.headline)
                            Text(String(format: "%.1f%% · %.0f m", item.coverage.percentage, item.street.totalLength))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Top 50 Streets by Coverage")
                    .font(.headline)
                Spacer()
                Text("(tap to view map)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// Filtered street list view
private struct FilteredStreetListView: View {
    let title: String
    let allStreets: [(street: ConsolidatedStreet, coverage: ConsolidatedStreet.CoverageResult)]
    let filterType: FilterType
    let routes: [Route]
    let processor: FastStreetProcessor

    @State private var sortOption: SortOption = .coverageDesc
    @State private var selectedStreet: ConsolidatedStreet?
    @State private var viewMode: ViewMode = .list
    @Environment(\.dismiss) var dismiss

    enum FilterType {
        case district(String)
        case stadtteil(String)
    }

    enum ViewMode: String, CaseIterable {
        case list = "List"
        case lines = "Lines"
        case dots = "Dots"
    }

    enum SortOption: String, CaseIterable {
        case coverageDesc = "Coverage (High to Low)"
        case coverageAsc = "Coverage (Low to High)"
        case nameAsc = "Name (A-Z)"
        case missing = "Missing Streets First"
        case completed = "Completed Streets First"
    }

    var filteredStreets: [(street: ConsolidatedStreet, coverage: ConsolidatedStreet.CoverageResult)] {
        let filtered: [(street: ConsolidatedStreet, coverage: ConsolidatedStreet.CoverageResult)]

        switch filterType {
        case .district(let district):
            filtered = allStreets.filter { $0.street.district == district }
        case .stadtteil(let stadtteil):
            filtered = allStreets.filter { $0.street.segments.first?.stadtteil == stadtteil }
        }

        switch sortOption {
        case .coverageDesc:
            return filtered.sorted { $0.coverage.percentage > $1.coverage.percentage }
        case .coverageAsc:
            return filtered.sorted { $0.coverage.percentage < $1.coverage.percentage }
        case .nameAsc:
            return filtered.sorted { $0.street.name < $1.street.name }
        case .missing:
            return filtered.sorted { ($0.coverage.percentage == 0 ? 0 : 1, $0.street.name) < ($1.coverage.percentage == 0 ? 0 : 1, $1.street.name) }
        case .completed:
            return filtered.sorted { ($0.coverage.isFullyCovered ? 0 : 1, -$0.coverage.percentage) < ($1.coverage.isFullyCovered ? 0 : 1, -$1.coverage.percentage) }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Stats bar
                let missing = filteredStreets.filter { $0.coverage.percentage == 0 }.count
                let partial = filteredStreets.filter { $0.coverage.percentage > 0 && !$0.coverage.isFullyCovered }.count
                let completed = filteredStreets.filter { $0.coverage.isFullyCovered }.count

                HStack(spacing: 16) {
                    VStack {
                        Text("\(missing)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                        Text("Missing")
                            .font(.caption)
                    }
                    VStack {
                        Text("\(partial)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                        Text("Partial")
                            .font(.caption)
                    }
                    VStack {
                        Text("\(completed)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Text("Complete")
                            .font(.caption)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))

                // View toggle and sort picker
                HStack {
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if viewMode == .list {
                        Spacer()
                        Picker("Sort", selection: $sortOption) {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .padding(.horizontal)

                // Content
                if viewMode == .lines {
                    MultiStreetMapView(
                        streets: filteredStreets,
                        routes: routes,
                        processor: processor,
                        showDots: false
                    )
                } else if viewMode == .dots {
                    MultiStreetMapView(
                        streets: filteredStreets,
                        routes: routes,
                        processor: processor,
                        showDots: true
                    )
                } else {
                    // Street list
                    ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredStreets, id: \.street.id) { item in
                            Button {
                                selectedStreet = item.street
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.street.name)
                                            .font(.headline)
                                        Text(String(format: "%.1f%% · %.0f m", item.coverage.percentage, item.street.totalLength))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if item.coverage.isFullyCovered {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else if item.coverage.percentage == 0 {
                                        Image(systemName: "circle")
                                            .foregroundColor(.red)
                                    } else {
                                        Image(systemName: "circle.lefthalf.filled")
                                            .foregroundColor(.orange)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { selectedStreet.map { IdentifiableStreet(street: $0) } },
            set: { selectedStreet = $0?.street }
        )) { identifiableStreet in
            StreetMapView(
                street: identifiableStreet.street,
                routes: routes,
                processor: processor
            )
        }
    }
}

// Multi-street map view showing all streets in a district/stadtteil
private struct MultiStreetMapView: UIViewRepresentable {
    let streets: [(street: ConsolidatedStreet, coverage: ConsolidatedStreet.CoverageResult)]
    let routes: [Route]
    let processor: FastStreetProcessor
    let showDots: Bool
    private let maxCoverageDotOverlays = 2_500

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator

        // Calculate region to fit all streets
        var allCoords: [CLLocationCoordinate2D] = []
        for item in streets {
            for segment in item.street.segments {
                allCoords.append(contentsOf: segment.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                })
            }
        }

        if let firstCoord = allCoords.first {
            let minLat = allCoords.map { $0.latitude }.min() ?? firstCoord.latitude
            let maxLat = allCoords.map { $0.latitude }.max() ?? firstCoord.latitude
            let minLon = allCoords.map { $0.longitude }.min() ?? firstCoord.longitude
            let maxLon = allCoords.map { $0.longitude }.max() ?? firstCoord.longitude

            let centerLat = (minLat + maxLat) / 2
            let centerLon = (minLon + maxLon) / 2
            let spanLat = (maxLat - minLat) * 1.3 // Add 30% padding
            let spanLon = (maxLon - minLon) * 1.3

            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: max(spanLat, 0.01), longitudeDelta: max(spanLon, 0.01))
            )
            mapView.setRegion(region, animated: false)
        }

        if showDots {
            // Build spatial index for point-by-point coverage checking
            DispatchQueue.global(qos: .userInitiated).async {
                let spatialIndex = SpatialIndex(metersPerCell: 40)

                // Add all route coordinates to index
                for route in routes {
                    let coords = route.coordinates.map { ($0.latitude, $0.longitude) }
                    spatialIndex.addRoute(coords)
                }

                let totalPointCount = streets.reduce(0) { total, item in
                    total + item.street.segments.reduce(0) { $0 + $1.coordinates.count }
                }
                let displayStride = max(1, Int(ceil(Double(totalPointCount) / Double(maxCoverageDotOverlays))))

                // Check each displayed point individually. Dense street datasets can have more
                // coordinates than MapKit can render smoothly as true-radius circles.
                var overlays: [ColoredCircle] = []
                var pointIndex = 0
                for item in streets {
                    for segment in item.street.segments {
                        for coord in segment.coordinates {
                            defer { pointIndex += 1 }
                            guard pointIndex % displayStride == 0 else { continue }

                            let result = spatialIndex.isNearRoute(lat: coord.lat, lon: coord.lon, thresholdMeters: 20)

                            let circle = ColoredCircle(
                                center: CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lon),
                                radius: 20.0
                            )

                            // Color based on actual point coverage
                            circle.color = result.isNear ? .green : .red

                            overlays.append(circle)
                        }
                    }
                }

                // Add to map on main thread
                DispatchQueue.main.async {
                    if !overlays.isEmpty {
                        mapView.addOverlays(overlays)
                    }
                    print("🗺️ Added \(overlays.count) sampled coverage dots to map from \(totalPointCount) street points")
                }
            }
        } else {
            // Add polylines for each street with color based on coverage
            for item in streets {
                for segment in item.street.segments {
                    let coords = segment.coordinates.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }

                    if !coords.isEmpty {
                        let polyline = ColoredPolyline(coordinates: coords, count: coords.count)

                        // Determine color based on coverage
                        if item.coverage.isFullyCovered {
                            polyline.color = .green
                        } else if item.coverage.percentage == 0 {
                            polyline.color = .red
                        } else {
                            polyline.color = .orange
                        }

                        polyline.streetName = item.street.name
                        polyline.coveragePercentage = item.coverage.percentage

                        mapView.addOverlay(polyline)
                    }
                }
            }
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Nothing to update
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? ColoredPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(polyline.color)
                renderer.lineWidth = 4
                renderer.alpha = 0.95  // Less transparent
                return renderer
            } else if let circle = overlay as? ColoredCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor(circle.color).withAlphaComponent(0.6)
                renderer.strokeColor = UIColor(circle.color).withAlphaComponent(0.95)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }

    // Custom polyline class to store color and metadata
    class ColoredPolyline: MKPolyline {
        var color: Color = .blue
        var streetName: String = ""
        var coveragePercentage: Double = 0
    }

    // Custom circle class to store color
    class ColoredCircle: MKCircle {
        var color: Color = .blue
    }
}

// Map view showing all street points in Berlin colored by coverage
private struct MissingStreetsMapView: View {
    let allStreets: [(street: ConsolidatedStreet, coverage: ConsolidatedStreet.CoverageResult)]
    let routes: [Route]
    let processor: FastStreetProcessor

    @Environment(\.dismiss) var dismiss
    @State private var isProcessing = true
    @State private var coveredPoints = 0
    @State private var uncoveredPoints = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Stats bar
                HStack(spacing: 16) {
                    VStack {
                        if isProcessing {
                            ProgressView()
                        } else {
                            Text("\(uncoveredPoints)")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.red)
                        }
                        Text("Red Points")
                            .font(.caption)
                    }
                    VStack {
                        if !isProcessing {
                            Text("\(coveredPoints)")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                        }
                        Text("Green Points")
                            .font(.caption)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))

                // Map
                CoveragePointsMapRepresentable(
                    streets: allStreets,
                    routes: routes,
                    processor: processor,
                    onStatsUpdate: { covered, uncovered in
                        coveredPoints = covered
                        uncoveredPoints = uncovered
                        isProcessing = false
                    }
                )
            }
            .navigationTitle("Coverage Map - All Points")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// UIKit map view that colors each point based on actual coverage
private struct CoveragePointsMapRepresentable: UIViewRepresentable {
    let streets: [(street: ConsolidatedStreet, coverage: ConsolidatedStreet.CoverageResult)]
    let routes: [Route]
    let processor: FastStreetProcessor
    let onStatsUpdate: (Int, Int) -> Void  // (covered, uncovered)
    private let maxPointOverlays = 4_000

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator

        // Set region to all of Berlin
        let berlinCenter = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)
        let region = MKCoordinateRegion(
            center: berlinCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4)
        )
        mapView.setRegion(region, animated: false)

        // Build spatial index from routes in background
        DispatchQueue.global(qos: .userInitiated).async {
            let spatialIndex = SpatialIndex(metersPerCell: 40)

            // Add all route coordinates to index
            for route in routes {
                let coords = route.coordinates.map { ($0.latitude, $0.longitude) }
                spatialIndex.addRoute(coords)
            }

            print("🗺️ Built spatial index for coverage map")

            // Only process streets with low coverage to reduce point count
            let streetsToShow = streets.filter { $0.coverage.percentage < 75 }
            print("🗺️ Showing \(streetsToShow.count) streets with <75% coverage (filtered from \(streets.count) total)")

            var coveredCount = 0
            var uncoveredCount = 0
            var redPoints: [CLLocationCoordinate2D] = []
            var greenPoints: [CLLocationCoordinate2D] = []

            let candidatePointCount = streetsToShow.reduce(0) { total, item in
                total + item.street.segments.reduce(0) { $0 + (($1.coordinates.count + 1) / 2) }
            }
            let displayStride = max(1, Int(ceil(Double(candidatePointCount) / Double(maxPointOverlays))))
            var sampledPointIndex = 0

            // Sample points for coverage, then further cap displayed overlays for MapKit.
            for item in streetsToShow {
                for segment in item.street.segments {
                    for (index, coord) in segment.coordinates.enumerated() {
                        // Sample every 2nd point for performance
                        guard index % 2 == 0 else { continue }

                        let result = spatialIndex.isNearRoute(lat: coord.lat, lon: coord.lon, thresholdMeters: 20)

                        if result.isNear {
                            if sampledPointIndex % displayStride == 0 {
                                greenPoints.append(CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lon))
                            }
                            coveredCount += 1
                        } else {
                            if sampledPointIndex % displayStride == 0 {
                                redPoints.append(CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lon))
                            }
                            uncoveredCount += 1
                        }
                        sampledPointIndex += 1
                    }
                }
            }

            print("🗺️ Processed \(coveredCount + uncoveredCount) sampled points: \(coveredCount) covered, \(uncoveredCount) uncovered; displaying \(redPoints.count + greenPoints.count)")

            // Add overlays to map in batches on main thread
            DispatchQueue.main.async {
                let redOverlays = redPoints.map { point -> ColoredCircle in
                    let circle = ColoredCircle(center: point, radius: 20.0)
                    circle.isCovered = false
                    return circle
                }
                let greenOverlays = greenPoints.map { point -> ColoredCircle in
                    let circle = ColoredCircle(center: point, radius: 20.0)
                    circle.isCovered = true
                    return circle
                }
                if !redOverlays.isEmpty {
                    mapView.addOverlays(redOverlays)
                }
                if !greenOverlays.isEmpty {
                    mapView.addOverlays(greenOverlays)
                }

                onStatsUpdate(coveredCount, uncoveredCount)
                print("🗺️ Finished adding \(redOverlays.count + greenOverlays.count) coverage overlays to map")
            }
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Nothing to update
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? ColoredCircle {
                let renderer = MKCircleRenderer(circle: circle)
                if circle.isCovered {
                    renderer.fillColor = UIColor.green.withAlphaComponent(0.5)
                    renderer.strokeColor = UIColor.green.withAlphaComponent(0.9)
                } else {
                    renderer.fillColor = UIColor.red.withAlphaComponent(0.5)
                    renderer.strokeColor = UIColor.red.withAlphaComponent(0.9)
                }
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }

    // Custom circle class to store coverage status
    class ColoredCircle: MKCircle {
        var isCovered: Bool = false
    }
}

// Helper to make Street identifiable for sheet
private struct IdentifiableStreet: Identifiable {
    let street: ConsolidatedStreet
    var id: String { street.id }
}

// Map view that shows true 20m radius circles using MKCircle overlays
private struct StreetCircleMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    @Binding var region: MKCoordinateRegion
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        
        // Add circle overlays for each coordinate with 20m radius
        for coordinate in coordinates {
            let circle = MKCircle(center: coordinate, radius: 20.0) // 20 meters
            mapView.addOverlay(circle)
        }
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.setRegion(region, animated: true)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: StreetCircleMapView
        
        init(_ parent: StreetCircleMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circleOverlay = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circleOverlay)
                renderer.fillColor = UIColor.blue.withAlphaComponent(0.3)
                renderer.strokeColor = UIColor.blue
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.region = mapView.region
        }
    }
}
