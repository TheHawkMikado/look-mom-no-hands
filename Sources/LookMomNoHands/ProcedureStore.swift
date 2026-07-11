import Foundation
import Combine

/// The user's ever-growing library of taught procedures ("here's how I do X").
/// Persisted to disk. When a command matches a procedure's triggers, its steps are
/// fed to the planner as the recipe to follow — so the assistant does the task the
/// user's way and gets more capable over time.
@MainActor
final class ProcedureStore: ObservableObject {
    @Published private(set) var procedures: [Procedure] = []

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".procedures")

    init(directory: URL) {
        url = directory.appendingPathComponent("procedures.json")
        load()
    }

    /// Saves a taught procedure. Deduped on name (case-insensitive) so re-teaching
    /// updates in place rather than piling up duplicates.
    func learn(_ p: TaughtProcedure) {
        guard p.isValid else { return }
        upsert(Procedure(name: p.name, triggers: p.triggers, steps: p.steps))
    }

    /// Empty steps are allowed (a draft being edited in the dashboard); an empty
    /// name is not. Deduped on name so a re-teach updates in place.
    func upsert(_ p: Procedure) {
        guard !p.name.isEmpty else { return }
        procedures.removeAll { $0.name.lowercased() == p.name.lowercased() && $0.id != p.id }
        if let i = procedures.firstIndex(where: { $0.id == p.id }) { procedures[i] = p }
        else { procedures.insert(p, at: 0) }
        persist()
    }

    func remove(_ id: String) {
        procedures.removeAll { $0.id == id }
        persist()
    }

    // Common words that must not, on their own, match a procedure to a command.
    private static let stopwords: Set<String> = [
        "new", "the", "and", "for", "open", "tab", "app", "file", "window", "this",
        "that", "with", "from", "into", "get", "got", "let", "you", "now", "use",
        "all", "can", "how", "what", "then", "here", "want", "please", "session"
    ]
    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) })
    }

    /// Procedures that genuinely match a command: a trigger phrase appears in the
    /// command (strong), OR they share ≥2 significant (non-stopword) words. Requiring
    /// more than one common word stops a lone "new"/"the" pulling in unrelated recipes.
    func relevant(to command: String, limit: Int = 3) -> [Procedure] {
        let cmd = command.lowercased()
        let cmdTokens = Self.tokens(cmd)
        guard !cmdTokens.isEmpty else { return [] }
        return procedures.compactMap { p -> (Procedure, Int)? in
            if p.triggers.contains(where: { !$0.isEmpty && cmd.contains($0.lowercased()) }) { return (p, 100) }
            let shared = Self.tokens(([p.name] + p.triggers).joined(separator: " ")).intersection(cmdTokens).count
            return shared >= 2 ? (p, shared) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map { $0.0 }
    }

    /// A prompt block listing the procedures relevant to a command (steps truncated
    /// so one long recipe can't bloat the latency-critical planner prompt).
    func promptContext(for command: String) -> String {
        let hits = relevant(to: command)
        guard !hits.isEmpty else { return "" }
        var lines = ["The user has taught you how to do these tasks. If one matches the request, follow its steps exactly (adapting to what's on screen):"]
        for p in hits {
            lines.append("• \(p.name): \(p.steps.prefix(400))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Procedure].self, from: data) else { return }
        procedures = decoded
    }

    private func persist() {
        let snapshot = procedures
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
