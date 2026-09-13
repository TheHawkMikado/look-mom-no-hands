import XCTest
@testable import LookMomNoHands

/// The Local Brain (SPEC §8.1): readable markdown files plus an index. The pure
/// pieces — slugging, rendering, the index round trip — are pinned here, and
/// one end-to-end pass writes to a temp folder and reads it back.
final class LocalBrainTests: XCTestCase {

    // MARK: slugs

    func testSlugIsFileSafeAndStable() {
        XCTAssertEqual(LocalBrain.slug("Hawk Mikado"), "hawk-mikado")
        XCTAssertEqual(LocalBrain.slug("  José  Álvarez-Núñez "), "jose-alvarez-nunez", "diacritics fold, runs collapse")
        XCTAssertEqual(LocalBrain.slug("Content Drafter (agent)"), "content-drafter-agent")
        XCTAssertEqual(LocalBrain.slug("Q3 / Ads: Meta & Google"), "q3-ads-meta-google")
        XCTAssertEqual(LocalBrain.slug("---"), "untitled")
        XCTAssertEqual(LocalBrain.slug(""), "untitled")
        XCTAssertEqual(LocalBrain.slug("Hawk Mikado"), LocalBrain.slug("hawk mikado"), "same person, same file")
    }

    // MARK: markdown rendering (no frontmatter)

    func testPersonMarkdownHasHeadingFactsAndNotes() {
        let md = LocalBrain.personMarkdown(name: "Sam Lee", role: "Editor", org: "Funneltopia", notes: "Prefers Slack.")
        XCTAssertTrue(md.hasPrefix("# Sam Lee\n\n"), "a heading, not a frontmatter block")
        XCTAssertFalse(md.hasPrefix("---"))
        XCTAssertTrue(md.contains("- Role: Editor\n"))
        XCTAssertTrue(md.contains("- Org: Funneltopia\n"))
        XCTAssertTrue(md.contains("## Notes\n\nPrefers Slack.\n"))
    }

    func testPersonMarkdownOmitsEmptyFacts() {
        let md = LocalBrain.personMarkdown(name: "Sam", role: "", org: "  ", notes: "")
        XCTAssertEqual(md, "# Sam\n\n## Notes\n\n")
    }

    func testNotesSectionRoundTrips() {
        let md = LocalBrain.personMarkdown(name: "Sam", role: "Editor", org: "", notes: "One.\nTwo.")
        XCTAssertEqual(LocalBrain.notesSection(of: md), "One.\nTwo.")
        XCTAssertEqual(LocalBrain.notesSection(of: "# No notes here\n"), "")
    }

