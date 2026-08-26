import Foundation

extension Notification.Name {
    static let runMapRouteAnalysisDidFinish = Notification.Name("runMapRouteAnalysisDidFinish")
}

/// Coalesces analysis requests and runs only the newest route library at utility priority.
/// The result is a small, precalculated snapshot that UI surfaces can open immediately.
final class RunMapBackgroundAnalysisService {
    static let shared = RunMapBackgroundAnalysisService()

    private let stateQueue = DispatchQueue(label: "runmap.analysis.state")
    private let analysisQueue = DispatchQueue(label: "runmap.analysis.worker", qos: .utility)
    private var pendingRoutes: [Route]?
    private var isRunning = false

    private init() {}

    func schedule(routes: [Route]) {
        guard !routes.isEmpty else { return }
        stateQueue.async {
            self.pendingRoutes = routes
            self.startNextIfNeeded()
        }
    }

    private func startNextIfNeeded() {
        guard !isRunning, let routes = pendingRoutes else { return }
        pendingRoutes = nil
        isRunning = true

        analysisQueue.async {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let snapshots = routes.map(RunMapRouteSnapshot.init(route:))
            let snapshot = RunMapRouteAnalysisEngine().makeSnapshot(routes: snapshots)
            do {
                try RunMapRouteAnalysisStore.appCache().save(snapshot)
                RunMapPerformanceMetrics.log(
                    "route_analysis_precompute",
                    seconds: CFAbsoluteTimeGetCurrent() - startedAt,
                    metadata: "routes=\(snapshot.routeCount) coordinates=\(snapshot.coordinateCount)"
                )
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .runMapRouteAnalysisDidFinish,
                        object: self,
                        userInfo: ["routeFingerprint": snapshot.routeFingerprint]
                    )
                }
            } catch {
                print("⚠️ Failed to save route analysis snapshot: \(error.localizedDescription)")
            }

            self.stateQueue.async {
                self.isRunning = false
                self.startNextIfNeeded()
            }
        }
    }
}

