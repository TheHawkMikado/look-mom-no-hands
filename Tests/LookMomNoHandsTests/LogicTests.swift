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

    func testLearnedFactDecodesAndValidates() throws {
        let json = #"""
        {"say":"Opening Google Chrome, and I'll remember that.","confidence":0.9,
         "learn":{"spoken":"chrome","written":"Google Chrome"},
         "steps":[{"kind":"open_app","target":"Google Chrome","text":"","url":"","keys":"","direction":"down"}]}
        """#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.learn?.spoken, "chrome")
        XCTAssertEqual(plan.learn?.written, "Google Chrome")
        XCTAssertTrue(plan.learn?.isValid ?? false)
        XCTAssertEqual(plan.steps.count, 1)
    }

    func testPlanWithoutLearnHasNilLearn() throws {
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(#"{"say":"","steps":[],"confidence":1}"#.utf8))
        XCTAssertNil(plan.learn)
    }

    func testLearnedFactNoOpIsInvalid() throws {
        let json = #"{"say":"","confidence":1,"steps":[],"learn":{"spoken":"same","written":"Same"}}"#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertFalse(plan.learn?.isValid ?? true)   // same word (case-insensitive) → not learned
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

    func testNonArrayStepsIsMalformedNotEmptySuccess() throws {
        // A present-but-non-array `steps` (schema drift) must fail closed, not
        // read as a clean empty plan that speaks success.
        let object = try JSONDecoder().decode(ActionPlan.self, from: Data(#"{"steps":{"kind":"click"}}"#.utf8))
        XCTAssertTrue(object.malformed)
        let string = try JSONDecoder().decode(ActionPlan.self, from: Data(#"{"steps":"click send"}"#.utf8))
        XCTAssertTrue(string.malformed)
    }

    func testAbsentOrNullStepsIsNotMalformed() throws {
        // A genuinely empty/absent plan (e.g. a pure spoken reply) is fine.
        let absent = try JSONDecoder().decode(ActionPlan.self, from: Data(#"{"say":"hi"}"#.utf8))
        XCTAssertFalse(absent.malformed)
        let null = try JSONDecoder().decode(ActionPlan.self, from: Data(#"{"steps":null}"#.utf8))
        XCTAssertFalse(null.malformed)
    }
}

import AppKit

final class DictationChordTests: XCTestCase {
    func testChordFlags() {
        XCTAssertNil(DictationChord.off.flags)
        XCTAssertEqual(DictationChord.controlOption.flags, [.control, .option])
        XCTAssertEqual(DictationChord.commandControlOption.flags, [.command, .control, .option])
    }

    func testChordRawValueRoundTrips() {
        for c in DictationChord.allCases {
            XCTAssertEqual(DictationChord(rawValue: c.rawValue), c)
        }
    }

    func testAllChordsHaveLabels() {
        for c in DictationChord.allCases { XCTAssertFalse(c.label.isEmpty) }
    }
}

final class DictateVoicePhraseTests: XCTestCase {
    func testStartAndStopPhrasesDoNotCollideWithWake() {
        // "mama dictate this" must not read as a wake or stop word, and vice versa.
        for start in AppCoordinator.dictateStartPhrases {
            XCTAssertFalse(AppCoordinator.wakePhrases.contains(where: start.contains), start)
            XCTAssertFalse(AppCoordinator.stopPhrases.contains(where: start.contains), start)
        }
    }

    func testTriggersStrippedOnlyAtEdges() {
        // Trailing stop phrase removed.
        XCTAssertEqual(AppCoordinator.stripDictationTriggers("buy milk and eggs mama stop dictating"),
                       "buy milk and eggs")
        // The real-world case: comma after "Mama" and a trailing "this." — both
        // used to defeat stripping.
        XCTAssertEqual(AppCoordinator.stripDictationTriggers("I'm wondering how well this dictates. Mama, stop dictating this."),
                       "I'm wondering how well this dictates.")
        // Leading start phrase removed (with punctuation).
        XCTAssertEqual(AppCoordinator.stripDictationTriggers("Mama, dictate this: buy milk"),
                       "buy milk")
        // Overlapping stop phrases: "you stop dictating" strips whole, no dangling "you".
        XCTAssertEqual(AppCoordinator.stripDictationTriggers("buy milk you stop dictating"),
                       "buy milk")
        // Mid-note content that merely CONTAINS a phrase (with >2 trailing words)
        // is preserved.
        XCTAssertEqual(AppCoordinator.stripDictationTriggers("remind me to stop dictating at work when done"),
                       "remind me to stop dictating at work when done")
        XCTAssertEqual(AppCoordinator.stripDictationTriggers("tell mama dictate the recipe to grandma"),
                       "tell mama dictate the recipe to grandma")
    }
}

final class LiveTranscriptPhraseTests: XCTestCase {
    func testLivePhrasesDoNotCollideWithWakeOrDictation() {
        // "mama take notes" / "mama stop transcribing" must not read as the wake
        // word, the command stop word, or a dictation start/stop trigger.
        for phrase in AppCoordinator.liveStartPhrases + AppCoordinator.liveStopPhrases {
            XCTAssertFalse(AppCoordinator.wakePhrases.contains(where: phrase.contains), phrase)
            XCTAssertFalse(AppCoordinator.dictateStartPhrases.contains(where: phrase.contains), phrase)
        }
    }

    func testStartAndStopPhrasesAreDistinct() {
        // A single utterance must not match both a start and a stop phrase, or the
        // toggle would fight itself.
        for start in AppCoordinator.liveStartPhrases {
            XCTAssertFalse(AppCoordinator.liveStopPhrases.contains(where: start.contains), start)
        }
        for stop in AppCoordinator.liveStopPhrases {
            XCTAssertFalse(AppCoordinator.liveStartPhrases.contains(where: stop.contains), stop)
        }
    }

    func testChunkPacingConstantsAreSane() {
        // A chunk must be allowed to flush at its target before the hard cap, and
        // the pause window must be shorter than the target (else it never fires).
        XCTAssertLessThan(AppCoordinator.liveChunkSecondsForTest, AppCoordinator.liveChunkMaxForTest)
        XCTAssertLessThan(AppCoordinator.liveChunkSilenceForTest, AppCoordinator.liveChunkSecondsForTest)
    }
}

final class SpeechEngineTests: XCTestCase {
    func testScribeRoutingPerMode() {
        XCTAssertFalse(SpeechEngine.appleOnly.usesScribe(forDictation: true))
        XCTAssertFalse(SpeechEngine.appleOnly.usesScribe(forDictation: false))
        XCTAssertTrue(SpeechEngine.scribeDictation.usesScribe(forDictation: true))
        XCTAssertFalse(SpeechEngine.scribeDictation.usesScribe(forDictation: false))
        XCTAssertTrue(SpeechEngine.scribeAll.usesScribe(forDictation: true))
        XCTAssertTrue(SpeechEngine.scribeAll.usesScribe(forDictation: false))
    }

    func testEngineRawValueRoundTrips() {
        for e in SpeechEngine.allCases {
            XCTAssertEqual(SpeechEngine(rawValue: e.rawValue), e)
        }
    }
}

final class VocabularyTests: XCTestCase {
    @MainActor private func store() -> VocabularyStore {
        VocabularyStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-vocab-\(UUID().uuidString)"))
    }

    @MainActor func testPromptContextComposesAllKinds() {
        let v = store()
        v.add(VocabEntry(kind: .word, spoken: "Styku"))
        v.add(VocabEntry(kind: .correction, spoken: "stycu", written: "Styku"))
        v.add(VocabEntry(kind: .snippet, spoken: "my email", written: "me@x.com"))
        let ctx = v.promptContext
        XCTAssertTrue(ctx.contains("Styku"))
        XCTAssertTrue(ctx.contains("When you hear \"stycu\""))
        XCTAssertTrue(ctx.contains("expand it to: me@x.com"))
    }

    @MainActor func testEmptyVocabHasEmptyContext() {
        XCTAssertEqual(store().promptContext, "")
    }

    @MainActor func testContextualStringsIncludeTermsAndTriggers() {
        let v = store()
        v.add(VocabEntry(kind: .word, spoken: "Hawk Mikado"))
        v.add(VocabEntry(kind: .snippet, spoken: "brb", written: "be right back"))
        let cs = v.contextualStrings
        XCTAssertTrue(cs.contains("Hawk Mikado"))
        XCTAssertTrue(cs.contains("brb"))
    }

    @MainActor func testLearnCorrectionDedupesOnSpoken() {
        let v = store()
        v.learnCorrection(spoken: "chrome", written: "Google Chrome")
        v.learnCorrection(spoken: "Chrome", written: "Google Chrome Canary")   // updates in place
        let corrections = v.entries(of: .correction)
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.written, "Google Chrome Canary")
    }

    @MainActor func testLearnCorrectionIgnoresNoOp() {
        let v = store()
        v.learnCorrection(spoken: "same", written: "same")   // no change
        v.learnCorrection(spoken: "x", written: "")          // empty target
        XCTAssertTrue(v.entries(of: .correction).isEmpty)
    }
}

final class ReportDecodingTests: XCTestCase {
    func testFullReportDecodes() throws {
        let json = #"""
        {"title":"Weekly plan","summary":"Ship the feature.",
         "key_points":["a","b"],"action_items":["do x"],"transcript":"raw text"}
        """#
        let r = try JSONDecoder().decode(DictationReport.self, from: Data(json.utf8))
        XCTAssertEqual(r.title, "Weekly plan")
        XCTAssertEqual(r.keyPoints, ["a", "b"])
        XCTAssertEqual(r.actionItems, ["do x"])
        XCTAssertEqual(r.transcript, "raw text")
    }

    func testSparseReportDegradesNotThrows() throws {
        // A report missing newer fields must not throw (tolerant decode).
        let r = try JSONDecoder().decode(DictationReport.self, from: Data(#"{"summary":"s"}"#.utf8))
        XCTAssertEqual(r.summary, "s")
        XCTAssertEqual(r.title, "")
        XCTAssertTrue(r.keyPoints.isEmpty)
    }

    func testReportSchemaRequiresAllFields() {
        let body = ClaudeClient.reportRequestBody(transcript: "x", model: .opus48)
        let oc = body["output_config"] as? [String: Any]
        let fmt = oc?["format"] as? [String: Any]
        let schema = fmt?["schema"] as? [String: Any]
        let required = schema?["required"] as? [String]
        for f in ["title", "summary", "key_points", "action_items", "transcript"] {
            XCTAssertTrue(required?.contains(f) ?? false, "\(f) required")
        }
    }
}

final class RecoveredAudioRetentionTests: XCTestCase {
    private func url(_ n: Int) -> URL { URL(fileURLWithPath: "/tmp/note-\(n).wav") }

    func testKeepsNewestAndPrunesRest() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let dated = (0..<5).map { (url($0), base.addingTimeInterval(Double($0))) } // 4 is newest
        let prune = AppStore.recoveredNotesToPrune(dated, keep: 2)
        // Keep the 2 newest (4, 3); prune 2, 1, 0.
        XCTAssertEqual(Set(prune), Set([url(2), url(1), url(0)]))
    }

    func testNothingPrunedUnderCap() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let dated = (0..<3).map { (url($0), base.addingTimeInterval(Double($0))) }
        XCTAssertTrue(AppStore.recoveredNotesToPrune(dated, keep: 20).isEmpty)
    }
}

final class WavAndScribeTests: XCTestCase {
    func testWavHeaderIsCanonical() {
        let samples: [Int16] = [0, 1000, -1000, 32767, -32768]
        let wav = VoiceListener.wav(from: samples, sampleRate: 16000)
        XCTAssertEqual(wav.count, 44 + samples.count * 2, "44-byte header + 16-bit samples")
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        // Sample rate at bytes 24..28, little-endian = 16000.
        let rate = wav[24..<28].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(rate, 16000)
        // 16-bit depth at bytes 34..36.
        XCTAssertEqual(wav[34], 16); XCTAssertEqual(wav[35], 0)
    }

    func testScribeMultipartContainsModelAndFile() {
        let wav = VoiceListener.wav(from: [1, 2, 3], sampleRate: 16000)
        let body = ScribeClient.multipartBody(wav: wav, boundary: "B")
        let s = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(s.contains("name=\"model_id\""))
        XCTAssertTrue(s.contains("scribe_v1"))
        XCTAssertTrue(s.contains("filename=\"audio.wav\""))
        XCTAssertTrue(s.contains("--B--"), "closing boundary present")
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

    func testSnapshotPromptText() {
        let snap = ScreenController.Snapshot(
            app: "Google Chrome", title: "YouTube", url: "https://youtube.com",
            elements: [("AXButton", "Search"), ("AXLink", "Home")])
        let s = snap.promptText
        XCTAssertTrue(s.contains("Google Chrome — YouTube (https://youtube.com)"))
        XCTAssertTrue(s.contains("button: Search"))
        XCTAssertTrue(s.contains("link: Home"))
    }

    func testSnapshotWithNoElements() {
        let snap = ScreenController.Snapshot(app: "Finder", title: "Downloads", url: "", elements: [])
        XCTAssertEqual(snap.promptText, "On screen now: Finder — Downloads")
    }

    func testScreenIntentHeuristic() {
        XCTAssertTrue(AppCoordinator.needsScreenContext("click the compose button"))
        XCTAssertTrue(AppCoordinator.needsScreenContext("what's on this page"))
        XCTAssertTrue(AppCoordinator.needsScreenContext("scroll down and press send"))
        // Simple app/url commands skip the AX walk.
        XCTAssertFalse(AppCoordinator.needsScreenContext("open YouTube in Chrome"))
        XCTAssertFalse(AppCoordinator.needsScreenContext("go to google.com"))
    }

    func testWindowMatchPicksBestByTitle() {
        // The reporter's real scenario: several VS Code windows, target one by name.
        let labels = [
            "Code file.ts — best-day-manager — Visual Studio Code",
            "Code file.swift — look-mom-no-hands — Visual Studio Code",
            "Google Chrome — YouTube",
        ]
        XCTAssertEqual(ScreenController.bestWindowIndex(labels, query: "the look mom no hands VS Code"), 1)
        XCTAssertEqual(ScreenController.bestWindowIndex(labels, query: "best day manager vs code"), 0)
        XCTAssertEqual(ScreenController.bestWindowIndex(labels, query: "chrome youtube"), 2)
        // No shared words → nil (caller errors rather than raising a random window).
        XCTAssertNil(ScreenController.bestWindowIndex(labels, query: "photoshop"))
        XCTAssertNil(ScreenController.bestWindowIndex(labels, query: ""))
    }

    func testAppNameResolvesShorthand() {
        // Mirrors the reporter's real /Applications, incl. a longer decoy that
        // also contains "chrome".
        let apps = ["Google Chrome.app", "Chrome Remote Desktop Host Uninstaller.app",
                    "Google Chrome Canary.app", "Safari.app", "Notes.app"]
        // "chrome" → the shortest containing match (Google Chrome), not the decoy.
        XCTAssertEqual(ScreenController.bestAppMatch(apps, query: "chrome"), "Google Chrome.app")
        // Whole-word beats mid-word substring: "code" → Visual Studio Code, not Xcode.
        XCTAssertEqual(ScreenController.bestAppMatch(["Xcode.app", "Visual Studio Code.app"], query: "code"),
                       "Visual Studio Code.app")
        // With only a mid-word substring available, it's still reachable last-resort.
        XCTAssertEqual(ScreenController.bestAppMatch(["Xcode.app"], query: "code"), "Xcode.app")
        // Exact stem wins.
        XCTAssertEqual(ScreenController.bestAppMatch(apps, query: "Safari"), "Safari.app")
        XCTAssertEqual(ScreenController.bestAppMatch(apps, query: "SAFARI"), "Safari.app")
        // No match → nil (caller falls back to `open -a`).
        XCTAssertNil(ScreenController.bestAppMatch(apps, query: "Firefox"))
        XCTAssertNil(ScreenController.bestAppMatch(apps, query: ""))
    }

    func testExactMatchBeatsSubstringGlobally() {
        // Simulates candidates gathered ACROSS directories (Safari Technology
        // Preview from /Applications listed before exact Safari from /System).
        // Exact stem must win regardless of list order.
        let mixed = ["Safari Technology Preview.app", "Airmail.app", "Safari.app", "Mail.app"]
        XCTAssertEqual(ScreenController.bestAppMatch(mixed, query: "Safari"), "Safari.app")
        XCTAssertEqual(ScreenController.bestAppMatch(mixed, query: "Mail"), "Mail.app")
    }

    func testTrustedTierBeatsUserLocalHijack() {
        // A planted ~/Applications/Chrome.app (exact) must NOT beat the machine
        // /Applications/Google Chrome.app (substring) — trusted tier wins first.
        let trusted = ["Google Chrome.app"]
        let user = ["Chrome.app"]
        XCTAssertEqual(ScreenController.firstTierMatch([trusted, user], query: "chrome"), "Google Chrome.app")
        // But a user-local app is still reachable when nothing trusted matches.
        XCTAssertEqual(ScreenController.firstTierMatch([[], ["MyTool.app"]], query: "mytool"), "MyTool.app")
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
