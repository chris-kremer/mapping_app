import SwiftUI
import MapKit
import CoreLocation
import HealthKit

struct RoutePlannerView: View {
    let initialRegion: MKCoordinateRegion
    let routes: [Route]
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
    @State private var focusRequestID = UUID()
    @State private var fallbackConsolidatedStreets: [ConsolidatedStreet] = []
    @State private var savedPlanPreviews: [UUID: SavedPlanPreview] = [:]
    @State private var plannerMode: PlannerMode = .new
    @State private var isSimulationMode = false
    @State private var simulatedPlanIDs: Set<UUID> = []
    @State private var simulationStats = PlanSimulationStats.empty
    @State private var isComputingSimulation = false
    @State private var savedPlanSort: SavedPlanSortMode = .distance
    @State private var suggestionDistance: SmartRouteDistance = .fiveK
    @State private var suggestionShape: SmartRouteShape = .loop
    @State private var isGeneratingSuggestion = false
    @State private var suggestionMessage: String?

    private var waypointSignature: String {
        waypoints
            .map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" }
            .joined(separator: "|")
    }

    private var plannerConsolidatedStreets: [ConsolidatedStreet] {
        consolidatedStreets.isEmpty ? fallbackConsolidatedStreets : consolidatedStreets
    }

    private var plannerDataSignature: String {
        "\(plannerConsolidatedStreets.count):\(streetCoverageByID.count)"
    }

    private var selectedSavedPlan: SavedRoutePlan? {
        guard let selectedID = plannerMode.selectedPlanID else { return nil }
        return savedPlans.first { $0.id == selectedID }
    }

    private var canEditWaypoints: Bool {
        plannerMode.canEditWaypoints && !isSimulationMode
    }

    private var mapHintText: String {
        if isSimulationMode {
            return "Simulation mode"
        }
        return canEditWaypoints ? "Tap the map to add waypoints" : "Viewing saved plan"
    }

    private var simulatedPlans: [SavedRoutePlan] {
        savedPlans.filter { simulatedPlanIDs.contains($0.id) }
    }

    private var rankedSavedPlans: [SavedRoutePlan] {
        savedPlans.sorted { lhs, rhs in
            savedPlanSort.compare(lhs, rhs, previews: savedPlanPreviews)
        }
    }

