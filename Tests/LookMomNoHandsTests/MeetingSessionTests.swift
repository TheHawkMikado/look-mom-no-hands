import XCTest
@testable import LookMomNoHands

/// The live meeting loop (SPEC §5.2), pure pieces first: segment → turn
/// grouping, the ring-buffer window math, the introduction ritual's name
/// parsing, extraction decoding + dedupe, the spoken summary, the markdown.
/// Then the session itself against fakes — no mic, no model, no web.
final class MeetingTurnTests: XCTestCase {

    private func seg(_ text: String, _ t: TimeInterval, _ d: TimeInterval = 0.3) -> SpeechSegment {
        SpeechSegment(text: text, timestamp: t, duration: d)
    }

    func testPartialLeavesTheTailWordAndFinalConsumesIt() {
        var b = TurnBuilder()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(b.ingest(requestID: 1, startedAt: t0, segments: [seg("we", 0), seg("ship", 0.4)], isFinal: false).isEmpty)
        XCTAssertEqual(b.pending?.text, "we", "the last word of a partial may still change")
        let closed = b.ingest(requestID: 1, startedAt: t0, segments: [seg("we", 0), seg("ship", 0.4), seg("friday", 0.8)], isFinal: true)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].text, "we ship friday")
        XCTAssertEqual(closed[0].start, t0)
        XCTAssertEqual(closed[0].end.timeIntervalSince(t0), 1.1, accuracy: 0.001)
        XCTAssertNil(b.pending)
    }

    func testPauseSplitsTurnsAndLongTurnsAreCapped() {
        var b = TurnBuilder(gapSeconds: 0.7, maxSeconds: 1.4)
        let t0 = Date(timeIntervalSince1970: 1_000)
        // Words at 0, 0.4, then a 1.5 s pause, then 2.2, 2.6, 3.0, 3.4 (1.5 s → over the cap), 3.8, 4.6.
        let segs = [seg("a", 0), seg("b", 0.4), seg("c", 2.2), seg("d", 2.6), seg("e", 3.0), seg("f", 3.4), seg("g", 3.8), seg("h", 4.6)]
        let closed = b.ingest(requestID: 7, startedAt: t0, segments: segs, isFinal: true)
        XCTAssertEqual(closed.map(\.text), ["a b", "c d e f", "g h"])
        XCTAssertEqual(closed[1].start.timeIntervalSince(t0), 2.2, accuracy: 0.001)
        XCTAssertEqual(closed[2].start.timeIntervalSince(t0), 3.8, accuracy: 0.001)
    }

    func testANewRequestContinuesAcrossTheBoundaryWhenTheGapIsShort() {
        var b = TurnBuilder()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = b.ingest(requestID: 1, startedAt: t0, segments: [seg("hello", 0), seg("there", 0.4)], isFinal: false)
        // Request 2 starts 0.9 s in; its first word lands 0.5 s after "hello" ended.
        let closed = b.ingest(requestID: 2, startedAt: t0.addingTimeInterval(0.9), segments: [seg("friends", 0), seg("today", 0.4)], isFinal: false)
        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(b.pending?.text, "hello friends", "request 1's tail word was never final — dropped, not duplicated")
        XCTAssertEqual(b.pending?.requestID, 2)
    }

    func testStaleFlushAndShrunkPartialsAreSafe() {
        var b = TurnBuilder()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = b.ingest(requestID: 1, startedAt: t0, segments: [seg("one", 0), seg("two", 0.3), seg("three", 0.6)], isFinal: false)
        // A re-recognition that SHRINKS the segment list must not crash or re-consume.
        XCTAssertTrue(b.ingest(requestID: 1, startedAt: t0, segments: [seg("one", 0)], isFinal: false).isEmpty)
        XCTAssertNil(b.flushStale(now: t0.addingTimeInterval(1.0), staleAfter: 1.2))
        let stale = b.flushStale(now: t0.addingTimeInterval(2.0), staleAfter: 1.2)
        XCTAssertEqual(stale?.text, "one two")
        XCTAssertNil(b.flushAll())
    }

    func testSampleRangeMapsWallClockOntoTheRing() throws {
        let rate = 16_000.0
        let count = Int(8 * rate)
        let now = Date(timeIntervalSince1970: 2_000)
        // A turn from 3.0 s to 1.5 s ago, padded 0.15 s each side.
        let r = MeetingAudioWindow.sampleRange(start: now.addingTimeInterval(-3), end: now.addingTimeInterval(-1.5),
                                               now: now, sampleCount: count, rate: rate)
        XCTAssertEqual(Double(try XCTUnwrap(r?.lowerBound)), (8 - 3.15) * rate, accuracy: 2)
        XCTAssertEqual(Double(try XCTUnwrap(r?.upperBound)), (8 - 1.35) * rate, accuracy: 2)
        // Scrolled out of the buffer entirely → nil; partly out → clamped.
        XCTAssertNil(MeetingAudioWindow.sampleRange(start: now.addingTimeInterval(-20), end: now.addingTimeInterval(-12),
                                                    now: now, sampleCount: count, rate: rate))
        let clamped = MeetingAudioWindow.sampleRange(start: now.addingTimeInterval(-9), end: now.addingTimeInterval(-6),
                                                     now: now, sampleCount: count, rate: rate)
        XCTAssertEqual(clamped?.lowerBound, 0)
        XCTAssertEqual(Double(try XCTUnwrap(clamped?.upperBound)), (8 - 5.85) * rate, accuracy: 2)
        // Too short after clamping → nil; zero-length → nil; empty buffer → nil.
        XCTAssertNil(MeetingAudioWindow.sampleRange(start: now.addingTimeInterval(-8.2), end: now.addingTimeInterval(-7.9),
                                                    now: now, sampleCount: count, rate: rate))
        XCTAssertNil(MeetingAudioWindow.sampleRange(start: now, end: now, now: now, sampleCount: count, rate: rate))
        XCTAssertNil(MeetingAudioWindow.sampleRange(start: now.addingTimeInterval(-2), end: now, now: now, sampleCount: 0, rate: rate))
    }
}

