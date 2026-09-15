import XCTest
@testable import LookMomNoHands

final class BrowserBridgeTests: XCTestCase {

    // MARK: refs in planner targets

    func testRefIsRecognisedInItsUsualSpellings() {
        XCTAssertEqual(BrowserProtocol.ref(in: "e7"), "e7")
        XCTAssertEqual(BrowserProtocol.ref(in: " E12 "), "e12")
        XCTAssertEqual(BrowserProtocol.ref(in: "[e3]"), "e3")
        XCTAssertEqual(BrowserProtocol.ref(in: "e3 Search box"), "e3")
        XCTAssertEqual(BrowserProtocol.ref(in: "ref e41"), "e41")
        XCTAssertEqual(BrowserProtocol.ref(in: "e5: Go"), "e5")
    }

    func testOrdinaryLabelsAreNotRefs() {
        XCTAssertNil(BrowserProtocol.ref(in: "Search"))
        XCTAssertNil(BrowserProtocol.ref(in: "email address field"))
        XCTAssertNil(BrowserProtocol.ref(in: "e"))
        XCTAssertNil(BrowserProtocol.ref(in: "edit"), "a word starting with e followed by letters is a label")
        XCTAssertNil(BrowserProtocol.ref(in: "e12345"), "refs are at most four digits")
        XCTAssertNil(BrowserProtocol.ref(in: "the first video thumbnail"))
    }

    // MARK: pairing / origin

    func testPairingCodeIsSixDigits() {
        let code = BrowserProtocol.pairingCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
    }

    func testHelloIsAcceptedOnlyWithTheExactCode() {
        XCTAssertTrue(BrowserProtocol.acceptsHello(token: "123456", expected: "123456"))
        XCTAssertFalse(BrowserProtocol.acceptsHello(token: "123457", expected: "123456"))
        XCTAssertFalse(BrowserProtocol.acceptsHello(token: "12345", expected: "123456"))
        XCTAssertFalse(BrowserProtocol.acceptsHello(token: "", expected: "123456"))
        XCTAssertFalse(BrowserProtocol.acceptsHello(token: "", expected: ""), "an empty expected code never pairs")
    }

    func testOnlyExtensionOriginsMayConnect() {
        XCTAssertTrue(BrowserProtocol.acceptsOrigin("chrome-extension://abcdefghijklmnopabcdefghijklmnop"))
        XCTAssertTrue(BrowserProtocol.acceptsOrigin("moz-extension://1234"))
        XCTAssertFalse(BrowserProtocol.acceptsOrigin("https://evil.example"))
        XCTAssertFalse(BrowserProtocol.acceptsOrigin("http://127.0.0.1:47831"))
        XCTAssertFalse(BrowserProtocol.acceptsOrigin(""), "no Origin header is not a browser extension")
    }

    func testChromiumDetection() {
        XCTAssertTrue(BrowserProtocol.isChromiumBrowser(bundleID: "com.google.Chrome"))
        XCTAssertTrue(BrowserProtocol.isChromiumBrowser(bundleID: "company.thebrowser.Browser"))
        XCTAssertTrue(BrowserProtocol.isChromiumBrowser(bundleID: "com.brave.Browser"))
        XCTAssertFalse(BrowserProtocol.isChromiumBrowser(bundleID: "com.apple.Safari"))
        XCTAssertFalse(BrowserProtocol.isChromiumBrowser(bundleID: nil))
    }

    // MARK: wire format

