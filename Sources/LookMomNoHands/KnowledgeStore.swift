import Foundation
import Combine

/// The assistant's "general memory": durable facts about the user and their setup,
/// fed into every command so they never have to be re-stated. Persisted to disk.
/// Distinct from the vocabulary (spoken-form corrections) and procedures (how-tos).
@MainActor
final class KnowledgeStore: ObservableObject {
    @Published private(set) var facts: [KnowledgeFact] = []

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".knowledge")
    private static let maxFactsInPrompt = 30

    init(directory: URL) {
        url = directory.appendingPathComponent("knowledge.json")
        load()
    }

    /// Adds a fact. Deduped case-insensitively so repeating one doesn't pile up.
    func remember(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !facts.contains(where: { $0.text.lowercased() == t.lowercased() }) else { return }
        facts.insert(KnowledgeFact(text: t), at: 0)
        persist()
    }

    func update(_ id: String, text: String) {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[i].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func remove(_ id: String) {
        facts.removeAll { $0.id == id }
        persist()
    }

    /// A compact block of what the assistant knows, injected into every command.
    var promptContext: String {
        let shown = facts.prefix(Self.maxFactsInPrompt)
        guard !shown.isEmpty else { return "" }
        return "What you know about the user (apply it):\n" + shown.map { "- \($0.text.prefix(200))" }.joined(separator: "\n")
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([KnowledgeFact].self, from: data) else { return }
        facts = decoded
    }

    private func persist() {
        let snapshot = facts
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
