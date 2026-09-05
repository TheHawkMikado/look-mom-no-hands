import XCTest
@testable import LookMomNoHands

final class MeetingTests: XCTestCase {

    // MARK: Link detection

    func testDetectsMeetLinkInCalendarNotes() {
        let text = "Weekly sync\nJoin: https://meet.google.com/abc-defg-hij?authuser=0\nAgenda: ..."
        let link = MeetingLink.detect(in: text)
        XCTAssertEqual(link?.service, .meet)
        XCTAssertEqual(link?.url, "https://meet.google.com/abc-defg-hij?authuser=0")
        XCTAssertNil(link?.appDeepLink)   // Meet is browser-only
    }

    func testDetectsSchemelessMeetLink() {
        let link = MeetingLink.detect(in: "room is meet.google.com/xyz-abcd-efg see you there")
        XCTAssertEqual(link?.service, .meet)
        XCTAssertEqual(link?.url, "https://meet.google.com/xyz-abcd-efg")
    }

    func testDetectsZoomLinkAndBuildsDeepLink() {
        let text = "Topic: Standup <https://us02web.zoom.us/j/86091234567?pwd=aBcD1234>"
        let link = MeetingLink.detect(in: text)
        XCTAssertEqual(link?.service, .zoom)
        XCTAssertEqual(link?.url, "https://us02web.zoom.us/j/86091234567?pwd=aBcD1234")
        XCTAssertEqual(link?.appDeepLink, "zoommtg://us02web.zoom.us/join?confno=86091234567&pwd=aBcD1234")
    }

    func testZoomVanityLinkHasNoDeepLink() {
        let link = MeetingLink.detect(in: "https://zoom.us/my/hawkmikado")
        XCTAssertEqual(link?.service, .zoom)
        XCTAssertNil(link?.appDeepLink)   // no conference number to hand zoommtg
    }

    func testDetectsTeamsLinkAndBuildsDeepLink() {
        let url = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d"
        let link = MeetingLink.detect(in: "Click here to join: \(url)")
        XCTAssertEqual(link?.service, .teams)
        XCTAssertEqual(link?.appDeepLink, url.replacingOccurrences(of: "https://", with: "msteams://"))
    }

    func testTeamsLiveLinkStaysInBrowser() {
        let link = MeetingLink.detect(in: "https://teams.live.com/meet/9387513350?p=abc")
        XCTAssertEqual(link?.service, .teams)
        XCTAssertNil(link?.appDeepLink)
    }

    func testEarliestLinkWinsAcrossServices() {
        let text = "zoom fallback https://zoom.us/j/123456789 but prefer https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(MeetingLink.detect(in: text)?.service, .zoom)
    }

    func testNoLinkInPlainProse() {
        XCTAssertNil(MeetingLink.detect(in: "let's meet at the google office and zoom around"))
    }

    // MARK: Join click-through vocabulary

    func testPermissionPromptBeatsJoinButton() {
        let labels = ["Join now", "Allow while visiting the site", "Block"]
        XCTAssertEqual(MeetingLink.nextJoinControl(in: labels, service: .meet, alreadyClicked: []),
                       "Allow while visiting the site")
    }

    func testAlreadyClickedControlIsSkipped() {
        let labels = ["Join now", "Got it"]
        XCTAssertEqual(MeetingLink.nextJoinControl(in: labels, service: .meet, alreadyClicked: ["Join now"]),
                       "Got it")
        XCTAssertNil(MeetingLink.nextJoinControl(in: labels, service: .meet,
                                                 alreadyClicked: ["Join now", "Got it"]))
    }

    func testZoomAudioButtonMatchesByContainment() {
        let labels = ["Mute", "Join with Computer Audio", "Test Speaker and Microphone"]
        XCTAssertEqual(MeetingLink.nextJoinControl(in: labels, service: .zoom, alreadyClicked: []),
                       "Join with Computer Audio")
    }

    func testInMeetingMarkers() {
        XCTAssertTrue(MeetingLink.indicatesInMeeting("Leave call"))
        XCTAssertTrue(MeetingLink.indicatesInMeeting("Leave"))
        XCTAssertTrue(MeetingLink.indicatesInMeeting("Hang up"))
        XCTAssertFalse(MeetingLink.indicatesInMeeting("Leave a comment"))
        XCTAssertFalse(MeetingLink.indicatesInMeeting("Join now"))
    }

    func testLeaveControlsNeverEndForAll() {
        // "End meeting for all" kicks every participant — the leave vocabulary
        // must never contain a control with "end" in it.
        XCTAssertFalse(MeetingLink.leaveControls.contains { $0.lowercased().contains("end") })
    }

    // MARK: New plan kinds

