import Foundation
import CryptoKit
import IOKit

/// Licensing for paid distribution.
///
/// Two-step by design. The customer receives a short, typo-tolerant key by email
/// after checkout (`NOHANDS-XXXX-XXXX-XXXX`); the app trades that key once, over
/// the network, for an **Ed25519-signed entitlement token** bound to this Mac.
/// From then on validation is a local signature check against the public key
/// compiled in below — no phone-home on launch, works on a plane, and the server
/// being down never locks a paying customer out of their own machine.
///
/// The private half of the keypair lives only in the Vercel project's env
/// (`LICENSE_SIGNING_KEY`). Nothing secret ships in the app: a public key is
/// useless for minting tokens, so extracting it from the binary buys an attacker
/// nothing. Cracking this still just means patching the binary — that is true of
/// every client-side license check, and the goal here is an honest speed bump for
/// honest customers, not DRM.
enum LicenseConfig {
    /// Ed25519 public key, raw 32 bytes, hex. Public by nature — it can verify
    /// tokens but never mint them, so shipping it in the binary is safe and
    /// committing it is fine. Its private half lives only in the Vercel
    /// project's `LICENSE_SIGNING_KEY`.
    ///
    /// Rotating this invalidates every token already issued, so if you ever
    /// must, re-issue tokens for existing orders before shipping the new key.
    static let publicKeyHex = "6329a6338a49b8487c4875537d07e21709332e5b842e315b3813444e3ee2f4a0"

    static let activationURL = URL(string: "https://nohandsapp.com/api/activate")!
    static let purchaseURL = URL(string: "https://nohandsapp.com/#pricing")!

    /// How long a fresh install runs unlicensed.
    static let trialDays = 7
    /// A token whose `exp` has passed still works this long, so an expiring card
    /// or a lapsed subscription degrades into a warning rather than a hard stop.
    static let expiryGraceDays = 14

    static var isConfigured: Bool { publicKeyHex.contains(where: { $0 != "0" }) }
}

/// What the signed token asserts. Mirrors the payload the Vercel `/api/activate`
/// route signs — keep the two in step.
struct LicenseClaims: Codable, Sendable {
    let email: String
    let plan: String
    /// Seconds since epoch. `0` means perpetual (a one-time purchase).
    let exp: TimeInterval
    let issuedAt: TimeInterval
    /// The machine this token was minted for; a copied token fails here.
    let device: String

    var expiryDate: Date? { exp == 0 ? nil : Date(timeIntervalSince1970: exp) }
}

/// Why a token was rejected. Carries a message fit to show the customer — every
/// failure here is something they may need to act on.
struct LicenseError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

enum LicenseStatus: Equatable, Sendable {
    case licensed(LicenseClaims)
    /// Past `exp` but inside the grace window — still usable, worth nagging about.
    case expiringSoon(LicenseClaims, daysLeft: Int)
    case trial(daysLeft: Int)
    case trialExpired
    case expired
    case invalid(String)

    /// The single gate the rest of the app asks about. Kept as one property so
    /// changing the business rule never means hunting call sites.
    var allowsUse: Bool {
        switch self {
        case .licensed, .expiringSoon, .trial: return true
        case .trialExpired, .expired, .invalid: return false
        }
    }

    var isPaid: Bool {
        switch self {
        case .licensed, .expiringSoon: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .licensed: return "Licensed"
        case .expiringSoon(_, let d): return "Renewal needed — \(d)d left"
        case .trial(let d): return "Trial — \(d) day\(d == 1 ? "" : "s") left"
        case .trialExpired: return "Trial ended"
        case .expired: return "License expired"
        case .invalid: return "License problem"
        }
    }

    static func == (a: LicenseStatus, b: LicenseStatus) -> Bool { a.label == b.label }
}

@MainActor
final class LicenseStore: ObservableObject {
    @Published private(set) var status: LicenseStatus = .trialExpired
    @Published private(set) var isActivating = false
    @Published private(set) var lastError: String?

    private let tokenAccount = "license-token"
    private let trialAccount = "trial-started"

    init() { refresh() }

    // MARK: - State

    /// Recomputes status from what's on disk. Cheap and pure enough to call on
    /// every panel open — it's a signature check, not a network call.
    func refresh() {
        if let token = KeychainStore.load(account: tokenAccount) {
            switch Self.verify(token) {
            case .success(let claims):
                status = Self.status(for: claims)
                return
            case .failure(let err):
                // A bad token shouldn't strand someone mid-trial.
                status = trialStatus() ?? .invalid(err.message)
                return
            }
        }
        status = trialStatus() ?? .trialExpired
    }

