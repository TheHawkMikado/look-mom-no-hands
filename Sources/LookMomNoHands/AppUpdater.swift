import Foundation
import AppKit
import Security

/// One-click, user-initiated update: download the release DMG, prove the app
/// inside is OURS, stage it, swap and relaunch. The app's old trust line holds
/// — nothing here ever runs without the user clicking Update — the line just
/// moves from "go do the Finder ritual yourself" to "one deliberate click".
///
/// The security bar is the signature, not the transport. The staged app must
/// satisfy a pinned Developer ID requirement for this team or the update is
/// discarded: HTTPS protects the download in flight; the codesign requirement
/// protects against everything else (a hijacked release asset, a wrong URL, a
/// poisoned mirror). Quarantine is cleared only AFTER verification passes —
/// Gatekeeper would otherwise translocate the copy we just proved is ours.
///
/// Every install keeps the bundle it replaced (one generation, under
/// `updates/previous/`) so "revert to the last working version" is a click,
/// not a hunt through old DMGs. The revert goes through the SAME signature
/// gate as an update — a bundle that sat on disk for a week is still code we
/// are about to run.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()   // survives the panel closing mid-download

    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case relaunching
        case failed(String)

        var label: String {
            switch self {
            case .idle: return ""
            case .downloading: return "Downloading update…"
            case .verifying: return "Verifying it's really ours…"
            case .relaunching: return "Installing — back in a moment…"
            case .failed(let m): return "Update failed: \(m)"
            }
        }

        var busy: Bool {
            switch self {
            case .downloading, .verifying, .relaunching: return true
            case .idle, .failed: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    /// The build the last update replaced, if it is still on disk. Read from
    /// `updates/previous/previous.json`; nil until the first self-update lands
    /// (or after a revert, which consumes it).
    @Published private(set) var previousBuild: PreviousBuild?

    /// `(version, path)` of the bundle a revert would reinstall — nil when
    /// there is nothing to go back to. Same information as `previousBuild`,
    /// in the shape the settings UI reads.
    var previousVersion: (version: String, path: String)? {
        guard let p = previousBuild else { return nil }
        return (p.version, p.path)
    }

    init() {
        previousBuild = Self.loadPrevious(from: previousRecordURL)
    }

    /// Pin the TEAM, not a certificate: rotation of the signing cert must not
    /// brick updates, but no requirement weaker than "Apple-anchored Developer
    /// ID for exactly this team" is acceptable for code we're about to run.
    nonisolated static let requirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"B59AM8227J\""

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func install(fromDMG url: URL) {
        guard !phase.busy else { return }
        Task { await run(url) }
    }

    private func run(_ url: URL) async {
        phase = .downloading
        do {
            let dmg = try await download(url)
            phase = .verifying
            let staged = try await Task.detached { try Self.stageApp(fromDMG: dmg) }.value
            try Self.verifySignature(at: staged)
            try? Self.clearQuarantine(at: staged)
            let running = Bundle.main.bundlePath
            let dest = Self.installDestination(forRunningBundle: running)
            try Self.checkReplaceable(dest)
            phase = .relaunching
            // Keep what we are replacing: the helper moves it aside and writes
            // the record only once the move succeeded, so previous.json never
            // names a bundle that isn't there.
            let keep = PreviousBuild(version: Self.currentVersion,
                                     path: previousBundleURL(forInstall: dest).path,
                                     replacedAt: PreviousBuild.stamp(Date()))
            try Self.spawnSwapHelper(staged: staged, dest: dest, running: running,
                                     cleanup: [dmg.path], log: updatesDir.appendingPathComponent("swap.log"),
                                     keep: keep, record: previousRecordURL)
            // The helper waits for this exit, swaps the bundle, and relaunches.
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Revert

    /// Puts the previous build back. Same gate, same swap, same relaunch as an
    /// update — only the source differs (the kept bundle instead of a fresh
    /// download). The version we are leaving is recorded so the auto-installer
    /// doesn't put it straight back the moment the app is idle again; the
    /// banner still shows it and a manual "Update now" still works.
    func revertToPrevious() {
        guard !phase.busy, let previous = previousBuild else { return }
        Task { await runRevert(previous) }
    }

    private func runRevert(_ previous: PreviousBuild) async {
        phase = .verifying
        do {
            let staged = URL(fileURLWithPath: previous.path)
            guard FileManager.default.fileExists(atPath: previous.path) else {
                previousBuild = nil
                try? FileManager.default.removeItem(at: previousRecordURL)
                throw UpdateError(message: "the previous build is no longer on disk")
            }
            try Self.verifySignature(at: staged)
            try? Self.clearQuarantine(at: staged)
            let running = Bundle.main.bundlePath
            let dest = Self.installDestination(forRunningBundle: running)
            try Self.checkReplaceable(dest)
            UserDefaults.standard.set(Self.currentVersion, forKey: UpdateChecker.skipAutoInstallKey)
            phase = .relaunching
            // No `keep`: the build being reverted FROM is the one that didn't
            // work, and keeping it would make the next revert flip-flop. The
            // staging folder the helper removes afterwards IS `updates/previous`.
            try Self.spawnSwapHelper(staged: staged, dest: dest, running: running,
                                     cleanup: [previousRecordURL.path],
                                     log: updatesDir.appendingPathComponent("swap.log"),
                                     keep: nil, record: nil)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Steps

    private var updatesDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.storageFolder).appendingPathComponent("updates")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `updates/previous/` — one kept generation, replaced on every install.
    private var previousDir: URL { updatesDir.appendingPathComponent("previous", isDirectory: true) }
    private var previousRecordURL: URL { previousDir.appendingPathComponent("previous.json") }
    private func previousBundleURL(forInstall dest: String) -> URL {
        previousDir.appendingPathComponent((dest as NSString).lastPathComponent)
    }

    /// The running build's marketing version — what previous.json records.
    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// nil unless the record decodes AND the bundle it names still exists — a
    /// record pointing at nothing is worse than none (a revert button that
    /// fails on click).
    nonisolated private static func loadPrevious(from url: URL) -> PreviousBuild? {
        guard let data = try? Data(contentsOf: url), let p = PreviousBuild.decode(data),
              FileManager.default.fileExists(atPath: p.path) else { return nil }
        return p
    }

    private func download(_ url: URL) async throws -> URL {
        guard url.scheme == "https" else { throw UpdateError(message: "refusing a non-HTTPS download") }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError(message: "download failed (HTTP \(status))") }
        let dest = updatesDir.appendingPathComponent("update.dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Mount read-only, copy the one .app out to a staging folder, unmount.
    /// Runs off the main actor — hdiutil takes seconds.
    nonisolated private static func stageApp(fromDMG dmg: URL) throws -> URL {
        let attach = try shell("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
        guard let mount = parseMountPoint(fromAttachPlist: Data(attach.utf8)) else {
            throw UpdateError(message: "couldn't mount the update image")
        }
        defer { _ = try? shell("/usr/bin/hdiutil", ["detach", mount, "-force"]) }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mount)) ?? []
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError(message: "no app inside the update image")
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(appName)
        _ = try shell("/usr/bin/ditto", ["\(mount)/\(appName)", staged.path])
        return staged
    }

    /// The mount point from `hdiutil attach -plist`: the system-entity that has
    /// one. Pure so it's testable against a canned plist.
    nonisolated static func parseMountPoint(fromAttachPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    /// The gate everything hangs on: Apple-anchored Developer ID, our team,
    /// valid across all architectures. Fails closed.
    nonisolated private static func verifySignature(at app: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdateError(message: "downloaded app is unreadable")
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
              let requirement = req else {
            throw UpdateError(message: "internal: bad code requirement")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else {
            throw UpdateError(message: "the downloaded app is not signed by us — discarded")
        }
    }

    nonisolated private static func clearQuarantine(at app: URL) throws {
        _ = try shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    }

    /// Where the new build lands. Normally the running bundle's own path — but
    /// two places must never be swapped in place: a Gatekeeper-translocated
    /// copy (`…/AppTranslocation/…`, what you get when the app is launched
    /// straight from a download without a drag to Applications) and an app run
    /// off the mounted DMG (`/Volumes/…`). Replacing those updates a throwaway
    /// copy and leaves the real install — or no install at all — on the old
    /// version. Both land in /Applications instead, which is where the user
    /// expected the app to be anyway. Pure for tests.
    nonisolated static func installDestination(forRunningBundle path: String,
                                               applicationsDir: String = "/Applications") -> String {
        let name = (path as NSString).lastPathComponent
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return (applicationsDir as NSString).appendingPathComponent(name)
        }
        return path
    }

    /// Fail BEFORE quitting if the swap cannot succeed: once the app has
    /// terminated there is nobody left to show an error. A bundle installed by
    /// another admin account, or an Applications folder this user can't write,
    /// gets the manual "drag from the DMG" path instead of a vanished app.
    nonisolated private static func checkReplaceable(_ dest: String) throws {
        let fm = FileManager.default
        let parent = (dest as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: parent) else {
            throw UpdateError(message: "can't write to \(parent) — drag the new version in from the DMG instead")
        }
        if fm.fileExists(atPath: dest), !fm.isDeletableFile(atPath: dest) {
            throw UpdateError(message: "the installed app is owned by another user — drag the new version in from the DMG instead")
        }
    }

    /// A tiny detached shell that outlives us: wait for our exit, replace the
    /// bundle, relaunch it, clean up. Detached (new session, ignored signals via
    /// nohup-like setup) so terminating the app doesn't kill the installer.
    nonisolated private static func spawnSwapHelper(staged: URL, dest: String, running: String,
                                                    cleanup: [String], log: URL,
                                                    keep: PreviousBuild?, record: URL?) throws {
        let script = swapScript(pid: ProcessInfo.processInfo.processIdentifier,
                                staged: staged.path, app: dest, running: running,
                                cleanup: cleanup, log: log.path,
                                previous: keep?.path, record: record?.path,
                                recordJSON: keep.flatMap { $0.encodedString() })
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        // Deliberately NOT waited on — it must outlive this process.
    }

    /// Pure for tests. Single-quoted paths so spaces ("Look Ma, No Hands.app")
    /// survive; the wait loop polls our pid rather than trusting timing.
    ///
    /// `app` is the install destination, `running` the bundle that was actually
    /// executing (the same path unless it was translocated or on the DMG). The
    /// old version is moved to `previous` (when given — any older kept bundle
    /// there is replaced first) or removed, then the new one is copied in.
    /// `record` + `recordJSON` name the previous.json to write — and it is
    /// written ONLY after the move succeeded, so it can never describe a
    /// bundle that isn't there. If the copy fails the moved-aside bundle is
    /// put back and the record removed, so a failed update leaves the user on
    /// the version they had; the script still tries to relaunch SOMETHING —
    /// the destination first, then the bundle we came from — so a failed
    /// update never leaves the user with no app at all. Everything is logged
    /// so a failure can be read afterwards.
    nonisolated static func swapScript(pid: Int32, staged: String, app: String,
                                       running: String? = nil, cleanup: [String] = [],
                                       log: String? = nil,
                                       previous: String? = nil, record: String? = nil,
                                       recordJSON: String? = nil) -> String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let staging = (staged as NSString).deletingLastPathComponent
        var lines = [
            "#!/bin/sh",
            "# Look Ma, No Hands self-update helper. Safe to delete.",
        ]
        if let log { lines.append("exec >>\(q(log)) 2>&1; echo \"--- $(date) update to \(q(app))\"") }
        lines.append("while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done")
        if let previous {
            let previousDir = (previous as NSString).deletingLastPathComponent
            lines += [
                "/bin/rm -rf \(q(previous))",
                "/bin/mkdir -p \(q(previousDir))",
                "kept=0",
                "if [ -e \(q(app)) ]; then",
                "  if /bin/mv \(q(app)) \(q(previous)); then kept=1; else /bin/rm -rf \(q(app)); fi",
                "fi",
                "if /usr/bin/ditto \(q(staged)) \(q(app)); then",
                "  echo installed",
            ]
            if let record, let recordJSON {
                lines.append("  if [ \"$kept\" = 1 ]; then printf '%s' \(q(recordJSON)) > \(q(record)); fi")
            }
            lines += [
                "else",
                "  echo \"install failed; restoring the previous bundle\"",
                "  if [ \"$kept\" = 1 ] && [ ! -e \(q(app)) ]; then /bin/mv \(q(previous)) \(q(app)); fi",
            ]
            if let record { lines.append("  /bin/rm -f \(q(record))") }
            lines.append("fi")
        } else {
            lines += [
                "if /bin/rm -rf \(q(app)) && /usr/bin/ditto \(q(staged)) \(q(app)); then",
                "  echo installed",
                "else",
                "  echo \"install failed; relaunching what is left\"",
                "fi",
            ]
        }
        if let running, running != app {
            lines.append("/usr/bin/open \(q(app)) || /usr/bin/open \(q(running))")
        } else {
            lines.append("/usr/bin/open \(q(app))")
        }
        lines.append("/bin/rm -rf \(q(staging))")
        for path in cleanup { lines.append("/bin/rm -f \(q(path))") }
        lines.append("/bin/rm -f \"$0\"")
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    nonisolated private static func shell(_ launchPath: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError(message: "\((launchPath as NSString).lastPathComponent) failed (\(p.terminationStatus))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What `updates/previous/previous.json` holds: the build the last update
/// replaced. `replaced_at` is an ISO-8601 stamp (a string, not a Date, so the
/// file stays readable by hand and by the shell helper that writes it). A
/// plain top-level type — not nested in the main-actor updater — so the pure
/// encode/decode can be exercised from tests without an actor hop.
struct PreviousBuild: Codable, Equatable {
    let version: String
    let path: String
    let replacedAt: String

    enum CodingKeys: String, CodingKey {
        case version, path
        case replacedAt = "replaced_at"
    }

    /// Single-line JSON, sorted keys: goes through `printf '%s'` inside a
    /// single-quoted shell argument, so no newlines and a stable shape.
    func encodedString() -> String? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let data = try? e.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// nil for anything that isn't a complete record — a half-written file
    /// must read as "no previous build", never as a bundle to reinstall.
    static func decode(_ data: Data) -> PreviousBuild? {
        guard let p = try? JSONDecoder().decode(PreviousBuild.self, from: data),
              !p.version.isEmpty, !p.path.isEmpty else { return nil }
        return p
    }

    static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
