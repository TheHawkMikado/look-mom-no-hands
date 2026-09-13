import Foundation
import Combine

/// One row of the brain's index.json. Top-level (not nested in the main-actor
/// store) so the pure encode/decode helpers and tests use it freely.
struct BrainIndexEntry: Codable, Equatable {
    var title: String
    var updated: Date
    var kind: String       // "person" | "area" | "preferences" | "inbox"
}

struct BrainSearchHit: Equatable {
    let slug: String
    let title: String
    let kind: String
    let snippet: String
}

/// The Local Brain (SPEC.md §8.1): the private, on-device memory — people,
/// preferences, areas of work, and an inbox of notes and decisions the intake
/// says stay local. Plain Markdown the user can open in any editor, under
/// `~/Library/Application Support/LookMaNoHands/brain/`:
///
///     people/<slug>.md      one person: role, org, notes
///     areas/<slug>.md       one area of work
///     preferences.md        how the user likes things done
///     inbox.md              dated notes and decisions, newest at the bottom
///     index.json            slug → {title, updated, kind}
///
/// Additive for now — nothing migrates out of the knowledge, vocabulary or
/// element stores yet. No frontmatter: a heading, a few `- Key: value` lines,
/// a Notes section. Nothing here ever leaves the Mac (SPEC.md §4.3).
@MainActor
final class LocalBrain: ObservableObject {
    typealias IndexEntry = BrainIndexEntry
    typealias SearchHit = BrainSearchHit

    @Published private(set) var index: [String: IndexEntry] = [:]

    let directory: URL          // …/brain

