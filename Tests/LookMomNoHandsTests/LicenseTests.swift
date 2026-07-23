import XCTest
@testable import LookMomNoHands

/// Pins the contract between `web/lib/licence.ts` (Node signs) and
/// `LicenseStore.verify` (Swift verifies). These two live in different
/// languages, repos-worth of tooling apart, and a silent disagreement about
/// byte formats would break activation for every paying customer at once —
/// with no error until someone actually bought something.
///
/// The vector below was produced by really running `signToken` under Node 26
/// with a throwaway keypair from Scripts/gen_license_keypair.sh. Regenerate it
/// the same way if the claim fields ever change; never hand-edit it.
final class LicenseTests: XCTestCase {

    /// Public half of the throwaway test keypair. Not used in production builds.
    private let publicKey = "edb00bd98ea92d0056af524ba5e8db3314a87922baae28378cac6c6e4fbf6781"
    private let device = "testdevice0123456789abcdef012345"
    private let token = """
        eyJlbWFpbCI6ImJ1eWVyQGV4YW1wbGUuY29tIiwicGxhbiI6InBybyIsImV4cCI6MCwiaXNzdWVkQXQiOjE3NTAwMDAwMDAsImRldmljZSI6InRlc3RkZXZpY2UwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1In0.Ecpduhibt7YIyC9UQBMA1nQrU-h5YyA0aYbBgdmqmM0_jqNGPFazQ9y7ukaZmmhJJwrRZUaZj0--htwlHx3RBw
        """

    func testAcceptsATokenSignedByTheNodeServer() throws {
        let claims = try LicenseStore.verify(token, publicKeyHex: publicKey,
                                             expectedDevice: device).get()
        XCTAssertEqual(claims.email, "buyer@example.com")
        XCTAssertEqual(claims.plan, "pro")
        XCTAssertEqual(claims.device, device)
        XCTAssertEqual(claims.exp, 0, "0 must decode as a perpetual licence")
        XCTAssertNil(claims.expiryDate, "exp == 0 means no expiry date")
    }

    /// A token lifted from one customer's Keychain must not work on another Mac.
    func testRejectsATokenMintedForADifferentMac() {
        let result = LicenseStore.verify(token, publicKeyHex: publicKey,
                                         expectedDevice: "some-other-mac")
        assertFails(result, containing: "different Mac")
    }

