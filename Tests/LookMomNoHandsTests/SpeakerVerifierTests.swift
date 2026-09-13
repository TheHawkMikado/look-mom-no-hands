import XCTest
@testable import LookMomNoHands

// Pure-logic tests for speaker verification (PLAN-SPEAKER-VERIFICATION.md,
// Phase 6). Nothing here touches the mic; the one Core ML test skips itself
// when the model isn't bundled.

final class SpeakerVerifierMathTests: XCTestCase {

    func testCosineOfIdenticalVectorsIsOne() {
        let v: [Float] = [0.3, -0.2, 0.9, 0.1]
        XCTAssertEqual(SpeakerVerifier.cosine(v, v), 1, accuracy: 1e-6)
        XCTAssertEqual(SpeakerVerifier.cosine(v, v.map { $0 * 7 }), 1, accuracy: 1e-6)   // scale-invariant
    }

    func testCosineOrthogonalAndOpposite() {
        XCTAssertEqual(SpeakerVerifier.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(SpeakerVerifier.cosine([1, 0], [-1, 0]), -1, accuracy: 1e-6)
    }

    func testCosineDegenerateInputsAreZeroNotNaN() {
        XCTAssertEqual(SpeakerVerifier.cosine([], []), 0)
        XCTAssertEqual(SpeakerVerifier.cosine([1, 2], [1, 2, 3]), 0)       // length mismatch
        XCTAssertEqual(SpeakerVerifier.cosine([0, 0], [1, 1]), 0)          // zero vector
    }

    func testNormalizedHasUnitLength() {
        let n = SpeakerVerifier.normalized([3, 4])
        XCTAssertEqual(n[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(n[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(SpeakerVerifier.normalized([0, 0]), [0, 0])         // no divide-by-zero
    }

    // MARK: trimToSpeech

    private func tone(seconds: Double, amplitude: Float, rate: Double = 16000) -> [Float] {
        (0..<Int(seconds * rate)).map { i in amplitude * sin(2 * .pi * 220 * Float(i) / Float(rate)) }
    }

    func testTrimKeepsTheSpeechAndDropsSilence() {
        let silence = [Float](repeating: 0, count: 16000)          // 1 s
        let speech = tone(seconds: 1.5, amplitude: 0.2)
        let trimmed = SpeakerVerifier.trimToSpeech(silence + speech + silence, rate: 16000)
        // 1.5 s of speech + up to 100 ms padding each side.
        XCTAssertGreaterThanOrEqual(trimmed.count, speech.count)
        XCTAssertLessThanOrEqual(trimmed.count, speech.count + 2 * 1600 + 320)
    }

    func testTrimIgnoresRoomHissBelowTheGate() {
        // Hiss at 0.002 around 0.2 speech: the 15 %-of-peak gate rejects it.
        var hiss = [Float](repeating: 0, count: 32000)
        for i in 0..<hiss.count { hiss[i] = (i % 2 == 0) ? 0.002 : -0.002 }
        let speech = tone(seconds: 1.0, amplitude: 0.2)
        let trimmed = SpeakerVerifier.trimToSpeech(hiss + speech + hiss, rate: 16000)
        XCTAssertLessThanOrEqual(trimmed.count, speech.count + 2 * 1600 + 320)
        XCTAssertGreaterThanOrEqual(trimmed.count, speech.count)
    }

    func testTrimOfSilenceIsEmpty() {
        XCTAssertTrue(SpeakerVerifier.trimToSpeech([Float](repeating: 0, count: 16000)).isEmpty)
        XCTAssertTrue(SpeakerVerifier.trimToSpeech([]).isEmpty)
        // Hiss-only input never clears the absolute floor either.
        let hiss = (0..<16000).map { _ in Float.random(in: -0.001...0.001) }
        XCTAssertTrue(SpeakerVerifier.trimToSpeech(hiss).isEmpty)
    }
}

final class SpeakerDecisionTests: XCTestCase {

    private func unit(_ angle: Float) -> [Float] { [cos(angle), sin(angle)] }

    func testScoreIsMaxOverEnrolledSamples() {
        // Owner enrolled at 0° and 90°; an utterance at 80° is far from the
        // first sample but close to the second — max keeps it.
        let profile = VoiceProfile(embeddings: [unit(0), unit(.pi / 2)])
        let score = SpeakerVerifier.score(unit(80 * .pi / 180), against: profile)
        XCTAssertEqual(score, cos(10 * .pi / 180), accuracy: 1e-5)
        XCTAssertGreaterThan(score, SpeakerVerifier.cosine(unit(80 * .pi / 180), unit(0)))
    }

    func testThresholdTable() {
        XCTAssertEqual(SpeakerVerifier.Strictness.lenient.threshold, 0.22)
        XCTAssertEqual(SpeakerVerifier.Strictness.normal.threshold, 0.30)
        XCTAssertEqual(SpeakerVerifier.Strictness.strict.threshold, 0.40)
        XCTAssertTrue(SpeakerVerifier.accepts(score: 0.25, strictness: .lenient))
        XCTAssertFalse(SpeakerVerifier.accepts(score: 0.25, strictness: .normal))
        XCTAssertTrue(SpeakerVerifier.accepts(score: 0.35, strictness: .normal))
        XCTAssertFalse(SpeakerVerifier.accepts(score: 0.35, strictness: .strict))
        XCTAssertTrue(SpeakerVerifier.accepts(score: 0.40, strictness: .strict))   // inclusive
    }

    func testEnrollmentConsistencyWarning() {
        let previous = [unit(0), unit(0.1)]
        XCTAssertTrue(SpeakerVerifier.isConsistent(unit(0.2), withPrevious: previous))   // cos 0.995
        XCTAssertFalse(SpeakerVerifier.isConsistent(unit(.pi / 2), withPrevious: previous)) // cos ≈ 0 < 0.45
        XCTAssertTrue(SpeakerVerifier.isConsistent(unit(.pi / 2), withPrevious: []))     // first sample
    }

    func testIdentifyPicksBestProfileAboveThreshold() {
        let profiles = ["Hawk": VoiceProfile(embeddings: [unit(0)]),
                        "Sam": VoiceProfile(embeddings: [unit(.pi / 2)])]
        let hit = SpeakerVerifier.identify(unit(0.2), among: profiles, threshold: 0.3)
        XCTAssertEqual(hit?.name, "Hawk")
        XCTAssertEqual(hit?.score ?? 0, cos(0.2), accuracy: 1e-5)
        // Nobody close enough → nil.
        XCTAssertNil(SpeakerVerifier.identify(unit(.pi / 4 + 0.3), among: profiles, threshold: 0.9))
        // Stale profiles (other model) are never matched.
        let stale = ["Old": VoiceProfile(embeddings: [unit(0)], modelVersion: "something-else")]
        XCTAssertNil(SpeakerVerifier.identify(unit(0), among: stale, threshold: 0.3))
    }

    // MARK: shouldAccept fail-open behaviour (no model needed)

    private func makeVerifier() -> (SpeakerVerifier, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-speaker-tests-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "lmnh-speaker-tests-\(UUID().uuidString)")!
        return (SpeakerVerifier(profileURL: dir.appendingPathComponent("voiceprint.json"), defaults: defaults), dir)
    }

    func testDefaultsAreOffAndNormal() {
        let (v, _) = makeVerifier()
        XCTAssertFalse(v.onlyRespondToMyVoice)
        XCTAssertFalse(v.verifyEveryCommand)
        XCTAssertEqual(v.strictness, .normal)
        XCTAssertNil(v.profile)
        XCTAssertFalse(v.hasProfile)
    }

    func testAcceptsWhenFeatureOffOrNoProfile() {
        let (v, _) = makeVerifier()
        let loud = (0..<48000).map { i in 0.3 * sin(Float(i) * 0.1) }
        XCTAssertTrue(v.shouldAccept(recentAudio: loud))             // off
        v.onlyRespondToMyVoice = true
        XCTAssertTrue(v.shouldAccept(recentAudio: loud))             // on, but no profile
        XCTAssertNil(v.verifyCurrentSpeaker())                       // can't judge
    }

    func testAcceptsTooShortAudioEvenWithProfile() throws {
        let (v, dir) = makeVerifier()
        defer { try? FileManager.default.removeItem(at: dir) }
        try v.saveProfile(embeddings: [[Float](repeating: 1, count: SpeakerVerifier.embeddingSize)])
        v.onlyRespondToMyVoice = true
        XCTAssertTrue(v.hasProfile)
        // 0.3 s of tone in 3 s of silence: under the 0.8 s speech minimum → nil → accept.
        var audio = [Float](repeating: 0, count: 48000)
        for i in 20000..<24800 { audio[i] = 0.3 * sin(Float(i) * 0.1) }
        XCTAssertNil(v.verdict(for: audio))
        XCTAssertTrue(v.shouldAccept(recentAudio: audio))
    }

    func testDeleteProfileTurnsTheGateOff() throws {
        let (v, dir) = makeVerifier()
        defer { try? FileManager.default.removeItem(at: dir) }
        try v.saveProfile(embeddings: [[1, 0, 0]])
        v.onlyRespondToMyVoice = true
        v.deleteProfile()
        XCTAssertNil(v.profile)
        XCTAssertFalse(v.onlyRespondToMyVoice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.profileURL.path))
    }
}

final class VoiceProfilePersistenceTests: XCTestCase {

    func testProfileJSONRoundTrip() throws {
        let profile = VoiceProfile(embeddings: [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]],
                                   createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try SpeakerVerifier.encode(profile)
        let back = try SpeakerVerifier.decode(data)
        XCTAssertEqual(back, profile)
        XCTAssertEqual(back.modelVersion, SpeakerVerifier.modelVersion)
        XCTAssertTrue(back.isCompatible)
        // Plain JSON with the expected keys — inspectable, no binary blobs.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["embeddings"])
        XCTAssertNotNil(json["createdAt"])
        XCTAssertEqual(json["modelVersion"] as? String, SpeakerVerifier.modelVersion)
    }

    func testModelVersionMismatchInvalidatesProfile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-speaker-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("voiceprint.json")
        let stale = VoiceProfile(embeddings: [[1, 0]], modelVersion: "ecapa-voxceleb-v0")
        try SpeakerVerifier.encode(stale).write(to: url)

        let defaults = UserDefaults(suiteName: "lmnh-speaker-tests-\(UUID().uuidString)")!
        defaults.set(true, forKey: "onlyRespondToMyVoice")
        let v = SpeakerVerifier(profileURL: url, defaults: defaults)
        XCTAssertNotNil(v.profile)                 // still on disk, shown as "re-enroll"
        XCTAssertFalse(v.hasProfile)               // but never used for scoring
        XCTAssertTrue(v.profileNeedsReenrollment)
        XCTAssertFalse(v.isGating)
        XCTAssertTrue(v.shouldAccept(recentAudio: (0..<48000).map { i in 0.3 * sin(Float(i) * 0.1) }))
    }

    func testSaveThenReloadFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-speaker-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voiceprint.json")
        let defaults = UserDefaults(suiteName: "lmnh-speaker-tests-\(UUID().uuidString)")!
        let v = SpeakerVerifier(profileURL: url, defaults: defaults)
        try v.saveProfile(embeddings: [[3, 4]])
        let reloaded = try XCTUnwrap(SpeakerVerifier.loadProfile(from: url))
        XCTAssertEqual(reloaded.embeddings.count, 1)
        XCTAssertEqual(reloaded.embeddings[0][0], 0.6, accuracy: 1e-6)   // stored unit-normalised
        XCTAssertEqual(reloaded.embeddings[0][1], 0.8, accuracy: 1e-6)
    }

    func testSettingsPersistToDefaults() {
        let suite = "lmnh-speaker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        let v = SpeakerVerifier(profileURL: url, defaults: defaults)
        v.strictness = .strict
        v.verifyEveryCommand = true
        XCTAssertEqual(defaults.string(forKey: "speakerStrictness"), "strict")
        XCTAssertTrue(defaults.bool(forKey: "verifyEveryCommand"))
        let again = SpeakerVerifier(profileURL: url, defaults: defaults)
        XCTAssertEqual(again.strictness, .strict)
        XCTAssertTrue(again.verifyEveryCommand)
    }
}

final class SpeakerClustererTests: XCTestCase {

