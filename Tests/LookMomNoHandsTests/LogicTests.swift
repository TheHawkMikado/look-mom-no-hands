import XCTest
@testable import LookMomNoHands

// Pure-logic regression tests for the bugs found in review. Anything touching
// the mic, AX tree, or network stays out — these run headless in CI.

final class PhraseMatchingTests: XCTestCase {
    func testNormalizationStripsPunctuationAndCase() {
        XCTAssertEqual(AppCoordinator.normalizedForMatching("Hey, Mama."), "hey mama")
        XCTAssertEqual(AppCoordinator.normalizedForMatching("  HEY   MAMA!  "), "hey mama")
    }

    func testWakePhraseSurvivesRecognizerPunctuation() {
        let tail = AppCoordinator.normalizedForMatching("okay so — Hey Mama!")
        XCTAssertTrue(AppCoordinator.wakePhrases.contains(where: tail.contains))
    }

    func testStopPhraseWithAccentMatches() {
        let tail = AppCoordinator.normalizedForMatching("Adiós Mama")
        XCTAssertTrue(AppCoordinator.stopPhrases.contains(where: tail.contains))
    }

    func testStrippingPhrasesIsCaseInsensitive() {
        let out = AppCoordinator.strippingPhrases(["hey mama"], from: "Hey Mama open safari")
        XCTAssertEqual(out, "open safari")
    }

    func testStrippingPhrasesSurvivesCaseFoldingLengthChanges() {
        // "İ" (U+0130) lowercases to two scalars; applying a lowercased copy's
        // indices to the original used to remove the wrong range or trap.
        let out = AppCoordinator.strippingPhrases(["hey mama"], from: "İstanbul trip hey mama click send")
        XCTAssertTrue(out.contains("click send"))
        XCTAssertTrue(out.contains("İstanbul trip"))
        XCTAssertFalse(out.lowercased().contains("hey mama"))
    }
}

final class RequestShapeTests: XCTestCase {
    func testHaikuReportBodyOmitsEffortAndThinking() {
        // Haiku 4.5 rejects `effort` (HTTP 400) and lacks adaptive thinking —
        // the capability gates must strip both.
        let body = ClaudeClient.reportRequestBody(transcript: "x", model: .haiku45)
        XCTAssertNil(body["thinking"])
        let output = body["output_config"] as? [String: Any]
        XCTAssertNil(output?["effort"])
        XCTAssertNotNil(output?["format"])
    }

    func testOpusReportBodyKeepsEffortAndThinking() {
        let body = ClaudeClient.reportRequestBody(transcript: "x", model: .opus48)
        XCTAssertNotNil(body["thinking"])
        let output = body["output_config"] as? [String: Any]
        XCTAssertEqual(output?["effort"] as? String, "medium")
    }

    func testPlanBodyStaysThinkingFree() {
        let body = ClaudeClient.planRequestBody(transcript: "x", model: .haiku45)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        let choice = body["tool_choice"] as? [String: Any]
        XCTAssertEqual(choice?["name"] as? String, "emit_plan")
    }

    func testPlanStepSchemaRequiresAllFields() throws {
        let body = ClaudeClient.planRequestBody(transcript: "x", model: .haiku45)
        let tools = body["tools"] as? [[String: Any]]
        let schema = tools?.first?["input_schema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        let steps = props?["steps"] as? [String: Any]
        let item = steps?["items"] as? [String: Any]
        let required = item?["required"] as? [String]
        // Without strict mode the model may omit non-required fields; every step
        // field must be present so the ""-when-unused convention holds.
        for field in ["kind", "target", "text", "url", "keys", "direction"] {
            XCTAssertTrue(required?.contains(field) ?? false, "\(field) must be required")
        }
    }

    func testPlanBodyCarriesDialogue() {
        let body = ClaudeClient.planRequestBody(
            transcript: "the first one",
            dialogue: [(role: "user", content: "open it"),
                       (role: "assistant", content: "I need to clarify: which app?")],
            model: .haiku45)
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 3, "prior turns + current transcript")
        XCTAssertEqual(messages?.last?["role"] as? String, "user")
    }
}

