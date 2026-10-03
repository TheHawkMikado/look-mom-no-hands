import XCTest
@testable import LookMomNoHands

final class OpenPreferenceTests: XCTestCase {

    private func step(_ json: String) throws -> ScreenAction {
        try JSONDecoder().decode(ScreenAction.self, from: Data(json.utf8))
    }

    func testKeyNormalises() {
        XCTAssertEqual(OpenPreferenceStore.key(" ChatGPT.app "), "chatgpt")
        XCTAssertEqual(OpenPreferenceStore.key("the Slack"), "slack")
    }

    func testWebEquivalentsBothWays() {
        XCTAssertEqual(OpenPreferenceStore.webURL(forApp: "ChatGPT"), "chatgpt.com")
        XCTAssertNil(OpenPreferenceStore.webURL(forApp: "Xcode"))
        XCTAssertEqual(OpenPreferenceStore.appName(forURL: "https://chatgpt.com/c/abc"), "chatgpt")
        XCTAssertEqual(OpenPreferenceStore.appName(forURL: "www.docs.google.com/document/1"), "google docs")
        XCTAssertNil(OpenPreferenceStore.appName(forURL: "https://nohandsapp.com"))
    }

    func testCandidateFromOpenApp() throws {
        let s = try step(#"{"kind":"open_app","target":"ChatGPT"}"#)
        let c = OpenPreferenceStore.candidate(name: s.target, url: s.url, kind: s.kind)
        XCTAssertEqual(c?.name, "ChatGPT")
        XCTAssertEqual(c?.url, "chatgpt.com")
        // The planner's own url wins over the table.
        let s2 = try step(#"{"kind":"open_app","target":"Linear","url":"linear.app/hawk"}"#)
        XCTAssertEqual(OpenPreferenceStore.candidate(name: s2.target, url: s2.url, kind: s2.kind)?.url, "linear.app/hawk")
        // A native-only app is never a candidate.
        let s3 = try step(#"{"kind":"open_app","target":"Finder"}"#)
        XCTAssertNil(OpenPreferenceStore.candidate(name: s3.target, url: s3.url, kind: s3.kind))
    }

    func testCandidateFromOpenURL() throws {
        let s = try step(#"{"kind":"open_url","url":"https://chatgpt.com","target":""}"#)
        let c = OpenPreferenceStore.candidate(name: s.target, url: s.url, kind: s.kind)
        XCTAssertEqual(c?.name, "chatgpt")
        let plain = try step(#"{"kind":"open_url","url":"https://nohandsapp.com","target":""}"#)
        XCTAssertNil(OpenPreferenceStore.candidate(name: plain.target, url: plain.url, kind: plain.kind))
        let click = try step(#"{"kind":"click","target":"ChatGPT"}"#)
        XCTAssertNil(OpenPreferenceStore.candidate(name: click.target, url: click.url, kind: click.kind))
    }

    func testExplicitChoiceInTheCommand() {
        XCTAssertEqual(OpenPreferenceStore.explicitChoice(in: "Hey Mama open ChatGPT in Chrome"), .browser)
        XCTAssertEqual(OpenPreferenceStore.explicitChoice(in: "open the ChatGPT app"), .app)
        XCTAssertEqual(OpenPreferenceStore.explicitChoice(in: "open slack on my computer"), .app)
        XCTAssertNil(OpenPreferenceStore.explicitChoice(in: "open chatgpt"))
        XCTAssertNil(OpenPreferenceStore.explicitChoice(in: "open the table of contents"), "whole words only")
        XCTAssertEqual(OpenPreferenceStore.explicitChoice(in: "open chatgpt in a new tab"), .browser)
    }

    func testParseAnswer() {
        XCTAssertEqual(OpenPreferenceStore.parseAnswer("Chrome"), .browser)
        XCTAssertEqual(OpenPreferenceStore.parseAnswer("in the browser please"), .browser)
        XCTAssertEqual(OpenPreferenceStore.parseAnswer("The app"), .app)
        XCTAssertEqual(OpenPreferenceStore.parseAnswer("on my computer"), .app)
        XCTAssertEqual(OpenPreferenceStore.parseAnswer("the app, no wait, chrome"), .browser)
        XCTAssertNil(OpenPreferenceStore.parseAnswer("huh"))
        XCTAssertNil(OpenPreferenceStore.parseAnswer(""))
    }

    @MainActor
    func testStoreRemembersAndForgets() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-prefs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OpenPreferenceStore(directory: dir)
        XCTAssertNil(store.lookup("ChatGPT"))
        store.set(name: "ChatGPT", choice: .browser, url: "chatgpt.com")
        XCTAssertEqual(store.lookup("chatgpt")?.choice, .browser)
        store.set(name: "chatgpt", choice: .app, url: "chatgpt.com")
        XCTAssertEqual(store.preferences.count, 1, "one entry per thing")
        XCTAssertEqual(store.lookup("ChatGPT")?.choice, .app)
        store.remove(store.preferences[0].id)
        XCTAssertNil(store.lookup("ChatGPT"))
    }
}