    private func unit(_ angle: Float) -> [Float] { [cos(angle), sin(angle)] }

    func testOpensNewSpeakersAndReusesNearOnes() {
        var c = SpeakerClusterer(threshold: 0.8)
        XCTAssertEqual(c.assign(unit(0)), "Speaker 1")
        XCTAssertEqual(c.assign(unit(0.1)), "Speaker 1")          // cos 0.995 ≥ 0.8
        XCTAssertEqual(c.assign(unit(.pi / 2)), "Speaker 2")      // orthogonal → new
        XCTAssertEqual(c.assign(unit(.pi / 2 + 0.05)), "Speaker 2")
        XCTAssertEqual(c.clusters.count, 2)
        XCTAssertEqual(c.clusters[0].count, 2)
        XCTAssertEqual(c.clusters[1].count, 2)
    }

    func testCentroidIsRunningMeanAndUnitLength() {
        var c = SpeakerClusterer(threshold: 0.5)
        _ = c.assign(unit(0))
        _ = c.assign(unit(0.2))
        let centroid = c.clusters[0].centroid
        let expected = SpeakerVerifier.normalized([(1 + cos(0.2)) / 2, sin(0.2) / 2])
        XCTAssertEqual(centroid[0], expected[0], accuracy: 1e-5)
        XCTAssertEqual(centroid[1], expected[1], accuracy: 1e-5)
        XCTAssertEqual(centroid[0] * centroid[0] + centroid[1] * centroid[1], 1, accuracy: 1e-5)
    }

