import Foundation

// The pure half of the live meeting loop (SPEC.md §5.2): turning timed speech
// segments into speaker turns, cutting the matching audio out of the ring
// buffer, reading the introduction ritual, de-duplicating extracted items,
// and rendering the spoken summary and the local meeting markdown. Nothing
// here touches audio hardware, the network or the main actor — every type is
// unit-tested in MeetingSessionTests.

// MARK: - Turns

/// A speaker-labelled stretch of speech. Times are seconds since the session
/// began, so the markdown can show `[03:12]` without wall-clock arithmetic.
struct MeetingTurn: Equatable, Sendable {
    var speaker: String
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Groups Apple Speech's per-word segments into turns as they arrive. A turn
/// closes on a pause longer than `gapSeconds`, when it reaches `maxSeconds`
/// (the speaker model takes ≤ 10 s, the ring holds 8 s), or when a request
/// finalizes. Partial results revise their last word freely, so only the
/// final result consumes the tail segment; on a partial the last segment is
/// left for the next callback. Pure — unit-tested.
struct TurnBuilder: Equatable {
    struct Pending: Equatable {
        var text: String
        var start: Date
        var end: Date
        var requestID: Int
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    let gapSeconds: TimeInterval
    let maxSeconds: TimeInterval
    private(set) var pending: Pending?
    private var consumed: [Int: Int] = [:]   // requestID → segments already consumed

    init(gapSeconds: TimeInterval = 0.7, maxSeconds: TimeInterval = 6) {
        self.gapSeconds = gapSeconds
        self.maxSeconds = maxSeconds
    }

    /// Feeds one result's segments. Returns the turns that closed.
    mutating func ingest(requestID: Int, startedAt: Date, segments: [SpeechSegment], isFinal: Bool) -> [Pending] {
        var closed: [Pending] = []
        let already = consumed[requestID] ?? 0
        let upto = isFinal ? segments.count : max(already, segments.count - 1)
        guard upto > already else {
            if isFinal, let p = pending, p.requestID == requestID {
                closed.append(p)
                pending = nil
            }
            return closed
        }
        for s in segments[already..<upto] {
            let start = startedAt.addingTimeInterval(s.timestamp)
            let end = start.addingTimeInterval(max(0, s.duration))
            let word = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            if var p = pending {
                let gap = start.timeIntervalSince(p.end)
                if gap > gapSeconds || p.duration >= maxSeconds {
                    closed.append(p)
                    pending = Pending(text: word, start: start, end: end, requestID: requestID)
                } else {
                    p.text += " " + word
                    p.end = max(p.end, end)
                    p.requestID = requestID
                    pending = p
                }
            } else {
                pending = Pending(text: word, start: start, end: end, requestID: requestID)
            }
        }
        consumed[requestID] = upto
        if isFinal, let p = pending, p.requestID == requestID {
            closed.append(p)
            pending = nil
        }
        return closed
    }

    /// Closes the pending turn when nobody has added to it for `staleAfter`
    /// seconds — the ring buffer only holds 8 s, so a turn must be cut out
    /// while its audio is still there.
    mutating func flushStale(now: Date, staleAfter: TimeInterval) -> Pending? {
        guard let p = pending, now.timeIntervalSince(p.end) >= staleAfter else { return nil }
        pending = nil
        return p
    }

