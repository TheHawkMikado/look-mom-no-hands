import XCTest
@testable import LookMomNoHands

/// Wearable ingest (Phase 6): the Limitless response shape, the request URL,
/// and the poll loop against a fake source — cursor kept, ids remembered,
/// every recording handed to the pipeline exactly once.
final class LimitlessParsingTests: XCTestCase {

    static let sample = #"""
    {"data":{"lifelogs":[
      {"id":"ll_1","title":"Standup with Alex","startTime":"2026-09-13T15:00:00Z","endTime":"2026-09-13T15:20:00Z",
       "markdown":"# Standup\n- Alex: ship Friday",
       "contents":[
         {"type":"heading1","content":"Standup with Alex"},
         {"type":"blockquote","content":"Let's ship on Friday.","speakerName":"Alex","speakerIdentifier":null},
         {"type":"blockquote","content":"I'll send the deck.","speakerName":"","speakerIdentifier":"user",
          "children":[{"type":"blockquote","content":"By Thursday.","speakerName":"Alex"}]}
       ]},
      {"id":"ll_2","title":"","markdown":"Just markdown, no contents."},
      {"id":"","markdown":"dropped: no id"},
      {"id":"ll_4","markdown":"","contents":[{"type":"heading2","content":"only a heading"}]}
    ]},"meta":{"lifelogs":{"nextCursor":"abc123","count":4}}}
    """#

    func testParsesLifelogsIntoSpeakerLines() throws {
        let batch = try XCTUnwrap(LimitlessSource.parse(Data(Self.sample.utf8)))
        XCTAssertEqual(batch.nextCursor, "abc123")
        XCTAssertEqual(batch.recordings.map(\.id), ["ll_1", "ll_2"], "no id → dropped; heading-only → dropped")
        XCTAssertEqual(batch.recordings[0].title, "Standup with Alex")
        XCTAssertEqual(batch.recordings[0].text, "Alex: Let's ship on Friday.\nMe: I'll send the deck.\nAlex: By Thursday.")
        XCTAssertEqual(batch.recordings[0].startedAt, Date(timeIntervalSince1970: 1_789_311_600))
        XCTAssertEqual(batch.recordings[1].title, "Limitless recording")
        XCTAssertEqual(batch.recordings[1].text, "Just markdown, no contents.", "markdown is the fallback")
        XCTAssertNil(batch.recordings[1].startedAt)
    }

    func testEnvelopeErrorsAreNotAnEmptyPage() {
        XCTAssertNil(LimitlessSource.parse(Data("<html>".utf8)))
        XCTAssertNil(LimitlessSource.parse(Data(#"{"error":"unauthorized"}"#.utf8)))
        let empty = LimitlessSource.parse(Data(#"{"data":{"lifelogs":[]},"meta":{"lifelogs":{"nextCursor":null,"count":0}}}"#.utf8))
        XCTAssertEqual(empty?.recordings.count, 0)
        XCTAssertNil(empty?.nextCursor)
    }

    func testRequestURLUsesCursorOrStart() throws {
        let since = Date(timeIntervalSince1970: 1_789_311_600)
        let first = LimitlessSource.url(cursor: nil, since: since)
        let comps = try XCTUnwrap(URLComponents(url: first, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "api.limitless.ai")
        XCTAssertEqual(comps.path, "/v1/lifelogs")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["start"], "2026-09-13T15:00:00Z")
        XCTAssertEqual(items["direction"], "asc")
        XCTAssertEqual(items["limit"], "10")
        XCTAssertNil(items["cursor"])
        let next = LimitlessSource.url(cursor: "abc123", since: since)
        let nextItems = Dictionary(uniqueKeysWithValues: (URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(nextItems["cursor"], "abc123")
        XCTAssertNil(nextItems["start"], "with a cursor the server owns the window")
    }
}

/// A scripted source: pages served in order, every call recorded.
private final class FakeWearableSource: WearableSource {
    let id = "limitless"
    let label = "Fake"
    var pages: [WearableBatch]
    var calls: [(key: String, cursor: String?)] = []
    var error: Error?

    init(pages: [WearableBatch]) { self.pages = pages }

    func fetch(apiKey: String, cursor: String?, since: Date) async throws -> WearableBatch {
        calls.append((apiKey, cursor))
        if let error { throw error }
        guard !pages.isEmpty else { return WearableBatch(recordings: [], nextCursor: cursor) }
        return pages.removeFirst()
    }
}

@MainActor
final class WearableIngestTests: XCTestCase {

    func testPollPagesFilesEachRecordingOnceAndKeepsTheCursor() async {
        let defaults = UserDefaults(suiteName: "lmnh-wear-\(UUID().uuidString)")!
        let r1 = WearableRecording(id: "ll_1", title: "One", text: "Alex: hi", startedAt: nil)
        let r2 = WearableRecording(id: "ll_2", title: "Two", text: "Me: hello", startedAt: nil)
        let source = FakeWearableSource(pages: [
            WearableBatch(recordings: [r1], nextCursor: "c1"),
            WearableBatch(recordings: [r2, r1], nextCursor: "c2"),   // a page that repeats ll_1
        ])
        let ingest = WearableIngest(defaults: defaults, limitless: source, keyProvider: { "key-123" })
        XCTAssertTrue(ingest.hasLimitlessKey)
        var filed: [String] = []
        ingest.onRecording = { filed.append($0.id) }

        await ingest.poll()
        XCTAssertTrue(filed.isEmpty, "disabled → nothing pulled")
        ingest.limitlessEnabled = true   // its didSet kicks off a poll; wait for our own explicit one too
        await ingest.poll()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Set(filed), ["ll_1", "ll_2"])
        XCTAssertEqual(filed.count, 2, "the repeated lifelog is filed once")
        XCTAssertEqual(source.calls.first?.key, "key-123")
        XCTAssertNil(source.calls.first?.cursor ?? nil, "first fetch is bounded by `start`, not a cursor")
        XCTAssertEqual(defaults.string(forKey: "limitlessCursor"), "c2")
        XCTAssertTrue(ingest.lastStatus.hasPrefix("Limitless:"))
        XCTAssertNotNil(ingest.lastPoll)

        // A later poll continues from the stored cursor and files nothing new.
        let before = filed.count
        await ingest.poll()
        XCTAssertEqual(filed.count, before)
        XCTAssertEqual(source.calls.last?.cursor, "c2")
        XCTAssertEqual(ingest.lastStatus, "Limitless: up to date")
    }

    func testFetchErrorIsReportedNotFatal() async {
        let defaults = UserDefaults(suiteName: "lmnh-wear-\(UUID().uuidString)")!
        let source = FakeWearableSource(pages: [])
        source.error = WearableError.http(401)
        let ingest = WearableIngest(defaults: defaults, limitless: source, keyProvider: { "k" })
        var filed = 0
        ingest.onRecording = { _ in filed += 1 }
        ingest.limitlessEnabled = true
        await ingest.poll()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(filed, 0)
        XCTAssertTrue(ingest.lastStatus.contains("HTTP 401"))
        XCTAssertNil(defaults.string(forKey: "limitlessCursor"))
    }

    func testNoKeyMeansNoPoll() async {
        let defaults = UserDefaults(suiteName: "lmnh-wear-\(UUID().uuidString)")!
        let source = FakeWearableSource(pages: [WearableBatch(recordings: [], nextCursor: nil)])
        let ingest = WearableIngest(defaults: defaults, limitless: source, keyProvider: { nil })
        XCTAssertFalse(ingest.hasLimitlessKey)
        ingest.limitlessEnabled = true
        await ingest.poll()
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertEqual(ingest.lastStatus, "Limitless: no API key")
    }

    func testPlaudIsAnHonestStub() async {
        do {
            _ = try await PlaudSource().fetch(apiKey: "x", cursor: nil, since: Date())
            XCTFail("expected notImplemented")
        } catch {
            XCTAssertTrue("\(error)".contains("Plaud"))
        }
    }
}
