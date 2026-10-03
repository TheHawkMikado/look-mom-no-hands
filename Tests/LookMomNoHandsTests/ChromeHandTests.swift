import XCTest
@testable import LookMomNoHands

final class ChromeHandTests: XCTestCase {

    // MARK: refs

    func testRefParsing() {
        XCTAssertEqual(ChromeHand.ref(in: "e12"), "e12")
        XCTAssertEqual(ChromeHand.ref(in: "[e12]"), "e12")
        XCTAssertEqual(ChromeHand.ref(in: "E7"), "e7")
        XCTAssertEqual(ChromeHand.ref(in: "[e3] button \"Send\""), "e3")
        XCTAssertNil(ChromeHand.ref(in: "the send button"))
        XCTAssertNil(ChromeHand.ref(in: "edge"))
        XCTAssertNil(ChromeHand.ref(in: "e3 something else"), "a bare ref followed by words is ambiguous")
        XCTAssertNil(ChromeHand.ref(in: ""))
    }

    // MARK: pairing

    func testTokenShape() {
        for _ in 0..<50 {
            let t = ChromeHand.makeToken()
            XCTAssertEqual(t.count, 6)
            XCTAssertFalse(t.contains("0") || t.contains("O") || t.contains("1") || t.contains("I") || t.contains("L"))
        }
        XCTAssertEqual(ChromeHand.normalizeToken(" ab-c1 23\n"), "ABC123")
    }

    func testChromiumDetection() {
        XCTAssertTrue(ChromeHand.isChromiumBrowser(bundleID: "com.google.Chrome"))
        XCTAssertTrue(ChromeHand.isChromiumBrowser(bundleID: "com.google.Chrome.canary"))
        XCTAssertTrue(ChromeHand.isChromiumBrowser(bundleID: "com.brave.Browser"))
        XCTAssertTrue(ChromeHand.isChromiumBrowser(bundleID: "company.thebrowser.Browser"))
        XCTAssertFalse(ChromeHand.isChromiumBrowser(bundleID: "com.apple.Safari"))
        XCTAssertFalse(ChromeHand.isChromiumBrowser(bundleID: nil))
    }

    // MARK: match picking

    func testPickRequiresAClearWinner() {
        let a = Match(ref: "e1", role: "button", name: "Sign in", score: 100)
        let b = Match(ref: "e2", role: "link", name: "Sign in help", score: 70)
        XCTAssertEqual(ChromeHand.pick([a, b]), a)
        XCTAssertNil(ChromeHand.pick([Match(ref: "e1", role: "link", name: "x", score: 40)]), "weak match falls through")
        let tie1 = Match(ref: "e1", role: "link", name: "Pricing plans", score: 70)
        let tie2 = Match(ref: "e2", role: "link", name: "Pricing FAQ", score: 70)
        XCTAssertNil(ChromeHand.pick([tie1, tie2]), "a tie is not a decision")
        XCTAssertNil(ChromeHand.pick([]))
    }

    // MARK: frames

    func testDecodeFrame() {
        XCTAssertEqual(ChromeHand.decodeFrame(Data("{\"id\":3,\"result\":{\"ok\":true}}".utf8))?["id"] as? Int, 3)
        XCTAssertNil(ChromeHand.decodeFrame(Data("not json".utf8)))
        XCTAssertNil(ChromeHand.decodeFrame(Data("[1,2]".utf8)), "a frame is always an object")
    }

    // MARK: page map → prompt

    func testPageMapPromptText() throws {
        let json: [String: Any] = [
            "url": "https://example.com/login", "title": "Sign in",
            "total": 5,
            "elements": [
                ["ref": "e1", "role": "link", "name": "Pricing", "href": "/pricing", "inView": true],
                ["ref": "e2", "role": "textbox", "name": "Email", "placeholder": "you@example.com", "inView": true],
                ["ref": "e3", "role": "combobox", "name": "Plan", "value": "Starter", "options": ["Starter", "Team"], "inView": true],
                ["ref": "e4", "role": "button", "name": "Sign in", "state": ["disabled"], "inView": false],
            ],
            "headings": ["h1 Welcome back"],
            "text": "Welcome back. Enter your email.",
        ]
        let map = try PageMap.decode(json)
        let p = map.promptText
        XCTAssertTrue(p.hasPrefix("On screen now: Chrome — Sign in (https://example.com/login)"))
        XCTAssertTrue(p.contains("[e1] link \"Pricing\" → /pricing"))
        XCTAssertTrue(p.contains("[e2] textbox \"Email\" (empty; placeholder \"you@example.com\")"))
        XCTAssertTrue(p.contains("[e3] combobox \"Plan\" (= \"Starter\"; options: Starter, Team)"))
        XCTAssertTrue(p.contains("[e4] button \"Sign in\" (disabled; offscreen)"))
        XCTAssertTrue(p.contains("(1 more elements not listed"))
        XCTAssertTrue(p.contains("Headings: h1 Welcome back"))
        XCTAssertTrue(p.contains("Page text (excerpt): Welcome back."))
        XCTAssertTrue(p.contains("target is the ref"), "the planner is told how to use refs")
    }

    func testEmptyPageMap() throws {
        let map = try PageMap.decode(["url": "about:blank", "title": "", "elements": []])
        XCTAssertTrue(map.promptText.contains("no interactive elements"))
    }
}