final class ActionDecodingTests: XCTestCase {
    func testScrollDecodesTypedDirection() throws {
        let json = #"{"kind":"scroll","target":"","text":"","direction":"up","confidence":0.9}"#
        let action = try JSONDecoder().decode(ScreenAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.direction, .up)
    }

    func testMissingDirectionDecodesNilNotDown() throws {
        // The old code silently defaulted to .down — nil must surface instead.
        let json = #"{"kind":"scroll","target":"","text":"","confidence":0.9}"#
        let action = try JSONDecoder().decode(ScreenAction.self, from: Data(json.utf8))
        XCTAssertNil(action.direction)
    }

    func testJunkDirectionDoesNotFailTheAction() throws {
        // Tool-use inputs aren't strictly enforced server-side; a "" or garbage
        // direction on a click must not throw the whole command into .error.
        let empty = #"{"kind":"click","target":"send","text":"","direction":"","confidence":1.0}"#
        let a = try JSONDecoder().decode(ScreenAction.self, from: Data(empty.utf8))
        XCTAssertEqual(a.kind, .click)
        XCTAssertNil(a.direction)

        let mixedCase = #"{"kind":"scroll","target":"","text":"","direction":"Up","confidence":1.0}"#
        let b = try JSONDecoder().decode(ScreenAction.self, from: Data(mixedCase.utf8))
        XCTAssertEqual(b.direction, .up)
    }

    func testSnakeCaseKindsDecode() throws {
        let json = #"{"kind":"dictate_start","target":"","text":"","confidence":1.0}"#
        let action = try JSONDecoder().decode(ScreenAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.kind, .dictateStart)
    }

    func testDecodeBlockUnpacksToolUse() throws {
        let json: [String: Any] = ["content": [
            ["type": "text", "text": "thinking aloud"],
            ["type": "tool_use", "input": ["kind": "click", "target": "send", "text": "", "confidence": 1.0]]
        ]]
        let action: ScreenAction = try ClaudeClient.decodeBlock(json, blockType: "tool_use", payloadKey: "input")
        XCTAssertEqual(action.kind, .click)
        XCTAssertEqual(action.target, "send")
    }

    func testDecodeBlockThrowsNoToolUse() {
        let json: [String: Any] = ["content": [["type": "text", "text": "{}"]]]
        XCTAssertThrowsError(try ClaudeClient.decodeBlock(json, blockType: "tool_use", payloadKey: "input") as ScreenAction) { error in
            guard case ClaudeError.noToolUse = error else {
                return XCTFail("expected noToolUse, got \(error)")
            }
        }
    }

    func testUnresolvableAppNameThrows() {
        // `open -a` exits nonzero for an unknown app with no side effects, so
        // this exercises the real failure path safely.
        XCTAssertThrowsError(try ScreenController.openApp(named: "Definitely Not An App 8f3a2c")) { error in
            guard case ScreenController.ControlError.appLaunchFailed = error else {
                return XCTFail("expected appLaunchFailed, got \(error)")
            }
        }
    }

