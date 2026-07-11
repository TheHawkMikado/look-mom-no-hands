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

    func testCommandBodyStaysThinkingFree() {
        let body = ClaudeClient.commandRequestBody(transcript: "x", model: .haiku45)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertNotNil(body["tool_choice"])
    }

    func testCommandSchemaRequiresScrollDirection() throws {
        let body = ClaudeClient.commandRequestBody(transcript: "x", model: .haiku45)
        let tools = body["tools"] as? [[String: Any]]
        let schema = tools?.first?["input_schema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["direction"], "scroll direction must be a typed schema field")
        // Without strict mode the model may omit non-required fields, and a
        // scroll without a direction hard-fails at execution.
        let required = schema?["required"] as? [String]
        XCTAssertTrue(required?.contains("direction") ?? false, "direction must be required")
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

    func testDecodeBlockUnpacksTextPayload() throws {
        let json: [String: Any] = ["content": [
            ["type": "text", "text": #"{"summary":"s","action_items":["a"],"transcript":"t"}"#]
        ]]
        let report: DictationReport = try ClaudeClient.decodeBlock(json, blockType: "text", payloadKey: "text")
        XCTAssertEqual(report.summary, "s")
        XCTAssertEqual(report.actionItems, ["a"])
    }
}