    mutating func flushAll() -> Pending? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - Audio window

/// Maps a turn's wall-clock span onto the ring buffer snapshot the listener
/// hands back (`recentAudio(seconds:)` — the last N seconds ending at `now`,
/// oldest first). Pure — unit-tested.
enum MeetingAudioWindow {
    /// The sample range of `[start, end]` (padded by `pad` seconds each side)
    /// inside a snapshot of `sampleCount` samples at `rate` that ends at
    /// `now`. Nil when the span has already scrolled out of the buffer or is
    /// shorter than `minSeconds` after clamping.
    static func sampleRange(start: Date, end: Date, now: Date, sampleCount: Int,
                            rate: Double = SpeakerVerifier.sampleRate,
                            pad: TimeInterval = 0.15, minSeconds: TimeInterval = 0.5) -> Range<Int>? {
        guard sampleCount > 0, rate > 0, end > start else { return nil }
        let bufferStart = now.timeIntervalSince1970 - Double(sampleCount) / rate
        let lo = Int(((start.timeIntervalSince1970 - pad) - bufferStart) * rate)
        let hi = Int(((end.timeIntervalSince1970 + pad) - bufferStart) * rate)
        let from = max(0, min(sampleCount, lo))
        let to = max(0, min(sampleCount, hi))
        guard to > from, Double(to - from) >= minSeconds * rate else { return nil }
        return from..<to
    }
}

// MARK: - Introduction ritual

/// One person as the ritual introduced them: "I'm Alex, head of growth at
/// Funneltopia" → name Alex, role "head of growth", org Funneltopia, isSelf.
/// "here with Alex and Amari" → two non-self introductions with names only.
struct Introduction: Equatable, Sendable {
    var name: String
    var role: String = ""
    var org: String = ""
    var isSelf: Bool
}

/// Regex heuristics over one utterance. Names must be capitalised the way
/// the recognizer capitalises proper nouns — that is what keeps "I'm going
/// to share my screen" from enrolling someone called Going. Pure — tested.
enum IntroParser {
    /// Capitalised words that are never a name.
    static let notNames: Set<String> = [
        "The", "A", "An", "I", "Here", "Just", "Not", "So", "Going", "Also", "Sorry", "Glad",
        "Happy", "Good", "Okay", "OK", "Really", "Sure", "Back", "Done", "In", "On", "Still",
        "All", "Ready", "Recording", "Now", "Very", "Pretty", "Gonna", "Only", "Fine", "Late",
        "Early", "Muted", "New", "Old", "Off", "Up", "Down", "Out", "Today", "Tomorrow",
    ]

    // Case is spelled out instead of `.caseInsensitive` so the NAME group
    // stays strictly capitalised.
    private static let selfPattern = try! NSRegularExpression(
        pattern: #"(?:^|[\s,;.!?])(?:[Ii]'?m|[Ii] am|[Tt]his is|[Mm]y name is)\s+([A-Z][\w'’-]*(?:\s+[A-Z][\w'’-]*)?)"#,
        options: [])
    private static let othersPattern = try! NSRegularExpression(
        pattern: #"(?:[Hh]ere with|[Jj]oined by|[Ww]ith me (?:is|are|today is|today are)|[Aa]long with|[Tt]ogether with)\s+([^.!?;]+)"#,
        options: [])
    // ", head of growth at Funneltopia" / ", the operations lead" / ", I'm a designer from Acme"
    private static let rolePattern = try! NSRegularExpression(
        pattern: #",\s*(?:(?:I'?m|I am)\s+)?(?:the\s+|our\s+|a\s+|an\s+)?([A-Za-z][A-Za-z ]{1,40}?)(?:\s+(?:at|from|with|for)\s+([A-Z][\w&.'’-]*(?:\s+[A-Z][\w&.'’-]*){0,2}))?(?=[.,;!?]|$)"#,
        options: [])
    private static let roleStopwords: Set<String> = ["here", "and", "with", "joined", "so", "just", "this", "that", "also", "we", "let", "thanks", "thank"]

