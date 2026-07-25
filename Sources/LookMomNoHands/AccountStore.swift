import Foundation

/// The signed-in account: the app's replacement for pasting a licence key.
///
/// Access is now tied to a **person**, not a transferable secret. The user signs
/// in through the browser (`/app/login`), which hands back a per-device **bearer
/// token** over the `lookmomnohands://auth` URL scheme. With that token the app:
///   1. registers this Mac against the account's device pool (`/api/app/device`)
///      and receives a device-bound **Ed25519 entitlement token** — the same
///      offline-verifiable token the app has always gated on, so a plane still
///      works and a copied token still fails on another Mac;
///   2. pulls the account holder's **shared Anthropic + ElevenLabs keys**
///      (`/api/app/keys`) so nobody types a key into the app.
///
/// The bearer token is only needed online, to refresh the entitlement and keys.
/// Day-to-day the app runs on the cached entitlement token via `LicenseStore`.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var status: LicenseStatus = .signedOut
    @Published private(set) var info: AccountInfo?
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    /// Who's signed in — for display only. Persisted so it survives an offline
    /// launch (the entitlement token also carries email + plan, but this keeps
    /// the sub-user relationship visible without a round-trip).
    struct AccountInfo: Codable, Equatable {
        let email: String
        let plan: String
        let isSubUser: Bool
        let parentEmail: String?
    }

    static let host = URL(string: "https://nohandsapp.com")!
    static var signInURL: URL { host.appendingPathComponent("app/login") }
    static var accountURL: URL { host.appendingPathComponent("account") }

    private let appTokenAccount = "app-token"
    private let entTokenAccount = "license-token"   // reused format — LicenseStore verifies it
    private let infoDefaultsKey = "account-info"

    /// Set once at launch so key fetches can reach the running coordinator.
    private weak var coordinator: AppCoordinator?

    var isSignedIn: Bool { KeychainStore.load(account: appTokenAccount) != nil }

    init() { refresh() }

    func attach(coordinator: AppCoordinator) { self.coordinator = coordinator }

    // MARK: - Local state

    /// Recomputes status from what's on disk — a signature check, no network.
    /// Safe to call on every panel open.
    func refresh() {
        info = loadInfo()
        guard isSignedIn else { status = .signedOut; info = nil; return }
        if let token = KeychainStore.load(account: entTokenAccount),
           case .success(let claims) = LicenseStore.verify(token) {
            status = LicenseStore.status(for: claims)
        } else {
            // Signed in, but no usable entitlement yet (first run, or it was
            // cleared). A launch sync will mint one; until then, locked.
            status = .expired
        }
    }

    // MARK: - Sign-in handoff

    /// Handles `lookmomnohands://auth?token=…` opened by the browser after login.
    /// Matches on the scheme and the token query rather than a strict host, so a
    /// stray `//` or trailing slash in the redirect can't drop a valid sign-in.
    func handleAuthCallback(_ url: URL) async {
        guard url.scheme?.lowercased() == "lookmomnohands",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else { return }

        KeychainStore.save(token, account: appTokenAccount)
        lastError = nil
        await sync()
    }

    /// Refreshes the entitlement + keys if signed in. Called at launch and after
    /// a fresh sign-in. A network failure never downgrades a still-valid cached
    /// entitlement — `refresh()` has already set the honest offline status.
    func syncOnLaunch() async {
        refresh()
        guard isSignedIn else { return }
        await sync()
    }

    private func sync() async {
        guard let bearer = KeychainStore.load(account: appTokenAccount) else {
            status = .signedOut; return
        }
        isWorking = true
        defer { isWorking = false }

        await registerDevice(bearer: bearer)
        // Only chase session details + keys if the device call left us signed in.
        guard isSignedIn else { return }
        await fetchSession(bearer: bearer)
        await fetchKeys(bearer: bearer)
    }

    // MARK: - Networking

    private func registerDevice(bearer: String) async {
        let body: [String: Any] = ["device": LicenseStore.deviceID, "version": LicenseStore.appVersion]
        var req = request("api/app/device", method: "POST", bearer: bearer)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if code == 401 {
                // Token revoked or expired server-side — sign out locally.
                clearSession()
                status = .signedOut
                lastError = "You were signed out. Please sign in again."
                return
            }
            guard code == 200, let token = payload?["token"] as? String else {
                applyDeviceError(payload?["error"] as? String, payload: payload)
                return
            }
            // Never trust the server blindly — the token must verify against the
            // compiled-in public key before it's worth storing or gating on.
            switch LicenseStore.verify(token) {
            case .success(let claims):
                KeychainStore.save(token, account: entTokenAccount)
                status = LicenseStore.status(for: claims)
                lastError = nil
                // Capture plan / sub-user from the response for display.
                let plan = payload?["plan"] as? String ?? claims.plan
                let isSub = payload?["isSubUser"] as? Bool ?? false
                saveInfo(AccountInfo(email: claims.email, plan: plan,
                                     isSubUser: isSub, parentEmail: info?.parentEmail))
            case .failure(let err):
                lastError = "The server returned a token this build can't verify: \(err.message)"
            }
        } catch {
            // Offline or unreachable: keep the cached entitlement status set by
            // refresh(). Nagging someone on a plane would be worse than silence.
            lastError = nil
        }
    }

    private func applyDeviceError(_ error: String?, payload: [String: Any]?) {
        switch error {
        case "no_subscription":
            status = .expired
            lastError = "No active subscription on this account. Subscribe at nohandsapp.com."
        case "inactive":
            status = .expired
            lastError = "Your subscription is inactive. Update billing at nohandsapp.com."
        case "device_limit":
            let n = payload?["devices"] as? Int
            status = .invalid("Device limit reached")
            lastError = n.map { "You've reached your \($0)-device limit. Free a device at nohandsapp.com." }
                ?? "You've reached your device limit. Free a device at nohandsapp.com."
        default:
            // Unknown server error — don't lock a working cached entitlement.
            lastError = "Couldn't refresh your account right now."
        }
    }

    private func fetchSession(bearer: String) async {
        let req = request("api/app/session", method: "GET", bearer: bearer)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let email = p["email"] as? String
        else { return }
        saveInfo(AccountInfo(
            email: email,
            plan: p["plan"] as? String ?? info?.plan ?? "—",
            isSubUser: p["isSubUser"] as? Bool ?? info?.isSubUser ?? false,
            parentEmail: p["parentEmail"] as? String))
    }

    /// Pulls the account's shared keys and hands them to the coordinator, which
    /// persists them to the Keychain (so they're available offline next launch).
    /// Only mutates on a clean 200 — a failed fetch must never wipe cached keys.
    private func fetchKeys(bearer: String) async {
        let req = request("api/app/keys", method: "GET", bearer: bearer)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        guard let coordinator else { return }
        let anthropic = (p["anthropic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let eleven = (p["elevenlabs"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let anthropic, !anthropic.isEmpty { coordinator.setAPIKey(anthropic) }
        else { coordinator.clearAPIKey() }

        if let eleven, !eleven.isEmpty { coordinator.setElevenLabsKey(eleven) }
        else { coordinator.clearElevenLabsKey() }
    }

    // MARK: - Sign out

    func signOut() {
        if let bearer = KeychainStore.load(account: appTokenAccount) {
            // Best-effort server-side revoke; local sign-out proceeds regardless.
            let req = request("api/app/logout", method: "POST", bearer: bearer)
            Task { _ = try? await URLSession.shared.data(for: req) }
        }
        clearSession()
        // The keys belonged to the account, not this Mac — don't leave them behind.
        coordinator?.clearAPIKey()
        coordinator?.clearElevenLabsKey()
        status = .signedOut
        lastError = nil
    }

    private func clearSession() {
        KeychainStore.delete(account: appTokenAccount)
        KeychainStore.delete(account: entTokenAccount)
        UserDefaults.standard.removeObject(forKey: infoDefaultsKey)
        info = nil
    }

    // MARK: - Helpers

    private func request(_ path: String, method: String, bearer: String) -> URLRequest {
        var req = URLRequest(url: Self.host.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func saveInfo(_ new: AccountInfo) {
        info = new
        if let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: infoDefaultsKey)
        }
    }

    private func loadInfo() -> AccountInfo? {
        guard let data = UserDefaults.standard.data(forKey: infoDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(AccountInfo.self, from: data)
    }
}
