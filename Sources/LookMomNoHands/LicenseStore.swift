import Foundation
import CryptoKit
import IOKit

/// Entitlement verification for the account-login model.
///
/// Access is granted by **signing in** (see `AccountStore`), but the thing the
/// app checks minute-to-minute is still an **Ed25519-signed entitlement token**
/// bound to this Mac — minted server-side at `/api/app/device` after sign-in.
/// From then on validation is a local signature check against the public key
/// compiled in below: no phone-home on launch, works on a plane, and the server
/// being down never locks a paying customer out of their own machine.
///
/// This type is now a namespace of pure verification helpers; the session and
/// networking live in `AccountStore`. The private half of the keypair lives only
/// in Vercel (`LICENSE_SIGNING_KEY`) — a public key can verify tokens but never
/// mint them, so shipping it in the binary is safe.
enum LicenseConfig {
    /// Ed25519 public key, raw 32 bytes, hex. Public by nature — it can verify
    /// tokens but never mint them, so shipping it in the binary is safe and
    /// committing it is fine. Its private half lives only in the Vercel
    /// project's `LICENSE_SIGNING_KEY`.
    ///
    /// Rotating this invalidates every token already issued, so if you ever
    /// must, re-issue tokens for existing orders before shipping the new key.
    static let publicKeyHex = "6329a6338a49b8487c4875537d07e21709332e5b842e315b3813444e3ee2f4a0"

    static let purchaseURL = URL(string: "https://nohandsapp.com/#pricing")!

    /// A token whose `exp` has passed still works this long, so a card that
    /// fails on a Friday degrades into a warning rather than a dead app.
    ///
    /// Kept short deliberately: billing is weekly, so a generous grace period is
    /// a large fraction of a paid week given away on every cancellation. Three
    /// days covers a weekend and the first of Stripe's dunning retries.
    static let expiryGraceDays = 3

    /// Refresh the token once it's within this long of expiring. Tokens are
    /// minted for one billing period, so without this every weekly subscriber
    /// would lock themselves out seven days after activating.
    static let refreshWithinDays = 3.0

    static var isConfigured: Bool { publicKeyHex.contains(where: { $0 != "0" }) }
}

/// What the signed token asserts. Mirrors the payload the Vercel `/api/app/device`
/// route signs — keep the two in step.
struct LicenseClaims: Codable, Sendable {
    let email: String
    let plan: String
    /// Seconds since epoch. `0` means perpetual (a one-time purchase).
    let exp: TimeInterval
    let issuedAt: TimeInterval
    /// The machine this token was minted for; a copied token fails here.
    let device: String
    /// Combined device pool for the plan. Optional so older tokens (minted before
    /// this field existed) still decode — must mirror web `Claims`.
    let devices: Int?
    /// Sub-users the account may add. Optional for the same reason.
    let subUsers: Int?

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
    /// Signed in, but no active subscription (lapsed, cancelled, or never bought).
    case expired
    /// Not signed in — the resting state of a fresh install.
    case signedOut
    case invalid(String)

    /// The single gate the rest of the app asks about. Kept as one property so
    /// changing the business rule never means hunting call sites.
    var allowsUse: Bool {
        switch self {
        case .licensed, .expiringSoon: return true
        case .expired, .signedOut, .invalid: return false
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
        case .licensed: return "Active"
        case .expiringSoon(_, let d): return "Renewal needed — \(d)d left"
        case .expired: return "No active subscription"
        case .signedOut: return "Not signed in"
        case .invalid: return "Account problem"
        }
    }

    static func == (a: LicenseStatus, b: LicenseStatus) -> Bool { a.label == b.label }
}

/// Pure verification helpers, shared by `AccountStore`. No instance state — the
/// live session (bearer token, entitlement token, networking) lives there.
enum LicenseStore {

    /// Turns verified claims into a status, applying the grace window.
    static func status(for claims: LicenseClaims) -> LicenseStatus {
        guard let expiry = claims.expiryDate else { return .licensed(claims) }
        let now = Date()
        if now < expiry { return .licensed(claims) }
        let graceEnds = expiry.addingTimeInterval(Double(LicenseConfig.expiryGraceDays) * 86_400)
        guard now < graceEnds else { return .expired }
        let left = Int(ceil(graceEnds.timeIntervalSince(now) / 86_400))
        return .expiringSoon(claims, daysLeft: max(1, left))
    }

    // MARK: - Verification

    /// `base64url(claimsJSON).base64url(signature)` — a compact JWS-style token
    /// without the header, since there's exactly one algorithm in play.
    ///
    /// The key and device are parameters purely so the test suite can pin the
    /// Node-signing / Swift-verifying interop against a fixed vector; production
    /// callers take the defaults.
    static func verify(_ token: String,
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
            return .failure(LicenseError("this account is registered to a different Mac"))
        }
        return .success(claims)
    }

    // MARK: - Machine identity

    /// Hashed IOPlatformUUID. Hashing keeps a raw hardware serial off the wire
    /// while still being stable across reinstalls and OS upgrades.
    static let deviceID: String = {
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

    static var appVersion: String {
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

    /// Lowercase hex, the inverse of `init?(hex:)`. Fleet identity strings must
    /// byte-match across encode sites, so there is exactly one encoder.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