    static func parse(_ utterance: String) -> [Introduction] {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var out: [Introduction] = []
        var seen: Set<String> = []

        func add(_ intro: Introduction) {
            let key = intro.name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append(intro)
        }

        // Self introductions, with an optional ", role at Org" tail.
        for m in selfPattern.matches(in: text, range: whole) {
            guard let r = Range(m.range(at: 1), in: text),
                  let full = Range(m.range, in: text) else { continue }
            guard let name = cleanName(String(text[r])) else { continue }
            // "I'm Hawk and this is Alex" — the second one is someone else.
            let before = text[..<full.lowerBound].lowercased().trimmingCharacters(in: .whitespaces)
            let introducesOther = before.hasSuffix(" and") || before == "and"
            var intro = Introduction(name: name, isSelf: !introducesOther)
            let tailStart = r.upperBound
            let tail = String(text[tailStart...])
            if let rm = rolePattern.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
               rm.range.location == 0,
               let rr = Range(rm.range(at: 1), in: tail) {
                let role = String(tail[rr]).trimmingCharacters(in: .whitespaces)
                let firstWord = role.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if !roleStopwords.contains(firstWord), role.split(separator: " ").count <= 6 {
                    intro.role = role.lowercased()
                    if rm.numberOfRanges > 2, let orgRange = Range(rm.range(at: 2), in: tail) {
                        intro.org = String(tail[orgRange])
                    }
                }
            }
            add(intro)
        }

        // "here with Alex and Amari" — people in the room who have not spoken yet.
        for m in othersPattern.matches(in: text, range: whole) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let list = String(text[r])
                .replacingOccurrences(of: " and ", with: ",")
                .replacingOccurrences(of: " & ", with: ",")
            for part in list.split(separator: ",") {
                // "Amari from ops" → "Amari"; keep only the leading capitalised run.
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
                var run: [String] = []
                for w in words {
                    guard let first = w.first, first.isUppercase, run.count < 2 else { break }
                    run.append(w)
                }
                if let name = cleanName(run.joined(separator: " ")) {
                    add(Introduction(name: name, isSelf: false))
                }
            }
        }
        return out
    }

    /// Strips trailing punctuation and rejects stop-words; nil when nothing
    /// name-like is left.
    static func cleanName(_ raw: String) -> String? {
        let words = raw.split(separator: " ").map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'’\""))
        }.filter { !$0.isEmpty && !notNames.contains($0) && $0.first?.isUppercase == true }
        guard !words.isEmpty, words.count <= 2 else { return nil }
        return words.joined(separator: " ")
    }
}

// MARK: - Extraction (the model's structured output)

/// One action item as the extraction pass returns it. Tolerant decoding: a
/// missing owner or due phrase is nil, a missing tier is 0 (internal).
struct MeetingActionItem: Decodable, Equatable, Sendable {
    let title: String
    let detail: String
    let ownerName: String?
    let duePhrase: String?
    let blastTier: Int

    init(title: String, detail: String = "", ownerName: String? = nil, duePhrase: String? = nil, blastTier: Int = 0) {
        self.title = title
        self.detail = detail
        self.ownerName = ownerName
        self.duePhrase = duePhrase
        self.blastTier = blastTier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        detail = ((try? c.decodeIfPresent(String.self, forKey: .detail)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ownerName = Self.blankToNil(try? c.decodeIfPresent(String.self, forKey: .ownerName))
        duePhrase = Self.blankToNil(try? c.decodeIfPresent(String.self, forKey: .duePhrase))
        let tier = (try? c.decodeIfPresent(Int.self, forKey: .blastTier)) ?? 0
        blastTier = max(0, min(4, tier))
    }

    private static func blankToNil(_ s: String??) -> String? {
        guard let inner = s, let v = inner else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.lowercased() == "null" || t.lowercased() == "none" ? nil : t
    }

    private enum CodingKeys: String, CodingKey {
        case title, detail
        case ownerName = "owner_name"
        case duePhrase = "due_phrase"
        case blastTier = "blast_tier"
    }

    /// The one string the web's intake receives (SPEC.md §4.3: the task text,
    /// never the transcript): "<title>. <detail>. Owner: <name>. Due <phrase>".
    var intakeText: String {
        var parts: [String] = []
        parts.append(Self.sentence(title))
        if !detail.isEmpty { parts.append(Self.sentence(detail)) }
        if let ownerName { parts.append("Owner: \(ownerName).") }
        if let duePhrase { parts.append("Due \(duePhrase).") }
        return parts.joined(separator: " ")
    }

    private static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".!?".contains(last) ? t : t + "."
    }
}

/// Everything one extraction pass found in the new transcript text.
struct MeetingExtraction: Decodable, Equatable, Sendable {
    let actionItems: [MeetingActionItem]
    let decisions: [String]
    let openQuestions: [String]
    let commitments: [String]