final class IntroParserTests: XCTestCase {

    func testOwnerIntroducesSelfAndOthers() {
        let intros = IntroParser.parse("I'm Hawk, here with Alex and Amari.")
        XCTAssertEqual(intros, [Introduction(name: "Hawk", isSelf: true),
                                Introduction(name: "Alex", isSelf: false),
                                Introduction(name: "Amari", isSelf: false)])
    }

    func testSelfIntroWithRoleAndOrg() {
        let intros = IntroParser.parse("Hi, I'm Alex, head of growth at Funneltopia. I run the ad side.")
        XCTAssertEqual(intros.count, 1)
        XCTAssertEqual(intros[0].name, "Alex")
        XCTAssertEqual(intros[0].role, "head of growth")
        XCTAssertEqual(intros[0].org, "Funneltopia")
        XCTAssertTrue(intros[0].isSelf)
    }

    func testTwoWordNameAndRoleWithoutOrg() {
        let intros = IntroParser.parse("This is Amari Jones, the operations lead.")
        XCTAssertEqual(intros, [Introduction(name: "Amari Jones", role: "operations lead", org: "", isSelf: true)])
    }

    func testAndThisIsIntroducesSomeoneElse() {
        let intros = IntroParser.parse("I'm Hawk and this is Sam.")
        XCTAssertEqual(intros.map(\.name), ["Hawk", "Sam"])
        XCTAssertEqual(intros.map(\.isSelf), [true, false])
    }

    func testOrdinarySpeechIsNotAnIntroduction() {
        XCTAssertTrue(IntroParser.parse("I'm going to share my screen now.").isEmpty)
        XCTAssertTrue(IntroParser.parse("I'm here with the numbers from last week.").isEmpty, "\"the\" is never a name")
        XCTAssertTrue(IntroParser.parse("this is the part where we decide").isEmpty)
        XCTAssertTrue(IntroParser.parse("").isEmpty)
    }

    func testJoinedByListStopsAtLowercaseWords() {
        let intros = IntroParser.parse("Joined by Priya from ops, Sam, and Lee Chen today.")
        XCTAssertEqual(intros.map(\.name), ["Priya", "Sam", "Lee Chen"])
        XCTAssertTrue(intros.allSatisfy { !$0.isSelf })
    }

    func testCleanNameRejectsStopWordsAndLongRuns() {
        XCTAssertEqual(IntroParser.cleanName("Alex."), "Alex")
        XCTAssertNil(IntroParser.cleanName("Going"))
        XCTAssertNil(IntroParser.cleanName("alex"))
        XCTAssertNil(IntroParser.cleanName("One Two Three"))
    }
}

