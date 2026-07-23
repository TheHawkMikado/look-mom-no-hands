import XCTest
@testable import LookMomNoHands

/// Guards the prompt-caching setup on the command hot path.
///
/// Caching here is worth roughly a third of the per-hour API cost, and every way
/// it breaks is silent: the API returns 200 and bills full price whether the
/// prefix cached or not. There is no error to notice, so these assertions are
/// the only thing standing between a working cache and paying 10x for it
/// indefinitely.
final class PromptCacheTests: XCTestCase {

    /// claude-haiku-4-5 refuses to cache prefixes shorter than this and says
    /// nothing about it. The tool definition sits close to the line, so a prompt
    /// edit that trims it can silently switch caching off.
    private let haikuCacheMinimumTokens = 4096

    private func body(vocabulary: String = "", screen: String = "", context: String = "")
        -> [String: Any] {
        ClaudeClient.planRequestBody(transcript: "open youtube",
                                     vocabulary: vocabulary,
                                     screen: screen,
                                     context: context,
                                     model: .haiku45)
    }

    func testToolCarriesACacheBreakpoint() throws {
        let tools = try XCTUnwrap(body()["tools"] as? [[String: Any]])
        let cache = try XCTUnwrap(tools.first?["cache_control"] as? [String: String],
                                  "the tool is the largest static thing we send — without a "
                                    + "breakpoint every command pays full input price")
        XCTAssertEqual(cache["type"], "ephemeral")
    }

    /// The whole point of splitting the system prompt: per-turn bytes must come
    /// *after* the cached ones. Screen state ahead of the breakpoint would
    /// invalidate the prefix on every single command.
    func testPerTurnContentSitsAfterTheBreakpointAndIsNotItselfCached() throws {
        let system = try XCTUnwrap(
            body(vocabulary: "Say 'lmnh' as look-mom-no-hands.",
                 screen: "Chrome — 42 elements",
                 context: "Recent actions: opened Safari")["system"] as? [[String: Any]])

        XCTAssertEqual(system.count, 2, "expected a stable block then a per-turn block")

        XCTAssertNotNil(system[0]["cache_control"], "the stable block anchors the cache")
        XCTAssertTrue((system[0]["text"] as? String ?? "").contains("lmnh"))

        let volatile = try XCTUnwrap(system[1]["text"] as? String)
        XCTAssertTrue(volatile.contains("Chrome"), "screen state belongs in the tail block")
        XCTAssertTrue(volatile.contains("Recent actions"))
        XCTAssertNil(system[1]["cache_control"],
                     "caching per-turn content writes a fresh entry every command — "
                       + "pure cost, never a hit")
    }

    /// With nothing stable to say there is no second breakpoint, but the tool
    /// must still carry its own or a new user caches nothing at all.
    func testCachingStillAppliesWithNoStableContent() throws {
        let b = body(screen: "Finder — 3 elements")
        let tools = try XCTUnwrap(b["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools.first?["cache_control"])

        let system = try XCTUnwrap(b["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertNil(system[0]["cache_control"])
    }

    /// ~4 characters per token. Coarse, but the failures this guards against are
    /// losing a third of the prompt, not drifting by ten tokens.
    private func approxTokens(_ body: [String: Any]) throws -> Int {
        var prefix = try JSONSerialization.data(
            withJSONObject: XCTUnwrap(body["tools"] as? [[String: Any]])).count
        // The breakpoint sits on the first system block, so anything up to and
        // including it is part of the same cacheable prefix.
        if let system = body["system"] as? [[String: Any]],
           let first = system.first, first["cache_control"] != nil {
            prefix += (first["text"] as? String ?? "").count
        }
        return prefix / 4
    }

    /// The tool alone does **not** clear Haiku's minimum — measured at ~3.3k
    /// against a 4096 floor. This is recorded rather than asserted away because
    /// it is the live state of the app: a brand-new user, with no vocabulary or
    /// remembered facts yet, caches nothing and pays full input price.
    ///
    /// The test exists to catch the prompt shrinking *further* and to keep the
    /// real number visible. Closing the gap means adding genuinely useful
    /// content to the tool description — worked examples of the failure modes
    /// already fixed in prose — not filler to game a threshold.
    func testBareToolFallsShortOfTheCacheMinimum_knownGap() throws {
        let tokens = try approxTokens(body())
        XCTAssertGreaterThan(tokens, 3_000,
                             "the tool description has been trimmed substantially; "
                               + "that widens an already-open caching gap")
        XCTAssertLessThan(tokens, haikuCacheMinimumTokens,
                          """
                          The bare tool now clears \(haikuCacheMinimumTokens) tokens — \
                          caching engages for every user, including new ones. That's \
                          the goal: delete this test and keep only the one below.
                          """)
    }

    /// Once a user has accumulated vocabulary and remembered facts, the stable
    /// block extends the prefix past the minimum and caching starts paying. This
    /// asserts the wiring actually delivers that — the breakpoint has to sit on
    /// the stable block for its bytes to count toward the prefix at all.
    func testPrefixClearsTheMinimumOnceStableContentAccumulates() throws {
        // ~1k tokens: the bare tool is ~760 short of the minimum, so this is the
        // rough volume of vocabulary and remembered facts an established user
        // needs before caching starts paying.
        let stable = String(repeating: "Say 'lmnh' as look-mom-no-hands. ", count: 120)
        let tokens = try approxTokens(body(vocabulary: stable, screen: "Chrome — 42 elements"))
        XCTAssertGreaterThan(
            tokens, haikuCacheMinimumTokens,
            "with ~\(stable.count / 4) tokens of stable content the prefix should "
              + "clear \(haikuCacheMinimumTokens); if it doesn't, the breakpoint is "
              + "in the wrong place and the stable block isn't counting")
    }

    /// Spoken replies are billed per character by the TTS provider, so an
    /// unbounded `say` field is a recurring cost, not just a verbose one.
    func testSayFieldConstrainsSpokenLength() throws {
        let tools = try XCTUnwrap(body()["tools"] as? [[String: Any]])
        let schema = try XCTUnwrap(tools.first?["input_schema"] as? [String: Any])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        let say = try XCTUnwrap(props["say"] as? [String: Any])
        let description = try XCTUnwrap(
            say["description"] as? String,
            "an undescribed `say` lets the model speak at any length, and every "
              + "character is billed")
        XCTAssertTrue(description.lowercased().contains("word"),
                      "the description should bound the spoken length")
    }
}
