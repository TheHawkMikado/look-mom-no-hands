import XCTest
@testable import LookMomNoHands

/// The rollback path: the swap helper keeps the bundle it replaces, records it
/// only when the move succeeded, and the auto-installer refuses to reinstall
/// exactly the version the user just reverted away from.
final class RollbackTests: XCTestCase {

    // MARK: previous.json encode / decode

    func testPreviousBuildRoundTripsThroughJSON() throws {
        let p = PreviousBuild(version: "0.04.260912.a1b2c3d",
                              path: "/Users/h/Library/Application Support/LookMaNoHands/updates/previous/Look Ma, No Hands.app",
                              replacedAt: "2026-09-13T10:00:00Z")
        let encoded = try XCTUnwrap(p.encodedString())
        XCTAssertFalse(encoded.contains("\n"), "goes through printf inside one shell argument — no newlines")
        XCTAssertTrue(encoded.contains("\"replaced_at\""), "snake_case on disk, like the other records")
        XCTAssertEqual(PreviousBuild.decode(Data(encoded.utf8)), p)
    }

    func testIncompleteOrGarbledRecordReadsAsNoPreviousBuild() {
        XCTAssertNil(PreviousBuild.decode(Data("not json".utf8)))
        XCTAssertNil(PreviousBuild.decode(Data(#"{"version":"","path":"/x","replaced_at":"t"}"#.utf8)),
                     "an empty version is not a build to offer")
        XCTAssertNil(PreviousBuild.decode(Data(#"{"version":"0.1","path":"","replaced_at":"t"}"#.utf8)),
                     "an empty path is not a bundle to reinstall")
        XCTAssertNil(PreviousBuild.decode(Data(#"{"version":"0.1"}"#.utf8)), "half a record is no record")
    }

    func testStampIsISO8601() {
        let s = PreviousBuild.stamp(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s, "1970-01-01T00:00:00Z")
    }

    // MARK: swap helper keeps the old bundle

    func testSwapScriptMovesTheOldBundleAsideAndRecordsItAfterTheMove() throws {
        let previous = "/Users/h/Library/Application Support/LookMaNoHands/updates/previous/Look Ma, No Hands.app"
        let record = "/Users/h/Library/Application Support/LookMaNoHands/updates/previous/previous.json"
        let json = try XCTUnwrap(PreviousBuild(version: "0.04.260912", path: previous,
                                               replacedAt: "2026-09-13T10:00:00Z").encodedString())
        let script = AppUpdater.swapScript(pid: 7,
                                           staged: "/tmp/stage/Look Ma, No Hands.app",
                                           app: "/Applications/Look Ma, No Hands.app",
                                           previous: previous, record: record, recordJSON: json)
        XCTAssertTrue(script.contains("/bin/mv '/Applications/Look Ma, No Hands.app' '\(previous)'"),
                      "the old bundle is MOVED, not deleted")
        XCTAssertFalse(script.contains("/bin/rm -rf '/Applications/Look Ma, No Hands.app' &&"),
                       "the rm-rf swap is the no-keep path only")
        XCTAssertTrue(script.contains("/bin/rm -rf '\(previous)'"), "any older kept bundle is replaced")
        let move = try XCTUnwrap(script.range(of: "/bin/mv '/Applications"))
        let write = try XCTUnwrap(script.range(of: "> '\(record)'"))
        XCTAssertTrue(move.lowerBound < write.lowerBound, "the record is written after the move, never before")
        XCTAssertTrue(script.contains("printf '%s' '\(json)'"), "the record content rides in the script verbatim")
        XCTAssertTrue(script.contains("/usr/bin/open"), "still ends in a relaunch")
    }

    func testSwapScriptRestoresThePreviousBundleWhenTheCopyFails() {
        let previous = "/Users/h/Library/Application Support/LookMaNoHands/updates/previous/Look Ma, No Hands.app"
        let script = AppUpdater.swapScript(pid: 7,
                                           staged: "/tmp/stage/Look Ma, No Hands.app",
                                           app: "/Applications/Look Ma, No Hands.app",
                                           previous: previous, record: "/x/previous.json", recordJSON: "{}")
        XCTAssertTrue(script.contains("/bin/mv '\(previous)' '/Applications/Look Ma, No Hands.app'"),
                      "a failed copy puts the old bundle back where it was")
        XCTAssertTrue(script.contains("/bin/rm -f '/x/previous.json'"),
                      "and drops the record, since nothing was replaced")
    }

    func testSwapScriptWithoutKeepIsTheOriginalSwap() {
        // The revert path (and any caller that predates keep) must still get
        // the plain rm-rf + ditto swap, with no previous.json handling at all.
        let script = AppUpdater.swapScript(pid: 1, staged: "/s/A.app", app: "/Applications/A.app")
        XCTAssertTrue(script.contains("/bin/rm -rf '/Applications/A.app' && /usr/bin/ditto '/s/A.app' '/Applications/A.app'"))
        XCTAssertFalse(script.contains("previous.json"))
        XCTAssertFalse(script.contains("/bin/mv"))
    }

    func testRecordJSONWithoutARecordPathIsNotWritten() {
        let script = AppUpdater.swapScript(pid: 1, staged: "/s/A.app", app: "/Applications/A.app",
                                           previous: "/p/A.app", recordJSON: "{}")
        XCTAssertFalse(script.contains("printf"), "no destination file, no write")
    }

    // MARK: auto-install skips exactly the reverted version

    func testAutoInstallSkipsOnlyTheRevertedVersion() {
        XCTAssertFalse(UpdateChecker.autoInstallAllowed(version: "0.05.260913", attempted: nil, skipped: "0.05.260913"),
                       "the version the user just reverted from must not come straight back")
        XCTAssertTrue(UpdateChecker.autoInstallAllowed(version: "0.06.260920", attempted: nil, skipped: "0.05.260913"),
                      "a NEWER release after the revert installs as usual")
        XCTAssertTrue(UpdateChecker.autoInstallAllowed(version: "0.05.260913", attempted: nil, skipped: nil))
    }

    func testAutoInstallStillRunsOncePerVersion() {
        XCTAssertFalse(UpdateChecker.autoInstallAllowed(version: "0.05.260913", attempted: "0.05.260913", skipped: nil),
                       "a failed attempt is shown, not retried")
        XCTAssertTrue(UpdateChecker.autoInstallAllowed(version: "0.05.260914", attempted: "0.05.260913", skipped: nil))
    }
}
