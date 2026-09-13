import XCTest
@testable import LookMomNoHands

/// Quiet hours / "a good moment to speak" (SPEC §5.4, Phase 6), the team
/// prompt channel, and the offline outbox.
final class QuietHoursTests: XCTestCase {

    func testWindowWrapsMidnight() {
        let start = 22 * 60, end = 7 * 60
        XCTAssertTrue(QuietHours.isQuiet(minuteOfDay: 22 * 60, start: start, end: end), "the start minute is inside")
        XCTAssertTrue(QuietHours.isQuiet(minuteOfDay: 23 * 60 + 59, start: start, end: end))
        XCTAssertTrue(QuietHours.isQuiet(minuteOfDay: 0, start: start, end: end))
        XCTAssertTrue(QuietHours.isQuiet(minuteOfDay: 6 * 60 + 59, start: start, end: end))
        XCTAssertFalse(QuietHours.isQuiet(minuteOfDay: 7 * 60, start: start, end: end), "the end minute is outside")
        XCTAssertFalse(QuietHours.isQuiet(minuteOfDay: 12 * 60, start: start, end: end))
    }

    func testDaytimeWindowAndDegenerateWindow() {
        XCTAssertTrue(QuietHours.isQuiet(minuteOfDay: 13 * 60, start: 12 * 60, end: 14 * 60))
        XCTAssertFalse(QuietHours.isQuiet(minuteOfDay: 15 * 60, start: 12 * 60, end: 14 * 60))
        XCTAssertFalse(QuietHours.isQuiet(minuteOfDay: 12 * 60, start: 12 * 60, end: 12 * 60), "start == end → never quiet")
    }

    func testTimeParsingAndLabels() {
        XCTAssertEqual(QuietHours.minute(from: "22:00"), 1320)
        XCTAssertEqual(QuietHours.minute(from: " 7:05 "), 425)
        XCTAssertNil(QuietHours.minute(from: "25:00"))
        XCTAssertNil(QuietHours.minute(from: "9"))
        XCTAssertNil(QuietHours.minute(from: "22:60"))
        XCTAssertNil(QuietHours.minute(from: ""))
        XCTAssertEqual(QuietHours.label(minute: 1320), "22:00")
        XCTAssertEqual(QuietHours.label(minute: 425), "07:05")
        XCTAssertEqual(QuietHours.label(minute: 1440), "00:00")
    }

    @MainActor func testGoodMomentGate() {
        let defaults = UserDefaults(suiteName: "lmnh-quiet-\(UUID().uuidString)")!
        let q = QuietHours(defaults: defaults)
        XCTAssertEqual(q.startMinute, 22 * 60, "default 22:00")
        XCTAssertEqual(q.endMinute, 7 * 60, "default 07:00")
        XCTAssertTrue(q.muteDuringMeetings)
        XCTAssertTrue(q.muteWhileLocked)
        var noon = DateComponents()
        noon.year = 2026; noon.month = 9; noon.day = 14; noon.hour = 12; noon.minute = 0
        let midday = Calendar.current.date(from: noon)!
        var late = noon
        late.hour = 23
        let night = Calendar.current.date(from: late)!

        XCTAssertTrue(q.goodMomentToSpeak(idle: true, inMeeting: false, recording: false, now: midday))
        XCTAssertFalse(q.goodMomentToSpeak(idle: false, inMeeting: false, recording: false, now: midday))
        XCTAssertFalse(q.goodMomentToSpeak(idle: true, inMeeting: true, recording: false, now: midday))
        XCTAssertFalse(q.goodMomentToSpeak(idle: true, inMeeting: false, recording: true, now: midday))
        XCTAssertFalse(q.goodMomentToSpeak(idle: true, inMeeting: false, recording: false, now: night))
        XCTAssertEqual(q.reasonNotToSpeak(idle: true, inMeeting: false, recording: false, now: night), "quiet hours")
        XCTAssertEqual(q.reasonNotToSpeak(idle: true, inMeeting: true, recording: false, now: midday), "in a meeting")
        XCTAssertNil(q.reasonNotToSpeak(idle: true, inMeeting: false, recording: false, now: midday))

        q.muteDuringMeetings = false
        XCTAssertTrue(q.goodMomentToSpeak(idle: true, inMeeting: true, recording: false, now: midday))
        q.startMinute = 11 * 60
        q.endMinute = 13 * 60
        XCTAssertFalse(q.goodMomentToSpeak(idle: true, inMeeting: false, recording: false, now: midday))
        // Settings persist through the injected defaults.
        let again = QuietHours(defaults: defaults)
        XCTAssertEqual(again.startMinute, 11 * 60)
        XCTAssertFalse(again.muteDuringMeetings)
    }
}

