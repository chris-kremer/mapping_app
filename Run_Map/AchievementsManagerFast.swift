import Foundation
import SwiftUI
import Combine

/// Fast street processing extension for AchievementsManager
extension AchievementsManager {

    // FAST VERSION - Process routes using spatial index
    func processNewRoutesForStreetsFast(routes: [Route]) async {
        print("🚀 FAST processNewRoutesForStreets called with \(routes.count) total routes")

        let newRoutes = routes.filter { route in
            let routeID = "\(route.date.timeIntervalSince1970)"
            return processedRoutes[routeID] == nil
        }

        if newRoutes.isEmpty && !streetCoverageByID.isEmpty {
            print("ℹ️ No new routes detected and coverage cache available – skipping recomputation")
            await updateStreetsAchievementFast()
            await MainActor.run {
                processingStatus = "Streets up to date ✓"
                processingProgress = 1.0
                currentStadtteilProgressInfo = nil
                for route in routes {
                    let routeID = "\(route.date.timeIntervalSince1970)"
                    if processedRoutes[routeID] == nil {
                        processedRoutes[routeID] = RouteCoverageData(routeID: routeID, districts: [], coveredSegments: [])
                    }
                }
                saveCachedData()
            }
            return
        }

        // Initialize fast processor
        let processor = FastStreetProcessor()
        await MainActor.run {
            self.fastProcessor = processor
        }

        // Get all Berlin districts
        let allDistricts = BerlinDistricts.districts.map { $0.name }

        // Process all streets with fast spatial index
        await MainActor.run {
            processingStatus = "Initializing fast street processor..."
            processingProgress = 0
        }

        // Subscribe to processor updates
        let updateTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                await MainActor.run {
                    if let proc = self.fastProcessor {
                        self.processingStatus = proc.processingStatus
                        self.processingProgress = proc.processingProgress
                        self.currentStadtteil = proc.currentStadtteil
                        self.currentStadtteilProgressInfo = proc.currentStadtteilProgress
                        self.totalBerlinStreets = proc.totalStreetCount
                        self.processedBerlinStreets = proc.processedStreetCount
                        self.coveredBerlinStreets = proc.coveredStreetCount
                        self.fullyCoveredBerlinStreets = proc.fullyCoveredStreetCount
                        if proc.overallStreetCoverage > 0 {
                            self.overallStreetCoverage = proc.overallStreetCoverage
                        }
                    }
                }
            }
        }

        // Run fast processing
        let processingResult = await processor.processAllStreets(routes: routes, districts: allDistricts)

        updateTask.cancel()

        // Store results
        await MainActor.run {
            self.consolidatedStreets = processingResult.consolidatedStreets
            self.streetCoverageByID = processingResult.coverageByStreetID
            self.districtCoverageStats = processingResult.districtStats
            self.stadtteilCoverageStats = processingResult.stadtteilStats
            self.totalBerlinStreets = processingResult.totalStreetCount
            self.processedBerlinStreets = processingResult.totalStreetCount
            self.coveredBerlinStreets = processingResult.coveredStreetCount
            self.fullyCoveredBerlinStreets = processingResult.fullyCoveredStreetCount
            self.coveredBerlinPoints = processingResult.coveredPoints
            self.totalBerlinPoints = processingResult.totalPoints
            self.overallStreetCoverage = processingResult.overallCoveragePercentage
            self.currentStadtteilProgressInfo = nil
            self.streetCoverageLastUpdated = Date()

            // Group by district and stadtteil
            var byDistrict: [String: [ConsolidatedStreet]] = [:]
            var byStadtteil: [String: [ConsolidatedStreet]] = [:]

            for street in processingResult.consolidatedStreets {
                byDistrict[street.district, default: []].append(street)
                if let stadtteil = street.segments.first?.stadtteil {
                    byStadtteil[stadtteil, default: []].append(street)
                }
            }

            self.streetsByDistrict = byDistrict
            self.streetsByStadtteil = byStadtteil

            let visitedStadtteile = Set(processingResult.stadtteilStats.filter { $0.coveredStreets > 0 }.map { $0.stadtteil })
            self.berlinStadtteileVisitedCached = visitedStadtteile

            // Mark all routes as processed
            for route in routes {
                let routeID = "\(route.date.timeIntervalSince1970)"
                if processedRoutes[routeID] == nil {
                    let data = RouteCoverageData(routeID: routeID, districts: [], coveredSegments: [])
                    processedRoutes[routeID] = data
                }
            }

            saveCachedData()
        }

        // Update achievement
        await updateStreetsAchievementFast()

        await MainActor.run {
            processingStatus = "Complete! ✓"
            processingProgress = 1.0
        }

        print("✅ Fast processing complete!")
    }

    // Fast achievement update using consolidated streets
    func updateStreetsAchievementFast() async {
        guard !streetCoverageByID.isEmpty else {
            print("⚠️ No street coverage data yet")
            return
        }

        let visitedStadtteile = Set(stadtteilCoverageStats.filter { $0.coveredStreets > 0 }.map { $0.stadtteil })
        let percentage = overallStreetCoverage
        let coveredPoints = coveredBerlinPoints
        let totalPoints = totalBerlinPoints
        let coveredStreets = coveredBerlinStreets
        let totalStreets = totalBerlinStreets

        print("📊 Overall coverage: \(String(format: "%.2f", percentage))% (\(coveredPoints)/\(totalPoints) points)")
        print("📊 Covered streets: \(coveredStreets)/\(totalStreets)")

        await MainActor.run {
            berlinStadtteileVisitedCached = visitedStadtteile
            let stadtteilCount = visitedStadtteile.count
            let (stadtteilTier, stadtteilNext) = getCountTierAndNext(for: stadtteilCount, tiers: [10, 25, 50, 75])
            updateAchievementTier(id: "berlin_stadtteile", tier: stadtteilTier, currentProgress: Double(stadtteilCount), nextGoal: stadtteilNext)

            let (streetsTier, streetsNext) = getTierAndNext(for: percentage, tiers: [10, 20, 40, 80])
            updateAchievementTier(id: "berlin_streets", tier: streetsTier, currentProgress: percentage, nextGoal: streetsNext)

            objectWillChange.send()

            print("🛣️ Streets achievement updated: \(String(format: "%.2f", percentage))% overall coverage, \(stadtteilCount) stadtteile")
        }
    }
}