    private var achievementPreviewItems: [RouteAchievementPreviewItem] {
        RouteAchievementPreviewBuilder.makeItems(
            plannedCoordinates: waypoints,
            plannedStats: stats,
            existingRoutes: routes,
            consolidatedStreets: plannerConsolidatedStreets,
            streetCoverageByID: streetCoverageByID
        )
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                PlannerMapView(
                    waypoints: waypoints,
                    initialRegion: initialRegion,
                    showCurrentStreetCoverage: showCurrentStreetCoverage,
                    consolidatedStreets: plannerConsolidatedStreets,
                    streetCoverageByID: streetCoverageByID,
                    focusRequestID: focusRequestID,
                    isSimulationMode: isSimulationMode,
                    simulationPlans: simulatedPlans.map(\.coordinates),
                    onAddWaypoint: { coordinate in
                        guard canEditWaypoints else { return }
                        waypoints.append(coordinate)
                    }
                )
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Text(mapHintText)
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
                        Button("New Plan", systemImage: "plus") {
                            startNewPlan()
                        }

                        if case .editing = plannerMode {
                            Button("Save Changes", systemImage: "checkmark") {
                                saveEditingPlan()
                            }
                            .disabled(waypoints.count < 2)
                        } else {
                            Button("Save Plan", systemImage: "square.and.arrow.down") {
                                planTitle = defaultPlanTitle
                                showSavePlanDialog = true
                            }
                            .disabled(waypoints.count < 2 || !canEditWaypoints)
                        }

                        if case .viewing = plannerMode {
                            Button("Edit Saved Plan", systemImage: "pencil") {
                                if let selectedSavedPlan {
                                    editSavedPlan(selectedSavedPlan)
                                }
                            }
                        }

                        Button("Undo Last", systemImage: "arrow.uturn.backward") {
                            if !waypoints.isEmpty {
                                waypoints.removeLast()
                            }
                        }
                        .disabled(waypoints.isEmpty || !canEditWaypoints)

                        Button("Clear", systemImage: "trash", role: .destructive) {
                            waypoints.removeAll()
                        }
                        .disabled(waypoints.isEmpty || !canEditWaypoints)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            savedPlans = SavedRoutePlanStore.load()
            simulatedPlanIDs.formIntersection(Set(savedPlans.map(\.id)))
            loadFallbackStreetDataIfNeeded()
            recalculateStats()
            recalculateSavedPlanPreviews()
            recalculateSimulationStats()
        }
        .onChange(of: waypointSignature) { _ in
            recalculateStats()
        }
        .onChange(of: plannerDataSignature) { _ in
            recalculateStats()
            recalculateSavedPlanPreviews()
            recalculateSimulationStats()
        }
        .onChange(of: isSimulationMode) { _ in
            focusRequestID = UUID()
            recalculateSimulationStats()
        }
        .onChange(of: simulatedPlanIDs) { _ in
            focusRequestID = UUID()
            recalculateSimulationStats()
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

                modeControlSection

                HStack(spacing: 12) {
                    Toggle(isOn: $showCurrentStreetCoverage) {
                        Label("Street Coverage", systemImage: "map")
                    }
                    .toggleStyle(.switch)
                    .font(.subheadline)
                }

                simulationSection
                smartRouteSuggestionSection

                if isSimulationMode {
                    EmptyView()
                } else if waypoints.count < 2 {
                    Text("Add at least two waypoints to preview route stats.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    statsSection(title: "Places", items: stats.placeLines)
                    statsSection(title: "Berlin", items: stats.berlinLines)
                    newStreetSection
                    achievementPreviewSection
                }

                savedPlansSection
            }
            .padding()
        }
        .frame(maxHeight: 340)
    }

    private var modeControlSection: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(modeTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(modeSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch plannerMode {
            case .new:
                Button {
                    planTitle = defaultPlanTitle
                    showSavePlanDialog = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(waypoints.count < 2)

            case .viewing:
                Button {
                    if let selectedSavedPlan {
                        editSavedPlan(selectedSavedPlan)
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderedProminent)

            case .editing:
                Button {
                    saveEditingPlan()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(waypoints.count < 2)
            }

            Button {
                startNewPlan()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("New Plan")
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var smartRouteSuggestionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Smart Suggestion", systemImage: "sparkles")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if isGeneratingSuggestion {
                    ProgressView()
                        .scaleEffect(0.85)
                }
            }

            Picker("Distance", selection: $suggestionDistance) {
                ForEach(SmartRouteDistance.allCases) { distance in
                    Text(distance.title).tag(distance)
                }
            }
            .pickerStyle(.segmented)

            Picker("Shape", selection: $suggestionShape) {
                ForEach(SmartRouteShape.allCases) { shape in
                    Text(shape.title).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            Button {
                generateSmartRouteSuggestion()
            } label: {
                Label("Find Route", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGeneratingSuggestion || plannerConsolidatedStreets.isEmpty)

            if let suggestionMessage {
                Text(suggestionMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var simulationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isSimulationMode) {
                Label("Simulation Mode", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .toggleStyle(.switch)
            .font(.subheadline)

            if isSimulationMode {
                if savedPlans.isEmpty {
                    Text("Save plans first to simulate route combinations.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    simulationStatsRow

                    ForEach(rankedSavedPlans) { plan in
                        Button {
                            toggleSimulatedPlan(plan)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: simulatedPlanIDs.contains(plan.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(simulatedPlanIDs.contains(plan.id) ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(savedPlanPreviewText(for: plan))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var simulationStatsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(simulationStats.selectedPlanCount) selected")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if isComputingSimulation {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            HStack(spacing: 10) {
                metricPill(
                    title: "Distance",
                    value: String(format: "%.1f km", simulationStats.distanceKm),
                    color: .purple
                )
                metricPill(
                    title: "Before",
                    value: String(format: "%.1f%%", simulationStats.coverageBeforePercent),
                    color: .orange
                )
                metricPill(
                    title: "After",
                    value: String(format: "%.1f%%", simulationStats.coverageAfterPercent),
                    color: .green
                )
            }

            Text("\(simulationStats.newStreetCount) projected new streets")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var modeTitle: String {
        switch plannerMode {
        case .new:
            return "New plan"
        case .viewing:
            return "Viewing saved plan"
        case .editing:
            return "Editing saved plan"
        }
    }

    private var modeSubtitle: String {
        switch plannerMode {
        case .new:
            return waypoints.isEmpty ? "Create a route from scratch" : "Unsaved route"
        case .viewing:
            return selectedSavedPlan?.title ?? "Saved route"
        case .editing:
            return selectedSavedPlan?.title ?? "Saved route"
        }
    }

    private var savedPlansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !savedPlans.isEmpty {
                Text("Saved Plans")
                    .font(.headline)

                Picker("Rank plans", selection: $savedPlanSort) {
                    ForEach(SavedPlanSortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(rankedSavedPlans.prefix(5)) { plan in
                    HStack(spacing: 10) {
                        Button {
                            viewSavedPlan(plan)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text(savedPlanPreviewText(for: plan))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editSavedPlan(plan)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)

                        Button(role: .destructive) {
                            deletePlan(plan)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(savedPlanRowBackground(for: plan))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var newStreetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projected Street Coverage")
                .font(.headline)

            if plannerConsolidatedStreets.isEmpty {
                Text("Street coverage data is still loading.")
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

    private var achievementPreviewSection: some View {
        let items = achievementPreviewItems

        return VStack(alignment: .leading, spacing: 8) {
            Text("Achievement Preview")
                .font(.headline)

            if items.isEmpty {
                Text("No achievement progress detected for this plan yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(items.prefix(6)) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.iconName)
                            .foregroundColor(item.kind.color)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(item.kind.label)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(item.kind.color)
                    }
                    .padding(10)
                    .background(item.kind.color.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if items.count > 6 {
                    Text("and \(items.count - 6) other progress updates")
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
        let streets = plannerConsolidatedStreets
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

    private func generateSmartRouteSuggestion() {
        let streets = plannerConsolidatedStreets
        let existingCoverage = streetCoverageByID
        let start = initialRegion.center
        let distanceKm = suggestionDistance.kilometers
        let shape = suggestionShape

        guard !streets.isEmpty else {
            suggestionMessage = "Street coverage data is still loading."
            return
        }

        isGeneratingSuggestion = true
        suggestionMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let suggestion = SmartRouteSuggestionEngine.generate(
                start: start,
                targetDistanceKm: distanceKm,
                shape: shape,
                consolidatedStreets: streets,
                existingCoverage: existingCoverage
            )

            DispatchQueue.main.async {
                isGeneratingSuggestion = false
                guard let suggestion else {
                    suggestionMessage = "No useful uncovered streets found nearby."
                    return
                }

                plannerMode = .new
                waypoints = suggestion.coordinates
                focusRequestID = UUID()
                suggestionMessage = "\(suggestion.newStreetCount) likely new streets over \(String(format: "%.1f", suggestion.distanceKm)) km"
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
        plannerMode = .viewing(plan.id)
        SavedRoutePlanStore.save(savedPlans)
        recalculateSavedPlanPreviews()
        recalculateSimulationStats()
    }

    private func deletePlan(_ plan: SavedRoutePlan) {
        savedPlans.removeAll { $0.id == plan.id }
        simulatedPlanIDs.remove(plan.id)
        if plannerMode.selectedPlanID == plan.id {
            startNewPlan()
        }
        SavedRoutePlanStore.save(savedPlans)
        savedPlanPreviews[plan.id] = nil
        recalculateSavedPlanPreviews()
        recalculateSimulationStats()
    }

    private func startNewPlan() {
        plannerMode = .new
        waypoints.removeAll()
        planTitle = ""
        focusRequestID = UUID()
    }

    private func viewSavedPlan(_ plan: SavedRoutePlan) {
        plannerMode = .viewing(plan.id)
        waypoints = plan.coordinates
        planTitle = plan.title
        focusRequestID = UUID()
    }

    private func editSavedPlan(_ plan: SavedRoutePlan) {
        plannerMode = .editing(plan.id)
        waypoints = plan.coordinates
        planTitle = plan.title
        focusRequestID = UUID()
    }

    private func saveEditingPlan() {
        guard case let .editing(planID) = plannerMode,
              let index = savedPlans.firstIndex(where: { $0.id == planID }),
              waypoints.count >= 2 else { return }

        let existing = savedPlans[index]
        savedPlans[index] = SavedRoutePlan(
            id: existing.id,
            title: existing.title,
            createdAt: existing.createdAt,
            coordinates: waypoints
        )
        SavedRoutePlanStore.save(savedPlans)
        plannerMode = .viewing(planID)
        recalculateSavedPlanPreviews()
        recalculateSimulationStats()
    }

    private func toggleSimulatedPlan(_ plan: SavedRoutePlan) {
        if simulatedPlanIDs.contains(plan.id) {
            simulatedPlanIDs.remove(plan.id)
        } else {
            simulatedPlanIDs.insert(plan.id)
        }
    }

    private func savedPlanRowBackground(for plan: SavedRoutePlan) -> Color {
        plannerMode.selectedPlanID == plan.id ? Color.blue.opacity(0.10) : Color.clear
    }

    private func savedPlanPreviewText(for plan: SavedRoutePlan) -> String {
        guard let preview = savedPlanPreviews[plan.id] else {
            return String(format: "%.1f km", PlannedRouteStats.totalDistanceKm(for: plan.coordinates))
        }
        let streetLabel = preview.newStreetCount == 1 ? "new street" : "new streets"
        let districtLabel = preview.newDistrictCount == 1 ? "district" : "districts"
        return String(
            format: "%.1f km, %d %@, %.2f streets/km, %d new %@",
            preview.distanceKm,
            preview.newStreetCount,
            streetLabel,
            preview.newStreetsPerKm,
            preview.newDistrictCount,
            districtLabel
        )
    }

    private func loadFallbackStreetDataIfNeeded() {
        guard consolidatedStreets.isEmpty, fallbackConsolidatedStreets.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let streets = RoutePlannerStreetData.loadFallbackConsolidatedStreets()
            DispatchQueue.main.async {
                guard fallbackConsolidatedStreets.isEmpty else { return }
                fallbackConsolidatedStreets = streets
            }
        }
    }

    private func recalculateSavedPlanPreviews() {
        let plans = savedPlans
        let streets = plannerConsolidatedStreets
        let existingCoverage = streetCoverageByID

        guard !plans.isEmpty else {
            savedPlanPreviews = [:]
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let previews = Dictionary(uniqueKeysWithValues: plans.map { plan in
                let stats = PlannedRouteStats.calculate(
                    coordinates: plan.coordinates,
                    consolidatedStreets: streets,
                    existingCoverage: existingCoverage
                )
                let newDistrictCount = Self.projectedNewDistrictCount(
                    coordinates: plan.coordinates,
                    consolidatedStreets: streets,
                    existingCoverage: existingCoverage
                )
                return (
                    plan.id,
                    SavedPlanPreview(
                        distanceKm: stats.distanceKm,
                        newStreetCount: stats.newStreetNames.count,
                        newDistrictCount: newDistrictCount
                    )
                )
            })

            DispatchQueue.main.async {
                savedPlanPreviews = previews
            }
        }
    }

    private static func projectedNewDistrictCount(
        coordinates: [CLLocationCoordinate2D],
        consolidatedStreets: [ConsolidatedStreet],
        existingCoverage: [String: ConsolidatedStreet.CoverageResult]
    ) -> Int {
        guard coordinates.count >= 2, !consolidatedStreets.isEmpty else { return 0 }
        let plannedRoute = Route(
            coordinates: PlannedRouteStats.sampledPath(from: coordinates, maxStepMeters: 25),
            date: Date(),
            workoutType: .walking,
            durationSec: 0
        )
        let checker = FastStreetChecker(routes: [plannedRoute])
        var districts = Set<String>()

        for street in consolidatedStreets {
            let wasCovered = (existingCoverage[street.id]?.coveredPoints ?? 0) > 0 ||
                (existingCoverage[street.id]?.percentage ?? 0) > 0
            guard !wasCovered else { continue }

            let plannedCoverage = street.calculateCoverage(using: checker, densify: false)
            if plannedCoverage.coveredPoints > 0 {
                districts.insert(street.district)
            }
        }

        return districts.count
    }

    private func recalculateSimulationStats() {
        let plans = simulatedPlans
        let streets = plannerConsolidatedStreets
        let existingCoverage = streetCoverageByID

        guard isSimulationMode, !plans.isEmpty else {
            simulationStats = .empty
            isComputingSimulation = false
            return
        }

        isComputingSimulation = true
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = PlanSimulationStats.calculate(
                plans: plans,
                consolidatedStreets: streets,
                existingCoverage: existingCoverage
            )

            DispatchQueue.main.async {
                simulationStats = stats
                isComputingSimulation = false
            }
        }
    }
}

private struct PlannerMapView: UIViewRepresentable {
    let waypoints: [CLLocationCoordinate2D]
    let initialRegion: MKCoordinateRegion
    let showCurrentStreetCoverage: Bool
    let consolidatedStreets: [ConsolidatedStreet]
    let streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]
    let focusRequestID: UUID
    let isSimulationMode: Bool
    let simulationPlans: [[CLLocationCoordinate2D]]
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
            projectedPlans: isSimulationMode ? simulationPlans : [waypoints],
            on: mapView
        )
        context.coordinator.render(
            waypoints: waypoints,
            isSimulationMode: isSimulationMode,
            simulationPlans: simulationPlans,
            on: mapView
        )
        context.coordinator.focusIfNeeded(
            waypoints: isSimulationMode ? simulationPlans.flatMap { $0 } : waypoints,
            focusRequestID: focusRequestID,
            on: mapView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PlannerMapView
        weak var mapView: MKMapView?
        private var renderedSignature = ""
        private var renderedCoverageSignature = ""
        private var handledFocusRequestID: UUID?
        private var overlays: [MKOverlay] = []
        private var coverageOverlays: [MKOverlay] = []
        private weak var coveredStreetOverlay: MKMultiPolyline?
        private weak var uncoveredStreetOverlay: MKMultiPolyline?
        private weak var plannedStreetOverlay: MKMultiPolyline?
        private weak var simulationPlanOverlay: MKMultiPolyline?
        private var coverageRenderGeneration = 0

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
            projectedPlans: [[CLLocationCoordinate2D]],
            on mapView: MKMapView
        ) {
            let coveredStreetCount = streetCoverageByID.values.filter { $0.coveredPoints > 0 || $0.percentage > 0 }.count
            let waypointSignature = projectedPlans
                .map { Self.coordinateSignature(for: $0) }
                .joined(separator: "||")
            let signature = showCurrentStreetCoverage
                ? "on:\(consolidatedStreets.count):\(streetCoverageByID.count):\(coveredStreetCount):\(waypointSignature)"
                : "off"
            guard signature != renderedCoverageSignature else { return }
            renderedCoverageSignature = signature
            coverageRenderGeneration += 1
            let generation = coverageRenderGeneration

            if !coverageOverlays.isEmpty {
                mapView.removeOverlays(coverageOverlays)
                coverageOverlays.removeAll(keepingCapacity: true)
            }
            coveredStreetOverlay = nil
            uncoveredStreetOverlay = nil
            plannedStreetOverlay = nil

            guard showCurrentStreetCoverage else { return }

            DispatchQueue.global(qos: .userInitiated).async {
                let streets = consolidatedStreets.isEmpty
                    ? Self.loadFallbackConsolidatedStreets()
                    : consolidatedStreets
                let groups = Self.makeStreetCoveragePolylineGroups(
                    streets: streets,
                    coverageByID: streetCoverageByID,
                    projectedPlans: projectedPlans
                )

                DispatchQueue.main.async {
                    guard generation == self.coverageRenderGeneration else { return }

                    var newOverlays: [MKOverlay] = []
                    if !groups.uncovered.isEmpty {
                        let overlay = MKMultiPolyline(groups.uncovered)
                        self.uncoveredStreetOverlay = overlay
                        newOverlays.append(overlay)
                    }

                    if !groups.covered.isEmpty {
                        let overlay = MKMultiPolyline(groups.covered)
                        self.coveredStreetOverlay = overlay
                        newOverlays.append(overlay)
                    }

                    if !groups.planned.isEmpty {
                        let overlay = MKMultiPolyline(groups.planned)
                        self.plannedStreetOverlay = overlay
                        newOverlays.append(overlay)
                    }

                    guard !newOverlays.isEmpty else { return }
                    self.coverageOverlays = newOverlays
                    for overlay in newOverlays {
                        mapView.addOverlay(overlay, level: .aboveRoads)
                    }
                }
            }
        }

        private static func loadFallbackConsolidatedStreets() -> [ConsolidatedStreet] {
            RoutePlannerStreetData.loadFallbackConsolidatedStreets()
        }

        private static func makeStreetCoveragePolylineGroups(
            streets: [ConsolidatedStreet],
            coverageByID: [String: ConsolidatedStreet.CoverageResult],
            projectedPlans: [[CLLocationCoordinate2D]]
        ) -> (covered: [MKPolyline], uncovered: [MKPolyline], planned: [MKPolyline]) {
            var covered: [MKPolyline] = []
            var uncovered: [MKPolyline] = []
            var planned: [MKPolyline] = []
            covered.reserveCapacity(coverageByID.count)

            let checker = makeRouteChecker(for: projectedPlans)

            for street in streets {
                let coverage = coverageByID[street.id]
                let hasAnyHit = (coverage?.coveredPoints ?? 0) > 0 || (coverage?.percentage ?? 0) > 0
                let wouldBeHit = checker.map { street.calculateCoverage(using: $0, densify: false).coveredPoints > 0 } ?? false

                for segment in street.segments {
                    let coordinates = segment.clCoordinates
                    guard coordinates.count >= 2 else { continue }

                    let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                    if wouldBeHit {
                        planned.append(polyline)
                    } else if hasAnyHit {
                        covered.append(polyline)
                    } else {
                        uncovered.append(polyline)
                    }
                }
            }

            return (covered, uncovered, planned)
        }

        private static func makeRouteChecker(for plans: [[CLLocationCoordinate2D]]) -> FastStreetChecker? {
            let routes = plans.compactMap { waypoints -> Route? in
                guard waypoints.count >= 2 else { return nil }
                return Route(
                    coordinates: PlannedRouteStats.sampledPath(from: waypoints, maxStepMeters: 25),
                    date: Date(),
                    workoutType: .walking,
                    durationSec: 0
                )
            }
            guard !routes.isEmpty else { return nil }
            return FastStreetChecker(routes: routes)
        }

        private static func coordinateSignature(for coordinates: [CLLocationCoordinate2D]) -> String {
            coordinates
                .map { "\(String(format: "%.5f", $0.latitude)),\(String(format: "%.5f", $0.longitude))" }
                .joined(separator: "|")
        }

        func render(
            waypoints: [CLLocationCoordinate2D],
            isSimulationMode: Bool,
            simulationPlans: [[CLLocationCoordinate2D]],
            on mapView: MKMapView
        ) {
            let signature = isSimulationMode
                ? "sim:" + simulationPlans.map { Self.coordinateSignature(for: $0) }.joined(separator: "||")
                : "plan:" + Self.coordinateSignature(for: waypoints)
            guard signature != renderedSignature else { return }
            renderedSignature = signature

            if !overlays.isEmpty {
                mapView.removeOverlays(overlays)
                overlays.removeAll(keepingCapacity: true)
            }
            simulationPlanOverlay = nil

            if isSimulationMode {
                let polylines = simulationPlans.compactMap { coordinates -> MKPolyline? in
                    guard coordinates.count >= 2 else { return nil }
                    return MKPolyline(coordinates: coordinates, count: coordinates.count)
                }
                guard !polylines.isEmpty else { return }

                let overlay = MKMultiPolyline(polylines)
                simulationPlanOverlay = overlay
                overlays.append(overlay)
                mapView.addOverlay(overlay)
                return
            }

            if waypoints.count >= 2 {
                let polyline = PlannedRoutePolyline(coordinates: waypoints, count: waypoints.count)
                overlays.append(polyline)
                mapView.addOverlay(polyline)
            }
        }

        func focusIfNeeded(waypoints: [CLLocationCoordinate2D], focusRequestID: UUID, on mapView: MKMapView) {
            guard handledFocusRequestID != focusRequestID else { return }
            handledFocusRequestID = focusRequestID
            guard waypoints.count >= 2 else { return }

            let region = coordinateRegion(for: waypoints)
            mapView.setRegion(region, animated: true)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multiPolyline = overlay as? MKMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
                if multiPolyline === coveredStreetOverlay {
                    renderer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.82)
                    renderer.lineWidth = 2.7
                    renderer.alpha = 0.95
                } else if multiPolyline === uncoveredStreetOverlay {
                    renderer.strokeColor = UIColor.systemRed.withAlphaComponent(0.58)
                    renderer.lineWidth = 2.1
                    renderer.alpha = 0.95
                } else if multiPolyline === plannedStreetOverlay {
                    renderer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.9)
                    renderer.lineWidth = 3.5
                    renderer.alpha = 0.98
                } else if multiPolyline === simulationPlanOverlay {
                    renderer.strokeColor = UIColor.systemPurple.withAlphaComponent(0.9)
                    renderer.lineWidth = 5
                    renderer.alpha = 0.95
                } else {
                    renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.45)
                    renderer.lineWidth = 2
                }
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
    }
}

private final class PlannedRoutePolyline: MKPolyline {}

private enum PlannerMode: Equatable {
    case new
    case viewing(UUID)
    case editing(UUID)

    var selectedPlanID: UUID? {
        switch self {
        case .new:
            return nil
        case let .viewing(id), let .editing(id):
            return id
        }
    }

    var canEditWaypoints: Bool {
        switch self {
        case .new, .editing:
            return true
        case .viewing:
            return false
        }
    }
}

private enum SavedPlanSortMode: String, CaseIterable, Identifiable {
    case distance
    case streetsPerKm
    case newDistricts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distance:
            return "Distance"
        case .streetsPerKm:
            return "Streets/km"
        case .newDistricts:
            return "Districts"
        }
    }

    func compare(
        _ lhs: SavedRoutePlan,
        _ rhs: SavedRoutePlan,
        previews: [UUID: SavedPlanPreview]
    ) -> Bool {
        let lhsPreview = previews[lhs.id]
        let rhsPreview = previews[rhs.id]

        switch self {
        case .distance:
            return value(lhsPreview?.distanceKm, fallback: PlannedRouteStats.totalDistanceKm(for: lhs.coordinates)) >
                value(rhsPreview?.distanceKm, fallback: PlannedRouteStats.totalDistanceKm(for: rhs.coordinates))
        case .streetsPerKm:
            return value(lhsPreview?.newStreetsPerKm, fallback: 0) >
                value(rhsPreview?.newStreetsPerKm, fallback: 0)
        case .newDistricts:
            return value(Double(lhsPreview?.newDistrictCount ?? 0), fallback: 0) >
                value(Double(rhsPreview?.newDistrictCount ?? 0), fallback: 0)
        }
    }

    private func value(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return value
    }
}

private enum SmartRouteDistance: String, CaseIterable, Identifiable {
    case fiveK
    case tenK

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveK:
            return "5k"
        case .tenK:
            return "10k"
        }
    }

    var kilometers: Double {
        switch self {
        case .fiveK:
            return 5
        case .tenK:
            return 10
        }
    }
}

private enum SmartRouteShape: String, CaseIterable, Identifiable {
    case loop
    case oneWay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop:
            return "Loop"
        case .oneWay:
            return "One-way"
        }
    }
}

private struct SmartRouteSuggestion {
    let coordinates: [CLLocationCoordinate2D]
    let distanceKm: Double
    let newStreetCount: Int
}

private struct CoordinateBounds {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLat &&
            coordinate.latitude <= maxLat &&
            coordinate.longitude >= minLon &&
            coordinate.longitude <= maxLon
    }

    func intersects(_ other: CoordinateBounds) -> Bool {
        minLat <= other.maxLat &&
            maxLat >= other.minLat &&
            minLon <= other.maxLon &&
            maxLon >= other.minLon
    }

    func expanded(byMeters meters: CLLocationDistance) -> CoordinateBounds {
        let centerLat = (minLat + maxLat) / 2
        let latDelta = meters / 111_000
        let lonDelta = meters / max(1, 111_000 * cos(centerLat * .pi / 180))
        return CoordinateBounds(
            minLat: minLat - latDelta,
            maxLat: maxLat + latDelta,
            minLon: minLon - lonDelta,
            maxLon: maxLon + lonDelta
        )
    }
}

private struct RouteAchievementPreviewItem: Identifiable {
    enum Kind {
        case unlock
        case progress

        var label: String {
            switch self {
            case .unlock:
                return "Unlock"
            case .progress:
                return "Progress"
            }
        }

        var color: Color {
            switch self {
            case .unlock:
                return .green
            case .progress:
                return .blue
            }
        }
    }

    let id = UUID()
    let title: String
    let detail: String
    let iconName: String
    let kind: Kind
}

private enum RouteAchievementPreviewBuilder {
    static func makeItems(
        plannedCoordinates: [CLLocationCoordinate2D],
        plannedStats: PlannedRouteStats,
        existingRoutes: [Route],
        consolidatedStreets: [ConsolidatedStreet],
        streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]
    ) -> [RouteAchievementPreviewItem] {
        guard plannedCoordinates.count >= 2, plannedStats.distanceKm > 0 else { return [] }

        var items: [RouteAchievementPreviewItem] = []
        appendDistanceItems(to: &items, plannedStats: plannedStats, existingRoutes: existingRoutes)
        appendLocationItems(to: &items, plannedStats: plannedStats, existingRoutes: existingRoutes)
        appendBerlinItems(
            to: &items,
            plannedStats: plannedStats,
            existingRoutes: existingRoutes,
            consolidatedStreets: consolidatedStreets,
            streetCoverageByID: streetCoverageByID
        )
        appendMauerwegItem(to: &items, plannedCoordinates: plannedCoordinates, existingRoutes: existingRoutes)

        return items
    }

    private static func appendDistanceItems(
        to items: inout [RouteAchievementPreviewItem],
        plannedStats: PlannedRouteStats,
        existingRoutes: [Route]
    ) {
        let currentWalkingKm = existingRoutes
            .filter { $0.workoutType == .walking }
            .map(\.distanceKm)
            .reduce(0, +)
        let afterWalkingKm = currentWalkingKm + plannedStats.distanceKm
        appendThresholdItem(
            to: &items,
            title: "Walking Distance",
            iconName: "figure.walk",
            before: currentWalkingKm,
            after: afterWalkingKm,
            thresholds: [500, 1000, 2500, 10000],
            unit: "km"
        )

        let today = Calendar.current.startOfDay(for: Date())
        let todayDistance = existingRoutes
            .filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
            .map(\.distanceKm)
            .reduce(0, +)
        appendThresholdItem(
            to: &items,
            title: "Daily Distance",
            iconName: "calendar",
            before: todayDistance,
            after: todayDistance + plannedStats.distanceKm,
            thresholds: [10, 15, 20, 30],
            unit: "km"
        )
    }

    private static func appendLocationItems(
        to items: inout [RouteAchievementPreviewItem],
        plannedStats: PlannedRouteStats,
        existingRoutes: [Route]
    ) {
        let existing = locationSets(for: existingRoutes)
        let countryAfter = existing.countries.union(plannedStats.countries)
        appendCountItem(
            to: &items,
            title: "Countries Visited",
            iconName: "globe",
            before: existing.countries.count,
            after: countryAfter.count,
            thresholds: [1, 10, 25, 50]
        )

        let cityAfter = existing.cities.union(plannedStats.cities)
        appendCountItem(
            to: &items,
            title: "Cities Visited",
            iconName: "building.2",
            before: existing.cities.count,
            after: cityAfter.count,
            thresholds: [10, 50, 100, 500]
        )
    }

    private static func appendBerlinItems(
        to items: inout [RouteAchievementPreviewItem],
        plannedStats: PlannedRouteStats,
        existingRoutes: [Route],
        consolidatedStreets: [ConsolidatedStreet],
        streetCoverageByID: [String: ConsolidatedStreet.CoverageResult]
    ) {
        let existingDistricts = Set(existingRoutes.flatMap { route in
            route.coordinates.compactMap { BerlinDistricts.getDistrict(lat: $0.latitude, lon: $0.longitude) }
        })
        appendCountItem(
            to: &items,
            title: "Berlin Districts",
            iconName: "building.columns.fill",
            before: existingDistricts.count,
            after: existingDistricts.union(plannedStats.districts).count,
            thresholds: [3, 6, 9, 12]
        )

        let existingStadtteile = Set(BerlinStreets.getStadtteileFromCoordinates(existingRoutes.flatMap(\.coordinates)))
        appendCountItem(
            to: &items,
            title: "Berlin Stadtteile",
            iconName: "house.fill",
            before: existingStadtteile.count,
            after: existingStadtteile.union(plannedStats.stadtteile).count,
            thresholds: [10, 25, 50, 75]
        )

        let totalStreetCount = max(consolidatedStreets.count, 1)
        let coveredStreetCount = streetCoverageByID.values.filter { $0.coveredPoints > 0 || $0.percentage > 0 }.count
        let beforePercent = Double(coveredStreetCount) / Double(totalStreetCount) * 100
        let afterPercent = Double(coveredStreetCount + plannedStats.newStreetNames.count) / Double(totalStreetCount) * 100
        appendThresholdItem(
            to: &items,
            title: "Berlin Streets",
            iconName: "map.fill",
            before: beforePercent,
            after: afterPercent,
            thresholds: [10, 20, 40, 80],
            unit: "%"
        )
    }

    private static func appendMauerwegItem(
        to items: inout [RouteAchievementPreviewItem],
        plannedCoordinates: [CLLocationCoordinate2D],
        existingRoutes: [Route]
    ) {
        let mauerwegCoordinates = BerlinMauerweg.coordinates()
        guard !mauerwegCoordinates.isEmpty else { return }

        let before = mauerwegCoverage(routes: existingRoutes, mauerwegCoordinates: mauerwegCoordinates)
        let plannedRoute = Route(
            coordinates: PlannedRouteStats.sampledPath(from: plannedCoordinates, maxStepMeters: 25),
            date: Date(),
            workoutType: .walking,
            durationSec: 0
        )
        let after = mauerwegCoverage(routes: existingRoutes + [plannedRoute], mauerwegCoordinates: mauerwegCoordinates)

        appendThresholdItem(
            to: &items,
            title: "Mauerweg",
            iconName: "figure.walk.motion",
            before: before,
            after: after,
            thresholds: [0.1, 10, 50, 100],
            unit: "%"
        )
    }

    private static func appendThresholdItem(
        to items: inout [RouteAchievementPreviewItem],
        title: String,
        iconName: String,
        before: Double,
        after: Double,
        thresholds: [Double],
        unit: String
    ) {
        guard after > before else { return }
        let beforeTier = tierIndex(for: before, thresholds: thresholds)
        let afterTier = tierIndex(for: after, thresholds: thresholds)
        let kind: RouteAchievementPreviewItem.Kind = afterTier > beforeTier ? .unlock : .progress
        let detail = "\(format(before, unit: unit)) -> \(format(after, unit: unit))"

        items.append(RouteAchievementPreviewItem(
            title: title,
            detail: detail,
            iconName: iconName,
            kind: kind
        ))
    }

    private static func appendCountItem(
        to items: inout [RouteAchievementPreviewItem],
        title: String,
        iconName: String,
        before: Int,
        after: Int,
        thresholds: [Int]
    ) {
        guard after > before else { return }
        let beforeTier = tierIndex(for: Double(before), thresholds: thresholds.map(Double.init))
        let afterTier = tierIndex(for: Double(after), thresholds: thresholds.map(Double.init))
        let kind: RouteAchievementPreviewItem.Kind = afterTier > beforeTier ? .unlock : .progress

        items.append(RouteAchievementPreviewItem(
            title: title,
            detail: "\(before) -> \(after)",
            iconName: iconName,
            kind: kind
        ))
    }

    private static func tierIndex(for value: Double, thresholds: [Double]) -> Int {
        thresholds.reduce(0) { partialResult, threshold in
            value >= threshold ? partialResult + 1 : partialResult
        }
    }

    private static func format(_ value: Double, unit: String) -> String {
        if unit == "%" {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.1f %@", value, unit)
    }

    private static func locationSets(for routes: [Route]) -> (countries: Set<String>, cities: Set<String>) {
        var countries = Set<String>()
        var cities = Set<String>()

        for route in routes {
            for coordinate in sampledCoordinates(route.coordinates, maxCount: 10) {
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

    private static func sampledCoordinates(_ coordinates: [CLLocationCoordinate2D], maxCount: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxCount else { return coordinates }
        let step = max(1, coordinates.count / maxCount)
        return stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
    }

    private static func mauerwegCoverage(
        routes: [Route],
        mauerwegCoordinates: [BerlinStreets.SimpleCoordinate]
    ) -> Double {
        guard !routes.isEmpty else { return 0 }
        let checker = FastStreetChecker(routes: routes)
        let coveredPointCount = checker.checkStreetCoverage(streetCoords: mauerwegCoordinates).filter { $0 }.count
        return (Double(coveredPointCount) / Double(mauerwegCoordinates.count)) * 100.0
    }
}

private enum SmartRouteSuggestionEngine {
    private struct Candidate {
        let streetID: String
        let streetName: String
        let district: String
        let coordinate: CLLocationCoordinate2D
        let distanceFromStart: CLLocationDistance
        let bearingSector: Int
        let distanceBand: Int
        let localOpportunityScore: Int
    }

    static func generate(
        start: CLLocationCoordinate2D,
        targetDistanceKm: Double,
        shape: SmartRouteShape,
        consolidatedStreets: [ConsolidatedStreet],
        existingCoverage: [String: ConsolidatedStreet.CoverageResult]
    ) -> SmartRouteSuggestion? {
        let candidates = uncoveredCandidates(
            start: start,
            targetDistanceKm: targetDistanceKm,
            shape: shape,
            consolidatedStreets: consolidatedStreets,
            existingCoverage: existingCoverage
        )
        guard !candidates.isEmpty else { return nil }

        let targetMeters = targetDistanceKm * 1_000
        let maxMeters = targetMeters * 1.22
        var waypoints = [start]
        var current = start
        var usedStreetIDs = Set<String>()
        let routeCandidates = focusedCandidates(candidates, shape: shape)

        for candidate in routeCandidates {
            guard !usedStreetIDs.contains(candidate.streetID) else { continue }

            let addedMeters = distanceMeters(from: current, to: candidate.coordinate)
            let returnMeters = shape == .loop ? distanceMeters(from: candidate.coordinate, to: start) : 0
            let currentMeters = routeDistanceMeters(waypoints)
            guard addedMeters >= 80 || waypoints.count == 1 else { continue }

            if currentMeters + addedMeters + returnMeters > maxMeters {
                continue
            }

            waypoints.append(candidate.coordinate)
            usedStreetIDs.insert(candidate.streetID)
            current = candidate.coordinate

            if currentMeters + addedMeters + returnMeters >= targetMeters * 0.86 {
                break
            }
        }

        if shape == .loop, waypoints.count > 1 {
            waypoints.append(start)
        }

        guard waypoints.count >= 2, !usedStreetIDs.isEmpty else { return nil }
        return SmartRouteSuggestion(
            coordinates: waypoints,
            distanceKm: PlannedRouteStats.totalDistanceKm(for: waypoints),
            newStreetCount: usedStreetIDs.count
        )
    }

    private static func uncoveredCandidates(
        start: CLLocationCoordinate2D,
        targetDistanceKm: Double,
        shape: SmartRouteShape,
        consolidatedStreets: [ConsolidatedStreet],
        existingCoverage: [String: ConsolidatedStreet.CoverageResult]
    ) -> [Candidate] {
        let startLocation = CLLocation(latitude: start.latitude, longitude: start.longitude)
        let targetMeters = targetDistanceKm * 1_000
        let searchRadius = shape == .loop
            ? max(2_200, min(5_200, targetMeters * 0.55))
            : max(3_000, min(10_000, targetMeters * 1.05))
        let bounds = coordinateBounds(around: start, radiusMeters: searchRadius)

        let rawCandidates = consolidatedStreets.compactMap { street -> Candidate? in
            let wasCovered = (existingCoverage[street.id]?.coveredPoints ?? 0) > 0 ||
                (existingCoverage[street.id]?.percentage ?? 0) > 0
            guard !wasCovered, let coordinate = representativeCoordinate(for: street) else { return nil }
            guard bounds.contains(coordinate) else { return nil }

            let distance = startLocation.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard distance <= searchRadius else { return nil }
            let bearingSector = bearingSector(from: start, to: coordinate)
            let distanceBand = Int(distance / 650)

            return Candidate(
                streetID: street.id,
                streetName: street.name,
                district: street.district,
                coordinate: coordinate,
                distanceFromStart: distance,
                bearingSector: bearingSector,
                distanceBand: distanceBand,
                localOpportunityScore: 0
            )
        }

        let opportunityByBucket = Dictionary(grouping: rawCandidates) { candidate in
            "\(candidate.bearingSector):\(candidate.distanceBand)"
        }
        .mapValues { $0.count }

        return rawCandidates.map { candidate in
            let neighboringScore = (-1...1).reduce(0) { total, sectorOffset in
                let sector = (candidate.bearingSector + sectorOffset + 12) % 12
                return total + (-1...1).reduce(0) { bandTotal, bandOffset in
                    bandTotal + opportunityByBucket["\(sector):\(candidate.distanceBand + bandOffset)", default: 0]
                }
            }

            return Candidate(
                streetID: candidate.streetID,
                streetName: candidate.streetName,
                district: candidate.district,
                coordinate: candidate.coordinate,
                distanceFromStart: candidate.distanceFromStart,
                bearingSector: candidate.bearingSector,
                distanceBand: candidate.distanceBand,
                localOpportunityScore: neighboringScore
            )
        }
        .sorted {
            if $0.localOpportunityScore != $1.localOpportunityScore {
                return $0.localOpportunityScore > $1.localOpportunityScore
            }
            if abs($0.distanceFromStart - $1.distanceFromStart) > 180 {
                return $0.distanceFromStart > $1.distanceFromStart
            }
            return $0.streetName.localizedCaseInsensitiveCompare($1.streetName) == .orderedAscending
        }
        .prefix(180)
        .map { $0 }
    }

    private static func focusedCandidates(_ candidates: [Candidate], shape: SmartRouteShape) -> [Candidate] {
        guard shape == .loop else {
            return candidates.sorted {
                if $0.localOpportunityScore != $1.localOpportunityScore {
                    return $0.localOpportunityScore > $1.localOpportunityScore
                }
                return $0.distanceFromStart < $1.distanceFromStart
            }
        }

        let bestSector = Dictionary(grouping: candidates, by: { $0.bearingSector })
            .map { sector, values in
                (sector: sector, score: values.prefix(18).reduce(0) { $0 + $1.localOpportunityScore })
            }
            .max { $0.score < $1.score }?
            .sector

        guard let bestSector else { return candidates }

        let focused = candidates
            .filter { candidate in
                let clockwiseDistance = abs(candidate.bearingSector - bestSector)
                let wrappedDistance = min(clockwiseDistance, 12 - clockwiseDistance)
                return wrappedDistance <= 1
            }
            .sorted {
                if $0.distanceBand != $1.distanceBand {
                    return $0.distanceBand < $1.distanceBand
                }
                if $0.localOpportunityScore != $1.localOpportunityScore {
                    return $0.localOpportunityScore > $1.localOpportunityScore
                }
                return $0.streetName.localizedCaseInsensitiveCompare($1.streetName) == .orderedAscending
            }

        return focused.isEmpty ? candidates : focused
    }

    private static func representativeCoordinate(for street: ConsolidatedStreet) -> CLLocationCoordinate2D? {
        let coordinates = street.allCoordinates
        guard !coordinates.isEmpty else { return nil }
        let coordinate = coordinates[coordinates.count / 2]
        return CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lon)
    }

    private static func routeDistanceMeters(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count >= 2 else { return 0 }
        var total: CLLocationDistance = 0
        for index in 0..<(coordinates.count - 1) {
            total += distanceMeters(from: coordinates[index], to: coordinates[index + 1])
        }
        return total
    }

    private static func distanceMeters(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    private static func bearingSector(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Int {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let bearing = atan2(y, x) * 180 / .pi
        let normalized = bearing >= 0 ? bearing : bearing + 360
        return min(11, Int(normalized / 30))
    }

    private static func coordinateBounds(
        around coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) -> CoordinateBounds {
        let latDelta = radiusMeters / 111_000
        let lonDelta = radiusMeters / max(1, 111_000 * cos(coordinate.latitude * .pi / 180))
        return CoordinateBounds(
            minLat: coordinate.latitude - latDelta,
            maxLat: coordinate.latitude + latDelta,
            minLon: coordinate.longitude - lonDelta,
            maxLon: coordinate.longitude + lonDelta
        )
    }
}

private struct SavedPlanPreview {
    let distanceKm: Double
    let newStreetCount: Int
    let newDistrictCount: Int

    var newStreetsPerKm: Double {
        guard distanceKm > 0 else { return 0 }
        return Double(newStreetCount) / distanceKm
    }
}

private struct PlanSimulationStats {
    let selectedPlanCount: Int
    let distanceKm: Double
    let coverageBeforePercent: Double
    let coverageAfterPercent: Double
    let newStreetCount: Int

    static let empty = PlanSimulationStats(
        selectedPlanCount: 0,
        distanceKm: 0,
        coverageBeforePercent: 0,
        coverageAfterPercent: 0,
        newStreetCount: 0
    )

    static func calculate(
        plans: [SavedRoutePlan],
        consolidatedStreets: [ConsolidatedStreet],
        existingCoverage: [String: ConsolidatedStreet.CoverageResult]
    ) -> PlanSimulationStats {
        let totalStreets = consolidatedStreets.count
        let currentlyCoveredIDs = Set(existingCoverage.compactMap { streetID, coverage in
            (coverage.coveredPoints > 0 || coverage.percentage > 0) ? streetID : nil
        })
        let distanceKm = plans
            .map { PlannedRouteStats.totalDistanceKm(for: $0.coordinates) }
            .reduce(0, +)

        guard totalStreets > 0, !plans.isEmpty else {
            return PlanSimulationStats(
                selectedPlanCount: plans.count,
                distanceKm: distanceKm,
                coverageBeforePercent: totalStreets > 0 ? Double(currentlyCoveredIDs.count) / Double(totalStreets) * 100 : 0,
                coverageAfterPercent: totalStreets > 0 ? Double(currentlyCoveredIDs.count) / Double(totalStreets) * 100 : 0,
                newStreetCount: 0
            )
        }

        let routes = plans.compactMap { plan -> Route? in
            let coordinates = plan.coordinates
            guard coordinates.count >= 2 else { return nil }
            return Route(
                coordinates: PlannedRouteStats.sampledPath(from: coordinates, maxStepMeters: 25),
                date: Date(),
                workoutType: .walking,
                durationSec: 0
            )
        }
        guard !routes.isEmpty else {
            let percent = Double(currentlyCoveredIDs.count) / Double(totalStreets) * 100
            return PlanSimulationStats(
                selectedPlanCount: plans.count,
                distanceKm: distanceKm,
                coverageBeforePercent: percent,
                coverageAfterPercent: percent,
                newStreetCount: 0
            )
        }

        let checker = FastStreetChecker(routes: routes)
        var projectedCoveredIDs = currentlyCoveredIDs

        for street in consolidatedStreets where !currentlyCoveredIDs.contains(street.id) {
            let plannedCoverage = street.calculateCoverage(using: checker, densify: false)
            if plannedCoverage.coveredPoints > 0 {
                projectedCoveredIDs.insert(street.id)
            }
        }

        return PlanSimulationStats(
            selectedPlanCount: plans.count,
            distanceKm: distanceKm,
            coverageBeforePercent: Double(currentlyCoveredIDs.count) / Double(totalStreets) * 100,
            coverageAfterPercent: Double(projectedCoveredIDs.count) / Double(totalStreets) * 100,
            newStreetCount: projectedCoveredIDs.count - currentlyCoveredIDs.count
        )
    }
}

private enum RoutePlannerStreetData {
    static func loadFallbackConsolidatedStreets() -> [ConsolidatedStreet] {
        let streets = BerlinStreets.getStreets(forDistricts: BerlinDistricts.districts.map(\.name))
        guard !streets.isEmpty else { return [] }
        return StreetConsolidator.consolidate(streets: streets)
    }
}

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
        guard let bounds = coordinateBounds(for: coordinates)?.expanded(byMeters: 90) else { return [] }

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
            guard let streetBounds = coordinateBounds(for: street.allCoordinates),
                  bounds.intersects(streetBounds) else { continue }

            let plannedCoverage = street.calculateCoverage(using: checker, densify: false)
            if plannedCoverage.coveredPoints > 0 {
                names.insert(street.name)
            }
        }

        return sorted(names)
    }

    private static func coordinateBounds(for coordinates: [CLLocationCoordinate2D]) -> CoordinateBounds? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude

        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        return CoordinateBounds(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
    }

    private static func coordinateBounds(for coordinates: [BerlinStreets.SimpleCoordinate]) -> CoordinateBounds? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.lat
        var maxLat = first.lat
        var minLon = first.lon
        var maxLon = first.lon

        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.lat)
            maxLat = max(maxLat, coordinate.lat)
            minLon = min(minLon, coordinate.lon)
            maxLon = max(maxLon, coordinate.lon)
        }

        return CoordinateBounds(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
    }

    static func sampledPath(from coordinates: [CLLocationCoordinate2D], maxStepMeters: Double) -> [CLLocationCoordinate2D] {
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

    static func totalDistanceKm(for coordinates: [CLLocationCoordinate2D]) -> Double {
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
