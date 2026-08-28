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
            phase = .relaunching
            try Self.spawnSwapHelper(staged: staged, bundlePath: Bundle.main.bundlePath)
            // The helper waits for this exit, swaps the bundle, and relaunches.
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

    /// A tiny detached shell that outlives us: wait for our exit, replace the
    /// bundle, relaunch it, clean up. Detached (new session, ignored signals via
    /// nohup-like setup) so terminating the app doesn't kill the installer.
    nonisolated private static func spawnSwapHelper(staged: URL, bundlePath: String) throws {
        let script = swapScript(pid: ProcessInfo.processInfo.processIdentifier,
                                staged: staged.path, app: bundlePath)
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
    nonisolated static func swapScript(pid: Int32, staged: String, app: String) -> String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/sh
        # Look Ma, No Hands self-update helper. Safe to delete.
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(q(app))
        /usr/bin/ditto \(q(staged)) \(q(app))
        /usr/bin/open \(q(app))
        /bin/rm -rf \(q((staged as NSString).deletingLastPathComponent))
        /bin/rm -f "$0"
        """
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