final class MeetingExtractionTests: XCTestCase {

    func testDecodesTolerantly() throws {
        let json = #"""
        {"action_items":[
           {"title":"Send the deck to Amari","detail":"The Q3 ad deck","owner_name":"Alex","due_phrase":"Friday","blast_tier":2},
           {"title":"Book the venue","detail":"","owner_name":"","due_phrase":null,"blast_tier":9},
           {"title":"","detail":"dropped: no title"}
         ],
         "decisions":["Go with Stripe"," "],
         "open_questions":[],
         "commitments":["Call the client Monday"]}
        """#
        let x = try JSONDecoder().decode(MeetingExtraction.self, from: Data(json.utf8))
        XCTAssertEqual(x.actionItems.count, 2, "an item without a title is dropped")
        XCTAssertEqual(x.actionItems[0].ownerName, "Alex")
        XCTAssertEqual(x.actionItems[0].duePhrase, "Friday")
        XCTAssertEqual(x.actionItems[0].blastTier, 2)
        XCTAssertNil(x.actionItems[1].ownerName, "empty owner → nil")
        XCTAssertNil(x.actionItems[1].duePhrase)
        XCTAssertEqual(x.actionItems[1].blastTier, 4, "tier is clamped to 0…4")
        XCTAssertEqual(x.decisions, ["Go with Stripe"])
        XCTAssertEqual(x.commitments, ["Call the client Monday"])
        XCTAssertTrue(x.openQuestions.isEmpty)
        let empty = try JSONDecoder().decode(MeetingExtraction.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.isEmpty)
    }

    func testIntakeTextIsTheItemAndOnlyTheItem() {
        let full = MeetingActionItem(title: "Send the deck to Amari", detail: "The Q3 ad deck", ownerName: "Alex", duePhrase: "Friday", blastTier: 2)
        XCTAssertEqual(full.intakeText, "Send the deck to Amari. The Q3 ad deck. Owner: Alex. Due Friday.")
        let bare = MeetingActionItem(title: "Book the venue!")
        XCTAssertEqual(bare.intakeText, "Book the venue!")
    }

    func testDeduperCatchesRepeatsAndNearRepeats() {
        var d = MeetingItemDeduper()
        XCTAssertTrue(d.admit("Send the deck to Amari"))
        XCTAssertFalse(d.admit("send the deck to Amari."), "case and punctuation don't make it new")
        XCTAssertFalse(d.admit("Send the deck to Amari before Friday's review meeting"), "a long superset is the same item")
        XCTAssertTrue(d.admit("Send the invoice"), "short strings only match exactly")
        XCTAssertTrue(d.admit("Send the invoice to Sam"), "a short key inside a longer one isn't containment — too easy to collide")
        XCTAssertFalse(d.admit("   "))
        XCTAssertEqual(d.admitAll(["Book the venue", "book the venue", "Order lunch"]), ["Book the venue", "Order lunch"])
    }

    func testExtractionRequestBodyCarriesTheSchemaAndTheDataRule() throws {
        let body = ClaudeClient.extractionRequestBody(transcript: "Hawk: ship Friday", attendees: ["Hawk", "Alex"],
                                                      model: ClaudeModel(rawValue: "claude-opus-5"), options: ["effort": "low"])
        let oc = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(oc["effort"] as? String, "low")
        let fmt = try XCTUnwrap(oc["format"] as? [String: Any])
        let schema = try XCTUnwrap(fmt["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["action_items", "decisions", "open_questions", "commitments"])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        let items = try XCTUnwrap(props["action_items"] as? [String: Any])
        let item = try XCTUnwrap(items["items"] as? [String: Any])
        let itemProps = try XCTUnwrap(item["properties"] as? [String: Any])
        for f in ["title", "detail", "owner_name", "due_phrase", "blast_tier"] { XCTAssertNotNil(itemProps[f], f) }
        let system = try XCTUnwrap(body["system"] as? String)
        XCTAssertTrue(system.contains("DATA"), "SPEC §12: transcript content is data, never instructions")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(content.contains("Hawk, Alex"))
        XCTAssertTrue(content.contains("Hawk: ship Friday"))
        // Haiku gets the plain shape.
        let plain = ClaudeClient.extractionRequestBody(transcript: "x", attendees: [], model: .haiku45)
        XCTAssertNil((plain["output_config"] as? [String: Any])?["effort"])
        XCTAssertNil(plain["thinking"])
    }
}

final class MeetingSummaryTests: XCTestCase {

    private func outcome(_ title: String, _ kind: String, _ name: String? = nil) -> MeetingTriageOutcome {
        MeetingTriageOutcome(item: MeetingActionItem(title: title), ownerKind: kind, ownerName: name, taskID: nil, status: kind)
    }

    func testSpokenSummaryNamesAgentsHumansAndTheUser() {
        let s = MeetingSummary.spoken([
            outcome("Draft the launch post", "agent", "Content Drafter"),
            outcome("Research venues", "agent", "Researcher"),
            outcome("Send the deck", "human", "Amari"),
            outcome("Approve the ad budget", "user"),
        ])
        XCTAssertEqual(s, "4 action items. Agents took 2: Draft the launch post and Research venues. Amari gets Send the deck. One needs your call: Approve the ad budget.")
    }

    func testSpokenSummaryEdges() {
        XCTAssertEqual(MeetingSummary.spoken([]), "No action items came out of that meeting.")
        XCTAssertEqual(MeetingSummary.spoken([outcome("Book lunch", "agent", "Assistant")]),
                       "One action item. Agents took one: Book lunch. Nothing needs you.")
        let queued = MeetingSummary.spoken([outcome("Book lunch", "queued"), outcome("Send deck", "human", "Alex")])
        XCTAssertTrue(queued.hasPrefix("Two action items. Alex gets Send deck. Nothing needs you."))
        XCTAssertTrue(queued.hasSuffix("One is waiting for the team to come back online; I'll keep trying."))
        XCTAssertEqual(MeetingSummary.list(["A", "B", "C", "D", "E"]), "A, B, and 3 more")
    }
}

final class MeetingMarkdownTests: XCTestCase {

    func testFilenameAndClock() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = MeetingMarkdown.filename(title: "Weekly Sync: Q3 Ads", date: date)
        XCTAssertTrue(name.hasSuffix("-weekly-sync-q3-ads"))
        XCTAssertNotNil(name.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression))
        XCTAssertEqual(MeetingMarkdown.clock(0), "00:00")
        XCTAssertEqual(MeetingMarkdown.clock(192.4), "03:12")
    }

    func testRenderHasEverySection() {
        let item = MeetingActionItem(title: "Send the deck", detail: "Q3", ownerName: "Amari", duePhrase: "Friday", blastTier: 2)
        let md = MeetingMarkdown.render(
            title: "Weekly sync", date: Date(timeIntervalSince1970: 1_800_000_000), attendees: ["Hawk", "Amari"],
            consentRecordedAt: Date(timeIntervalSince1970: 1_800_000_010),
            turns: [MeetingTurn(speaker: "Hawk", text: "Let's ship Friday.", start: 12, end: 14),
                    MeetingTurn(speaker: "Speaker 2", text: "Works for me.", start: 15, end: 16)],
            actionItems: [item], decisions: ["Ship Friday"], openQuestions: [], commitments: [],
            outcomes: [MeetingTriageOutcome(item: item, ownerKind: "human", ownerName: "Amari", taskID: "t_9", status: "assigned")],
            summary: "One action item. Amari gets Send the deck. Nothing needs you.")
        XCTAssertTrue(md.hasPrefix("# Weekly sync\n\n- Date: "))
        XCTAssertTrue(md.contains("- Source: live\n"))
        XCTAssertTrue(md.contains("- Attendees: Hawk, Amari\n"))
        XCTAssertTrue(md.contains("- Consent: recorded "))
        XCTAssertTrue(md.contains("**Hawk** [00:12]: Let's ship Friday.\n"))
        XCTAssertTrue(md.contains("**Speaker 2** [00:15]: Works for me.\n"))
        XCTAssertTrue(md.contains("- [ ] Send the deck — Q3 (owner: Amari, due: Friday, tier 2, → human (Amari) [t_9])\n"))
        XCTAssertTrue(md.contains("## Decisions\n\n- Ship Friday\n"))
        XCTAssertTrue(md.contains("## Open questions\n\n_None._\n"))
        XCTAssertTrue(md.contains("## Summary\n\nOne action item."))
        let bare = MeetingMarkdown.render(title: "x", date: Date(), attendees: [], consentRecordedAt: nil, turns: [],
                                          actionItems: [], decisions: [], openQuestions: [], commitments: [], outcomes: [], summary: "")
        XCTAssertTrue(bare.contains("- Consent: not recorded\n"))
        XCTAssertTrue(bare.contains("_Nothing captured._"))
        XCTAssertFalse(bare.contains("## Summary"))
    }
}

@MainActor
final class MeetingSessionFlowTests: XCTestCase {

    /// A fresh brain under a temp folder per call; callers remove
    /// `brain.directory.deletingLastPathComponent()` when done. (No setUp
    /// override: XCTest's is nonisolated and this class is main-actor.)
    private func makeSession(services: MeetingSession.Services) -> (MeetingSession, LocalBrain, TaskOutbox) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lmnh-meeting-\(UUID().uuidString)")
        let brain = LocalBrain(directory: root)
        let outbox = TaskOutbox(brainDirectory: brain.directory)
        return (MeetingSession(brain: brain, outbox: outbox, services: services), brain, outbox)
    }

    private func cleanUp(_ brain: LocalBrain) {
        try? FileManager.default.removeItem(at: brain.directory.deletingLastPathComponent())
    }

    private func reply(_ id: String, title: String, status: String, ownerKind: String, ownerName: String?) -> IntakeReply {
        IntakeReply(intent: "task", confirmation: "ok",
                    task: TeamTask(id: id, title: title, status: status, ownerName: ownerName, confirmation: "ok",
                                   ownerKind: ownerKind, source: "meeting", blastTier: 2))
    }

    func testOwnerKindFallsBackToStatus() {
        XCTAssertEqual(MeetingSession.ownerKind(of: reply("a", title: "x", status: "dispatching", ownerKind: "agent", ownerName: nil)), "agent")
        XCTAssertEqual(MeetingSession.ownerKind(of: IntakeReply(intent: "task", confirmation: "", task: TeamTask(id: "a", title: "x", status: "assigned", ownerName: "Sam", confirmation: ""))), "human")
        XCTAssertEqual(MeetingSession.ownerKind(of: IntakeReply(intent: "task", confirmation: "", task: TeamTask(id: "a", title: "x", status: "needs_decision", ownerName: nil, confirmation: ""))), "user")
        XCTAssertEqual(MeetingSession.ownerKind(of: IntakeReply(intent: "note", confirmation: "", task: nil)), "user")
    }

    func testLabelledTextRoundTripsAndChunks() {
        let text = "Hawk: we ship Friday\nAlex Chen: I'll send the deck\njust a stray line\nhttps://example.com/x: not a speaker"
        let turns = MeetingSession.turns(fromLabelledText: text)
        XCTAssertEqual(turns.map(\.speaker), ["Hawk", "Alex Chen", "Speaker", "https"])
        XCTAssertEqual(turns[1].text, "I'll send the deck")
        XCTAssertEqual(MeetingSession.labelledText(Array(turns.prefix(2))), "Hawk: we ship Friday\nAlex Chen: I'll send the deck")
        let chunks = MeetingSession.chunks(turns, maxChars: 40)
        XCTAssertEqual(chunks.map(\.count), [1, 1, 1, 1])
        XCTAssertEqual(MeetingSession.chunks(turns, maxChars: 10_000).count, 1)
        XCTAssertTrue(MeetingSession.chunks([], maxChars: 10).isEmpty)
    }

    func testSessionSpeaksConsentTranscribesExtractsTriagesAndWrites() async throws {
        var spoken: [String] = []
        var extracted: [String] = []
        var submitted: [(String, TicketDelivery?)] = []
        var services = MeetingSession.Services()
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        services.now = { clock }
        services.speak = { spoken.append($0) }
        services.extract = { text, _ in
            extracted.append(text)
            return MeetingExtraction(actionItems: [
                MeetingActionItem(title: "Send the deck to Amari", detail: "Q3 ads", ownerName: "Amari", duePhrase: "Friday", blastTier: 2),
                MeetingActionItem(title: "Draft the launch post", detail: "", ownerName: nil, duePhrase: nil, blastTier: 0),
            ], decisions: ["Ship Friday"])
        }
        services.submit = { text, deliver in
            submitted.append((text, deliver))
            if text.hasPrefix("Send the deck") {
                return self.reply("t_1", title: "Send the deck to Amari", status: "assigned", ownerKind: "human", ownerName: "Amari")
            }
            return self.reply("t_2", title: "Draft the launch post", status: "dispatching", ownerKind: "agent", ownerName: "Content Drafter")
        }
        let (session, brain, outbox) = makeSession(services: services)
        defer { cleanUp(brain) }
        brain.upsertPerson(name: "Amari Jones", role: "Ops", email: "amari@example.com")

        await session.start(title: "Weekly sync")
        XCTAssertEqual(spoken, [MeetingSession.consentLine])
        XCTAssertTrue(session.consentRecorded)
        XCTAssertEqual(session.state, .introductions)

        // Two turns from the mic (no audio in the ring → no voiceprint, the label falls back).
        let t0 = clock.addingTimeInterval(-3)
        session.ingest(requestID: 1, startedAt: t0,
                       segments: [SpeechSegment(text: "I'm", timestamp: 0, duration: 0.2),
                                  SpeechSegment(text: "Hawk,", timestamp: 0.25, duration: 0.3),
                                  SpeechSegment(text: "here", timestamp: 0.6, duration: 0.2),
                                  SpeechSegment(text: "with", timestamp: 0.85, duration: 0.2),
                                  SpeechSegment(text: "Amari.", timestamp: 1.1, duration: 0.4)], isFinal: true)
        session.ingest(requestID: 2, startedAt: t0.addingTimeInterval(2),
                       segments: [SpeechSegment(text: "Let's", timestamp: 0, duration: 0.2),
                                  SpeechSegment(text: "ship", timestamp: 0.25, duration: 0.2),
                                  SpeechSegment(text: "Friday", timestamp: 0.5, duration: 0.4)], isFinal: true)
        XCTAssertEqual(session.turns.count, 2)
        XCTAssertEqual(session.turns[0].text, "I'm Hawk, here with Amari.")
        XCTAssertEqual(session.turns[0].speaker, "Hawk", "a self-introduction names the (unrecognised) speaker")
        XCTAssertEqual(session.turns[1].speaker, "Hawk", "too little audio → the previous speaker keeps talking")
        XCTAssertEqual(session.attendees, ["Hawk", "Amari Jones"], "a first name resolves to the person the brain knows")
        XCTAssertNotNil(brain.person(named: "Hawk"))
        XCTAssertEqual(brain.listPeople().map(\.slug), ["amari-jones", "hawk"], "no duplicate file for “Amari”")
        XCTAssertFalse(session.extractionDue(now: clock), "not enough new text yet")

        await session.end()
        XCTAssertEqual(session.state, .ended)
        XCTAssertEqual(extracted.count, 1)
        XCTAssertEqual(extracted[0], "Hawk: I'm Hawk, here with Amari.\nHawk: Let's ship Friday")
        XCTAssertEqual(session.actionItems.map(\.title), ["Send the deck to Amari", "Draft the launch post"])
        XCTAssertEqual(session.decisions, ["Ship Friday"])

        XCTAssertEqual(submitted.count, 2)
        XCTAssertEqual(submitted[0].0, "Send the deck to Amari. Q3 ads. Owner: Amari. Due Friday.")
        XCTAssertEqual(submitted[0].1, TicketDelivery(channel: "email", to: "amari@example.com", name: "Amari Jones"),
                       "the owner's email is handed over once, from the Local Brain, by first name")
        XCTAssertNil(submitted[1].1)
        XCTAssertEqual(session.outcomes.map(\.ownerKind), ["human", "agent"])
        XCTAssertEqual(session.submittedTaskIDs, ["t_1", "t_2"])
        XCTAssertEqual(session.summary, "Two action items. Agents took one: Draft the launch post. Amari gets Send the deck to Amari. Nothing needs you.")
        XCTAssertEqual(spoken.last, session.summary)
        XCTAssertTrue(outbox.isEmpty)

        let md = try String(contentsOf: XCTUnwrap(session.markdownURL), encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# Weekly sync"))
        XCTAssertTrue(md.contains("**Hawk** [00:00]: I'm Hawk, here with Amari."))
        XCTAssertTrue(md.contains("→ human (Amari) [t_1]"))
        XCTAssertTrue(session.markdownURL!.path.hasSuffix("/brain/meetings/2027-01-15-weekly-sync.md")
                      || session.markdownURL!.path.hasSuffix("/brain/meetings/2027-01-14-weekly-sync.md"),
                      "dated in the local zone: \(session.markdownURL!.lastPathComponent)")
    }

    func testUnreachableTeamKeepsItemsInTheOutbox() async throws {
        var services = MeetingSession.Services()
        services.extract = { _, _ in
            MeetingExtraction(actionItems: [MeetingActionItem(title: "Book the venue", detail: "For the offsite", ownerName: "Alex", blastTier: 3)])
        }
        services.submit = { _, _ in nil }   // offline
        let (session, brain, outbox) = makeSession(services: services)
        defer { cleanUp(brain) }
        brain.upsertPerson(name: "Alex", phone: "+1 555 0100")
        await session.start(title: "Offsite planning")
        let t0 = Date().addingTimeInterval(-2)
        session.ingest(requestID: 1, startedAt: t0,
                       segments: (0..<20).map { SpeechSegment(text: "word\($0)", timestamp: Double($0) * 0.1, duration: 0.1) },
                       isFinal: true)
        await session.end()
        XCTAssertEqual(session.outcomes.map(\.ownerKind), ["queued"])
        XCTAssertEqual(outbox.entries.count, 1)
        XCTAssertEqual(outbox.entries[0].text, "Book the venue. For the offsite. Owner: Alex.")
        XCTAssertEqual(outbox.entries[0].delivery, TicketDelivery(channel: "sms", to: "+1 555 0100", name: "Alex"))
        XCTAssertEqual(outbox.entries[0].meeting, session.basename)
        XCTAssertTrue(session.summary.contains("waiting for the team to come back online"))
        // The file survives a relaunch.
        let reopened = TaskOutbox(brainDirectory: brain.directory)
        XCTAssertEqual(reopened.entries, outbox.entries)
    }

    func testCancelDuringConsentRecordsNothing() async {
        var services = MeetingSession.Services()
        let (session, brain, _) = makeSession(services: services)
        defer { cleanUp(brain) }
        // Cancel while the consent line is "being spoken".
        services.speak = { [weak session] _ in session?.cancel() }
        session.services = services
        await session.start(title: "Nope")
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.consentRecorded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.markdownURL?.path ?? "/nonexistent"))
    }

    func testKnownVoiceIsRecognisedAndNewVoiceIsEnrolled() async throws {
        // Voices are told apart by amplitude: loud → the enrolled "Alex", quiet → someone new.
        let rate = SpeakerVerifier.sampleRate
        var amplitude: Float = 0.5
        var services = MeetingSession.Services()
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        services.now = { clock }
        services.recentAudio = { seconds in
            let n = Int(seconds * rate)
            return (0..<n).map { i in amplitude * sinf(Float(i) * 0.3) }
        }
        services.embed = { samples in
            var peak: Float = 0
            for s in samples { peak = max(peak, abs(s)) }
            return peak > 0.3 ? [1, 0, 0] : [0, 1, 0]
        }
        services.threshold = { 0.5 }
        let (session, brain, _) = makeSession(services: services)
        defer { cleanUp(brain) }
        brain.upsertPerson(name: "Alex", role: "Growth")
        brain.addVoiceprint(name: "Alex", embedding: [1, 0, 0])
        XCTAssertTrue(brain.hasVoiceprint(name: "Alex"))

        await session.start(title: "Voices")
        let t0 = clock.addingTimeInterval(-2.5)
        let words = ["I'm", "Alex,", "growth", "lead."].enumerated().map {
            SpeechSegment(text: $1, timestamp: Double($0) * 0.4, duration: 0.35)
        }
        session.ingest(requestID: 1, startedAt: t0, segments: words, isFinal: true)
        amplitude = 0.1
        let words2 = ["This", "is", "Priya,", "design."].enumerated().map {
            SpeechSegment(text: $1, timestamp: Double($0) * 0.4, duration: 0.35)
        }
        session.ingest(requestID: 2, startedAt: t0, segments: words2, isFinal: true)
        await session.end()

        XCTAssertEqual(session.turns.map(\.speaker), ["Alex", "Priya"])
        XCTAssertEqual(session.attendees, ["Alex", "Priya"])
        XCTAssertTrue(brain.hasVoiceprint(name: "Priya"), "a new voice that introduced itself is enrolled")
        XCTAssertEqual(brain.person(named: "Priya")?.role, "design")
        XCTAssertEqual(brain.voiceprints().keys.sorted(), ["Alex", "Priya"])
    }
}
