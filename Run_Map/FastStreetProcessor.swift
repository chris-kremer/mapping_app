import Foundation
import CoreLocation

// MARK: - Data Transfer Objects

struct StadtteilProgressInfo: Equatable {
    let stadtteil: String
    let district: String
    var totalStreets: Int
    var processedStreets: Int
    var coveredStreets: Int

    var processedPercentage: Double {
        guard totalStreets > 0 else { return 0 }
        return (Double(processedStreets) / Double(totalStreets)) * 100.0
    }

    var coveragePercentage: Double {
        guard totalStreets > 0 else { return 0 }
        return (Double(coveredStreets) / Double(totalStreets)) * 100.0
    }
}

struct DistrictCoverageStats: Codable, Identifiable {
    var id: String { district }

    let district: String
    let totalStreets: Int
    let coveredStreets: Int
    let fullyCoveredStreets: Int
    let coveredPoints: Int
    let totalPoints: Int

    var coveragePercentage: Double {
        guard totalPoints > 0 else { return 0 }
        return (Double(coveredPoints) / Double(totalPoints)) * 100.0
    }
}

struct StadtteilCoverageStats: Codable, Identifiable {
    var id: String { "\(district)|\(stadtteil)" }

    let district: String
    let stadtteil: String
    let totalStreets: Int
    let coveredStreets: Int
    let fullyCoveredStreets: Int
    let coveredPoints: Int
    let totalPoints: Int

    var coveragePercentage: Double {
        guard totalPoints > 0 else { return 0 }
        return (Double(coveredPoints) / Double(totalPoints)) * 100.0
    }
}

struct StreetProcessingOutput {
    let consolidatedStreets: [ConsolidatedStreet]
    let coverageByStreetID: [String: ConsolidatedStreet.CoverageResult]
    let districtStats: [DistrictCoverageStats]
    let stadtteilStats: [StadtteilCoverageStats]
    let overallCoveragePercentage: Double
    let totalStreetCount: Int
    let coveredStreetCount: Int
    let fullyCoveredStreetCount: Int
    let coveredPoints: Int
    let totalPoints: Int
}

// MARK: - Fast street processor using spatial indexing

class FastStreetProcessor: ObservableObject {
    @Published var processingStatus = ""
    @Published var processingProgress: Double = 0
    @Published var currentStadtteil = ""
    @Published var consolidatedStreets: [ConsolidatedStreet] = []

    // Live progress + summaries
    @Published var coverageByStreetID: [String: ConsolidatedStreet.CoverageResult] = [:]
    @Published var districtSummaries: [DistrictCoverageStats] = []
    @Published var stadtteilSummaries: [StadtteilCoverageStats] = []
    @Published var overallStreetCoverage: Double = 0
    @Published var totalStreetCount: Int = 0
    @Published var processedStreetCount: Int = 0
    @Published var coveredStreetCount: Int = 0
    @Published var fullyCoveredStreetCount: Int = 0
    @Published var currentStadtteilProgress: StadtteilProgressInfo?

    private var spatialIndex: FastStreetChecker?

