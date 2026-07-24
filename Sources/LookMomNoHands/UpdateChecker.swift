import Foundation

/// Checks nohandsapp.com for a newer build and surfaces a nudge in the panel.
///
/// The app ships direct (no Mac App Store), so there is no OS-provided update
/// path — this is it. It only ever *notifies*; downloading and installing stays
/// a deliberate act by the user. Silent auto-update of an app that can drive the
/// whole machine is a trust line this deliberately doesn't cross.
///
/// Everything here fails open: no network, a garbled manifest, a server outage —
/// all leave `status` at `.upToDate` (or its last good value) and never block or
/// nag. An update check that got in the way would be worse than no check.
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

    @Published private(set) var status: Status = .upToDate

    private let manifestURL = URL(string: "https://nohandsapp.com/api/version")!
    /// Don't poll more than this often, even across relaunches — the check is a
    /// courtesy, not something to hammer the endpoint for.
    private let minInterval: TimeInterval = 6 * 3600
    private let lastCheckKey = "lmnh.update.lastCheck"

    private var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Fire-and-forget at launch. Honours the throttle unless `force` is set
    /// (the panel's "Check now" button passes force).
    func checkInBackground(force: Bool = false) {
        Task { await check(force: force) }
    }

    func check(force: Bool = false) async {
        if !force, let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < minInterval {
            return
        }

        var req = URLRequest(url: manifestURL)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return }  // fail open — keep whatever status we had

        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        let url = URL(string: manifest.downloadURL) ?? AppLinks.download
        if Self.compare(current, isLessThan: manifest.minimumVersion) {
            status = .required(version: manifest.version, url: url, notes: manifest.notes)
        } else if Self.compare(current, isLessThan: manifest.version) {
            status = .available(version: manifest.version, url: url, notes: manifest.notes)
        } else {
            status = .upToDate
        }
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

        enum CodingKeys: String, CodingKey {
            case version
            case downloadURL = "download_url"
            case notes
            case minimumVersion = "minimum_version"
        }
    }
}

enum AppLinks {
    static let download = URL(string: "https://nohandsapp.com/#download")!
}
