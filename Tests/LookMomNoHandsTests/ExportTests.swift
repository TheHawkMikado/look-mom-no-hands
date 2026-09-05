import XCTest
@testable import LookMomNoHands

final class ExportTests: XCTestCase {

    private func report(_ json: String) throws -> DictationReport {
        try JSONDecoder().decode(DictationReport.self, from: Data(json.utf8))
    }

    func testMarkdownRendersFullReport() throws {
        let r = try report(#"{"title":"Standup","summary":"We planned the week.","key_points":["Ship v4"],"action_items":["Hawk: send deck"],"transcript":"..."}"#)
        let md = NotesExporter.markdown(title: "Standup", date: Date(timeIntervalSince1970: 0),
                                        report: r, transcript: "hello world")
        XCTAssertTrue(md.hasPrefix("# Standup\n"))
        XCTAssertTrue(md.contains("We planned the week."))
        XCTAssertTrue(md.contains("## Key points\n\n- Ship v4"))
        XCTAssertTrue(md.contains("## Action items\n\n- [ ] Hawk: send deck"))
        XCTAssertTrue(md.contains("## Transcript\n\nhello world"))
    }

    func testMarkdownWithoutReportIsJustTitleAndTranscript() {
        let md = NotesExporter.markdown(title: "", date: Date(timeIntervalSince1970: 0),
                                        report: nil, transcript: "raw text")
        XCTAssertTrue(md.hasPrefix("# Note\n"))
        XCTAssertFalse(md.contains("## Key points"))
        XCTAssertTrue(md.contains("raw text"))
    }

    func testExportFilenameSanitizesAndSorts() {
        let name = NotesExporter.exportFilename(title: "Q3: Plan / Review",
                                                date: Date(timeIntervalSince1970: 0), ext: "md")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".md"))
        // Date-first so a synced folder lists chronologically.
        XCTAssertTrue(name.first?.isNumber == true)
    }

    func testUnoccupiedAddsNumberedSuffixInsteadOfClobbering() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("Live note.md")
        XCTAssertEqual(NotesExporter.unoccupied(first), first)   // free name passes through
        try Data("x".utf8).write(to: first)
        XCTAssertEqual(NotesExporter.unoccupied(first).lastPathComponent, "Live note 2.md")
    }

    func testSafeComponentSharedByNotesAndRecordings() {
        XCTAssertEqual(NotesExporter.safeComponent("Q3: Plan / Review", max: 40), "Q3- Plan - Review")
        XCTAssertEqual(NotesExporter.safeComponent(String(repeating: "a", count: 100), max: 10).count, 10)
        // Windows/Dropbox-invalid characters must go too, or the file is
        // created locally and silently never syncs to the user's PC.
        XCTAssertEqual(NotesExporter.safeComponent("What's next? Q4 <draft> | \"plan\"\n", max: 60),
                       "What's next- Q4 -draft- - -plan--")
    }

    func testMultipartHeadEscapesQuotesInFilename() {
        // A meeting titled with quotes reaches the upload as the recording's
        // filename; unescaped, it would corrupt the Content-Disposition header.
        let head = ScribeClient.multipartHead(filename: "Meeting Design \"Sprint\" Review.m4a",
                                              contentType: "audio/mp4", boundary: "B")
        let s = String(decoding: head, as: UTF8.self)
        XCTAssertFalse(s.contains("\"Sprint\""))
        XCTAssertTrue(s.contains("filename=\"Meeting Design 'Sprint' Review.m4a\""))
        XCTAssertTrue(s.contains("Content-Type: audio/mp4"))
    }

}