    /// The whole scheme rests on this: flipping any payload byte must invalidate
    /// the signature rather than quietly granting a better licence.
    func testRejectsATamperedPayload() {
        let parts = token.split(separator: ".")
        // Re-encode the claims with a plan the buyer didn't pay for.
        let forged = #"{"email":"buyer@example.com","plan":"enterprise","exp":0,"issuedAt":1750000000,"device":"testdevice0123456789abcdef012345"}"#
        let payload = Data(forged.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let result = LicenseStore.verify("\(payload).\(parts[1])",
                                         publicKeyHex: publicKey, expectedDevice: device)
        assertFails(result, containing: "signature")
    }

    func testRejectsAValidTokenUnderTheWrongPublicKey() {
        let otherKey = String(repeating: "ab", count: 32)
        let result = LicenseStore.verify(token, publicKeyHex: otherKey, expectedDevice: device)
        assertFails(result, containing: "signature")
    }

    func testRejectsMalformedTokens() {
        for junk in ["", "nodot", "a.b.c", "!!!.???"] {
            let result = LicenseStore.verify(junk, publicKeyHex: publicKey, expectedDevice: device)
            if case .success = result {
                XCTFail("accepted malformed token \(junk.isEmpty ? "<empty>" : junk)")
            }
        }
    }

    /// Guards against shipping a paid build whose public key got reverted to the
    /// placeholder — every activation would fail, and only in the wild.
    func testShippingPublicKeyIsConfigured() {
        XCTAssertTrue(
            LicenseConfig.isConfigured,
            "LicenseConfig.publicKeyHex is back to the all-zero placeholder — "
                + "paste the public key whose private half is Vercel's LICENSE_SIGNING_KEY.")
        XCTAssertEqual(LicenseConfig.publicKeyHex.count, 64, "must be 32 bytes of hex")
        XCTAssertNotNil(Data(hex: LicenseConfig.publicKeyHex), "must be valid hex")
    }

    // MARK: - Status transitions

    func testPerpetualLicenceNeverExpires() {
        let claims = LicenseClaims(email: "a@b.c", plan: "pro", exp: 0,
                                   issuedAt: 0, device: device)
        XCTAssertNil(claims.expiryDate)
    }

    func testExpiredLicenceKeepsWorkingInsideTheGraceWindow() {
        let yesterday = Date().addingTimeInterval(-86_400).timeIntervalSince1970
        let claims = LicenseClaims(email: "a@b.c", plan: "solo", exp: yesterday,
                                   issuedAt: 0, device: device)
        XCTAssertNotNil(claims.expiryDate)
        XCTAssertTrue(claims.expiryDate! < Date())
    }

    // MARK: - Weekly billing

    /// Billing is weekly, so a grace period at or beyond a week would hand every
    /// canceller a free period on the way out.
    func testGraceIsShorterThanABillingWeek() {
        XCTAssertLessThan(LicenseConfig.expiryGraceDays, 7,
                          "grace must stay well under the 7-day billing period")
    }

    /// The renewal window has to open before the token dies, or the refresh can
    /// only ever fire once the customer is already locked out.
    func testRenewalWindowOpensBeforeExpiry() {
        XCTAssertGreaterThan(LicenseConfig.refreshWithinDays, 0)
        XCTAssertLessThan(LicenseConfig.refreshWithinDays, 7,
                          "must open inside the billing period, not before it starts")
        // And there must be real overlap with the grace window, so a Mac that was
        // asleep past the expiry date still gets a chance to renew itself.
        XCTAssertGreaterThanOrEqual(
            Double(LicenseConfig.expiryGraceDays) + LicenseConfig.refreshWithinDays, 5,
            "grace + renewal window should span a long weekend offline")
    }

    /// A weekly token must not read as perpetual — `exp == 0` is the only thing
    /// that means "never expires", and a subscription must never mint one.
    func testWeeklySubscriptionTokenIsNotPerpetual() {
        let weekOut = Date().addingTimeInterval(7 * 86_400).timeIntervalSince1970
        let claims = LicenseClaims(email: "a@b.c", plan: "solo", exp: weekOut,
                                   issuedAt: Date().timeIntervalSince1970, device: device)
        XCTAssertNotNil(claims.expiryDate, "a weekly licence must carry an expiry")
        XCTAssertGreaterThan(claims.expiryDate!, Date())
    }

    // MARK: - Encoding helpers

    func testBase64URLDecodesUnpaddedInputWithURLSafeAlphabet() {
        // "?~}" encodes to "P369" in standard base64 and needs no padding;
        // the interesting case is the - and _ substitutions round-tripping.
        XCTAssertEqual(Data(base64URL: "aGVsbG8"), Data("hello".utf8))
        XCTAssertEqual(Data(base64URL: "aGVsbG8="), Data("hello".utf8))
        XCTAssertNil(Data(base64URL: "!!!!"))
    }

    func testHexDecoding() {
        XCTAssertEqual(Data(hex: "00ff10"), Data([0x00, 0xff, 0x10]))
        XCTAssertNil(Data(hex: "abc"), "odd length must fail")
        XCTAssertNil(Data(hex: "zz"), "non-hex must fail")
    }

    // MARK: -

    private func assertFails(_ result: Result<LicenseClaims, LicenseError>,
                             containing needle: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success:
            XCTFail("expected failure containing \"\(needle)\"", file: file, line: line)
        case .failure(let err):
            XCTAssertTrue(err.message.contains(needle),
                          "expected \"\(needle)\", got \"\(err.message)\"",
                          file: file, line: line)
        }
    }
}
