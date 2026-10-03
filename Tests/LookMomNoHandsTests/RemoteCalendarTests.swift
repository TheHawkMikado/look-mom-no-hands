import XCTest
@testable import LookMomNoHands

final class RemoteCalendarTests: XCTestCase {

    // MARK: PKCE / OAuth plumbing

    func testCodeChallengeMatchesRFC7636Vector() {
        // RFC 7636 appendix B's published verifier → challenge pair.
        XCTAssertEqual(CalendarOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCodeVerifierIsURLSafeAndLong() {
        let v = CalendarOAuth.codeVerifier()
        XCTAssertGreaterThanOrEqual(v.count, 43)   // RFC 7636 minimum
        XCTAssertNil(v.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testAuthorizationURLCarriesPKCEAndExtras() throws {
        let url = try XCTUnwrap(CalendarOAuth.authorizationURL(
            endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            clientID: "cid", redirectURI: "http://127.0.0.1:1234",
            scope: "openid email", state: "st", challenge: "ch",
            extra: ["prompt": "consent"]))
        let q = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func val(_ n: String) -> String? { q.first { $0.name == n }?.value }
        XCTAssertEqual(val("code_challenge"), "ch")
        XCTAssertEqual(val("code_challenge_method"), "S256")
        XCTAssertEqual(val("redirect_uri"), "http://127.0.0.1:1234")
        XCTAssertEqual(val("prompt"), "consent")
    }

    func testExtractCodeHappyPath() throws {
        let line = "GET /?state=st&code=abc123 HTTP/1.1"
        XCTAssertEqual(try CalendarOAuth.extractCode(fromRequestLine: line, expectedState: "st"), "abc123")
    }

    func testExtractCodeRejectsStateMismatchAndProviderError() {
        // A stale tab from an earlier attempt must not complete this one.
        XCTAssertThrowsError(try CalendarOAuth.extractCode(
            fromRequestLine: "GET /?state=OLD&code=abc HTTP/1.1", expectedState: "st"))
        XCTAssertThrowsError(try CalendarOAuth.extractCode(
            fromRequestLine: "GET /?error=access_denied&state=st HTTP/1.1", expectedState: "st"))
    }

    func testFormBodyPercentEncodes() {
        let body = String(decoding: CalendarOAuth.formBody(["a": "x y+z", "b": "ok-._~"]), as: UTF8.self)
        XCTAssertEqual(body, "a=x%20y%2Bz&b=ok-._~")
    }

    func testEmailFromIDToken() {
        // header.payload.sig with payload {"email":"hawk@hawkmikado.com"}
        let payload = CalendarOAuth.base64URL(Data(#"{"email":"hawk@hawkmikado.com"}"#.utf8))
        XCTAssertEqual(RemoteCalendarClient.email(fromIDToken: "h.\(payload).s"), "hawk@hawkmikado.com")
        let msPayload = CalendarOAuth.base64URL(Data(#"{"preferred_username":"hawk@outlook.com"}"#.utf8))
        XCTAssertEqual(RemoteCalendarClient.email(fromIDToken: "h.\(msPayload).s"), "hawk@outlook.com")
    }

    // MARK: Google parsing

    func testGoogleCalendarIDsPrimaryFirstAndCapped() {
        let json = """
        {"items":[{"id":"b","selected":true},{"id":"p","primary":true,"selected":true},{"id":"x","selected":false}]}
        """
        XCTAssertEqual(RemoteCalendarClient.googleCalendarIDs(from: Data(json.utf8)), ["p", "b"])
    }

    func testGoogleMeetingsParseConferenceDataAndSkipAllDayAndCancelled() throws {
        let json = """
        {"items":[
          {"id":"e1","summary":"Standup",
           "start":{"dateTime":"2026-10-03T17:00:00Z"},"end":{"dateTime":"2026-10-03T17:30:00Z"},
           "conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://meet.google.com/abc-defg-hij"}]}},
          {"id":"e2","summary":"All day","start":{"date":"2026-10-03"},"end":{"date":"2026-10-04"},
           "location":"https://meet.google.com/zzz-zzzz-zzz"},
          {"id":"e3","summary":"Cancelled","status":"cancelled",
           "start":{"dateTime":"2026-10-03T18:00:00Z"},"end":{"dateTime":"2026-10-03T18:30:00Z"},
           "hangoutLink":"https://meet.google.com/qqq-qqqq-qqq"},
          {"id":"e4","summary":"No link",
           "start":{"dateTime":"2026-10-03T19:00:00Z"},"end":{"dateTime":"2026-10-03T19:30:00Z"}}
        ]}
        """
        let out = RemoteCalendarClient.googleMeetings(from: Data(json.utf8))
        XCTAssertEqual(out.count, 1)
        let m = try XCTUnwrap(out.first)
        XCTAssertEqual(m.title, "Standup")
        XCTAssertTrue(m.id.hasPrefix("g:e1#"))
        XCTAssertEqual(m.link.service, .meet)
        XCTAssertEqual(m.end.timeIntervalSince(m.start), 1800)
    }

    func testGoogleMeetingsFindPastedLinkInDescription() {
        let json = """
        {"items":[{"id":"e5","summary":"Client call",
          "start":{"dateTime":"2026-10-03T20:00:00Z"},"end":{"dateTime":"2026-10-03T20:30:00Z"},
          "description":"dial in: https://us02web.zoom.us/j/86091234567?pwd=x"}]}
        """
        let out = RemoteCalendarClient.googleMeetings(from: Data(json.utf8))
        XCTAssertEqual(out.first?.link.service, .zoom)
    }

    // MARK: Microsoft parsing

    func testGraphDateParsesSevenDigitFractionAsUTC() throws {
        let d = try XCTUnwrap(RemoteCalendarClient.graphDate("2026-10-03T17:00:00.0000000"))
        XCTAssertEqual(d.timeIntervalSince1970, 1791046800)   // 2026-10-03 17:00 UTC
    }

    func testMicrosoftMeetingsParseJoinUrlAndSkipAllDay() throws {
        let json = """
        {"value":[
          {"id":"m1","subject":"Teams sync","isAllDay":false,
           "start":{"dateTime":"2026-10-03T17:00:00.0000000","timeZone":"UTC"},
           "end":{"dateTime":"2026-10-03T17:30:00.0000000","timeZone":"UTC"},
           "onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"}},
          {"id":"m2","subject":"Holiday","isAllDay":true,
           "start":{"dateTime":"2026-10-03T00:00:00.0000000","timeZone":"UTC"},
           "end":{"dateTime":"2026-10-04T00:00:00.0000000","timeZone":"UTC"},
           "location":{"displayName":"https://teams.microsoft.com/l/meetup-join/x/0"}},
          {"id":"m3","subject":"Cancelled","isAllDay":false,"isCancelled":true,
           "start":{"dateTime":"2026-10-03T18:00:00.0000000","timeZone":"UTC"},
           "end":{"dateTime":"2026-10-03T18:30:00.0000000","timeZone":"UTC"},
           "onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/y/0"}}
        ]}
        """
        let out = RemoteCalendarClient.microsoftMeetings(from: Data(json.utf8))
        XCTAssertEqual(out.count, 1)
        let m = try XCTUnwrap(out.first)
        XCTAssertEqual(m.title, "Teams sync")
        XCTAssertTrue(m.id.hasPrefix("m:m1#"))
        XCTAssertEqual(m.link.service, .teams)
    }

    // MARK: Token persistence shape

    func testTokensRoundTripThroughJSON() throws {
        let t = RemoteCalendarTokens(kind: .google, email: "hawk@hawkmikado.com",
                                     accessToken: "a", refreshToken: "r",
                                     expiresAt: Date(timeIntervalSince1970: 1_791_000_000))
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(RemoteCalendarTokens.self, from: data)
        XCTAssertEqual(back.kind, .google)
        XCTAssertEqual(back.refreshToken, "r")
        XCTAssertEqual(back.expiresAt, t.expiresAt)
        XCTAssertEqual(RemoteCalendarTokens.keychainAccount(.microsoft), "calendar.microsoft")
    }
}