    /// Process all streets with progress updates by Stadtteil
    func processAllStreets(routes: [Route], districts: [String]) async -> StreetProcessingOutput {
        print("🚀 FastStreetProcessor: Processing \(districts.count) districts")

        // Build spatial index once for ALL routes
        await MainActor.run {
            processingStatus = "Building spatial index from \(routes.count) routes..."
            processingProgress = 0
        }

        let checker = FastStreetChecker(routes: routes)
        self.spatialIndex = checker

        // Load all streets from specified districts
        await MainActor.run {
            processingStatus = "Loading street data..."
        }

        let allStreets = await BerlinStreets.getStreets(forDistricts: districts)
        print("📊 Loaded \(allStreets.count) street segments")

        // Consolidate streets by name
        let consolidated = StreetConsolidator.consolidate(streets: allStreets)
        print("📊 Consolidated into \(consolidated.count) unique streets")

        await MainActor.run {
            totalStreetCount = consolidated.count
            processedStreetCount = 0
            coveredStreetCount = 0
            fullyCoveredStreetCount = 0
            currentStadtteilProgress = nil
            coverageByStreetID = [:]
            districtSummaries = []
            stadtteilSummaries = []
            overallStreetCoverage = 0
        }

        // Group by Stadtteil for sequential processing
        var streetsByStadtteil: [String: [ConsolidatedStreet]] = [:]
        for street in consolidated {
            // Use first segment's stadtteil
            if let stadtteil = street.segments.first?.stadtteil {
                streetsByStadtteil[stadtteil, default: []].append(street)
            }
        }

        let stadtteile = streetsByStadtteil.keys.sorted()
        print("📊 Processing \(stadtteile.count) Stadtteile sequentially")

        var allProcessedStreets: [ConsolidatedStreet] = []
        var coverageByStreet: [String: ConsolidatedStreet.CoverageResult] = [:]
        var districtAggregates: [String: CoverageAggregate] = [:]
        var stadtteilAggregates: [String: CoverageAggregate] = [:]
        var totalCoveredPoints = 0
        var totalPoints = 0
        var processedGlobal = 0
        var coveredGlobal = 0
        var fullyCoveredGlobal = 0

        // Process each Stadtteil sequentially
        for (stadtteilIndex, stadtteil) in stadtteile.enumerated() {
            guard let streets = streetsByStadtteil[stadtteil], !streets.isEmpty else { continue }

            let district = streets.first?.district ?? ""
            var stadtteilProcessed = 0
            var stadtteilCovered = 0

            await MainActor.run {
                currentStadtteil = stadtteil
                currentStadtteilProgress = StadtteilProgressInfo(
                    stadtteil: stadtteil,
                    district: district,
                    totalStreets: streets.count,
                    processedStreets: 0,
                    coveredStreets: 0
                )
                processingStatus = "Processing \(stadtteil) (\(streets.count) streets)..."
                processingProgress = 0
            }

            print("🏘️ Processing Stadtteil \(stadtteilIndex + 1)/\(stadtteile.count): \(stadtteil) (\(streets.count) streets)")

            // Process streets in this Stadtteil
            for (streetIndex, street) in streets.enumerated() {
                // Calculate coverage
                let coverage = street.calculateCoverage(using: checker, densify: false)
                allProcessedStreets.append(street)
                coverageByStreet[street.id] = coverage

                totalPoints += coverage.totalPoints
                totalCoveredPoints += coverage.coveredPoints

                processedGlobal += 1
                stadtteilProcessed += 1

                if coverage.coveredPoints > 0 {
                    coveredGlobal += 1
                    stadtteilCovered += 1
                }
                if coverage.isFullyCovered {
                    fullyCoveredGlobal += 1
                }

                // Aggregate by district
                var districtAggregate = districtAggregates[district] ?? CoverageAggregate(district: district, stadtteil: nil)
                districtAggregate.totalPoints += coverage.totalPoints
                districtAggregate.coveredPoints += coverage.coveredPoints
                districtAggregate.streetCount += 1
                if coverage.coveredPoints > 0 {
                    districtAggregate.coveredStreetCount += 1
                }
                if coverage.isFullyCovered {
                    districtAggregate.fullyCoveredStreetCount += 1
                }
                districtAggregates[district] = districtAggregate

                // Aggregate by stadtteil
                let stadtteilKey = "\(district)|\(stadtteil)"
                var stadtteilAggregate = stadtteilAggregates[stadtteilKey] ?? CoverageAggregate(district: district, stadtteil: stadtteil)
                stadtteilAggregate.totalPoints += coverage.totalPoints
                stadtteilAggregate.coveredPoints += coverage.coveredPoints
                stadtteilAggregate.streetCount += 1
                if coverage.coveredPoints > 0 {
                    stadtteilAggregate.coveredStreetCount += 1
                }
                if coverage.isFullyCovered {
                    stadtteilAggregate.fullyCoveredStreetCount += 1
                }
                stadtteilAggregates[stadtteilKey] = stadtteilAggregate

                // Update progress
                let progress = Double(streetIndex + 1) / Double(streets.count)
                await MainActor.run {
                    processingProgress = progress
                    processingStatus = "\(stadtteil): \(streetIndex + 1)/\(streets.count) - \(street.name) (\(String(format: "%.1f", coverage.percentage))%)"
                    processedStreetCount = processedGlobal
                    coveredStreetCount = coveredGlobal
                    fullyCoveredStreetCount = fullyCoveredGlobal
                    currentStadtteilProgress = StadtteilProgressInfo(
                        stadtteil: stadtteil,
                        district: district,
                        totalStreets: streets.count,
                        processedStreets: stadtteilProcessed,
                        coveredStreets: stadtteilCovered
                    )
                }

                // Small delay to allow UI updates
                if streetIndex % 10 == 0 {
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            }

            // Mark Stadtteil complete (100%)
            await MainActor.run {
                processingProgress = 1.0
                processingStatus = "\(stadtteil): Complete ✓"
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms pause between Stadtteile
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

        let overallPct = totalPoints > 0 ? (Double(totalCoveredPoints) / Double(totalPoints)) * 100.0 : 0.0

        await MainActor.run {
            processingStatus = "Complete! Processed \(allProcessedStreets.count) streets"
            processingProgress = 1.0
            consolidatedStreets = allProcessedStreets
            coverageByStreetID = coverageByStreet
            districtSummaries = districtStats
            stadtteilSummaries = stadtteilStats
            overallStreetCoverage = overallPct
            totalStreetCount = allProcessedStreets.count
            processedStreetCount = allProcessedStreets.count
            coveredStreetCount = coveredGlobal
            fullyCoveredStreetCount = fullyCoveredGlobal
            currentStadtteilProgress = nil
        }

        return StreetProcessingOutput(
            consolidatedStreets: allProcessedStreets,
            coverageByStreetID: coverageByStreet,
            districtStats: districtStats,
            stadtteilStats: stadtteilStats,
            overallCoveragePercentage: overallPct,
            totalStreetCount: allProcessedStreets.count,
            coveredStreetCount: coveredGlobal,
            fullyCoveredStreetCount: fullyCoveredGlobal,
            coveredPoints: totalCoveredPoints,
            totalPoints: totalPoints
        )
    }

    /// Calculate coverage for a specific street (for detail view)
    func calculateStreetCoverage(
        street: ConsolidatedStreet,
        routes: [Route],
        densify: Bool = false
    ) -> (coverage: ConsolidatedStreet.CoverageResult, points: [StreetCoveragePoint]) {

        let checker = spatialIndex ?? FastStreetChecker(routes: routes)

        var allPoints: [StreetCoveragePoint] = []

        for segment in street.segments {
            let coords = densify
                ? GeometryDensification.densifyCoordinates(segment.coordinates, maxDistanceMeters: 5.0)
                : segment.coordinates

            let coverageDetails = checker.checkStreetCoverageDetailed(streetCoords: coords)

            for (index, (isCovered, closestDistance)) in coverageDetails.enumerated() {
                allPoints.append(StreetCoveragePoint(
                    coordinate: CLLocationCoordinate2D(latitude: coords[index].lat, longitude: coords[index].lon),
                    isCovered: isCovered,
                    closestDistance: closestDistance
                ))
            }
        }

        let coverage = street.calculateCoverage(using: checker, densify: densify)

        return (coverage, allPoints)
    }

    private struct CoverageAggregate {
        let district: String
        let stadtteil: String?
        var totalPoints: Int = 0
        var coveredPoints: Int = 0
        var streetCount: Int = 0
        var coveredStreetCount: Int = 0
        var fullyCoveredStreetCount: Int = 0
    }
}

/// Represents a point on a street with coverage info
struct StreetCoveragePoint {
    let coordinate: CLLocationCoordinate2D
    let isCovered: Bool
    let closestDistance: Double?
}
