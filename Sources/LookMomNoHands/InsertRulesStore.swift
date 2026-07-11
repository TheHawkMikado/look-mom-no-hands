import Foundation
import Combine

/// How dictated text should be formatted before it's pasted (insert / push-to-
/// dictate). A general instruction that always applies, plus per-app instructions
/// (e.g. VS Code gets one set of rules, Slack another). Persisted to disk.
@MainActor
final class InsertRulesStore: ObservableObject {
    @Published var general: String {
        didSet { if !loading { persist() } }
    }
    @Published private(set) var appRules: [InsertRule] = []
    private var loading = false   // suppress the general didSet's persist during load

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".insert")

    init(directory: URL) {
        url = directory.appendingPathComponent("insert_rules.json")
        general = ""
        load()
    }

    func upsert(_ rule: InsertRule) {
        guard !rule.app.isEmpty else { return }
        if let i = appRules.firstIndex(where: { $0.id == rule.id }) { appRules[i] = rule }
        else { appRules.insert(rule, at: 0) }
        persist()
    }

    func remove(_ id: String) {
        appRules.removeAll { $0.id == id }
        persist()
    }

    /// The composed instruction for a target app: the general rule plus the first
    /// per-app rule that matches the target app's name. Matching is exact or by whole
    /// word so a rule keyed "Code" (VS Code → app name "Code") doesn't leak to "Xcode".
    func instructions(forApp appName: String?) -> String {
        let name = (appName ?? "").lowercased()
        let words = Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let appRule = appRules.first { rule in
            let key = rule.app.lowercased()
            guard !key.isEmpty else { return false }
            if name == key { return true }
            if key.contains(" ") { return name.contains(key) }   // multi-word key → substring
            return words.contains(key)                            // single word → whole-word match
        }?.instructions ?? ""
        return [general, appRule].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: Persistence

    private struct Saved: Codable { var general: String; var appRules: [InsertRule] }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        loading = true
        appRules = s.appRules   // assign first; general's didSet-persist is suppressed anyway
        general = s.general
        loading = false
    }

    private func persist() {
        let snapshot = Saved(general: general, appRules: appRules)
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
