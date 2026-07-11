import Foundation
import Combine

/// The user's learned vocabulary: names/terms to spell right, corrections for
/// consistent mishearings, and snippet expansions. Persisted to disk and applied
/// by the model (fed into the cleanup/report/command prompts) plus used to bias
/// the speech recognizer. This is the foundation for "make it learn" — entries
/// can be added by hand or captured from corrections.
@MainActor
final class VocabularyStore: ObservableObject {
    @Published private(set) var entries: [VocabEntry] = []

    private let url: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel + ".vocab")

    init(directory: URL) {
        url = directory.appendingPathComponent("vocabulary.json")
        load()
    }

    func add(_ entry: VocabEntry) {
        guard !entry.spoken.isEmpty else { return }
        entries.insert(entry, at: 0)
        persist()
    }

    func remove(_ id: VocabEntry.ID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Adds a correction learned from the user (e.g. they said "I mean Google
    /// Chrome"). Deduped on the spoken form so repeated corrections update in place.
    func learnCorrection(spoken: String, written: String) {
        let s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !w.isEmpty, s.lowercased() != w.lowercased() else { return }
        entries.removeAll { $0.kind == .correction && $0.spoken.lowercased() == s.lowercased() }
        entries.insert(VocabEntry(kind: .correction, spoken: s, written: w), at: 0)
        persist()
    }

    func entries(of kind: VocabEntry.Kind) -> [VocabEntry] { entries.filter { $0.kind == kind } }

    /// Phrases to bias the recognizer toward (SFSpeech contextualStrings): the
    /// terms themselves plus snippet triggers. Capped — contextualStrings has
    /// diminishing returns and a soft limit.
    var contextualStrings: [String] {
        var out: [String] = []
        for e in entries {
            switch e.kind {
            case .word, .correction: out.append(e.biasTerm)
            case .snippet: out.append(e.spoken)   // bias the trigger so it's heard
            }
        }
        return Array(Set(out)).prefix(100).map { $0 }
    }

    /// A compact instruction block injected into model prompts so it applies the
    /// vocabulary itself (correct spelling, fix mishearings, expand snippets).
    /// Empty when there's nothing to say, so prompts stay lean.
    var promptContext: String {
        let words = entries(of: .word).map(\.spoken).filter { !$0.isEmpty }
        let corrections = entries(of: .correction).filter { !$0.written.isEmpty }
        let snippets = entries(of: .snippet).filter { !$0.written.isEmpty }
        guard !words.isEmpty || !corrections.isEmpty || !snippets.isEmpty else { return "" }

        var lines: [String] = ["The user's personal vocabulary — apply it:"]
        if !words.isEmpty {
            lines.append("- Spell these names/terms exactly when they occur: " + words.joined(separator: ", ") + ".")
        }
        for c in corrections {
            lines.append("- When you hear \"\(c.spoken)\", the user means \"\(c.written)\".")
        }
        for s in snippets {
            lines.append("- When the user says \"\(s.spoken)\", expand it to: \(s.written)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([VocabEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        let snapshot = entries
        let url = self.url
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
