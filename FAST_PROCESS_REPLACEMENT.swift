    // FAST VERSION - Process only new routes incrementally (runs in background)
    func processNewRoutesForStreets(routes: [Route]) async {
        print("🚀 FAST processNewRoutesForStreets called with \(routes.count) total routes")

        // Find routes that haven't been processed yet
        let newRoutes = routes.filter { route in
            let routeID = "\(route.date.timeIntervalSince1970)"
            return processedRoutes[routeID] == nil
        }

        print("📊 Found \(newRoutes.count) new routes to process (already processed: \(processedRoutes.count))")

        guard !newRoutes.isEmpty else {
            // All routes processed, just update achievement
            print("✅ All routes already processed, updating achievement...")
            await updateStreetsAchievementFast(routes: routes)
            return
        }

        // Initialize fast processor
        let processor = FastStreetProcessor()
        await MainActor.run {
            self.fastProcessor = processor
        }

        // Get districts that have data
        let allDistricts = BerlinDistricts.districts.map { $0.name }

        // Process all streets with fast spatial index
        await MainActor.run {
            processingStatus = "Processing \(newRoutes.count) new routes with fast spatial index..."
            processingProgress = 0
        }

        // Subscribe to processor updates
        let processorTask = Task {
            for await _ in Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().values {
                await MainActor.run {
                    if let proc = self.fastProcessor {
                        self.processingStatus = proc.processingStatus
                        self.processingProgress = proc.processingProgress
                        self.currentStadtteil = proc.currentStadtteil
                    }
                }
            }
        }

        // Run fast processing
        let consolidatedResult = await processor.processAllStreets(routes: routes, districts: allDistricts)

        processorTask.cancel()

        // Store results
        await MainActor.run {
            self.consolidatedStreets = consolidatedResult

            // Group by district and stadtteil
            var byDistrict: [String: [ConsolidatedStreet]] = [:]
            var byStadtteil: [String: [ConsolidatedStreet]] = [:]

            for street in consolidatedResult {
                byDistrict[street.district, default: []].append(street)
                if let stadtteil = street.segments.first?.stadtteil {
                    byStadtteil[stadtteil, default: []].append(street)
                }
            }

            self.streetsByDistrict = byDistrict
            self.streetsByStadtteil = byStadtteil

            // Mark routes as processed
            for route in newRoutes {
                let routeID = "\(route.date.timeIntervalSince1970)"
                // Create minimal coverage data for compatibility
                let data = RouteCoverageData(routeID: routeID, districts: [], coveredSegments: [])
                processedRoutes[routeID] = data
            }

            saveCachedData()
        }

        // Update achievement
        await updateStreetsAchievementFast(routes: routes)

        await MainActor.run {
            processingStatus = "Complete!"
            processingProgress = 1.0
        }

        print("✅ Fast processing complete!")
    }

    // Fast achievement update using consolidated streets
    func updateStreetsAchievementFast(routes: [Route]) async {
        guard !consolidatedStreets.isEmpty else {
            print("⚠️ No consolidated streets yet, trying old method...")
            await updateStreetsAchievementLegacy()
            return
        }

        guard let processor = fastProcessor else {
            print("⚠️ No fast processor, calculating...")
            let checker = FastStreetChecker(routes: routes)
            await calculateStreetCoverage(using: checker)
            return
        }

        await calculateStreetCoverage(using: FastStreetChecker(routes: routes))
    }

    private func calculateStreetCoverage(using checker: FastStreetChecker) async {
        var totalPoints = 0
        var coveredPoints = 0

        for street in consolidatedStreets {
            let coverage = street.calculateCoverage(using: checker, densify: false)
            totalPoints += coverage.totalPoints
            coveredPoints += coverage.coveredPoints
        }

        let percentage = totalPoints > 0 ? (Double(coveredPoints) / Double(totalPoints)) * 100.0 : 0.0

        print("📊 Overall coverage: \(String(format: "%.2f", percentage))% (\(coveredPoints)/\(totalPoints) points)")

        // Update stadtteile from covered streets
        let visitedStadtteile = Set(consolidatedStreets.compactMap { street -> String? in
            let coverage = street.calculateCoverage(using: checker, densify: false)
            guard coverage.percentage > 0, let stadtteil = street.segments.first?.stadtteil else {
                return nil
            }
            return stadtteil
        })

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

    // Legacy fallback for old format
    func updateStreetsAchievementLegacy() async {
        // Get unique districts from covered segments
        let coveredDistricts = Set(streetSegmentsCovered.map { $0.district })

        guard !coveredDistricts.isEmpty else {
            print("⚠️ No covered districts yet")
            return
        }

        // Load streets for covered districts if not in memory
        var allStreets = BerlinStreets.getStreets(forDistricts: Array(coveredDistricts))

        if allStreets.isEmpty {
            // Need to load from disk/GeoJSON
            await withCheckedContinuation { continuation in
                BerlinStreets.loadDistrictsInBackground(Array(coveredDistricts)) { loadedStreets in
                    allStreets = loadedStreets.values.flatMap { $0 }
                    continuation.resume()
                }
            }
        }

        guard !allStreets.isEmpty else {
            print("⚠️ Failed to load streets for districts: \(coveredDistricts)")
            return
        }

        print("📊 Calculating coverage for \(allStreets.count) street segments across \(coveredDistricts.count) districts")

        // Group streets by name (multiple segments of same street count as one)
        var streetsByName: [String: [(street: BerlinStreets.Street, coveredIndices: Set<Int>)]] = [:]

        for street in allStreets {
            // Get unique coordinate indices that are covered for this segment
            let coveredIndices = Set(streetSegmentsCovered
                .filter { $0.streetName == street.name && $0.district == street.district }
                .map { $0.startIndex })

            streetsByName[street.name, default: []].append((street: street, coveredIndices: coveredIndices))
        }

        // Calculate coverage per unique street name
        var totalCoordsAll = 0
        var totalCoveredAll = 0

        for (_, segments) in streetsByName {
            let totalCoords = segments.reduce(0) { $0 + $1.street.coordinates.count }
            let coveredCoords = segments.reduce(0) { $0 + $1.coveredIndices.count }

            totalCoordsAll += totalCoords
            totalCoveredAll += coveredCoords
        }

        // Calculate overall percentage
        let overallPercentage = totalCoordsAll > 0 ? (Double(totalCoveredAll) / Double(totalCoordsAll)) * 100.0 : 0

        print("📊 Overall coverage (legacy): \(String(format: "%.2f", overallPercentage))% of all street coordinates")

        await MainActor.run {
            let (streetsTier, streetsNext) = getTierAndNext(for: overallPercentage, tiers: [10, 20, 40, 80])
            updateAchievementTier(id: "berlin_streets", tier: streetsTier, currentProgress: overallPercentage, nextGoal: streetsNext)

            objectWillChange.send()
        }
    }
