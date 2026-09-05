import Foundation

/// Mirrors finished notes — dictations and meeting notes — into a user-chosen
/// folder as portable Markdown (and meeting recordings as audio). Point it at
/// Dropbox and the Dropbox client syncs them everywhere; the app is NOT
/// sandboxed, so writing straight into ~/Dropbox (or any folder) just works —
/// no OAuth, no tokens, nothing to expire. Off until a folder is chosen.
@MainActor
final class NotesExporter: ObservableObject {

    /// Destination folder path; nil = export off. Persisted.
    @Published var folderPath: String? {
        didSet { UserDefaults.standard.set(folderPath, forKey: Self.folderKey) }
    }
    private static let folderKey = "notesExportFolder"

    /// Coordinator-provided activity logger. Export is a mirror, never the
    /// source of truth — every failure soft-fails into the log.
    var log: (String) -> Void = { _ in }

    init() {
        folderPath = UserDefaults.standard.string(forKey: Self.folderKey)
        // Warm the lazy Dropbox probe off-main: its first touch does File-
        // Provider round-trips, and without this that lands inside the Settings
        // tab's first body render. Global queue, not noteIO — a note filed at
        // launch must not wait behind a cold-provider probe.
        DispatchQueue.global(qos: .utility).async { _ = Self.dropboxFolder }
    }

    /// Where the Dropbox client keeps its synced folder, when installed —
    /// probed ONCE per launch (it's a File-Provider round-trip) and cached.
    /// Modern client: ~/Library/CloudStorage/Dropbox[-Team]; legacy: ~/Dropbox.
    nonisolated static let dropboxFolder: String? = {
        let home = NSHomeDirectory()
        let cloud = home + "/Library/CloudStorage"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: cloud) {
            // A user signed into personal + team Dropbox has "Dropbox" AND
            // "Dropbox-Team": prefer the personal one (private notes must not
            // default into a shared tree), and sort so the pick is at least
            // deterministic — directory enumeration order isn't.
            let candidates = entries.filter { $0.hasPrefix("Dropbox") }.sorted()
            if let pick = candidates.first(where: { $0 == "Dropbox" }) ?? candidates.first {
                return cloud + "/" + pick
            }
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: home + "/Dropbox", isDirectory: &isDir), isDir.boolValue {
            return home + "/Dropbox"
        }
        return nil
    }()

    /// Writes one note as Markdown into <folder>/Look Ma No Hands/Notes/.
    func exportNote(title: String, transcript: String, report: DictationReport?, date: Date = Date()) {
        guard let root = folderPath else { return }
        let dest = URL(fileURLWithPath: root)
            .appendingPathComponent("\(AppIdentity.exportFolder)/Notes/\(Self.exportFilename(title: title, date: date, ext: "md"))")
        // Markdown rendering happens inside the op — a long meeting transcript
        // is hundreds of KB and doesn't belong on the main actor.
        perform(into: dest, on: Self.noteIO) { target in
            let data = Data(Self.markdown(title: title, date: date, report: report,
                                          transcript: transcript).utf8)
            try data.write(to: target, options: .atomic)   // a torn .md must never sync as the note
        }
    }

    /// Copies a meeting recording into <folder>/Look Ma No Hands/Recordings/.
    func exportRecording(_ url: URL) {
        guard let root = folderPath else { return }
        let dest = URL(fileURLWithPath: root)
            .appendingPathComponent("\(AppIdentity.exportFolder)/Recordings/\(url.lastPathComponent)")
        perform(into: dest, on: Self.recordingIO) { target in
            try FileManager.default.copyItem(at: url, to: target)
        }
    }

    // SERIAL per artifact type: the collision check and the write must not race
    // a concurrent export of a same-named file, and the destination is
    // typically a File-Provider folder (Dropbox/CloudStorage) where one copy
    // can block for seconds. Notes and recordings live in different subfolders
    // — separate queues, so a tiny .md never waits behind a 100 MB m4a copy.
    private static let noteIO = DispatchQueue(label: AppIdentity.storeQueueLabel + ".notesexport", qos: .utility)
    private static let recordingIO = DispatchQueue(label: AppIdentity.storeQueueLabel + ".recordingexport", qos: .utility)

    /// Shared scaffolding: mkdir → numbered-suffix collision policy → op → log.
    /// Suffixing (never overwriting, never pre-deleting) means a failed op can't
    /// destroy an existing good export, and two same-minute notes both survive.
    private func perform(into dest: URL, on queue: DispatchQueue, _ op: @escaping (URL) throws -> Void) {
        let log = log
        queue.async {
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let target = Self.unoccupied(dest)
                try op(target)
                let name = target.lastPathComponent
                DispatchQueue.main.async { log("exported \(name)") }
            } catch {
                let name = dest.lastPathComponent
                let reason = error.localizedDescription
                DispatchQueue.main.async { log("export of \(name) failed: \(reason)") }
            }
        }
    }

    /// First free variant of a filename: "x.md", then "x 2.md", "x 3.md"…
    /// Unbounded on purpose — any cap's escape hatch would have to return an
    /// occupied name, which is exactly the overwrite this function forbids.
    nonisolated static func unoccupied(_ dest: URL) -> URL {
        guard FileManager.default.fileExists(atPath: dest.path) else { return dest }
        let dir = dest.deletingLastPathComponent()
        let stem = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Filename-safe timestamp, shared with MeetingRecorder's recording names.
    nonisolated static func stamp(_ date: Date) -> String { ExportStamp.name.string(from: date) }

    /// One sanitizer for every artifact name (notes here, recordings in
    /// MeetingRecorder). Strips everything Windows/Dropbox reject, not just
    /// macOS's set — a name macOS accepts but Dropbox won't sync breaks the
    /// exporter's whole promise on the user's other machines.
    nonisolated static func safeComponent(_ title: String, max: Int) -> String {
        let forbidden = Set("/:\\?*<>|\"")
        let cleaned = String(title.map { c -> Character in
            forbidden.contains(c) || c.isNewline ? "-" : c
        }).trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(max))
    }

    /// The note as portable Markdown. Pure — unit-tested.
    nonisolated static func markdown(title: String, date: Date, report: DictationReport?,
                                     transcript: String) -> String {
        var s = "# \(title.isEmpty ? "Note" : title)\n\n_\(ExportStamp.body.string(from: date))_\n"
        if let report {
            if !report.summary.isEmpty { s += "\n\(report.summary)\n" }
            if !report.keyPoints.isEmpty {
                s += "\n## Key points\n\n" + report.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if !report.actionItems.isEmpty {
                s += "\n## Action items\n\n" + report.actionItems.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n"
            }
        }
        if !transcript.isEmpty {
            s += "\n## Transcript\n\n\(transcript)\n"
        }
        return s
    }

    /// "2026-09-05 14.03 Standup notes.md" — date first so folders sort by time.
    /// Pure — unit-tested.
    nonisolated static func exportFilename(title: String, date: Date, ext: String) -> String {
        let safe = safeComponent(title, max: 60)
        return "\(stamp(date)) \(safe.isEmpty ? "Note" : safe).\(ext)"
    }
}

// POSIX-pinned, cached, outside the actor so nonisolated helpers can use them:
// an unpinned DateFormatter follows the system calendar (Buddhist/Japanese
// eras), which would break the date-first chronological sort the filenames
// exist to provide. DateFormatter is thread-safe for formatting on macOS 10.9+.
private enum ExportStamp {
    static let body: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    static let name: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}