    init(actionItems: [MeetingActionItem] = [], decisions: [String] = [],
         openQuestions: [String] = [], commitments: [String] = []) {
        self.actionItems = actionItems
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.commitments = commitments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actionItems = ((try? c.decodeIfPresent([MeetingActionItem].self, forKey: .actionItems)) ?? [])
            .filter { !$0.title.isEmpty }
        decisions = Self.strings(try? c.decodeIfPresent([String].self, forKey: .decisions))
        openQuestions = Self.strings(try? c.decodeIfPresent([String].self, forKey: .openQuestions))
        commitments = Self.strings(try? c.decodeIfPresent([String].self, forKey: .commitments))
    }

    private static func strings(_ v: [String]??) -> [String] {
        guard let inner = v, let list = inner else { return [] }
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case actionItems = "action_items"
        case decisions
        case openQuestions = "open_questions"
        case commitments
    }

    var isEmpty: Bool { actionItems.isEmpty && decisions.isEmpty && openQuestions.isEmpty && commitments.isEmpty }
}

/// Remembers what earlier extraction passes already produced so re-reading an
/// overlapping stretch of transcript doesn't file "Send the deck to Amari"
/// twice. Keys are lowercase alphanumeric words; a new item is a duplicate
/// when its key equals a known one, or when one contains the other and both
/// are long enough that the containment isn't coincidence. Pure — tested.
struct MeetingItemDeduper: Equatable {
    private(set) var keys: [String] = []
    static let containmentFloor = 20

    static func key(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// True (and remembers it) when `text` is new.
    mutating func admit(_ text: String) -> Bool {
        let k = Self.key(text)
        guard !k.isEmpty else { return false }
        for known in keys {
            if known == k { return false }
            if min(known.count, k.count) >= Self.containmentFloor, known.contains(k) || k.contains(known) { return false }
        }
        keys.append(k)
        return true
    }

    mutating func admitAll(_ items: [String]) -> [String] { items.filter { admit($0) } }
}

// MARK: - Triage + spoken summary

/// Where one action item went at the end of the session. `ownerKind` is the
/// web's verdict — agent | human | user — or "queued" when the web was
/// unreachable and the item sits in the outbox.
struct MeetingTriageOutcome: Equatable, Sendable {
    let item: MeetingActionItem
    let ownerKind: String
    let ownerName: String?
    let taskID: String?
    let status: String
}

enum MeetingSummary {
    /// The sentence spoken when the session ends (SPEC.md §5.2 step 5): what
    /// agents took, what went to which human, what needs the user. Short —
    /// every word is TTS time — but names every human so the owner knows who
    /// to expect a ticket from. Pure — tested.
    static func spoken(_ outcomes: [MeetingTriageOutcome]) -> String {
        guard !outcomes.isEmpty else { return "No action items came out of that meeting." }
        let agents = outcomes.filter { $0.ownerKind == "agent" }
        let humans = outcomes.filter { $0.ownerKind == "human" }
        let user = outcomes.filter { $0.ownerKind == "user" }
        let queued = outcomes.filter { $0.ownerKind == "queued" }
        var s = "\(count(outcomes.count, "action item")). "
        if !agents.isEmpty {
            s += "Agents took \(agents.count == 1 ? "one" : "\(agents.count)"): \(list(agents.map(\.item.title))). "
        }
        if !humans.isEmpty {
            var byName: [String: [String]] = [:]
            var order: [String] = []
            for h in humans {
                let name = h.ownerName ?? "the team"
                if byName[name] == nil { order.append(name) }
                byName[name, default: []].append(h.item.title)
            }
            let parts = order.map { name -> String in
                let titles = byName[name] ?? []
                return "\(name) gets \(titles.count == 1 ? "" : "\(titles.count): ")\(list(titles))"
            }
            s += parts.joined(separator: "; ") + ". "
        }
        if user.isEmpty {
            s += "Nothing needs you."
        } else {
            s += "\(user.count == 1 ? "One needs" : "\(user.count) need") your call: \(list(user.map(\.item.title)))."
        }
        if !queued.isEmpty {
            s += " \(queued.count == 1 ? "One is" : "\(queued.count) are") waiting for the team to come back online; I'll keep trying."
        }
        return s
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        switch n {
        case 1: return "One \(noun)"
        case 2: return "Two \(noun)s"
        case 3: return "Three \(noun)s"
        default: return "\(n) \(noun)s"
        }
    }

