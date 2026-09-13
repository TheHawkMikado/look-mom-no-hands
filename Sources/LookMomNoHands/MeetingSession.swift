import Foundation
import Combine

/// One live meeting session (SPEC.md §5.2, Phase 2): the consent line, the
/// introduction ritual that enrols attendees' voiceprints, the diarized live
/// transcript, continuous extraction, and the end-of-session triage with a
/// spoken summary. Driven by AppCoordinator (which owns the mic, the model
/// client and the team client) and shown in the Dashboard's Meetings tab.
///
/// Residency (SPEC.md §4.3): the transcript lives in memory and in the Local
/// Brain (`meetings/<date>-<slug>.md`). The only text that leaves the Mac is
/// the labelled transcript sent to the extraction model call, and each
/// action item's own text sent to `POST /api/app/tasks` — never the transcript.
///
/// Everything network- or hardware-shaped comes in through `Services`, so the
/// session runs under tests with fakes (no mic, no model, no web).
@MainActor
final class MeetingSession: ObservableObject {

    enum State: Equatable {
        case idle
        case consent          // speaking the consent line; Cancel discards everything
        case introductions    // "I'm Hawk, here with Alex and Amari" — enrolling voices
        case live             // transcribing, extracting
        case wrappingUp       // final extraction + triage + summary
        case ended
    }

    static let consentLine = "This meeting is being recorded so my assistant can take notes and track action items. Everyone okay with that?"
    /// Continuous extraction cadence (SPEC.md §5.2 step 4).
    static let extractionInterval: TimeInterval = 90
    static let extractionPause: TimeInterval = 6
    static let extractionMinNewChars = 80
    /// A pending turn is cut out of the ring buffer after this much silence —
    /// well inside the 8 s the ring holds.
    static let turnStaleAfter: TimeInterval = 1.2
    static let introductionsWindow: TimeInterval = 75

    /// The outside world, injected. Defaults are inert so a session can be
    /// constructed in a test with only the pieces it exercises.
    struct Services {
        var speak: (String) async -> Void = { _ in }
        var log: (String) -> Void = { _ in }
        /// Labelled transcript text + attendee names → the model's extraction.
        var extract: (String, [String]) async throws -> MeetingExtraction = { _, _ in MeetingExtraction() }
        /// One action item's intake text (+ optional address hand-off) → the
        /// web's reply, nil when unreachable.
        var submit: (String, TicketDelivery?) async -> IntakeReply? = { _, _ in nil }
        /// The listener's ring buffer: seconds → 16 kHz mono, oldest first.
        var recentAudio: (Double) -> [Float] = { _ in [] }
        /// Speech samples → voiceprint (blocking; called off the main actor,
        /// hence `@Sendable` — it must not capture main-actor state).
        var embed: @Sendable ([Float]) throws -> [Float] = { _ in throw SpeakerVerifier.VerifyError.modelUnavailable("no embedder") }
        var ownerProfile: () -> VoiceProfile? = { nil }
        var threshold: () -> Float = { SpeakerVerifier.Strictness.normal.threshold }
        var now: () -> Date = { Date() }
    }

    // MARK: Published state (the Meetings tab)

    @Published private(set) var state: State = .idle
    @Published private(set) var title = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var consentRecorded = false
    @Published private(set) var consentRecordedAt: Date?
    @Published private(set) var turns: [MeetingTurn] = []
    /// Everyone introduced or heard, in order of appearance.
    @Published private(set) var attendees: [String] = []
    @Published private(set) var actionItems: [MeetingActionItem] = []
    @Published private(set) var decisions: [String] = []
    @Published private(set) var openQuestions: [String] = []
    @Published private(set) var commitments: [String] = []
    @Published private(set) var outcomes: [MeetingTriageOutcome] = []
    @Published private(set) var summary = ""
    @Published private(set) var status = ""
    @Published private(set) var extracting = false
    /// Task ids the web handed back for this session's items — the voice
    /// approval gate treats them as meeting-born even before a GET says so.
    @Published private(set) var submittedTaskIDs: Set<String> = []

    /// The owner's name for the transcript. Empty until the ritual hears the
    /// owner say "I'm <name>" (matched against the enrolled voiceprint).
    @Published var ownerName: String {
        didSet { UserDefaults.standard.set(ownerName, forKey: Self.ownerNameKey) }
    }
    private static let ownerNameKey = "meetingOwnerName"

    var isActive: Bool {
        switch state {
        case .consent, .introductions, .live, .wrappingUp: return true
        case .idle, .ended: return false
        }
    }

