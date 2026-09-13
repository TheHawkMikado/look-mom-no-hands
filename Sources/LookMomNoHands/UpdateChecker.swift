import Foundation

/// Checks nohandsapp.com for a newer build and surfaces a nudge in the panel.
///
/// The app ships direct (no Mac App Store), so there is no OS-provided update
/// path — this is it. It notifies, and — since the owner asked for it — it can
/// also *install* the update on its own when the app is idle (`autoInstall`,
/// on by default, one switch in the panel to turn off). The download is still
/// only ever run through AppUpdater's signature gate: automatic means "no
/// click", never "less checking".
///
/// Everything here fails open: no network, a garbled manifest, a server outage —
/// all leave `status` at `.upToDate` (or its last good value) and never block or
/// nag. An update check that got in the way would be worse than no check.
///
/// ## Version format
///
/// Versions are `#.##.YYMMDD` — marketing version, then the release date
/// (`0.02.260730`). `compare` reads dot-separated components numerically, so the
/// date is simply a third component that only ever climbs, and two releases on
/// the same day are separated by the marketing version. Pre-dated builds order
/// correctly against it without a special case: `0.1.0` → `[0, 1, 0]`, which is
/// behind `0.02.260730` → `[0, 2, 260730]`.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case upToDate
        /// A newer version exists; the user can keep working.
        case available(version: String, url: URL, notes: String)
        /// Running below the server's floor — worth an upgrade prompt, but still
        /// not enforced client-side (the server gates what actually matters).
        case required(version: String, url: URL, notes: String)

        var updateURL: URL? {
            switch self {
            case .upToDate: return nil
            case .available(_, let url, _), .required(_, let url, _): return url
            }
        }
    }

    /// What a *hand-clicked* check should say when there's no update to show.
    /// Silence is right for the background poll and wrong for a button press —
    /// a click that changes nothing on screen reads as a broken button.
    enum ManualResult: Equatable {
        case current(String)
        case unreachable
    }

    @Published private(set) var status: Status = .upToDate
    @Published private(set) var isChecking = false
    /// Set only by a forced check, so the confirmation appears when a human asked
    /// and never as a side effect of the launch poll.
    @Published private(set) var manualResult: ManualResult?
    /// Direct DMG asset of the latest release, when the manifest carries one —
    /// what the in-app one-click updater downloads. nil = fall back to the page.
    @Published private(set) var dmgURL: URL?

    // MARK: - Automatic install

    nonisolated static let autoInstallKey = "lmnh.update.autoInstall"
    private let autoAttemptedKey = "lmnh.update.autoAttemptedVersion"
    /// The version the user reverted FROM (AppUpdater writes it). Exactly that
    /// version is never auto-installed again — the banner still shows it and a
    /// manual "Update now" still works; only the silent path is closed, or the
    /// idle-installer would undo the revert within the hour.
    nonisolated static let skipAutoInstallKey = "lmnh.update.skipAutoInstallVersion"

    /// Install updates without a click, when the app is idle. Default ON.
    var autoInstall: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoInstallKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.autoInstallKey)
            if newValue { tryPendingInstall() }
        }
    }

    /// Injected at wiring: true when nothing is in flight (no recording, no
    /// goal running, no meeting being captured). An update swaps the bundle and
    /// relaunches, so it must never land mid-sentence.
    var isIdle: (() -> Bool)?

    /// An update found while the app was busy; installed as soon as it idles.
    private var pendingAutoInstall: (version: String, dmg: URL)?

    /// Call whenever the app returns to idle (and after a check). Installs the
    /// pending update once per version: a failed attempt is shown in the panel
    /// and not retried automatically, so a bad download can't loop forever.
    func tryPendingInstall() {
        guard autoInstall, let pending = pendingAutoInstall, isIdle?() ?? false else { return }
        guard Self.autoInstallAllowed(version: pending.version,
                                      attempted: UserDefaults.standard.string(forKey: autoAttemptedKey),
                                      skipped: UserDefaults.standard.string(forKey: Self.skipAutoInstallKey))
        else { return }
        guard !AppUpdater.shared.phase.busy else { return }
        UserDefaults.standard.set(pending.version, forKey: autoAttemptedKey)
        pendingAutoInstall = nil
        AppUpdater.shared.install(fromDMG: pending.dmg)
    }

    /// Whether the silent installer may install `version`: once per version
    /// (`attempted`), and never the exact version the user reverted away from
    /// (`skipped`). Any other version — including a newer one after a revert —
    /// is fair game, so a bad release is skipped, not the whole update channel.
    /// Pure for tests.
    nonisolated static func autoInstallAllowed(version: String, attempted: String?, skipped: String?) -> Bool {
        if let attempted, attempted == version { return false }
        if let skipped, skipped == version { return false }
        return true
    }

    /// The version auto-install is currently skipping (after a revert), for the
    /// settings UI. nil = nothing skipped.
    var skippedVersion: String? { UserDefaults.standard.string(forKey: Self.skipAutoInstallKey) }

    /// The running build, for display next to the check button.
    var currentVersion: String { current }

    private let manifestURL = URL(string: "https://nohandsapp.com/api/version")!
    private let lastCheckKey = "lmnh.update.lastCheck"

    /// Background-check cadence by account mode: BYOK accounts check daily (a
    /// courtesy nudge); Cloud accounts hourly — they run on the platform's
    /// keys, so when a release closes a costly or unsafe behavior, the window
    /// where an old build keeps spending platform money must stay small.
    /// Manual "Check now" always bypasses this.
    nonisolated static func interval(forMode mode: String?) -> TimeInterval {
        // Prefix match, not equality: a future "cloud_pro" tier must get the
        // short leash automatically — falling to the slow cadence for exactly
        // the accounts that spend platform money is the failure mode here.
        (mode?.lowercased().hasPrefix("cloud") ?? false) ? 3600 : 24 * 3600
    }

    /// Injected at wiring (the app struct holds both this and AccountStore) so
    /// AccountStore stays the sole reader of its own persistence — a shadow
    /// parse of its storage here once risked silently falling back to the slow
    /// cadence for exactly the Cloud accounts the fast one exists for.
    var modeProvider: (() -> String?)?

    private var minInterval: TimeInterval { Self.interval(forMode: modeProvider?()) }

    private var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Fire-and-forget at launch. Honours the throttle unless `force` is set
    /// (the panel's "Check now" button passes force).
    func checkInBackground(force: Bool = false) {
        Task { await check(force: force) }
    }

    private var ticker: Timer?

    /// The cadence lives in the throttle, not the timer: this ticks hourly and
    /// `check()` declines until the mode's interval has passed — so a Cloud
    /// account effectively checks hourly and a BYOK one daily, without the
    /// panel ever being opened.
    func startPeriodicChecks() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func check(force: Bool = false) async {
        if !force, let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < minInterval {
            return
        }

        if force {
            isChecking = true
            manualResult = nil
        }
        defer { if force { isChecking = false } }

        // Stamped BEFORE the network call: stamping after it made every check
        // land a fraction later than its tick, so the equal-period throttle
        // rejected every other hourly tick and Cloud silently checked 2-hourly.
        // Restored on failure below, or an offline moment would burn the slot.
        let previousStamp = UserDefaults.standard.object(forKey: lastCheckKey)
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        var req = URLRequest(url: manifestURL)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            // Fail open — keep whatever status we had. But if a human clicked,
            // say so rather than leaving them staring at an unchanged panel.
            UserDefaults.standard.set(previousStamp, forKey: lastCheckKey)
            if force { manualResult = .unreachable }
            return
        }

        let url = URL(string: manifest.downloadURL) ?? AppLinks.download
        // Direct DMG asset for the one-click in-app update; the page URL stays
        // the fallback for older manifests and for a failed self-update.
        dmgURL = manifest.dmgURL.flatMap(URL.init(string:))
        // Minimum-version is a FLOOR, so it compares on the ordered base only —
        // running the numeric comparator over a hex commit component would hand
        // out (or withhold) the hard update-required prompt based on whether a
        // hash happens to start with a digit.
        if Self.compare(Self.baseThree(current), isLessThan: Self.baseThree(manifest.minimumVersion)) {
            status = .required(version: manifest.version, url: url, notes: manifest.notes)
        } else if Self.isUpdate(current: current, latest: manifest.version) {
            status = .available(version: manifest.version, url: url, notes: manifest.notes)
        } else {
            status = .upToDate
            if force { manualResult = .current(current) }
        }

        // Newer build with a direct image → queue it; it installs the moment the
        // app is idle (right now, usually). A manual check with the switch off
        // still only shows the banner.
        if let dmg = dmgURL, status != .upToDate {
            pendingAutoInstall = (manifest.version, dmg)
            tryPendingInstall()
        } else {
            pendingAutoInstall = nil
        }
    }

    /// Ordering for the V#.##.YYMMDD.COMMIT scheme: milestone, update, and
    /// date compare numerically; the commit component is an IDENTITY, not an
    /// ordinal — hex doesn't order. When the first three match, the server's
    /// word is authoritative: a different (or newly present) commit component
    /// means a respin this build doesn't have. Same-identity never updates, so
    /// a stale manifest can't downgrade anyone.
    /// The ordered half of a version: milestone.update.date, commit stripped.
    nonisolated static func baseThree(_ v: String) -> String {
        v.split(separator: ".").prefix(3).joined(separator: ".")
    }

    nonisolated static func isUpdate(current: String, latest: String) -> Bool {
        let c = parts(current), l = parts(latest)
        for i in 0..<3 {
            let cv = i < c.count ? c[i] : 0
            let lv = i < l.count ? l[i] : 0
            if cv != lv { return cv < lv }
        }
        let cCommit = current.split(separator: ".").dropFirst(3).joined(separator: ".")
        let lCommit = latest.split(separator: ".").dropFirst(3).joined(separator: ".")
        return !lCommit.isEmpty && cCommit != lCommit
    }

    // MARK: - Semver compare

    /// True when `a` is strictly older than `b`. Compares dot-separated numeric
    /// components, shorter-is-older ("1.2" < "1.2.1"); any non-numeric component
    /// is treated as 0 so a malformed manifest can never *invent* an update.
    nonisolated static func compare(_ a: String, isLessThan b: String) -> Bool {
        let lhs = parts(a), rhs = parts(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    nonisolated private static func parts(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    private struct Manifest: Decodable {
        let version: String
        let downloadURL: String
        let notes: String
        let minimumVersion: String
        /// Optional so a pre-dmg_url manifest still decodes (fails open to the
        /// download page, exactly the old behavior).
        let dmgURL: String?

        enum CodingKeys: String, CodingKey {
            case version
            case downloadURL = "download_url"
            case notes
            case minimumVersion = "minimum_version"
            case dmgURL = "dmg_url"
        }
    }
}

enum AppLinks {
    static let download = URL(string: "https://nohandsapp.com/#download")!
}