    nonisolated private static func status(for claims: LicenseClaims) -> LicenseStatus {
        guard let expiry = claims.expiryDate else { return .licensed(claims) }
        let now = Date()
        if now < expiry { return .licensed(claims) }
        let graceEnds = expiry.addingTimeInterval(Double(LicenseConfig.expiryGraceDays) * 86_400)
        guard now < graceEnds else { return .expired }
        let left = Int(ceil(graceEnds.timeIntervalSince(now) / 86_400))
        return .expiringSoon(claims, daysLeft: max(1, left))
    }

    /// Trial clock, stamped in the Keychain on first run. The Keychain outlives a
    /// drag-to-trash reinstall, so the obvious "delete and redownload" reset
    /// doesn't work. Anyone determined can still clear it — that's fine.
    private func trialStatus() -> LicenseStatus? {
        let started: Date
        if let raw = KeychainStore.load(account: trialAccount), let t = TimeInterval(raw) {
            started = Date(timeIntervalSince1970: t)
        } else {
            started = Date()
            KeychainStore.save(String(started.timeIntervalSince1970), account: trialAccount)
        }
        let ends = started.addingTimeInterval(Double(LicenseConfig.trialDays) * 86_400)
        guard Date() < ends else { return nil }
        let left = Int(ceil(ends.timeIntervalSince(Date()) / 86_400))
        return .trial(daysLeft: max(1, left))
    }

    // MARK: - Activation

    /// Trades a purchase key for a signed token. Errors surface on `lastError`
    /// rather than throwing — the caller is a SwiftUI button.
    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        guard LicenseConfig.isConfigured else {
            lastError = "This build has no license public key compiled in."
            return
        }

        isActivating = true
        lastError = nil
        defer { isActivating = false }

        var req = URLRequest(url: LicenseConfig.activationURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let body = ["key": key, "device": Self.deviceID, "version": Self.appVersion]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard code == 200, let token = payload?["token"] as? String else {
                lastError = (payload?["error"] as? String)
                    ?? "Activation failed (HTTP \(code)). Check the key and try again."
                return
            }
            // Never trust the server blindly — the token has to verify against the
            // compiled-in public key before it's worth storing.
            switch Self.verify(token) {
            case .success:
                KeychainStore.save(token, account: tokenAccount)
                refresh()
            case .failure(let err):
                lastError = "Server returned a token this build can't verify: \(err.message)"
            }
        } catch {
            lastError = "Couldn't reach nohandsapp.com: \(error.localizedDescription)"
        }
    }

    func deactivate() {
        KeychainStore.delete(account: tokenAccount)
        refresh()
    }

    // MARK: - Verification

    /// `base64url(claimsJSON).base64url(signature)` — a compact JWS-style token
    /// without the header, since there's exactly one algorithm in play.
    ///
    /// The key and device are parameters purely so the test suite can pin the
    /// Node-signing / Swift-verifying interop against a fixed vector; production
    /// callers take the defaults.
    nonisolated static func verify(_ token: String,
                       publicKeyHex: String = LicenseConfig.publicKeyHex,
                       expectedDevice: String = deviceID) -> Result<LicenseClaims, LicenseError> {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = Data(base64URL: String(parts[0])),
              let signature = Data(base64URL: String(parts[1]))
        else { return .failure(LicenseError("malformed token")) }

        guard let keyData = Data(hex: publicKeyHex),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return .failure(LicenseError("bad public key in build")) }

        guard publicKey.isValidSignature(signature, for: payload) else {
            return .failure(LicenseError("signature does not verify"))
        }
        guard let claims = try? JSONDecoder().decode(LicenseClaims.self, from: payload) else {
            return .failure(LicenseError("unreadable claims"))
        }
        guard claims.device == expectedDevice else {
            return .failure(LicenseError("this license is registered to a different Mac"))
        }
        return .success(claims)
    }

    // MARK: - Machine identity

    /// Hashed IOPlatformUUID. Hashing keeps a raw hardware serial off the wire
    /// while still being stable across reinstalls and OS upgrades.
    nonisolated static let deviceID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        guard service != 0,
              let cf = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
                                                       kCFAllocatorDefault, 0),
              let uuid = cf.takeRetainedValue() as? String
        else { return "unknown-device" }

        let digest = SHA256.hash(data: Data(uuid.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }()

    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

// MARK: - Encoding helpers

extension Data {
    /// base64url (RFC 4648 §5): `-`/`_` for `+`/`/`, padding optional.
    init?(base64URL s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        if t.count % 4 != 0 { t += String(repeating: "=", count: 4 - t.count % 4) }
        guard let d = Data(base64Encoded: t) else { return nil }
        self = d
    }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
