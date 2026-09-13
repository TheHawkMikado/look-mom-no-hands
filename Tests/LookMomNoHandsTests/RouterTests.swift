import XCTest
@testable import LookMomNoHands

/// The Mac's side of the model router: the seed must match MODEL_ROUTING.md,
/// the server's table must parse tolerantly, and a lookup must always return a
/// real model — offline, with a garbled cache, or for a task type the server
/// forgot.
final class RouterTests: XCTestCase {

    // MARK: seed mirrors MODEL_ROUTING.md

    func testSeedMatchesTheRoutingTableDocument() {
        let seed = RoutingTable.seed
        XCTAssertEqual(seed.qualityFloor, 0.6)
        XCTAssertEqual(seed.routes["intent_classify"]?.model, "claude-haiku-4-5")
        XCTAssertEqual(seed.routes["triage_decision"]?.model, "claude-haiku-4-5")
        XCTAssertEqual(seed.routes["task_extract"]?.model, "claude-opus-5")
        XCTAssertEqual(seed.routes["task_extract"]?.options["effort"], "low")
        XCTAssertEqual(seed.routes["summarize_meeting"]?.model, "claude-opus-5")
        XCTAssertEqual(seed.routes["summarize_meeting"]?.options["thinking"], "adaptive")
        XCTAssertEqual(seed.routes["draft_copy_short"]?.model, "claude-opus-5")
        XCTAssertEqual(seed.routes["code_change"]?.options["effort"], "xhigh")
        XCTAssertEqual(seed.routes["stt"]?.provider, "apple")
        XCTAssertEqual(seed.routes["speaker_id"]?.model, "ecapa-tdnn-coreml")
    }

    // MARK: server payload

    private let payload = #"""
    {"quality_floor":0.6,"routes":{
      "intent_classify":{"model":"claude-haiku-4-5","provider":"anthropic","options":{},
                         "candidates":[{"model":"claude-haiku-4-5","provider":"anthropic","score":0.8}]},
      "task_extract":{"model":"claude-opus-5","provider":"anthropic","options":{"effort":"low"},
                      "candidates":[{"model":"claude-opus-5","provider":"anthropic","score":0.85},
                                    {"model":"claude-haiku-4-5","provider":"anthropic","score":0.7}]},
      "draft_copy_long":{"model":"claude-opus-5","provider":"anthropic","options":{"thinking":"adaptive","stream":true,"max_uses":4}},
      "call_agent_realtime":{"model":null,"provider":null}
    }}
    """#

    func testParsesWinnersAndStringifiesOptions() throws {
        let table = try XCTUnwrap(RoutingTable.parse(Data(payload.utf8)))
        XCTAssertEqual(table.qualityFloor, 0.6)
        XCTAssertEqual(table.routes["intent_classify"]?.model, "claude-haiku-4-5")
        XCTAssertEqual(table.routes["task_extract"]?.options, ["effort": "low"])
        XCTAssertEqual(table.routes["draft_copy_long"]?.options["stream"], "true",
                       "a JSON boolean reads as \"true\", not \"1\"")
        XCTAssertEqual(table.routes["draft_copy_long"]?.options["max_uses"], "4")
        XCTAssertNil(table.routes["call_agent_realtime"], "a task type with no model is dropped, not fatal")
    }

    func testGarbledOrEmptyPayloadNeverReplacesTheTable() {
        XCTAssertNil(RoutingTable.parse(Data("not json".utf8)))
        XCTAssertNil(RoutingTable.parse(Data(#"{"quality_floor":0.6}"#.utf8)), "no routes → nil")
        XCTAssertNil(RoutingTable.parse(Data(#"{"routes":{}}"#.utf8)), "empty routes → nil, the seed stays")
        XCTAssertNil(RoutingTable.parse(Data(#"{"routes":{"x":{"model":""}}}"#.utf8)))
    }

    func testMissingProviderDefaultsToAnthropic() throws {
        let table = try XCTUnwrap(RoutingTable.parse(Data(#"{"routes":{"intent_classify":{"model":"m"}}}"#.utf8)))
        XCTAssertEqual(table.routes["intent_classify"]?.provider, "anthropic")
    }

    func testStringifiedDistinguishesBoolFromNumber() throws {
        // Through JSONSerialization, as in production — that is where booleans
        // and numbers both arrive as NSNumber and have to be told apart.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"a":true,"b":false,"c":1,"d":2.5,"e":"x","f":[1,2]}"#.utf8)) as? [String: Any])
        let out = RoutingTable.stringified(raw)
        XCTAssertEqual(out["a"], "true")
        XCTAssertEqual(out["b"], "false")
        XCTAssertEqual(out["c"], "1")
        XCTAssertEqual(out["d"], "2.5")
        XCTAssertEqual(out["e"], "x")
        XCTAssertNil(out["f"], "nested values have no string form and are dropped")
    }

    // MARK: lookups fall back, never fail

    func testLookupFallsBackToTheSeedPerTaskType() throws {
        let router = ModelRouter()
        // A server table that only routes ONE task type: the others must still
        // resolve from the seed, and an unknown type must still yield a model.
        let partial = try XCTUnwrap(RoutingTable.parse(Data(#"{"routes":{"intent_classify":{"model":"claude-haiku-9","provider":"anthropic"}}}"#.utf8)))
        router.install(partial, source: "test")
        XCTAssertEqual(router.model(for: "intent_classify"), "claude-haiku-9")
        XCTAssertEqual(router.model(for: "summarize_meeting"), "claude-opus-5", "seed fills the gap")
        XCTAssertEqual(router.options(for: "summarize_meeting"), ["thinking": "adaptive"])
        XCTAssertEqual(router.model(for: "no_such_task_type"), "claude-haiku-4-5", "never an empty model string")
        XCTAssertEqual(router.options(for: "no_such_task_type"), [:])
        XCTAssertEqual(router.source, "test")
    }

    func testFreshRouterServesTheSeed() {
        let router = ModelRouter()
        XCTAssertEqual(router.source, "seed")
        XCTAssertEqual(router.model(for: "intent_classify"), "claude-haiku-4-5")
        XCTAssertEqual(router.model(for: "summarize_meeting"), "claude-opus-5")
    }

    // MARK: request shapes follow the routed model's family

    func testRoutedOpusIdGetsThinkingAndEffort() {
        let m = ClaudeModel(rawValue: "claude-opus-5")
        XCTAssertTrue(m.supportsAdaptiveThinking)
        XCTAssertTrue(m.supportsEffort)
        let body = ClaudeClient.reportRequestBody(transcript: "x", model: m, options: ["effort": "low"])
        XCTAssertNotNil(body["thinking"])
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low",
                       "the route's effort knob overrides the default")
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
    }

    func testRoutedHaikuIdStaysPlain() {
        let m = ClaudeModel(rawValue: "claude-haiku-4-5")
        XCTAssertFalse(m.supportsEffort)
        let body = ClaudeClient.reportRequestBody(transcript: "x", model: m, options: ["effort": "low"])
        XCTAssertNil(body["thinking"])
        XCTAssertNil((body["output_config"] as? [String: Any])?["effort"], "Haiku rejects effort with a 400")
    }

    func testDefaultEffortWhenTheRouteHasNone() {
        let body = ClaudeClient.reportRequestBody(transcript: "x", model: .opus48)
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
    }
}
