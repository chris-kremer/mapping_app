import Foundation

enum RunMapPerformanceMetrics {
    @discardableResult
    static func measure<T>(_ name: String, metadata: String = "", _ block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let value = try block()
            log(name, seconds: CFAbsoluteTimeGetCurrent() - start, metadata: metadata)
            return value
        } catch {
            log(name, seconds: CFAbsoluteTimeGetCurrent() - start, metadata: "\(metadata) failed=\(error.localizedDescription)")
            throw error
        }
    }

    static func log(_ name: String, seconds: TimeInterval, metadata: String = "") {
        let suffix = metadata.isEmpty ? "" : " \(metadata)"
        print(String(format: "[perf] %@ %.3fs%@", name, seconds, suffix))
    }
}
