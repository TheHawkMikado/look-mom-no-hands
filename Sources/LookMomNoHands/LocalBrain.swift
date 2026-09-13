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

/// One person as `people/<slug>.md` describes them. Email and phone are the
/// one-time hand-off for human tickets (DECISIONS.md: the Mac hands over the
/// address, once) — they never leave the Mac except inside that one POST.
struct BrainPerson: Equatable, Sendable {
    var slug: String
    var name: String
    var role: String = ""
    var org: String = ""
    var email: String = ""
    var phone: String = ""
    var notes: String = ""
}

/// The Local Brain (SPEC.md §8.1): the private, on-device memory — people,
/// preferences, areas of work, and an inbox of notes and decisions the intake
/// says stay local. Plain Markdown the user can open in any editor, under
/// `~/Library/Application Support/LookMaNoHands/brain/`:
///
///     people/<slug>.md      one person: role, org, email, phone, notes
///     voiceprints/<slug>.json  that person's voiceprint (VoiceProfile), if enrolled
///     areas/<slug>.md       one area of work
///     meetings/<date>-<slug>.md  a meeting: labelled transcript, items, outcomes
///     preferences.md        how the user likes things done
///     inbox.md              dated notes and decisions, newest at the bottom
///     outbox.json           action items waiting for the web (TaskOutbox)
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
        try? fm.createDirectory(at: self.directory.appendingPathComponent("voiceprints"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: self.directory.appendingPathComponent("meetings"), withIntermediateDirectories: true)
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
    /// is known instead of replacing it. Empty role/org/email/phone keep what
    /// the file already says — a bare "I'm Alex" at a meeting must not wipe
    /// the email that was typed in last week.
    func upsertPerson(name: String, role: String = "", org: String = "", email: String = "",
                      phone: String = "", notes: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let slug = Self.slug(trimmed)
        let url = directory.appendingPathComponent("people").appendingPathComponent("\(slug).md")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let previous = Self.parsePerson(existing, slug: slug)
        let previousNotes = Self.notesSection(of: existing)
        let mergedNotes = [previousNotes, notes.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        func pick(_ new: String, _ old: String) -> String {
            let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? old : n
        }
        let markdown = Self.personMarkdown(name: trimmed, role: pick(role, previous?.role ?? ""),
                                           org: pick(org, previous?.org ?? ""),
                                           email: pick(email, previous?.email ?? ""),
                                           phone: pick(phone, previous?.phone ?? ""),
                                           notes: mergedNotes)
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

    /// The person whose file matches `name` (by slug, then by first name when
    /// the slug is a single word — "Amari" finds amari-jones). Nil when unknown.
    func person(named name: String) -> BrainPerson? {
        let wanted = Self.slug(name)
        guard wanted != "untitled" else { return nil }
        let people = listPeople()
        let slug: String
        if people.contains(where: { $0.slug == wanted }) {
            slug = wanted
        } else if !wanted.contains("-"),
                  let hit = people.first(where: { $0.slug == wanted || $0.slug.hasPrefix(wanted + "-") }) {
            slug = hit.slug
        } else {
            return nil
        }
        let url = directory.appendingPathComponent("people").appendingPathComponent("\(slug).md")
        guard let md = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.parsePerson(md, slug: slug)
    }

    // MARK: - Voiceprints (per person, local only)

    private func voiceprintURL(slug: String) -> URL {
        directory.appendingPathComponent("voiceprints").appendingPathComponent("\(slug).json")
    }

    /// Stores (or extends) a person's voiceprint next to their file. Same
    /// VoiceProfile shape as the owner's, so `SpeakerVerifier.identify` reads
    /// them all alike; a profile from an older model is replaced, not merged.
    func addVoiceprint(name: String, embedding: [Float]) {
        let slug = Self.slug(name)
        guard slug != "untitled" else { return }
        var embeddings: [[Float]] = []
        if let existing = SpeakerVerifier.loadProfile(from: voiceprintURL(slug: slug)), existing.isCompatible {
            embeddings = existing.embeddings
        }
        embeddings.append(SpeakerVerifier.normalized(embedding))
        if embeddings.count > 8 { embeddings.removeFirst(embeddings.count - 8) }
        guard let data = try? SpeakerVerifier.encode(VoiceProfile(embeddings: embeddings)) else { return }
        try? data.write(to: voiceprintURL(slug: slug), options: .atomic)
    }

    /// Every usable voiceprint, keyed by the person's display name.
    func voiceprints() -> [String: VoiceProfile] {
        var out: [String: VoiceProfile] = [:]
        for p in listPeople() {
            if let profile = SpeakerVerifier.loadProfile(from: voiceprintURL(slug: p.slug)), profile.isCompatible {
                out[p.title] = profile
            }
        }
        return out
    }

    func hasVoiceprint(name: String) -> Bool {
        SpeakerVerifier.loadProfile(from: voiceprintURL(slug: Self.slug(name)))?.isCompatible == true
    }

    // MARK: - Meetings (transcripts stay here, SPEC.md §4.3)

    /// Writes `meetings/<basename>.md` wholesale. Called on every change during
    /// a live session, so the file always holds the latest state.
    func writeMeeting(basename: String, markdown: String, title: String) {
        let url = directory.appendingPathComponent("meetings").appendingPathComponent("\(basename).md")
        write(markdown, to: url)
        index["meetings/\(basename)"] = IndexEntry(title: title, updated: Date(), kind: "meeting")
        persistIndex()
    }

    func meetingURL(basename: String) -> URL {
        directory.appendingPathComponent("meetings").appendingPathComponent("\(basename).md")
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
        case "meeting": return directory.appendingPathComponent("\(slug).md")   // slug carries "meetings/"
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
    nonisolated static func personMarkdown(name: String, role: String, org: String,
                                           email: String = "", phone: String = "", notes: String) -> String {
        var s = "# \(name)\n\n"
        let facts: [(String, String)] = [("Role", role), ("Org", org), ("Email", email), ("Phone", phone)]
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
        for (k, v) in facts { s += "- \(k): \(v)\n" }
        if !facts.isEmpty { s += "\n" }
        s += "## Notes\n\n"
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { s += notes + "\n" }
        return s
    }

    /// Reads a person file back: heading → name, `- Key: value` facts, notes.
    /// Nil when there is no heading (an empty or foreign file).
    nonisolated static func parsePerson(_ markdown: String, slug: String) -> BrainPerson? {
        var person = BrainPerson(slug: slug, name: "")
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# "), person.name.isEmpty {
                person.name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## ") {
                break   // facts end at the first section heading
            } else if line.hasPrefix("- "), let colon = line.firstIndex(of: ":") {
                let key = line[line.index(line.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "role": person.role = value
                case "org": person.org = value
                case "email": person.email = value
                case "phone": person.phone = value
                default: break
                }
            }
        }
        guard !person.name.isEmpty else { return nil }
        person.notes = notesSection(of: markdown)
        return person
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