    /// "A", "A and B", "A, B, and C" — capped at three, then "and N more".
    static func list(_ titles: [String]) -> String {
        let t = titles.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
        switch t.count {
        case 0: return ""
        case 1: return t[0]
        case 2: return "\(t[0]) and \(t[1])"
        case 3: return "\(t[0]), \(t[1]), and \(t[2])"
        default: return "\(t[0]), \(t[1]), and \(t.count - 2) more"
        }
    }
}

// MARK: - Markdown (Local Brain, never uploaded)

enum MeetingMarkdown {
    /// `meetings/<yyyy-MM-dd>-<slug>.md`'s basename, without the extension.
    static func filename(title: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: date))-\(LocalBrain.slug(title))"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// The whole meeting as one readable file: facts, the labelled transcript,
    /// what was extracted, and where each action item went. Rewritten on
    /// every change (a few hundred KB at most), so a crash mid-meeting still
    /// leaves the last state on disk.
    static func render(title: String, date: Date, attendees: [String], consentRecordedAt: Date?,
                       source: String = "live", turns: [MeetingTurn], actionItems: [MeetingActionItem],
                       decisions: [String], openQuestions: [String], commitments: [String],
                       outcomes: [MeetingTriageOutcome], summary: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var s = "# \(title)\n\n"
        s += "- Date: \(f.string(from: date))\n"
        s += "- Source: \(source)\n"
        if !attendees.isEmpty { s += "- Attendees: \(attendees.joined(separator: ", "))\n" }
        if let consentRecordedAt {
            s += "- Consent: recorded \(f.string(from: consentRecordedAt)) (consent line spoken at the start)\n"
        } else {
            s += "- Consent: not recorded\n"
        }
        s += "\n## Transcript\n\n"
        if turns.isEmpty { s += "_Nothing captured._\n" }
        for t in turns {
            s += "**\(t.speaker)** [\(clock(t.start))]: \(t.text)\n\n"
        }
        s += "## Action items\n\n"
        if actionItems.isEmpty { s += "_None._\n" }
        for item in actionItems {
            var line = "- [ ] \(item.title)"
            if !item.detail.isEmpty { line += " — \(item.detail)" }
            var tags: [String] = []
            if let o = item.ownerName { tags.append("owner: \(o)") }
            if let d = item.duePhrase { tags.append("due: \(d)") }
            tags.append("tier \(item.blastTier)")
            if let outcome = outcomes.first(where: { $0.item == item }) {
                var went = outcome.ownerKind
                if let n = outcome.ownerName, outcome.ownerKind != "queued" { went += " (\(n))" }
                if let id = outcome.taskID { went += " [\(id)]" }
                tags.append("→ \(went)")
            }
            line += " (\(tags.joined(separator: ", ")))"
            s += line + "\n"
        }
        s += "\n"
        s += section("Decisions", decisions)
        s += section("Open questions", openQuestions)
        s += section("Commitments", commitments)
        if !summary.isEmpty { s += "## Summary\n\n\(summary)\n" }
        return s
    }

    private static func section(_ title: String, _ lines: [String]) -> String {
        var s = "## \(title)\n\n"
        if lines.isEmpty { s += "_None._\n" } else { for l in lines { s += "- \(l)\n" } }
        return s + "\n"
    }
}