    /// `directory` is the app-support folder; the brain lives in `brain/` under it.
    init(directory: URL) {
        self.directory = directory.appendingPathComponent("brain", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: self.directory.appendingPathComponent("people"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: self.directory.appendingPathComponent("areas"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let loaded = Self.decodeIndex(data) {
            index = loaded
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var inboxURL: URL { directory.appendingPathComponent("inbox.md") }
    private var preferencesURL: URL { directory.appendingPathComponent("preferences.md") }

    // MARK: - People

    /// Creates or rewrites `people/<slug>.md`. An existing file's notes are
    /// kept and the new notes appended, so re-introducing someone adds to what
    /// is known instead of replacing it.
    func upsertPerson(name: String, role: String = "", org: String = "", notes: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let slug = Self.slug(trimmed)
        let url = directory.appendingPathComponent("people").appendingPathComponent("\(slug).md")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let previousNotes = Self.notesSection(of: existing)
        let mergedNotes = [previousNotes, notes.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let markdown = Self.personMarkdown(name: trimmed, role: role, org: org, notes: mergedNotes)
        write(markdown, to: url)
        index[slug] = IndexEntry(title: trimmed, updated: Date(), kind: "person")
        persistIndex()
    }

    /// Everyone in `people/`, alphabetical by title.
    func listPeople() -> [(slug: String, title: String)] {
        index.filter { $0.value.kind == "person" }
            .map { (slug: $0.key, title: $0.value.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Notes, decisions, preferences

    /// Appends one dated line to the file for `kind`: "preference" goes to
    /// preferences.md, everything else ("note", "decision", "inbox") to
    /// inbox.md with the kind as its marker.
    func appendNote(kind: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let k = kind.lowercased().trimmingCharacters(in: .whitespaces)
        let isPreference = k == "preference" || k == "preferences"
        let url = isPreference ? preferencesURL : inboxURL
        let slug = isPreference ? "preferences" : "inbox"
        let title = isPreference ? "Preferences" : "Inbox"
        var body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if body.isEmpty { body = "# \(title)\n\n" }
        if !body.hasSuffix("\n") { body += "\n" }
        body += Self.inboxLine(kind: isPreference ? "preference" : k, text: trimmed, date: Date()) + "\n"
        write(body, to: url)
        index[slug] = IndexEntry(title: title, updated: Date(), kind: slug)
        persistIndex()
    }

    // MARK: - Areas

    func upsertArea(name: String, notes: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let slug = Self.slug(trimmed)
        let url = directory.appendingPathComponent("areas").appendingPathComponent("\(slug).md")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let merged = [Self.notesSection(of: existing), notes.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        write(Self.areaMarkdown(name: trimmed, notes: merged), to: url)
        index[slug] = IndexEntry(title: trimmed, updated: Date(), kind: "area")
        persistIndex()
    }

    // MARK: - Search

    /// Case-insensitive substring search over titles and file bodies. Good
    /// enough for a few hundred small files; a hit carries the matching line.
    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for (slug, entry) in index.sorted(by: { $0.value.updated > $1.value.updated }) {
            let body = (try? String(contentsOf: fileURL(slug: slug, kind: entry.kind), encoding: .utf8)) ?? ""
            if let snippet = Self.match(query: q, title: entry.title, body: body) {
                hits.append(SearchHit(slug: slug, title: entry.title, kind: entry.kind, snippet: snippet))
            }
        }
        return hits
    }

    private func fileURL(slug: String, kind: String) -> URL {
        switch kind {
        case "person": return directory.appendingPathComponent("people").appendingPathComponent("\(slug).md")
        case "area": return directory.appendingPathComponent("areas").appendingPathComponent("\(slug).md")
        case "preferences": return preferencesURL
        default: return inboxURL
        }
    }

    // MARK: - Pure helpers (tests)

    /// A file-safe slug: lowercase ASCII letters, digits and single hyphens.
    /// Diacritics fold ("José" → "jose"); anything else becomes a hyphen;
    /// runs collapse; empty input becomes "untitled".
    nonisolated static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        var pendingHyphen = false
        for ch in folded {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(ch)
            } else {
                pendingHyphen = true
            }
        }
        return out.isEmpty ? "untitled" : out
    }

    /// `people/<slug>.md` — no frontmatter, just a heading, the facts, notes.
    nonisolated static func personMarkdown(name: String, role: String, org: String, notes: String) -> String {
        var s = "# \(name)\n\n"
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = org.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { s += "- Role: \(role)\n" }
        if !org.isEmpty { s += "- Org: \(org)\n" }
        if !role.isEmpty || !org.isEmpty { s += "\n" }
        s += "## Notes\n\n"
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { s += notes + "\n" }
        return s
    }

    nonisolated static func areaMarkdown(name: String, notes: String) -> String {
        var s = "# \(name)\n\n## Notes\n\n"
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { s += notes + "\n" }
        return s
    }

    /// Everything after the `## Notes` heading, trimmed; "" when absent.
    nonisolated static func notesSection(of markdown: String) -> String {
        guard let range = markdown.range(of: "## Notes\n") else { return "" }
        return String(markdown[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One inbox line: `- 2026-09-13 14:02 [decision] We're going with Stripe.`
    /// Newlines inside the text are folded so one entry stays one line.
    nonisolated static func inboxLine(kind: String, text: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "- \(f.string(from: date)) [\(kind)] \(flat)"
    }

    /// The matching line (or the title) for a case-insensitive substring hit,
    /// nil when neither title nor body contains the query.
    nonisolated static func match(query: String, title: String, body: String) -> String? {
        if title.range(of: query, options: .caseInsensitive) != nil { return title }
        for line in body.split(whereSeparator: \.isNewline) {
            if line.range(of: query, options: .caseInsensitive) != nil {
                return String(line).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    nonisolated static func encodeIndex(_ index: [String: IndexEntry]) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(index)
    }

    nonisolated static func decodeIndex(_ data: Data) -> [String: IndexEntry]? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode([String: IndexEntry].self, from: data)
    }

    // MARK: - Files

    // Synchronous on purpose: these files are a few hundred bytes, and a
    // search or a person lookup right after a write must see the write —
    // the same call site often does both (intake → file → confirm).
    private func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func persistIndex() {
        guard let data = Self.encodeIndex(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