    func testInboxLineIsDatedTaggedAndSingleLine() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)   // fixed, but the formatter uses the local zone
        let line = LocalBrain.inboxLine(kind: "decision", text: "Go with Stripe.\nNot Paddle.", date: date)
        XCTAssertTrue(line.hasPrefix("- "))
        XCTAssertTrue(line.contains(" [decision] Go with Stripe. Not Paddle."), "newlines fold into one entry")
        XCTAssertFalse(line.contains("\n"))
        XCTAssertNotNil(line.range(of: #"^- \d{4}-\d{2}-\d{2} \d{2}:\d{2} \["#, options: .regularExpression))
    }

    func testMatchIsCaseInsensitiveOverTitleThenBody() {
        XCTAssertEqual(LocalBrain.match(query: "sam", title: "Sam Lee", body: ""), "Sam Lee")
        XCTAssertEqual(LocalBrain.match(query: "SLACK", title: "Sam Lee", body: "# Sam Lee\n\n- Role: Editor\nPrefers Slack.\n"),
                       "Prefers Slack.")
        XCTAssertNil(LocalBrain.match(query: "zoom", title: "Sam Lee", body: "Prefers Slack."))
    }

    // MARK: index round trip

    func testIndexRoundTripsThroughJSON() throws {
        let updated = Date(timeIntervalSince1970: 1_757_800_000)
        let index: [String: BrainIndexEntry] = [
            "sam-lee": BrainIndexEntry(title: "Sam Lee", updated: updated, kind: "person"),
            "inbox": BrainIndexEntry(title: "Inbox", updated: updated, kind: "inbox"),
        ]
        let data = try XCTUnwrap(LocalBrain.encodeIndex(index))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"sam-lee\""), "keyed by slug")
        XCTAssertTrue(text.contains("2025-09-13T") , "ISO-8601 dates, readable by hand")
        let back = try XCTUnwrap(LocalBrain.decodeIndex(data))
        XCTAssertEqual(back, index)
        XCTAssertNil(LocalBrain.decodeIndex(Data("nope".utf8)))
    }

    // MARK: end to end on disk

    @MainActor private func brain() -> LocalBrain {
        LocalBrain(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-brain-\(UUID().uuidString)"))
    }

    @MainActor func testUpsertPersonWritesMarkdownAndIndexAndSearches() throws {
        let b = brain()
        b.upsertPerson(name: "Sam Lee", role: "Editor", org: "Funneltopia", notes: "Prefers Slack.")
        b.upsertPerson(name: "Ana Ruiz", role: "Designer")
        XCTAssertEqual(b.listPeople().map(\.title), ["Ana Ruiz", "Sam Lee"], "alphabetical")
        XCTAssertEqual(b.listPeople().map(\.slug), ["ana-ruiz", "sam-lee"])

        let file = b.directory.appendingPathComponent("people/sam-lee.md")
        let md = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# Sam Lee"))

        // Re-introducing someone ADDS notes rather than replacing them.
        b.upsertPerson(name: "sam lee", role: "Editor", org: "Funneltopia", notes: "Out on Fridays.")
        let again = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(again.contains("Prefers Slack."))
        XCTAssertTrue(again.contains("Out on Fridays."))
        XCTAssertEqual(b.listPeople().count, 2, "same slug, same file")

        let hits = b.search("fridays")
        XCTAssertEqual(hits.map(\.slug), ["sam-lee"])
        XCTAssertEqual(hits.first?.snippet, "Out on Fridays.")
        XCTAssertTrue(b.search("").isEmpty)

        // The index survives a relaunch.
        let reopened = LocalBrain(directory: b.directory.deletingLastPathComponent())
        XCTAssertEqual(reopened.listPeople().map(\.slug), ["ana-ruiz", "sam-lee"])
        try? FileManager.default.removeItem(at: b.directory.deletingLastPathComponent())
    }

    @MainActor func testAppendNoteGoesToInboxAndPreferencesToTheirOwnFile() throws {
        let b = brain()
        b.appendNote(kind: "decision", text: "We're going with Stripe.")
        b.appendNote(kind: "note", text: "Tow truck number is on the fridge.")
        b.appendNote(kind: "preference", text: "Short replies.")
        b.appendNote(kind: "note", text: "   ")   // ignored

        let inbox = try String(contentsOf: b.directory.appendingPathComponent("inbox.md"), encoding: .utf8)
        XCTAssertTrue(inbox.hasPrefix("# Inbox\n"))
        XCTAssertTrue(inbox.contains("[decision] We're going with Stripe."))
        XCTAssertTrue(inbox.contains("[note] Tow truck number is on the fridge."))
        XCTAssertFalse(inbox.contains("Short replies"), "preferences have their own file")
        XCTAssertEqual(inbox.components(separatedBy: "\n- ").count - 1, 2, "one line per entry, nothing blank")

        let prefs = try String(contentsOf: b.directory.appendingPathComponent("preferences.md"), encoding: .utf8)
        XCTAssertTrue(prefs.contains("[preference] Short replies."))

        XCTAssertEqual(b.search("stripe").first?.kind, "inbox")
        XCTAssertEqual(b.search("short replies").first?.kind, "preferences")
        XCTAssertTrue(b.listPeople().isEmpty, "inbox entries are not people")
        try? FileManager.default.removeItem(at: b.directory.deletingLastPathComponent())
    }
}