final class TeamPromptTests: XCTestCase {

    func testParsesPromptsInBothSpellings() throws {
        let json = #"""
        {"prompts":[
          {"id":"p1","kind":"escalation","taskId":"t1","question":"Amari hasn't sent the deck. Nudge Amari Friday morning, or handle it yourself?","defaultAnswer":"nudge Amari Friday morning","spokenAt":null},
          {"id":"p2","kind":"daily_brief","task_id":null,"question":"Three things are outstanding today.","default_answer":""},
          {"id":"","question":"dropped"},
          {"id":"p3","question":""}
        ]}
        """#
        let prompts = try XCTUnwrap(TeamClient.parsePrompts(Data(json.utf8)))
        XCTAssertEqual(prompts.map(\.id), ["p1", "p2"])
        XCTAssertEqual(prompts[0].defaultAnswer, "nudge Amari Friday morning")
        XCTAssertEqual(prompts[0].taskID, "t1")
        XCTAssertEqual(prompts[1].kind, "daily_brief")
        XCTAssertEqual(prompts[1].defaultAnswer, "")
        XCTAssertNil(TeamClient.parsePrompts(Data("<html>".utf8)), "no envelope = unreachable, not empty")
        XCTAssertEqual(TeamClient.parsePrompts(Data(#"{"prompts":[]}"#.utf8))?.count, 0)
    }

    func testSpokenPromptEndsWithThePromise() {
        let p = TeamPrompt(id: "p1", kind: "escalation",
                           question: "Amari hasn't sent the deck. Nudge Amari Friday morning, or handle it yourself",
                           defaultAnswer: "nudge Amari Friday morning", taskID: "t1")
        XCTAssertEqual(TeamClient.spokenPrompt(p),
                       "Amari hasn't sent the deck. Nudge Amari Friday morning, or handle it yourself? I'll nudge Amari Friday morning unless you say otherwise.")
        let brief = TeamPrompt(id: "p2", kind: "daily_brief", question: "Three things are outstanding today.", defaultAnswer: "ok", taskID: nil)
        XCTAssertEqual(TeamClient.spokenPrompt(brief), "Three things are outstanding today.", "a brief is a statement, not a bargain")
        let noDefault = TeamPrompt(id: "p3", kind: "escalation", question: "Drop it?", defaultAnswer: "", taskID: nil)
        XCTAssertEqual(TeamClient.spokenPrompt(noDefault), "Drop it?")
    }

    func testIntakeBodyCarriesOnlyTheItemText() throws {
        let body = TeamClient.intakeBody(text: "Send the deck. Owner: Amari. Due Friday.", source: "meeting",
                                         deliver: TicketDelivery(channel: "email", to: "amari@example.com", name: "Amari Jones"))
        XCTAssertEqual(body["text"] as? String, "Send the deck. Owner: Amari. Due Friday.")
        XCTAssertEqual(body["source"] as? String, "meeting")
        let deliver = try XCTUnwrap(body["deliver"] as? [String: Any])
        XCTAssertEqual(deliver["channel"] as? String, "email")
        XCTAssertEqual(deliver["to"] as? String, "amari@example.com")
        XCTAssertEqual(deliver["name"] as? String, "Amari Jones")
        XCTAssertEqual(Set(body.keys), ["text", "source", "deliver"], "no transcript, no audio, nothing else — SPEC §4.3")
        let plain = TeamClient.intakeBody(text: "x", source: "voice", deliver: nil)
        XCTAssertEqual(Set(plain.keys), ["text", "source"])
        XCTAssertNotNil(try JSONSerialization.data(withJSONObject: body), "serialisable as sent")
    }

    func testTaskRowsCarryOriginAndTier() throws {
        let json = #"{"tasks":[{"id":"a","title":"Send the deck","status":"awaiting_approval","owner_kind":"human","owner_name":"Amari","source":"meeting","blast_tier":2},{"id":"b","title":"Old","status":"in_progress"}]}"#
        let tasks = try XCTUnwrap(TeamClient.parseTasks(Data(json.utf8)))
        XCTAssertEqual(tasks[0].source, "meeting")
        XCTAssertEqual(tasks[0].ownerKind, "human")
        XCTAssertEqual(tasks[0].blastTier, 2)
        XCTAssertTrue(tasks[0].needsVerifiedVoiceApproval, "meeting-born + tier ≥ 2 → verified voice or the phone")
        XCTAssertNil(tasks[1].source)
        XCTAssertEqual(tasks[1].blastTier, 0)
        XCTAssertFalse(tasks[1].needsVerifiedVoiceApproval)
        XCTAssertFalse(TeamTask(id: "c", title: "t", status: "s", ownerName: nil, confirmation: "", source: "meeting", blastTier: 1).needsVerifiedVoiceApproval)
    }
}

final class TaskOutboxTests: XCTestCase {

    func testEntriesRoundTripThroughJSON() throws {
        let entries = [
            OutboxEntry(id: "e1", text: "Send the deck. Owner: Amari.", meeting: "2026-09-13-weekly-sync",
                        createdAt: Date(timeIntervalSince1970: 1_757_800_000), attempts: 2,
                        deliver: TicketDelivery(channel: "email", to: "amari@example.com", name: "Amari")),
            OutboxEntry(id: "e2", text: "Book the venue.", meeting: "limitless-abc", createdAt: Date(timeIntervalSince1970: 1_757_800_001)),
        ]
        let data = try XCTUnwrap(TaskOutbox.encode(entries))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"2025-09-13T"), "ISO-8601, readable by hand")
        XCTAssertFalse(text.contains("transcript"))
        let back = try XCTUnwrap(TaskOutbox.decode(data))
        XCTAssertEqual(back, entries)
        XCTAssertEqual(back[0].delivery, TicketDelivery(channel: "email", to: "amari@example.com", name: "Amari"))
        XCTAssertNil(back[1].delivery)
        XCTAssertNil(TaskOutbox.decode(Data("nope".utf8)))
    }

    @MainActor func testOutboxPersistsUntilDelivered() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lmnh-outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let box = TaskOutbox(brainDirectory: dir)
        XCTAssertTrue(box.isEmpty)
        box.enqueue(OutboxEntry(id: "e1", text: "Send the deck.", meeting: "m"))
        box.enqueue(OutboxEntry(id: "e2", text: "Book the venue.", meeting: "m"))
        box.recordAttempt(id: "e1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("outbox.json").path))

        // A relaunch sees the same two items, attempt count included.
        let reopened = TaskOutbox(brainDirectory: dir)
        XCTAssertEqual(reopened.entries.map(\.id), ["e1", "e2"])
        XCTAssertEqual(reopened.entries[0].attempts, 1)

        reopened.remove(id: "e1")
        XCTAssertEqual(TaskOutbox(brainDirectory: dir).entries.map(\.id), ["e2"])
        reopened.remove(id: "e2")
        XCTAssertTrue(reopened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("outbox.json").path),
                       "an empty outbox leaves no file behind")
    }
}
