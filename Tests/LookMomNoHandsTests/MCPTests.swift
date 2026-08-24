import XCTest
@testable import LookMomNoHands

final class MCPTests: XCTestCase {

    // MARK: newline framing

    func testCompleteLinesDrainPartialStays() {
        var buffer = Data("{\"a\":1}\n{\"b\":2}\n{\"c\":".utf8)
        let frames = MCPConnection.drainFrames(from: &buffer)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(String(decoding: frames[0], as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "{\"c\":",
                       "the partial tail must survive for the next read")
    }

    func testPartialThenCompletion() {
        var buffer = Data("{\"a\":".utf8)
        XCTAssertTrue(MCPConnection.drainFrames(from: &buffer).isEmpty)
        buffer.append(Data("1}\n".utf8))
        let frames = MCPConnection.drainFrames(from: &buffer)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testBlankLinesAreDropped() {
        var buffer = Data("\n\n{\"a\":1}\n\n".utf8)
        XCTAssertEqual(MCPConnection.drainFrames(from: &buffer).count, 1)
    }

    // MARK: qualified names

    func testQualifiedSplitsOnFirstDot() {
        let parsed = MCPManager.parse(qualified: "gmail.messages.search")
        XCTAssertEqual(parsed?.server, "gmail")
        XCTAssertEqual(parsed?.tool, "messages.search",
                       "tool names may contain dots; only the first dot is the server boundary")
    }

    func testUnqualifiedNamesAreRejected() {
        XCTAssertNil(MCPManager.parse(qualified: "gmail"))
        XCTAssertNil(MCPManager.parse(qualified: ".search"))
        XCTAssertNil(MCPManager.parse(qualified: "gmail."))
    }

    // MARK: config

    func testServerNameIsNormalizedForToolPrefixes() {
        // "My Slack" would make an unmatchable tool id — names normalize to
        // lowercase-hyphenated at construction.
        XCTAssertEqual(MCPServerConfig(name: "My Slack", command: "npx x").name, "my-slack")
    }
}
