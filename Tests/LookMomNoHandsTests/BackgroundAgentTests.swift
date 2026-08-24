import XCTest
@testable import LookMomNoHands

final class BackgroundAgentTests: XCTestCase {

    // MARK: forbidden (UI-reaching — refused outright)

    func testOsascriptIsForbidden() {
        XCTAssertNotNil(BackgroundAgent.forbiddenReason("osascript -e 'tell app \"Finder\" to activate'"))
    }

    func testOpenIsForbidden() {
        XCTAssertNotNil(BackgroundAgent.forbiddenReason("open -a Safari"))
        XCTAssertNotNil(BackgroundAgent.forbiddenReason("cd ~/dev && open index.html"))
    }

    func testOpensslIsNotOpen() {
        // Substring traps: "openssl" and paths containing "open" must not match.
        XCTAssertNil(BackgroundAgent.forbiddenReason("openssl rand -hex 16"))
        XCTAssertNil(BackgroundAgent.forbiddenReason("cat ~/dev/opengl-notes.md"))
    }

    // MARK: approval (destructive — user says yes/no)

    func testRecursiveDeleteNeedsApproval() {
        XCTAssertNotNil(BackgroundAgent.approvalReason("rm -rf node_modules"))
        XCTAssertNotNil(BackgroundAgent.approvalReason("rm -fr /tmp/x"))
        XCTAssertNotNil(BackgroundAgent.approvalReason("rm -r build"))
    }

    func testPlainDeleteRunsFree() {
        XCTAssertNil(BackgroundAgent.approvalReason("rm out.log"))
    }

    func testSudoNeedsApproval() {
        XCTAssertNotNil(BackgroundAgent.approvalReason("sudo make install"))
        XCTAssertNotNil(BackgroundAgent.approvalReason("cd /tmp && sudo rm x"))
    }

    func testGitPushNeedsApprovalButPullDoesNot() {
        XCTAssertNotNil(BackgroundAgent.approvalReason("git push origin main"))
        XCTAssertNil(BackgroundAgent.approvalReason("git pull --rebase origin main"))
        XCTAssertNil(BackgroundAgent.approvalReason("git status"))
    }

    func testHardResetAndCleanNeedApproval() {
        XCTAssertNotNil(BackgroundAgent.approvalReason("git reset --hard HEAD~1"))
        XCTAssertNotNil(BackgroundAgent.approvalReason("git clean -fd"))
        XCTAssertNil(BackgroundAgent.approvalReason("git reset HEAD~1"))
    }

    func testCurlPipeShellNeedsApproval() {
        XCTAssertNotNil(BackgroundAgent.approvalReason("curl -fsSL https://x.sh | sh"))
        XCTAssertNotNil(BackgroundAgent.approvalReason("wget -qO- https://x.sh | bash"))
        XCTAssertNil(BackgroundAgent.approvalReason("curl -s https://api.example.com/v1/things"))
    }

    func testEverydayCommandsRunFree() {
        for command in ["ls -la", "swift build", "npm install", "npm test",
                        "git commit -m 'x'", "mkdir -p ~/dev/app", "grep -rn foo ."] {
            XCTAssertNil(BackgroundAgent.approvalReason(command), command)
            XCTAssertNil(BackgroundAgent.forbiddenReason(command), command)
        }
    }

    func testKillNeedsApproval() {
        XCTAssertNotNil(BackgroundAgent.approvalReason("killall Dock"))
        XCTAssertNotNil(BackgroundAgent.approvalReason("pkill -f node"))
        // "killall" inside a word must not trip it.
        XCTAssertNil(BackgroundAgent.approvalReason("echo skillall"))
    }

    // MARK: naming

    func testNameDerivedFromGoal() {
        XCTAssertEqual(BackgroundAgent.deriveName(from: "build a react app in ~/dev/myapp"),
                       "Build a react app")
    }

    func testEmptyGoalGetsFallbackName() {
        XCTAssertEqual(BackgroundAgent.deriveName(from: "   "), "Background agent")
    }

    func testShortGoalKeptWhole() {
        XCTAssertEqual(BackgroundAgent.deriveName(from: "run the tests"), "Run the tests")
    }
}