    func testKnownProfilesSeedNamedClusters() {
        let known = ["Hawk": VoiceProfile(embeddings: [unit(0), unit(0.1)]),
                     "Sam": VoiceProfile(embeddings: [unit(.pi / 2)])]
        var c = SpeakerClusterer(threshold: 0.5, known: known)
        XCTAssertEqual(c.clusters.map(\.name), ["Hawk", "Sam"])     // sorted, deterministic
        XCTAssertEqual(c.assign(unit(0.05)), "Hawk")
        XCTAssertEqual(c.assign(unit(.pi / 2 - 0.1)), "Sam")
        XCTAssertEqual(c.assign(unit(.pi)), "Speaker 1")             // stranger
    }

    func testSpeakerNumberingSkipsNoNames() {
        var c = SpeakerClusterer(threshold: 0.99)
        XCTAssertEqual(c.assign(unit(0)), "Speaker 1")
        XCTAssertEqual(c.assign(unit(1)), "Speaker 2")
        XCTAssertEqual(c.assign(unit(2)), "Speaker 3")
    }
}

final class SpeakerModelSmokeTests: XCTestCase {

    /// Loads the bundled Core ML model (if SwiftPM compiled it into the resource
    /// bundle), embeds synthetic audio, and checks the output shape and that the
    /// embedding is deterministic and length-robust. Skips when no model is
    /// bundled so the suite stays green on a checkout without it.
    func testBundledModelEmbedsAudio() throws {
        guard SpeakerVerifier.locateModel() != nil else {
            throw XCTSkip("SpeakerEmbedder model not bundled in this build")
        }
        let suite = "lmnh-speaker-smoke-\(UUID().uuidString)"
        let v = SpeakerVerifier(profileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json"),
                                defaults: UserDefaults(suiteName: suite)!)
        // 1.5 s of a harmonic-rich "voice": a 140 Hz pulse train with vibrato.
        let rate = Float(SpeakerVerifier.sampleRate)
        let a = (0..<24000).map { i -> Float in
            let t = Float(i) / rate
            let f0: Float = 140 + 6 * sin(2 * .pi * 5 * t)
            var s: Float = 0
            for h in 1...12 { s += sin(2 * .pi * f0 * Float(h) * t) / Float(h) }
            return 0.2 * s
        }
        let e1 = try v.embedding(for: a)
        XCTAssertEqual(e1.count, SpeakerVerifier.embeddingSize)
        XCTAssertEqual(e1.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-3)   // unit length
        let e2 = try v.embedding(for: a)
        XCTAssertEqual(SpeakerVerifier.cosine(e1, e2), 1, accuracy: 1e-3)  // deterministic
        // Same sound, longer take → still the same voice (flexible input shape works).
        let e3 = try v.embedding(for: a + a)
        XCTAssertGreaterThan(SpeakerVerifier.cosine(e1, e3), 0.8)
        XCTAssertTrue(v.modelStatus.isReady)
    }
}
