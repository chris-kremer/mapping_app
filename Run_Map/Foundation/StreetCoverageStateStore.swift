import Foundation

struct StreetCoverageStateStore {
    enum StoreError: Error {
        case missingCachesDirectory
    }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func appCache(fileManager: FileManager = .default) throws -> StreetCoverageStateStore {
        guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw StoreError.missingCachesDirectory
        }

        return StreetCoverageStateStore(
            fileURL: cacheDirectory.appendingPathComponent("street_coverage_state_v1.json")
        )
    }

    func load() throws -> StreetCoverageState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(StreetCoverageState.self, from: data)
    }

    func save(_ state: StreetCoverageState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