    func testRequestEncodesIdMethodParams() throws {
        let data = try BrowserProtocol.encodeRequest(id: 7, method: "click", params: ["ref": "e3"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? Int, 7)
        XCTAssertEqual(obj["method"] as? String, "click")
        XCTAssertEqual((obj["params"] as? [String: Any])?["ref"] as? String, "e3")
    }

    func testDecodeHelloPingResponseEvent() {
        if case .hello(let token, let ext, let version) = BrowserProtocol.decode(Data(#"{"type":"hello","token":"123456","extension":"abc","version":"0.1.0"}"#.utf8)) {
            XCTAssertEqual(token, "123456"); XCTAssertEqual(ext, "abc"); XCTAssertEqual(version, "0.1.0")
        } else { XCTFail("hello not decoded") }

        if case .ping = BrowserProtocol.decode(Data(#"{"type":"ping"}"#.utf8)) {} else { XCTFail("ping not decoded") }

        if case .response(let id, let result, let error) = BrowserProtocol.decode(Data(#"{"id":3,"result":{"ok":true,"url":"https://x"}}"#.utf8)) {
            XCTAssertEqual(id, 3); XCTAssertEqual(result["ok"] as? Bool, true); XCTAssertNil(error)
        } else { XCTFail("response not decoded") }

        if case .response(let id, _, let error) = BrowserProtocol.decode(Data(#"{"id":4,"error":"unknown ref e99"}"#.utf8)) {
            XCTAssertEqual(id, 4); XCTAssertEqual(error, "unknown ref e99")
        } else { XCTFail("error response not decoded") }

        if case .event(let name, let payload) = BrowserProtocol.decode(Data(#"{"event":"navigated","url":"https://a/b","tabId":9}"#.utf8)) {
            XCTAssertEqual(name, "navigated"); XCTAssertEqual(payload["url"] as? String, "https://a/b"); XCTAssertNil(payload["event"])
        } else { XCTFail("event not decoded") }

        if case .unknown = BrowserProtocol.decode(Data("not json".utf8)) {} else { XCTFail("garbage must decode as unknown") }
        if case .unknown = BrowserProtocol.decode(Data(#"{"type":"whatever"}"#.utf8)) {} else { XCTFail("unknown type must decode as unknown") }
    }

    // MARK: snapshot → prompt

    private let sample: [String: Any] = [
        "url": "https://fixture.test/", "title": "Runner Fixture", "focused": "e4", "total": 40,
        "elements": [
            ["ref": "e1", "role": "heading", "name": "Welcome"],
            ["ref": "e2", "role": "link", "name": "Docs", "href": "/docs"],
            ["ref": "e3", "role": "textbox", "name": "Address and search bar", "value": ""],
            ["ref": "e4", "role": "textbox", "name": "Search", "value": "cats"],
            ["ref": "e5", "role": "checkbox", "name": "I agree", "checked": false],
            ["ref": "e6", "role": "button", "name": "Go", "disabled": true],
            ["ref": "e7", "role": "link", "name": "Bottom", "href": "/bottom", "offscreen": true],
        ],
    ]

    func testSnapshotParsesEveryField() {
        let snap = BrowserSnapshot.parse(sample)
        XCTAssertEqual(snap.url, "https://fixture.test/")
        XCTAssertEqual(snap.title, "Runner Fixture")
        XCTAssertEqual(snap.focused, "e4")
        XCTAssertEqual(snap.total, 40)
        XCTAssertEqual(snap.elements.count, 7)
        XCTAssertEqual(snap.elements[1].href, "/docs")
        XCTAssertEqual(snap.elements[4].checked, false)
        XCTAssertTrue(snap.elements[5].disabled)
        XCTAssertTrue(snap.elements[6].offscreen)
    }

    func testPromptTextListsRefsAndHidesTheAddressBar() {
        let text = BrowserSnapshot.parse(sample).promptText
        XCTAssertTrue(text.contains("browser tab \"Runner Fixture\" (https://fixture.test/)"))
        XCTAssertTrue(text.contains("- e2 link \"Docs\" → /docs"))
        XCTAssertTrue(text.contains("- e4 textbox \"Search\" = \"cats\" [focused]"))
        XCTAssertTrue(text.contains("- e5 checkbox \"I agree\" (unchecked)"))
        XCTAssertTrue(text.contains("- e6 button \"Go\" (disabled)"))
        XCTAssertTrue(text.contains("- e7 link \"Bottom\" → /bottom (offscreen — scroll to it)"))
        XCTAssertFalse(text.contains("Address and search bar"), "the address bar is never offered as a target")
        XCTAssertTrue(text.contains("33 more elements not listed"))
        XCTAssertTrue(text.contains("target is ITS REF"))
    }

    func testEmptySnapshotSaysSo() {
        let text = BrowserSnapshot.parse(["url": "about:blank", "title": ""]).promptText
        XCTAssertTrue(text.contains("No interactive elements found"))
    }

    func testMalformedElementsAreSkipped() {
        let snap = BrowserSnapshot.parse(["elements": [["role": "link"], ["ref": "e1"], ["ref": "e2", "role": "button", "name": "OK"]]])
        XCTAssertEqual(snap.elements.map(\.ref), ["e2"])
    }
}