    let brain: LocalBrain
    let outbox: TaskOutbox
    var services: Services
    private(set) var basename = ""
    private(set) var source = "live"

    private var builder = TurnBuilder()
    private var clusterer = SpeakerClusterer()
    private var known: [String: VoiceProfile] = [:]
    private var itemDeduper = MeetingItemDeduper()
    private var decisionDeduper = MeetingItemDeduper()
    private var questionDeduper = MeetingItemDeduper()
    private var commitmentDeduper = MeetingItemDeduper()
    private var extractedTurnCount = 0
    private var lastExtractionAt = Date()
    private var lastTurnAt: Date?
    private var lastSpeaker = ""
    private var inFlightLabels = 0
    private var ticker: Timer?
    private let embedQueue = DispatchQueue(label: "com.lookmomnohands.meeting.embed", qos: .userInitiated)

    init(brain: LocalBrain, outbox: TaskOutbox, services: Services = Services()) {
        self.brain = brain
        self.outbox = outbox
        self.services = services
        ownerName = UserDefaults.standard.string(forKey: Self.ownerNameKey) ?? ""
    }

    private var ownerLabel: String { ownerName.isEmpty ? "Me" : ownerName }

    // MARK: - Lifecycle

    /// Speaks the consent line, then opens the introductions. Returns after the
    /// line is spoken; the session runs on from there until `end` or `cancel`.
    func start(title: String) async {
        guard !isActive else { return }
        reset()
        source = "live"
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting" : title
        let now = services.now()
        startedAt = now
        basename = MeetingMarkdown.filename(title: self.title, date: now)
        known = brain.voiceprints()
        if let owner = services.ownerProfile() { known[ownerLabel] = owner }
        clusterer = SpeakerClusterer(threshold: services.threshold(), known: known)
        state = .consent
        status = "Asking for consent…"
        services.log("session started: \(self.title) (\(known.count) known voices)")
        await services.speak(Self.consentLine)
        guard state == .consent else { return }   // cancelled while the line was spoken
        consentRecorded = true
        consentRecordedAt = services.now()
        lastExtractionAt = services.now()
        state = .introductions
        status = "Introductions — “I'm Hawk, here with Alex and Amari”; each person: name, role, one line."
        startTicker()
        writeMarkdown()
    }

    /// Cancel: during consent nothing is kept; later, the local transcript is
    /// kept (it's already on disk) but nothing is extracted or sent.
    func cancel() {
        guard isActive else { return }
        stopTicker()
        let hadConsent = consentRecorded
        state = .idle
        status = hadConsent ? "Cancelled — transcript kept locally, nothing sent." : "Cancelled — nothing recorded."
        services.log("session cancelled\(hadConsent ? "" : " before consent")")
        if hadConsent, !turns.isEmpty { writeMarkdown(summaryOverride: "Cancelled before triage — nothing was sent.") }
    }

    /// End of session (SPEC.md §5.2 steps 5–6): final extraction, triage
    /// through the web's intake, the spoken summary, the markdown.
    func end() async {
        guard isActive, state != .wrappingUp, state != .consent else {
            if state == .consent { cancel() }
            return
        }
        state = .wrappingUp
        status = "Wrapping up…"
        stopTicker()
        if let p = builder.flushAll() { label(p) }
        await waitForLabels()
        await runExtraction(force: true)
        await triage()
        summary = MeetingSummary.spoken(outcomes)
        writeMarkdown()
        services.log("session ended: \(actionItems.count) action items, \(outcomes.filter { $0.ownerKind == "queued" }.count) queued")
        await services.speak(summary)
        state = .ended
        status = "Ended — \(actionItems.count) action item\(actionItems.count == 1 ? "" : "s")."
    }

