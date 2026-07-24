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
}