    func testDecodeBlockUnpacksTextPayload() throws {
        let json: [String: Any] = ["content": [
            ["type": "text", "text": #"{"summary":"s","action_items":["a"],"transcript":"t"}"#]
        ]]
        let report: DictationReport = try ClaudeClient.decodeBlock(json, blockType: "text", payloadKey: "text")
        XCTAssertEqual(report.summary, "s")
        XCTAssertEqual(report.actionItems, ["a"])
    }
}

final class PlanDecodingTests: XCTestCase {
    func testMultiStepPlanDecodesInOrder() throws {
        let json = #"""
        {"say":"Opening YouTube in Chrome and a new tab","confidence":0.9,"steps":[
          {"kind":"open_url","target":"Google Chrome","text":"","url":"youtube.com","keys":"","direction":"down"},
          {"kind":"keystroke","target":"","text":"","url":"","keys":"cmd+t","direction":"down"}
        ]}
        """#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertNil(plan.clarify)
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].kind, .openURL)
        XCTAssertEqual(plan.steps[0].url, "youtube.com")
        XCTAssertEqual(plan.steps[0].target, "Google Chrome")
        XCTAssertEqual(plan.steps[1].kind, .keystroke)
        XCTAssertEqual(plan.steps[1].keys, "cmd+t")
    }

    func testClarificationPlanDecodes() throws {
        let json = #"""
        {"say":"","confidence":0.4,"steps":[],
         "clarify":{"question":"Which browser?","options":["Chrome","Safari"]}}
        """#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.clarify?.options, ["Chrome", "Safari"])
        XCTAssertTrue(plan.clarify?.spoken.contains("Chrome") ?? false)
    }

    func testPlanWithMissingOptionalFieldsDecodes() throws {
        // Tolerant top-level decode: a sparse response must not throw.
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(#"{"steps":[]}"#.utf8))
        XCTAssertEqual(plan.say, "")
        XCTAssertNil(plan.clarify)
    }

    func testMalformedStepFlagsPlanForFailClosed() throws {
        // A bad step must not silently blank the array, but it also must not be
        // dropped and the rest run — ordered steps depend on each other. The
        // `malformed` flag lets the coordinator refuse partial execution.
        let json = #"""
        {"say":"","confidence":0.9,"steps":[
          {"kind":"open_app","target":"Safari","text":"","url":"","keys":"","direction":"down"},
          {"kind":"teleport","target":"","text":"","url":"","keys":"","direction":"down"},
          {"kind":"keystroke","target":"","text":"","url":"","keys":"cmd+t","direction":"down"}
        ]}
        """#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertTrue(plan.malformed, "a dropped step must be flagged")
        XCTAssertEqual(plan.steps.count, 2, "valid steps still decode (not blanked)")
    }

    func testWellFormedPlanIsNotMalformed() throws {
        let json = #"""
        {"say":"","confidence":0.9,"steps":[
          {"kind":"open_app","target":"Safari","text":"","url":"","keys":"","direction":"down"}
        ]}
        """#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertFalse(plan.malformed)
    }
}

final class URLAndKeystrokeTests: XCTestCase {
    func testBareHostGetsHTTPS() {
        XCTAssertEqual(ScreenController.normalizedURL("youtube.com"), "https://youtube.com")
        XCTAssertEqual(ScreenController.normalizedURL("  example.org "), "https://example.org")
    }

    func testExistingSchemePassesThrough() {
        XCTAssertEqual(ScreenController.normalizedURL("http://x.com"), "http://x.com")
        XCTAssertEqual(ScreenController.normalizedURL("https://x.com"), "https://x.com")
    }

    func testKeystrokeParsesModifiers() throws {
        let combo = try XCTUnwrap(ScreenController.parseKeystroke("cmd+shift+t"))
        XCTAssertEqual(combo.key, 17) // 't'
        XCTAssertTrue(combo.flags.contains(.maskCommand))
        XCTAssertTrue(combo.flags.contains(.maskShift))
    }

    func testKeystrokeAliasesAndBareKeys() throws {
        XCTAssertEqual(try XCTUnwrap(ScreenController.parseKeystroke("enter")).key, 36)
        XCTAssertTrue(try XCTUnwrap(ScreenController.parseKeystroke("option+left")).flags.contains(.maskAlternate))
    }

    func testUnknownKeystrokeReturnsNil() {
        XCTAssertNil(ScreenController.parseKeystroke("cmd+")) // no base key
        XCTAssertNil(ScreenController.parseKeystroke("cmd+f13")) // unmapped key
    }

    func testZoomShortcutsParse() throws {
        // "zoom in/out" idioms the model is likely to emit.
        XCTAssertEqual(try XCTUnwrap(ScreenController.parseKeystroke("cmd+=")).key, 24)
        XCTAssertEqual(try XCTUnwrap(ScreenController.parseKeystroke("cmd+plus")).key, 24)
        XCTAssertEqual(try XCTUnwrap(ScreenController.parseKeystroke("cmd+minus")).key, 27)
        // "cmd++" would collapse to just the modifier without the ++ → +plus fix.
        XCTAssertEqual(try XCTUnwrap(ScreenController.parseKeystroke("cmd++")).key, 24)
    }

    func testURLNormalizationEdgeCases() {
        XCTAssertEqual(ScreenController.normalizedURL("youtube.com/watch?v=x"), "https://youtube.com/watch?v=x")
        XCTAssertEqual(ScreenController.normalizedURL(""), "")
        XCTAssertEqual(ScreenController.normalizedURL("file:///tmp/x"), "file:///tmp/x")
    }
}