    private func reset() {
        title = ""
        startedAt = nil
        consentRecorded = false
        consentRecordedAt = nil
        turns = []
        attendees = []
        actionItems = []
        decisions = []
        openQuestions = []
        commitments = []
        outcomes = []
        summary = ""
        status = ""
        submittedTaskIDs = []
        builder = TurnBuilder()
        itemDeduper = MeetingItemDeduper()
        decisionDeduper = MeetingItemDeduper()
        questionDeduper = MeetingItemDeduper()
        commitmentDeduper = MeetingItemDeduper()
        extractedTurnCount = 0
        lastTurnAt = nil
        lastSpeaker = ""
        known = [:]
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Once a second: cut stale turns while their audio is still in the ring,
    /// leave the introductions phase, and run extraction when due.
    func tick() {
        guard state == .introductions || state == .live else { return }
        let now = services.now()
        if let stale = builder.flushStale(now: now, staleAfter: Self.turnStaleAfter) { label(stale) }
        if state == .introductions, let at = consentRecordedAt, now.timeIntervalSince(at) > Self.introductionsWindow {
            state = .live
            status = "Live — \(attendees.count) attendee\(attendees.count == 1 ? "" : "s")"
        }
        if extractionDue(now: now) { Task { await runExtraction(force: false) } }
    }

    // MARK: - Transcript

    /// The listener's timed segments for the current recognition request.
    func ingest(requestID: Int, startedAt: Date, segments: [SpeechSegment], isFinal: Bool) {
        guard state == .introductions || state == .live else { return }
        for closed in builder.ingest(requestID: requestID, startedAt: startedAt, segments: segments, isFinal: isFinal) {
            label(closed)
        }
    }

    /// Cuts the turn's audio out of the ring, embeds it off-main, and appends
    /// the labelled turn. Too little speech → the previous speaker keeps talking.
    private func label(_ p: TurnBuilder.Pending) {
        guard let sessionStart = startedAt else { return }
        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = services.now()
        lastTurnAt = now
        let start = p.start.timeIntervalSince(sessionStart)
        let end = p.end.timeIntervalSince(sessionStart)
        let intros = IntroParser.parse(text)
        let audio = services.recentAudio(VoiceListener.ringSeconds)
        var clip: [Float] = []
        if let r = MeetingAudioWindow.sampleRange(start: p.start, end: p.end, now: now, sampleCount: audio.count) {
            clip = Array(audio[r])
        }
        let speech = SpeakerVerifier.trimToSpeech(clip)
        guard Double(speech.count) >= SpeakerVerifier.minSpeechSeconds * SpeakerVerifier.sampleRate else {
            append(MeetingTurn(speaker: fallbackSpeaker, text: text, start: start, end: end), intros: intros, embedding: nil)
            return
        }
        inFlightLabels += 1
        let embed = services.embed
        embedQueue.async { [weak self] in
            let embedding = try? embed(speech)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlightLabels -= 1
                let speaker = embedding.map { self.speaker(for: $0) } ?? self.fallbackSpeaker
                self.append(MeetingTurn(speaker: speaker, text: text, start: start, end: end),
                            intros: intros, embedding: embedding)
            }
        }
    }

    private var fallbackSpeaker: String { lastSpeaker.isEmpty ? "Speaker" : lastSpeaker }

    /// Nearest enrolled voice above threshold, else a running cluster.
    private func speaker(for embedding: [Float]) -> String {
        if let hit = SpeakerVerifier.identify(embedding, among: known, threshold: services.threshold()) {
            return hit.name
        }
        return clusterer.assign(embedding)
    }

    private func append(_ turn: MeetingTurn, intros: [Introduction], embedding: [Float]?) {
        guard isActive else { return }
        var t = turn
        if let me = intros.first(where: \.isSelf) { enrol(me, turn: &t, embedding: embedding) }
        noteAttendee(t.speaker)
        for other in intros where !other.isSelf { expect(other) }
        lastSpeaker = t.speaker
        turns.append(t)
        writeMarkdown()
    }

    /// "Amari" spoken in a meeting is the "Amari Jones" the brain already
    /// knows — one file per person, not one per way of saying their name.
    private func resolvedName(_ spoken: String) -> String {
        brain.person(named: spoken)?.name ?? spoken
    }

    /// "I'm Alex, head of growth at Acme" spoken by the voice we just embedded.
    private func enrol(_ intro: Introduction, turn t: inout MeetingTurn, embedding: [Float]?) {
        let name = resolvedName(intro.name)
        if t.speaker == ownerLabel {
            // The owner naming themselves — the transcript label follows.
            if ownerName != name {
                let old = ownerLabel
                ownerName = name
                relabel(from: old, to: name)
                if let p = known.removeValue(forKey: old) { known[name] = p }
            }
            t.speaker = name
            brain.upsertPerson(name: name, role: intro.role, org: intro.org)
            services.log("owner introduced as \(name)")
            return
        }
        if t.speaker == name {
            // Returning attendee, recognised before they finished the sentence.
            brain.upsertPerson(name: name, role: intro.role, org: intro.org)
            services.log("welcome back, \(name) (voice recognised)")
            return
        }
        let previous = t.speaker
        t.speaker = name
        brain.upsertPerson(name: name, role: intro.role, org: intro.org)
        if let embedding {
            brain.addVoiceprint(name: name, embedding: embedding)
            var profile = known[name] ?? VoiceProfile(embeddings: [])
            profile.embeddings.append(SpeakerVerifier.normalized(embedding))
            known[name] = profile
            clusterer = SpeakerClusterer(threshold: services.threshold(), known: known)
            services.log("enrolled \(name)\(intro.role.isEmpty ? "" : " (\(intro.role))")")
        } else {
            services.log("\(name) introduced (too little audio to enrol a voiceprint yet)")
        }
        if previous.hasPrefix("Speaker ") { relabel(from: previous, to: name) }
    }

