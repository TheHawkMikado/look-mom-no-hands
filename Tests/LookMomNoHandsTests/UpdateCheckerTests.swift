import XCTest
@testable import LookMomNoHands

/// The version comparison decides whether every user sees an update nudge, so a
/// wrong answer is either a nag that never clears or a release nobody hears
/// about. These pin the ordering, including the awkward cases (uneven component
/// counts, a garbled manifest) where a naive string compare gets it wrong.
final class UpdateCheckerTests: XCTestCase {

    private func older(_ a: String, than b: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(UpdateChecker.compare(a, isLessThan: b),
                      "\(a) should be older than \(b)", file: file, line: line)
        XCTAssertFalse(UpdateChecker.compare(b, isLessThan: a),
                       "\(b) should not be older than \(a)", file: file, line: line)
    }

    func testBasicOrdering() {
        older("0.1.0", than: "0.2.0")
        older("0.1.0", than: "1.0.0")
        older("1.2.3", than: "1.2.4")
        older("1.9.0", than: "1.10.0")   // numeric, not lexical — "9" < "10"
    }

    func testEqualVersionsAreNotOlder() {
        XCTAssertFalse(UpdateChecker.compare("1.2.3", isLessThan: "1.2.3"))
        XCTAssertFalse(UpdateChecker.compare("0.1.0", isLessThan: "0.1.0"))
    }

    /// Shorter is older when the extra components are non-zero, equal when they're
    /// zero — "1.2" is behind "1.2.1" but level with "1.2.0".
    func testUnevenComponentCounts() {
        older("1.2", than: "1.2.1")
        XCTAssertFalse(UpdateChecker.compare("1.2", isLessThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.compare("1.2.0", isLessThan: "1.2"))
        older("1", than: "1.0.1")
    }

    /// A malformed manifest must never *invent* an update — a non-numeric
    /// component reads as 0, so junk can only ever compare equal-or-older, never
    /// newer than a real build.
    func testMalformedComponentsCannotFabricateAnUpdate() {
        // "abc" -> 0, so "1.abc.0" == "1.0.0"; neither is older.
        XCTAssertFalse(UpdateChecker.compare("1.0.0", isLessThan: "1.abc.0"))
        XCTAssertFalse(UpdateChecker.compare("1.abc.0", isLessThan: "1.0.0"))
        // Trailing build metadata after the number is ignored, not treated as newer.
        XCTAssertFalse(UpdateChecker.compare("1.2.3", isLessThan: "1.2.3-beta"))
    }

    /// The real shipping case: today's bundle vs a plausible next release.
    func testCurrentVsNextRelease() {
        older("0.1.0", than: "0.1.1")
        older("0.1.0", than: "0.2.0")
    }

    // MARK: - #.##.YYMMDD

    /// The date component is what usually moves between releases, so it has to
    /// order on its own — including across a month and a year boundary, where a
    /// string compare of "260901" vs "261001" happens to work but "261231" vs
    /// "270101" would not.
    func testDateComponentOrders() {
        older("0.02.260730", than: "0.02.260731")
        older("0.02.260930", than: "0.02.261001")
        older("0.02.261231", than: "0.02.270101")
    }

    /// A leading-zero day/month must read as decimal. Anything parsing "08" as
    /// octal would throw, and anything treating it as a string would sort wrong.
    func testLeadingZeroComponentsAreDecimal() {
        older("0.02.260808", than: "0.02.260809")
        older("0.02.260228", than: "0.02.260301")
    }

    /// The marketing version outranks the date — a same-day second release ships
    /// as 0.03, and it must beat 0.02 even though the dates tie.
    func testMarketingVersionOutranksDate() {
        older("0.02.260730", than: "0.03.260730")
        // …and an older date with a higher marketing version still wins, which is
        // what makes "cut 0.03 today, backport-tag 0.02 later" harmless.
        older("0.02.260801", than: "0.03.260730")
        older("0.09.260730", than: "0.10.260730")   // 9 < 10, not "9" > "1"
    }

    /// The actual upgrade every installed copy has to make: the shipped v0.1.0
    /// build, which predates the scheme, must see the first #.##.YYMMDD release
    /// as newer. "0.1.0" reads as [0,1,0] and "0.02.260730" as [0,2,260730], so
    /// it orders correctly despite looking larger to a human eye.
    func testPreSchemeBuildSeesFirstDatedRelease() {
        older("0.1.0", than: "0.02.260730")
        XCTAssertFalse(UpdateChecker.compare("0.02.260730", isLessThan: "0.1.0"))
    }

    /// A manifest that somehow drops the date must not read as an update to a
    /// build that already has one — otherwise a misconfigured env var nags every
    /// user forever with no way to clear it.
    func testUndatedManifestIsNotNewerThanDatedBuild() {
        XCTAssertFalse(UpdateChecker.compare("0.02.260730", isLessThan: "0.02"))
    }
}
