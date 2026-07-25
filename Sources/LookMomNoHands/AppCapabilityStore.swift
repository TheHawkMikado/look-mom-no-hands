import Foundation
import Combine

/// What the assistant has learned about one app's capabilities — its distilled
/// features and keyboard shortcuts, fetched from documentation via web search.
struct AppCapability: Codable, Identifiable, Sendable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    var appName: String
    var summary: String        // distilled shortcuts + notes
    var updatedAt: Date

    init(bundleID: String, appName: String, summary: String, updatedAt: Date = Date()) {
        self.bundleID = bundleID
        self.appName = appName
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updatedAt = updatedAt
    }
}

/// Persistent per-app capability notes pulled from documentation. Consulted when
/// building the planner prompt so the assistant knows what an app can do and how
/// to trigger it, instead of guessing. One fetch per app, cached to disk.
@MainActor
final class AppCapabilityStore: ObservableObject {
    @Published private(set) var capabilities: [AppCapability] = []

    /// Apps re-fetched no more often than this — docs change slowly.
    static let refreshInterval: TimeInterval = 60 * 60 * 24 * 30   // 30 days
    private static let maxSummaryChars = 1600

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".appcaps")

    init(directory: URL) {
        url = directory.appendingPathComponent("capabilities.json")
        load()
    }

    func capability(forBundleID bundleID: String) -> AppCapability? {
        capabilities.first { $0.bundleID == bundleID }
    }

    /// True when we have nothing recent for this app and should fetch.
    func needsFetch(bundleID: String, now: Date = Date()) -> Bool {
        guard let existing = capability(forBundleID: bundleID) else { return true }
        return now.timeIntervalSince(existing.updatedAt) > Self.refreshInterval
    }

    func store(bundleID: String, appName: String, summary: String) {
        let capped = String(summary.prefix(Self.maxSummaryChars))
        let entry = AppCapability(bundleID: bundleID, appName: appName, summary: capped)
        guard !entry.summary.isEmpty else { return }
        capabilities.removeAll { $0.bundleID == bundleID }
        capabilities.insert(entry, at: 0)
        persist()
    }

    /// The capability note for an app, formatted for the planner prompt.
    func promptText(forBundleID bundleID: String) -> String {
        guard let cap = capability(forBundleID: bundleID), !cap.summary.isEmpty else { return "" }
        return "What \(cap.appName) can do (use its shortcuts to act precisely):\n\(cap.summary)"
    }

    func remove(_ bundleID: String) {
        capabilities.removeAll { $0.bundleID == bundleID }
        persist()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AppCapability].self, from: data) else { return }
        capabilities = decoded
    }

    private func persist() {
        let snapshot = capabilities
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
