import XCTest
import CryptoKit
@testable import LookMomNoHands

final class FleetTests: XCTestCase {

    // MARK: envelope signing

    func testSignedEnvelopeVerifies() {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = FleetEnvelope.make(type: "goal", payload: "{\"goal\":\"x\"}", key: key, name: "Studio")
        XCTAssertNotNil(envelope)
        XCTAssertTrue(envelope!.verified())
    }

    func testTamperedPayloadFails() {
        let key = Curve25519.Signing.PrivateKey()
        let signed = FleetEnvelope.make(type: "goal", payload: "{\"goal\":\"safe\"}", key: key, name: "Studio")!
        let tampered = FleetEnvelope(type: signed.type, from: signed.from, name: signed.name,
                                     ts: signed.ts, payload: "{\"goal\":\"rm -rf /\"}", sig: signed.sig)
        XCTAssertFalse(tampered.verified())
    }

    func testTypeCannotBeSwappedUnderTheSameSignature() {
        // A signed "ping" replayed as a "goal" must die: the type is inside the
        // signed material.
        let key = Curve25519.Signing.PrivateKey()
        let ping = FleetEnvelope.make(type: "ping", payload: "", key: key, name: "Studio")!
        let asGoal = FleetEnvelope(type: "goal", from: ping.from, name: ping.name,
                                   ts: ping.ts, payload: ping.payload, sig: ping.sig)
        XCTAssertFalse(asGoal.verified())
    }

    func testStaleEnvelopeIsRejected() {
        // A captured goal replayed later must die at verification, not at the shell.
        let key = Curve25519.Signing.PrivateKey()
        let old = FleetEnvelope.make(type: "goal", payload: "{}", key: key, name: "Studio",
                                     ts: Date().timeIntervalSince1970 - 600)!
        XCTAssertFalse(old.verified())
        XCTAssertTrue(old.verified(now: old.ts + 30))
    }

    // MARK: pairing code

    func testPairingCodeIsSymmetricAndStable() {
        let a = "aa11", b = "bb22"
        XCTAssertEqual(FleetEnvelope.pairingCode(a, b), FleetEnvelope.pairingCode(b, a),
                       "both screens must show the same code regardless of who initiated")
        XCTAssertEqual(FleetEnvelope.pairingCode(a, b).count, 6)
        XCTAssertNotEqual(FleetEnvelope.pairingCode(a, b), FleetEnvelope.pairingCode(a, "cc33"))
    }

    // MARK: voice targeting

    func testTargetParsedAndStripped() {
        let parsed = FleetService.parseTarget(command: "on the mac mini, pull the newsletter report",
                                              peerNames: ["Mac mini", "Studio"])
        XCTAssertEqual(parsed?.peer, "Mac mini")
        XCTAssertEqual(parsed?.goal, "pull the newsletter report")
    }

    func testUnpairedNamesNeverMatch() {
        XCTAssertNil(FleetService.parseTarget(command: "on the mac mini, do a thing", peerNames: []))
    }

    func testOrdinarySentencesStartingWithOnPassThrough() {
        XCTAssertNil(FleetService.parseTarget(command: "on youtube search for cats", peerNames: ["Mac mini"]))
    }

    func testBareTargetWithNoGoalIsNotADispatch() {
        XCTAssertNil(FleetService.parseTarget(command: "on the mac mini", peerNames: ["Mac mini"]))
    }

    // MARK: store merge

    @MainActor
    func testProcedureMergeKeepsLocalScheduleAndDropsRemote() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProcedureStore(directory: dir)
        var local = Procedure(id: "p1", name: "report", steps: "old steps",
                              createdAt: Date(timeIntervalSince1970: 100))
        local.schedule = ProcedureSchedule(hour: 9, minute: 0, weekdays: [2])
        store.upsert(local)

        var remote = Procedure(id: "p1", name: "report", steps: "new steps",
                               createdAt: Date(timeIntervalSince1970: 200))
        remote.schedule = ProcedureSchedule(hour: 6, minute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7])
        store.mergeSnapshot([remote])

        let merged = store.procedures.first { $0.id == "p1" }
        XCTAssertEqual(merged?.steps, "new steps", "newer content wins")
        XCTAssertEqual(merged?.schedule?.hour, 9,
                       "schedules never travel — a synced schedule would fire on every machine at once")
    }
}