    func testMeetingKindsDecode() throws {
        let join = try JSONDecoder().decode(ScreenAction.self,
            from: Data(#"{"kind":"join_meeting","target":"standup","text":"","url":"https://meet.google.com/abc-defg-hij","confidence":1.0}"#.utf8))
        XCTAssertEqual(join.kind, .joinMeeting)
        XCTAssertEqual(join.url, "https://meet.google.com/abc-defg-hij")
        let leave = try JSONDecoder().decode(ScreenAction.self,
            from: Data(#"{"kind":"leave_meeting","target":"","confidence":1.0}"#.utf8))
        XCTAssertEqual(leave.kind, .leaveMeeting)
    }

    // MARK: Calendar meeting selection

    private func meeting(_ title: String, startIn: TimeInterval, minutes: Double = 30,
                         service: MeetingService = .meet, now: Date) -> CalendarMeetings.UpcomingMeeting {
        CalendarMeetings.UpcomingMeeting(id: title, title: title,
                                         start: now.addingTimeInterval(startIn),
                                         end: now.addingTimeInterval(startIn + minutes * 60),
                                         link: MeetingLink(service: service, url: "https://example.test/\(title)"))
    }

    func testPickPrefersImminentMeeting() {
        let now = Date()
        let list = [meeting("Standup", startIn: 5 * 60, now: now),
                    meeting("Board review", startIn: 3 * 3600, now: now)]
        XCTAssertEqual(CalendarMeetings.pick(from: list, hint: "", now: now)?.title, "Standup")
    }

    func testPickMatchesTitleHint() {
        let now = Date()
        let list = [meeting("Standup", startIn: 5 * 60, now: now),
                    meeting("Design review", startIn: 10 * 60, now: now)]
        XCTAssertEqual(CalendarMeetings.pick(from: list, hint: "the design meeting", now: now)?.title,
                       "Design review")
    }

    func testPickMatchesServiceHint() {
        let now = Date()
        let list = [meeting("Standup", startIn: 5 * 60, service: .meet, now: now),
                    meeting("Client call", startIn: 8 * 60, service: .zoom, now: now)]
        XCTAssertEqual(CalendarMeetings.pick(from: list, hint: "my zoom", now: now)?.title, "Client call")
    }

    func testPickWithUnmatchedHintReturnsNilNotSomeOtherMeeting() {
        // "Join the interview panel" with only a Board review on the calendar
        // must NOT fall back to Board review — that joins the wrong live call.
        let now = Date()
        let list = [meeting("Board review", startIn: 5 * 60, now: now)]
        XCTAssertNil(CalendarMeetings.pick(from: list, hint: "the interview panel", now: now))
    }

    func testMeetRoomCodeExtractedForTabMatching() {
        let meet = MeetingLink.detect(in: "https://meet.google.com/abc-defg-hij?authuser=0")
        XCTAssertEqual(meet?.roomCode, "abc-defg-hij")
        let zoom = MeetingLink.detect(in: "https://zoom.us/j/86091234567")
        XCTAssertNil(zoom?.roomCode)   // zoom tab titles don't carry the id
    }

    func testPickSkipsEndedMeetings() {
        let now = Date()
        let over = meeting("Old", startIn: -7200, minutes: 30, now: now)
        XCTAssertNil(CalendarMeetings.pick(from: [over], hint: "", now: now))
    }

    func testPromptTextListsUrlPerMeeting() {
        let now = Date()
        let text = CalendarMeetings.promptText(for: [meeting("Standup", startIn: 300, now: now)], now: now)
        XCTAssertTrue(text.contains("join_meeting"))
        XCTAssertTrue(text.contains("https://example.test/Standup"))
        XCTAssertEqual(CalendarMeetings.promptText(for: [], now: now), "")
    }

    // MARK: Audio mixer

    func testMixerMixesOverlapAndClamps() {
        var m = MeetingAudioMixer(maxLeadFrames: 100)
        m.appendSystem([0.5, 0.9, -0.5])
        m.appendMic([0.5, 0.9, -0.9])
        XCTAssertEqual(m.drain(), [1.0, 1.0, -1.0])   // summed, clamped at ±1
        XCTAssertTrue(m.drain().isEmpty)               // nothing buffered afterward
    }

    func testMixerHoldsLaggardUntilOverlap() {
        var m = MeetingAudioMixer(maxLeadFrames: 100)
        m.appendSystem([0.1, 0.2, 0.3])
        XCTAssertTrue(m.drain().isEmpty)     // mic hasn't produced yet — wait
        m.appendMic([0.0])
        XCTAssertEqual(m.drain(), [0.1])     // only the overlapping frame mixes
        XCTAssertEqual(m.system, [0.2, 0.3])
    }

    func testMixerFlushesStalledSourceAgainstSilence() {
        var m = MeetingAudioMixer(maxLeadFrames: 2)
        m.appendSystem([0.1, 0.2, 0.3])      // mic dead; leader beyond maxLead
        XCTAssertEqual(m.drain(), [0.1, 0.2, 0.3])
        XCTAssertTrue(m.system.isEmpty)
    }

    func testMixerFlushAllEmptiesBothTails() {
        var m = MeetingAudioMixer(maxLeadFrames: 1000)
        m.appendSystem([0.1, 0.2])
        m.appendMic([0.3])
        XCTAssertEqual(m.drain(flushAll: true), [MeetingAudioMixer.clamp(0.4), 0.2])
        XCTAssertTrue(m.system.isEmpty)
        XCTAssertTrue(m.mic.isEmpty)
    }

    func testRecordingURLSanitizesTitle() {
        let dir = FileManager.default.temporaryDirectory
        let url = MeetingRecorder.recordingURL(in: dir, title: "Q3: Plan / Review",
                                               now: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".m4a"))
        XCTAssertTrue(url.path.contains("/Recordings/"))
    }
}