    /// "here with Alex and Amari" — people who have not spoken yet.
    private func expect(_ intro: Introduction) {
        let name = resolvedName(intro.name)
        brain.upsertPerson(name: name)
        noteAttendee(name)
    }

    private func noteAttendee(_ name: String) {
        guard !name.hasPrefix("Speaker"), !attendees.contains(name) else { return }
        attendees.append(name)
    }

    private func relabel(from old: String, to new: String) {
        for i in turns.indices where turns[i].speaker == old { turns[i].speaker = new }
        if let i = attendees.firstIndex(of: old) { attendees[i] = new } else { noteAttendee(new) }
    }

    private func waitForLabels() async {
        var waited = 0
        while inFlightLabels > 0, waited < 60 {   // ≤ 3 s; the embedder takes ~100 ms a turn
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
    }

    // MARK: - Extraction

    /// Every ~90 s, or after a 6 s pause once there is enough new text.
    func extractionDue(now: Date) -> Bool {
        guard !extracting, turns.count > extractedTurnCount else { return false }
        let newChars = turns[extractedTurnCount...].reduce(0) { $0 + $1.text.count }
        guard newChars >= Self.extractionMinNewChars else { return false }
        if now.timeIntervalSince(lastExtractionAt) >= Self.extractionInterval { return true }
        if let last = lastTurnAt, now.timeIntervalSince(last) >= Self.extractionPause { return true }
        return false
    }

    /// One pass over the turns not yet extracted. On failure the turns stay
    /// un-extracted and ride along with the next pass.
    func runExtraction(force: Bool) async {
        guard !extracting else { return }
        let from = extractedTurnCount
        guard from < turns.count else { return }
        let slice = Array(turns[from...])
        let text = Self.labelledText(slice)
        guard force || text.count >= Self.extractionMinNewChars else { return }
        extracting = true
        lastExtractionAt = services.now()
        defer { extracting = false }
        do {
            let found = try await services.extract(text, attendees)
            merge(found)
            extractedTurnCount = from + slice.count
            services.log("extracted \(found.actionItems.count) items / \(found.decisions.count) decisions from \(slice.count) turns")
        } catch {
            services.log("extraction failed: \(error) — will retry with the next stretch")
            status = "Extraction hiccup — retrying with the next stretch."
        }
        writeMarkdown()
    }

    private func merge(_ found: MeetingExtraction) {
        for item in found.actionItems {
            if itemDeduper.admit(item.title) { actionItems.append(item) }
        }
        decisions += decisionDeduper.admitAll(found.decisions)
        openQuestions += questionDeduper.admitAll(found.openQuestions)
        commitments += commitmentDeduper.admitAll(found.commitments)
    }

    /// "Speaker: words" lines — what the extractor reads.
    nonisolated static func labelledText(_ turns: [MeetingTurn]) -> String {
        turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Triage (end of session)

    /// Every action item → `POST /api/app/tasks` as its own text (the web
    /// triages agent / human / user). Unreachable → the outbox keeps it and
    /// the coordinator retries every minute.
    private func triage() async {
        var results: [MeetingTriageOutcome] = []
        for item in actionItems {
            let handoff = delivery(for: item)
            let text = item.intakeText
            if let reply = await services.submit(text, handoff) {
                let kind = Self.ownerKind(of: reply)
                if let id = reply.task?.id { submittedTaskIDs.insert(id) }
                results.append(MeetingTriageOutcome(item: item, ownerKind: kind,
                                                    ownerName: reply.task?.ownerName ?? handoff?.name,
                                                    taskID: reply.task?.id, status: reply.task?.status ?? reply.intent))
                services.log(TeamClient.receiptLine(reply))
            } else {
                outbox.enqueue(OutboxEntry(text: text, meeting: basename, deliver: handoff))
                results.append(MeetingTriageOutcome(item: item, ownerKind: "queued", ownerName: item.ownerName,
                                                    taskID: nil, status: "queued"))
                services.log("team unreachable — “\(item.title)” kept in the outbox")
            }
        }
        outcomes = results
    }

    /// The web's verdict for an intake reply: `owner_kind` when present, else
    /// inferred from the status the intake sets. Pure — tested.
    nonisolated static func ownerKind(of reply: IntakeReply) -> String {
        guard let task = reply.task else { return "user" }
        if let k = task.ownerKind, !k.isEmpty { return k }
        switch task.status {
        case "dispatching", "in_progress", "drafting": return "agent"
        case "assigned", "delivered": return "human"
        default: return "user"
        }
    }

    /// The one-time address hand-off for a human ticket: the owner's email
    /// (preferred) or phone from their Local Brain file. Nil = the web
    /// assigns without a channel and the owner is asked later.
    func delivery(for item: MeetingActionItem) -> TicketDelivery? {
        guard let owner = item.ownerName, let person = brain.person(named: owner) else { return nil }
        if !person.email.isEmpty { return TicketDelivery(channel: "email", to: person.email, name: person.name) }
        if !person.phone.isEmpty { return TicketDelivery(channel: "sms", to: person.phone, name: person.name) }
        return nil
    }

    // MARK: - Imported recordings (wearables)

    /// A wearable recording through the same extraction and triage. Long days
    /// are extracted in chunks. Nothing is spoken here — the coordinator
    /// decides whether it's a good moment. Returns the summary sentence.
    func runImported(source: String, id: String, title: String, text: String, startedAt: Date?) async -> String {
        guard !isActive else { return "" }
        reset()
        self.source = "\(source) (wearable)"
        self.title = title.isEmpty ? "\(source) recording" : title
        self.startedAt = startedAt ?? services.now()
        basename = "\(source)-\(LocalBrain.slug(id))"
        state = .wrappingUp
        status = "Importing \(source) recording…"
        turns = Self.turns(fromLabelledText: text)
        for name in turns.map(\.speaker) { noteAttendee(name) }
        for chunk in Self.chunks(turns, maxChars: 6000) {
            do {
                let found = try await services.extract(Self.labelledText(chunk), attendees)
                merge(found)
            } catch {
                services.log("\(source) extraction failed: \(error)")
            }
        }
        extractedTurnCount = turns.count
        await triage()
        summary = MeetingSummary.spoken(outcomes)
        writeMarkdown()
        state = .ended
        status = "Imported — \(actionItems.count) action item\(actionItems.count == 1 ? "" : "s")."
        services.log("\(source) recording \(id): \(actionItems.count) items")
        return summary
    }

    /// "Alex: we should ship Friday" lines → turns; unlabelled lines get
    /// "Speaker". Pure — tested.
    nonisolated static func turns(fromLabelledText text: String) -> [MeetingTurn] {
        var out: [MeetingTurn] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 40 {
                let speaker = line[..<colon].trimmingCharacters(in: .whitespaces)
                let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !speaker.isEmpty, !body.isEmpty, !speaker.contains(" the "), speaker.split(separator: " ").count <= 4 {
                    out.append(MeetingTurn(speaker: speaker, text: body, start: 0, end: 0))
                    continue
                }
            }
            out.append(MeetingTurn(speaker: "Speaker", text: line, start: 0, end: 0))
        }
        return out
    }

    /// Consecutive turns grouped so no chunk's text exceeds `maxChars`
    /// (a single oversized turn is its own chunk). Pure — tested.
    nonisolated static func chunks(_ turns: [MeetingTurn], maxChars: Int) -> [[MeetingTurn]] {
        var out: [[MeetingTurn]] = []
        var current: [MeetingTurn] = []
        var size = 0
        for t in turns {
            let n = t.speaker.count + t.text.count + 3
            if !current.isEmpty, size + n > maxChars {
                out.append(current)
                current = []
                size = 0
            }
            current.append(t)
            size += n
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Markdown (Local Brain)

    private func writeMarkdown(summaryOverride: String? = nil) {
        guard !basename.isEmpty, let date = startedAt else { return }
        let md = MeetingMarkdown.render(title: title, date: date, attendees: attendees,
                                        consentRecordedAt: consentRecordedAt, source: source, turns: turns,
                                        actionItems: actionItems, decisions: decisions, openQuestions: openQuestions,
                                        commitments: commitments, outcomes: outcomes,
                                        summary: summaryOverride ?? summary)
        brain.writeMeeting(basename: basename, markdown: md, title: title)
    }

    var markdownURL: URL? { basename.isEmpty ? nil : brain.meetingURL(basename: basename) }
}
