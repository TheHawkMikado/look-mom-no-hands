import XCTest
@testable import LookMomNoHands

/// Delegation ("talk to it", SPEC §5.1): the planner's team steps decode apart
/// from screen steps, the web's replies parse, and the spoken summaries are
/// short and right.
final class TeamStepDecodingTests: XCTestCase {

    func testDelegateStepIsSplitOutOfTheScreenSteps() throws {
        let json = #"""
        {"say":"","confidence":0.9,"goal_complete":true,"steps":[
          {"kind":"delegate","target":"draft","text":"have the content agent draft a post about co-living and bring it to me","url":"","keys":"","prompt":"","direction":"down"}
        ]}
        """#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertTrue(plan.steps.isEmpty, "a team step is not a screen step")
        XCTAssertEqual(plan.teamSteps.count, 1)
        XCTAssertEqual(plan.teamSteps[0].kind, .delegate)
        XCTAssertEqual(plan.teamSteps[0].capability, "draft")
        XCTAssertTrue(plan.teamSteps[0].text.hasPrefix("have the content agent"))
        XCTAssertFalse(plan.malformed, "a known team kind is not a malformed step")
        XCTAssertTrue(plan.goalComplete)
    }

    func testTeamAndScreenStepsCoexistInOnePlan() throws {
        let json = #"""
        {"say":"","confidence":0.9,"steps":[
          {"kind":"open_app","target":"Slack","text":"","url":"","keys":"","direction":"down"},
          {"kind":"team_status","target":"","text":"","url":"","keys":"","direction":"down"},
          {"kind":"decide","target":"","text":"approve","url":"","keys":"","direction":"down"}
        ]}
        """#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.steps.map(\.kind), [.openApp])
        XCTAssertEqual(plan.teamSteps.map(\.kind), [.teamStatus, .decide])
        XCTAssertEqual(plan.teamSteps[1].verdict, "approve")
        XCTAssertFalse(plan.malformed)
    }

    func testUnknownKindIsStillMalformed() throws {
        // Adding a second step family must not turn every typo into a silent
        // drop — the fail-closed rule from PlanDecodingTests still holds.
        let json = #"{"say":"","confidence":0.9,"steps":[{"kind":"teleport","target":"","text":""}]}"#
        let plan = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        XCTAssertTrue(plan.malformed)
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.teamSteps.isEmpty)
    }

    func testScreenActionRefusesTeamKinds() {
        // The screen controller's exhaustive switches never see these.
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenAction.self,
                                                      from: Data(#"{"kind":"delegate","text":"x"}"#.utf8)))
    }

    func testVerdictOnlyAcceptsClearWords() throws {
        func step(_ text: String) throws -> TeamStep {
            try JSONDecoder().decode(TeamStep.self, from: Data(#"{"kind":"decide","text":"\#(text)"}"#.utf8))
        }
        XCTAssertEqual(try step("approve").verdict, "approve")
        XCTAssertEqual(try step("Approved").verdict, "approve")
        XCTAssertEqual(try step("go ahead").verdict, "approve")
        XCTAssertEqual(try step("deny").verdict, "deny")
        XCTAssertEqual(try step("No").verdict, "deny")
        XCTAssertNil(try step("maybe later").verdict, "a vague word must never become a decision")
        XCTAssertNil(try step("").verdict)
    }

    func testPlannerSchemaOffersTheTeamKinds() throws {
        let body = ClaudeClient.planRequestBody(transcript: "x", model: .haiku45)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let schema = try XCTUnwrap(tools.first?["input_schema"] as? [String: Any])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        let steps = try XCTUnwrap(props["steps"] as? [String: Any])
        let item = try XCTUnwrap(steps["items"] as? [String: Any])
        let itemProps = try XCTUnwrap(item["properties"] as? [String: Any])
        let kind = try XCTUnwrap(itemProps["kind"] as? [String: Any])
        let allowed = try XCTUnwrap(kind["enum"] as? [String])
        for k in ["delegate", "team_status", "decide"] {
            XCTAssertTrue(allowed.contains(k), "\(k) must be a kind the model can emit")
        }
        let description = try XCTUnwrap(tools.first?["description"] as? String)
        XCTAssertTrue(description.contains("delegate"), "the prompt must say when to hand work to the team")
    }
}

final class TeamClientTests: XCTestCase {

    func testIntakeReplyParsesTaskAndConfirmation() throws {
        let json = #"""
        {"intent":"task","confirmation":"I'll have the Content Drafter draft that and bring it to you.",
         "task":{"id":"t_1","title":"Draft a post about co-living","status":"dispatching","owner_name":"Content Drafter",
                 "confirmation":"I'll have the Content Drafter draft that and bring it to you.","blast_tier":2},
         "extraction":{"intent":"task"}}
        """#
        let reply = try XCTUnwrap(TeamClient.parseIntake(Data(json.utf8)))
        XCTAssertEqual(reply.intent, "task")
        XCTAssertEqual(reply.task?.id, "t_1")
        XCTAssertEqual(reply.task?.title, "Draft a post about co-living")
        XCTAssertEqual(reply.task?.status, "dispatching")
        XCTAssertEqual(reply.task?.ownerName, "Content Drafter")
        XCTAssertTrue(reply.confirmation.hasPrefix("I'll have"))
        XCTAssertTrue(TeamClient.receiptLine(reply).contains("Draft a post about co-living"))
        XCTAssertTrue(TeamClient.receiptLine(reply).contains("Content Drafter"))
    }

    func testIntakeReplyForANoteHasNoTask() throws {
        let json = #"{"intent":"note","confirmation":"Noted. That stays on your Mac.","task":null,"extraction":{}}"#
        let reply = try XCTUnwrap(TeamClient.parseIntake(Data(json.utf8)))
        XCTAssertEqual(reply.intent, "note")
        XCTAssertNil(reply.task)
        XCTAssertEqual(reply.confirmation, "Noted. That stays on your Mac.")
        XCTAssertTrue(TeamClient.receiptLine(reply).contains("note"))
    }

    func testGarbledIntakeIsNil() {
        XCTAssertNil(TeamClient.parseIntake(Data("<html>".utf8)))
    }

    func testTaskRowsWithoutIdOrTitleAreDropped() throws {
        let json = #"{"tasks":[{"id":"a","title":"One","status":"in_progress"},{"id":"","title":"x"},{"title":"no id"},{"id":"b","title":"","status":"done"}]}"#
        let tasks = try XCTUnwrap(TeamClient.parseTasks(Data(json.utf8)))
        XCTAssertEqual(tasks.map(\.id), ["a"])
        XCTAssertNil(TeamClient.parseTasks(Data(#"{"nope":1}"#.utf8)), "no tasks array = unreachable, not empty")
    }

    func testOutstandingSummaryIsOneShortSentence() {
        func task(_ t: String) -> TeamTask { TeamTask(id: t, title: t, status: "in_progress", ownerName: nil, confirmation: "") }
        XCTAssertEqual(TeamClient.outstandingSummary([]), "Nothing is outstanding.")
        XCTAssertEqual(TeamClient.outstandingSummary([task("Blog post")]), "One thing is outstanding: Blog post.")
        XCTAssertEqual(TeamClient.outstandingSummary([task("Blog post"), task("Tow truck")]),
                       "Two things are outstanding: Blog post, and Tow truck.")
        let five = TeamClient.outstandingSummary(["A", "B", "C", "D", "E"].map(task))
        XCTAssertTrue(five.hasPrefix("5 things are outstanding."))
        XCTAssertTrue(five.contains("A, and B"), "the top two, newest first")
        XCTAssertFalse(five.contains("C"), "never the whole list — every word is TTS time")
    }

    func testOutstandingStatusesMatchTheSpec() {
        XCTAssertEqual(TeamClient.outstandingStatuses, ["needs_decision", "awaiting_approval", "in_progress"])
    }
}
