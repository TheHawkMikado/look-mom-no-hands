import XCTest
@testable import LookMomNoHands

final class UpdaterTests: XCTestCase {

    // MARK: hdiutil plist parsing

    func testMountPointParsedFromAttachPlist() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>system-entities</key>
          <array>
            <dict><key>content-hint</key><string>GUID_partition_scheme</string></dict>
            <dict>
              <key>content-hint</key><string>Apple_HFS</string>
              <key>mount-point</key><string>/Volumes/Look Ma No Hands</string>
            </dict>
          </array>
        </dict></plist>
        """
        XCTAssertEqual(AppUpdater.parseMountPoint(fromAttachPlist: Data(plist.utf8)),
                       "/Volumes/Look Ma No Hands",
                       "the entity without a mount point (the partition map) must be skipped")
    }

    func testGarbageAttachOutputYieldsNil() {
        XCTAssertNil(AppUpdater.parseMountPoint(fromAttachPlist: Data("not a plist".utf8)))
    }

    // MARK: swap helper script

    func testSwapScriptQuotesPathsWithSpaces() {
        let script = AppUpdater.swapScript(pid: 123,
                                           staged: "/tmp/stage/Look Ma, No Hands.app",
                                           app: "/Applications/Look Ma, No Hands.app")
        XCTAssertTrue(script.contains("'/Applications/Look Ma, No Hands.app'"),
                      "unquoted spaces would rm-rf the wrong path")
        XCTAssertTrue(script.contains("kill -0 123"), "must wait for OUR exit, not sleep and hope")
        XCTAssertTrue(script.contains("/usr/bin/open"), "the swap must end in a relaunch")
    }

    // MARK: signature requirement

    func testRequirementPinsTheTeam() {
        // The whole security story of self-update hangs on this string: it must
        // anchor to Apple AND pin the team. Loosening either silently accepts
        // anyone's signed app as "ours".
        XCTAssertTrue(AppUpdater.requirement.contains("anchor apple generic"))
        XCTAssertTrue(AppUpdater.requirement.contains("B59AM8227J"))
    }

    // MARK: check cadence by account mode

    func testCloudChecksHourlyByokDaily() {
        XCTAssertEqual(UpdateChecker.interval(forMode: "cloud"), 3600)
        XCTAssertEqual(UpdateChecker.interval(forMode: "byok"), 24 * 3600)
        XCTAssertEqual(UpdateChecker.interval(forMode: nil), 24 * 3600,
                       "not signed in must get the conservative cadence, not the aggressive one")
    }

    // MARK: same-day respin ordering

    func testRespinComparesNewerThanItsBase() {
        // 0.03.260828.1 must read newer than 0.03.260828 (shorter pads as 0)
        // and newer than the previous day's release, or respins are invisible
        // to every installed app.
        XCTAssertTrue(UpdateChecker.compare("0.03.260828", isLessThan: "0.03.260828.1"))
        XCTAssertTrue(UpdateChecker.compare("0.03.260826", isLessThan: "0.03.260828.1"))
        XCTAssertTrue(UpdateChecker.compare("0.03.260828.1", isLessThan: "0.03.260828.2"))
        XCTAssertFalse(UpdateChecker.compare("0.03.260829", isLessThan: "0.03.260828.9"),
                       "the next DAY beats any respin count")
    }
}
