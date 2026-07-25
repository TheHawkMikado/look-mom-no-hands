import Foundation
import Combine

/// One learned mapping: in a given app, a spoken target the assistant *couldn't*
/// resolve ("the send button") is pinned to the canonical AX label the user then
/// clicked ("Send"). We store the label, not pixels, so re-resolution goes back
/// through the normal AX matcher — resolution- and layout-independent.
struct LearnedElement: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let appBundleID: String
    let appName: String
    var phrase: String       // the spoken target that missed (normalized, lowercased)
    var label: String        // canonical AX label to click instead
    var role: String         // for display ("button", "textField", …)
    let createdAt: Date

    init(id: String = UUID().uuidString, appBundleID: String, appName: String,
         phrase: String, label: String, role: String, createdAt: Date = Date()) {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
        self.createdAt = createdAt
    }
}

/// Persistent memory of controls the user has taught by demonstration. Consulted
/// on a click miss before the vision fallback, so each hard-to-find control is
/// only ever taught once.
@MainActor
final class ElementMemoryStore: ObservableObject {
    @Published private(set) var elements: [LearnedElement] = []

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".elements")

    init(directory: URL) {
        url = directory.appendingPathComponent("elements.json")
        load()
    }

    /// Records (or replaces) the mapping for an app + spoken phrase.
    func remember(appBundleID: String, appName: String, phrase: String, label: String, role: String) {
        let learned = LearnedElement(appBundleID: appBundleID, appName: appName,
                                     phrase: phrase, label: label, role: role)
        guard !learned.phrase.isEmpty, !learned.label.isEmpty else { return }
        // One mapping per app+phrase — a fresh demonstration supersedes the old one.
        elements.removeAll { $0.appBundleID == appBundleID && $0.phrase == learned.phrase }
        elements.insert(learned, at: 0)
        persist()
    }

    /// The control learned for a spoken phrase in an app, if any. Exact phrase
    /// first, then a loose contains-match so "click the send button" still finds a
    /// mapping taught for "send".
    func lookup(appBundleID: String, phrase: String) -> LearnedElement? {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { return nil }
        let mine = elements.filter { $0.appBundleID == appBundleID }
        return mine.first { $0.phrase == p }
            ?? mine.first { p.contains($0.phrase) || $0.phrase.contains(p) }
    }

    func remove(_ id: String) {
        elements.removeAll { $0.id == id }
        persist()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LearnedElement].self, from: data) else { return }
        elements = decoded
    }

    private func persist() {
        let snapshot = elements
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
