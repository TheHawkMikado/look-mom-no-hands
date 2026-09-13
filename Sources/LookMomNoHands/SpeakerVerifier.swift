import Foundation
import CoreML
import Combine

// Speaker verification ("only respond to MY voice") — see
// PLAN-SPEAKER-VERIFICATION.md. A bundled Core ML speaker-embedding model
// (WeSpeaker ResNet34-LM, fbank front end traced in) turns 16 kHz mono audio
// into a 256-dim voiceprint; cosine similarity against the enrolled samples
// decides accept/reject. Convenience filtering, not security: it is a
// similarity threshold, not a password. FAIL-OPEN everywhere — a missing model,
// a load error, or too little audio never stops the app from waking.

/// The enrolled owner's voiceprint: one embedding per enrollment sample.
/// `modelVersion` couples the profile to the model that produced it — vectors
/// from different models aren't comparable, so a mismatch invalidates the
/// profile and asks for re-enrollment instead of producing garbage scores.
struct VoiceProfile: Codable, Equatable {
    var embeddings: [[Float]]
    var createdAt: Date
    var modelVersion: String

    init(embeddings: [[Float]], createdAt: Date = Date(),
         modelVersion: String = SpeakerVerifier.modelVersion) {
        self.embeddings = embeddings
        self.createdAt = createdAt
        self.modelVersion = modelVersion
    }

    /// Usable with the model currently bundled?
    var isCompatible: Bool { modelVersion == SpeakerVerifier.modelVersion && !embeddings.isEmpty }
}

final class SpeakerVerifier: ObservableObject {

    static let shared = SpeakerVerifier()

    /// Bump whenever the bundled model changes (Scripts/convert_speaker_model.py
    /// stamps the same string into the .mlpackage's version field). The bundled
    /// model is WeSpeaker ResNet34-LM (VoxCeleb) with the Kaldi fbank front end
    /// traced in — the plan's SpeechBrain ECAPA first choice couldn't be fetched
    /// where the model was built; same interface, 256-dim instead of 192.
    static let modelVersion = "wespeaker-resnet34-lm-v1"
    static let sampleRate: Double = 16000
    static let embeddingSize = 256
    /// Below this much SPEECH (after trimming) we don't judge — nil decision.
    static let minSpeechSeconds: Double = 0.8
    /// Model input bounds baked into the Core ML package (0.5 s … 10 s).
    static let minModelSamples = 8000
    static let maxModelSamples = 160000
    /// Enrollment samples whose max cosine against the earlier ones is below
    /// this get a "that one sounded different" warning.
    static let enrollmentConsistencyFloor: Float = 0.45

    enum Strictness: String, CaseIterable, Codable {
        case lenient, normal, strict

        /// Cosine threshold. SpeechBrain's own verify_batch defaults to 0.25;
        /// typical ECAPA operating points sit around 0.25–0.35.
        var threshold: Float {
            switch self {
            case .lenient: return 0.22
            case .normal: return 0.30
            case .strict: return 0.40
            }
        }

        var label: String {
            switch self {
            case .lenient: return "Lenient"
            case .normal: return "Normal"
            case .strict: return "Strict"
            }
        }
    }

    enum ModelStatus: Equatable {
        case notLoaded
        case loading
        case ready
        case unavailable(String)

        var isReady: Bool { self == .ready }
        var failureReason: String? {
            if case .unavailable(let why) = self { return why }
            return nil
        }
    }

    /// One scored utterance — what the coordinator logs ("score 0.18").
    struct Verdict: Equatable {
        let score: Float
        let threshold: Float
        var accepted: Bool { score >= threshold }
    }

    enum VerifyError: Error, CustomStringConvertible {
        case modelUnavailable(String)
        case tooShort(Int)
        case badOutput(String)

        var description: String {
            switch self {
            case .modelUnavailable(let why): return "speaker model unavailable: \(why)"
            case .tooShort(let n): return "too little audio to embed (\(n) samples)"
            case .badOutput(let why): return "speaker model returned unexpected output: \(why)"
            }
        }
    }

    // MARK: Settings (UserDefaults-backed, the visionClickEnabled didSet pattern)

    private static let onlyMyVoiceKey = "onlyRespondToMyVoice"
    private static let strictnessKey = "speakerStrictness"
    private static let verifyEveryCommandKey = "verifyEveryCommand"

    /// The core feature: gate the wake word on the enrolled voice. Default off.
    @Published var onlyRespondToMyVoice: Bool {
        didSet {
            defaults.set(onlyRespondToMyVoice, forKey: Self.onlyMyVoiceKey)
            if onlyRespondToMyVoice { prepare() }
        }
    }
    @Published var strictness: Strictness {
        didSet { defaults.set(strictness.rawValue, forKey: Self.strictnessKey) }
    }
    /// Secondary: also check every command inside an open session. Default off —
    /// gating each clause risks dropping the owner's own commands mid-flow.
    @Published var verifyEveryCommand: Bool {
        didSet { defaults.set(verifyEveryCommand, forKey: Self.verifyEveryCommandKey) }
    }

    // MARK: Profile + model state

    @Published private(set) var profile: VoiceProfile?
    @Published private(set) var modelStatus: ModelStatus = .notLoaded
    /// Last scored utterance, for the Activity log / Settings "test" row.
    @Published private(set) var lastVerdict: Verdict?

    /// Where the wake-gate audio comes from when a caller doesn't pass it in
    /// (`verifyCurrentSpeaker`, the enrollment UI). Defaults to the running
    /// VoiceListener's 16 kHz ring buffer; injectable for tests.
    var recentAudioProvider: (Double) -> [Float] = { seconds in
        VoiceListener.active?.recentAudio(seconds: seconds) ?? []
    }

    let profileURL: URL
    private let defaults: UserDefaults
    private let modelLock = NSLock()
    private var model: MLModel?              // guarded by modelLock
    private var loadAttempted = false        // guarded by modelLock
    private let loadQueue = DispatchQueue(label: "com.lookmomnohands.speaker.load", qos: .userInitiated)

    /// Effective profile: only one produced by the current model counts.
    var usableProfile: VoiceProfile? {
        guard let profile, profile.isCompatible else { return nil }
        return profile
    }
    var hasProfile: Bool { usableProfile != nil }
    /// A stored profile exists but was made by a different model — re-enroll.
    var profileNeedsReenrollment: Bool {
        guard let profile else { return false }
        return !profile.isCompatible
    }
    var threshold: Float { strictness.threshold }

    /// Is the wake gate actually doing anything right now?
    var isGating: Bool { onlyRespondToMyVoice && hasProfile && modelStatus.failureReason == nil }

    convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(AppIdentity.storageFolder, isDirectory: true)
        self.init(profileURL: dir.appendingPathComponent("voiceprint.json"), defaults: .standard)
    }

    init(profileURL: URL, defaults: UserDefaults) {
        self.profileURL = profileURL
        self.defaults = defaults
        onlyRespondToMyVoice = defaults.bool(forKey: Self.onlyMyVoiceKey)
        strictness = Strictness(rawValue: defaults.string(forKey: Self.strictnessKey) ?? "") ?? .normal
        verifyEveryCommand = defaults.bool(forKey: Self.verifyEveryCommandKey)
        profile = Self.loadProfile(from: profileURL)
        if onlyRespondToMyVoice && hasProfile { prepare() }
    }

    // MARK: Profile persistence (local file only; never leaves the machine)

    static func loadProfile(from url: URL) -> VoiceProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VoiceProfile.self, from: data)
    }

    static func encode(_ profile: VoiceProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(profile)
    }

    static func decode(_ data: Data) throws -> VoiceProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceProfile.self, from: data)
    }

    /// Replaces the stored voiceprint with freshly enrolled embeddings.
    func saveProfile(embeddings: [[Float]]) throws {
        let new = VoiceProfile(embeddings: embeddings.map(Self.normalized))
        let data = try Self.encode(new)
        try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: profileURL, options: .atomic)
        onMain { self.profile = new }
    }

    func deleteProfile() {
        try? FileManager.default.removeItem(at: profileURL)
        onMain {
            self.profile = nil
            self.lastVerdict = nil
            // A voiceprint-less toggle would be a no-op that looks armed.
            if self.onlyRespondToMyVoice { self.onlyRespondToMyVoice = false }
        }
    }

    // MARK: Pure helpers (unit-tested)

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var n: Float = 0
        for x in v { n += x * x }
        let norm = n.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Energy-gates leading/trailing silence: 20 ms frames, a frame counts as
    /// speech when its RMS clears max(absolute floor, 15 % of the loudest
    /// frame); the kept span is first…last speech frame plus 100 ms on each
    /// side. All-silent input returns [].
    static func trimToSpeech(_ samples: [Float], rate: Double = sampleRate) -> [Float] {
        let frame = max(1, Int(rate * 0.02))
        guard samples.count >= frame else { return [] }
        let frames = samples.count / frame
        var energy = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        for f in 0..<frames {
            var sum: Float = 0
            let base = f * frame
            for i in 0..<frame { let s = samples[base + i]; sum += s * s }
            let rms = (sum / Float(frame)).squareRoot()
            energy[f] = rms
            if rms > peak { peak = rms }
        }
        let gate = max(0.004, peak * 0.15)
        guard let first = energy.firstIndex(where: { $0 >= gate }),
              let last = energy.lastIndex(where: { $0 >= gate }) else { return [] }
        let pad = Int(rate * 0.1)
        let start = max(0, first * frame - pad)
        let end = min(samples.count, (last + 1) * frame + pad)
        return Array(samples[start..<end])
    }

    /// Utterance-vs-profile score = MAX cosine over the enrolled embeddings
    /// (max, not mean — the owner's voice varies between samples; matching any
    /// one enrolled sample is the standard multi-enrollment trick).
    static func score(_ embedding: [Float], against profile: VoiceProfile) -> Float {
        var best: Float = -1
        for e in profile.embeddings {
            let c = cosine(embedding, e)
            if c > best { best = c }
        }
        return best
    }

    static func accepts(score: Float, strictness: Strictness) -> Bool {
        score >= strictness.threshold
    }

    /// Enrollment consistency check: does the new sample resemble at least one
    /// of the earlier ones? (Always true for the first sample.)
    static func isConsistent(_ embedding: [Float], withPrevious previous: [[Float]]) -> Bool {
        guard !previous.isEmpty else { return true }
        return score(embedding, against: VoiceProfile(embeddings: previous)) >= enrollmentConsistencyFloor
    }

    /// Which of several known voices is this? Max cosine per profile, best
    /// profile wins if it clears the threshold. Groundwork for the meeting loop
    /// (SPEC §5.2: returning attendees recognised automatically).
    static func identify(_ embedding: [Float], among profiles: [String: VoiceProfile],
                         threshold: Float) -> (name: String, score: Float)? {
        var best: (name: String, score: Float)?
        for (name, profile) in profiles where profile.isCompatible {
            let s = score(embedding, against: profile)
            if s >= threshold, s > (best?.score ?? -1) { best = (name, s) }
        }
        return best
    }

    // MARK: Model

    /// Where the model may live, in order: a drop-in override in the app-support
    /// folder (lets the owner update the model without rebuilding), then the
    /// SwiftPM resource bundle (`LookMomNoHands_LookMomNoHands.bundle`) next to
    /// the binary (swift run / swift test) or in Contents/Resources (the .app;
    /// Scripts/common.sh assemble_app copies it there). Both compiled
    /// (.mlmodelc) and source (.mlpackage, compiled at first load) forms count.
    /// Not `Bundle.module`: that accessor only exists when Package.swift declares
    /// resources, and the app must build with or without the model.
    static func locateModel(profileURL: URL? = nil) -> URL? {
        let fm = FileManager.default
        var roots: [URL] = []
        if let profileURL { roots.append(profileURL.deletingLastPathComponent()) }
        let bundleName = "LookMomNoHands_LookMomNoHands.bundle"
        var bases: [URL] = []
        if let r = Bundle.main.resourceURL { bases.append(r) }
        bases.append(Bundle.main.bundleURL)
        let mine = Bundle(for: SpeakerVerifier.self).bundleURL
        bases.append(mine)
        bases.append(mine.deletingLastPathComponent())
        if let exe = Bundle.main.executableURL { bases.append(exe.deletingLastPathComponent()) }
        for b in bases {
            roots.append(b.appendingPathComponent(bundleName, isDirectory: true))
            roots.append(b)
        }
        for root in roots {
            for name in ["SpeakerEmbedder.mlmodelc", "SpeakerEmbedder.mlpackage"] {
                let url = root.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Kicks off loading in the background so the first wake isn't slowed by
    /// the model load. Safe to call repeatedly.
    func prepare() {
        modelLock.lock()
        let already = loadAttempted
        modelLock.unlock()
        guard !already else { return }
        onMain { if self.modelStatus == .notLoaded { self.modelStatus = .loading } }
        loadQueue.async { [weak self] in _ = self?.loadIfNeeded() }
    }

    /// Loads once; later calls return the cached model (or nil after a failure
    /// — fail open, we don't keep retrying on every wake).
    private func loadIfNeeded() -> MLModel? {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let model { return model }
        if loadAttempted { return nil }
        loadAttempted = true
        guard let url = Self.locateModel(profileURL: profileURL) else {
            setStatus(.unavailable("SpeakerEmbedder model not bundled"))
            return nil
        }
        do {
            var compiled = url
            if url.pathExtension == "mlpackage" {
                compiled = try MLModel.compileModel(at: url)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let loaded = try MLModel(contentsOf: compiled, configuration: config)
            model = loaded
            setStatus(.ready)
            return loaded
        } catch {
            setStatus(.unavailable("couldn't load \(url.lastPathComponent): \(error.localizedDescription)"))
            return nil
        }
    }

    private func setStatus(_ status: ModelStatus) {
        onMain { self.modelStatus = status }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// 16 kHz mono in, unit-normalised 192-dim embedding out. Blocking — call
    /// off the main thread. Audio is clamped to the model's 0.5–10 s window
    /// (the middle 10 s kept when longer).
    func embedding(for samples: [Float]) throws -> [Float] {
        guard let model = loadIfNeeded() else {
            throw VerifyError.modelUnavailable(modelStatus.failureReason ?? "not loaded")
        }
        guard samples.count >= Self.minModelSamples else { throw VerifyError.tooShort(samples.count) }
        var input = samples
        if input.count > Self.maxModelSamples {
            let start = (input.count - Self.maxModelSamples) / 2
            input = Array(input[start..<(start + Self.maxModelSamples)])
        }
        let array = try MLMultiArray(shape: [1, NSNumber(value: input.count)], dataType: .float32)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<input.count { buffer[i] = input[i] }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: array)])
        let out = try model.prediction(from: provider)
        guard let result = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw VerifyError.badOutput("no 'embedding' feature")
        }
        let n = result.count
        guard n == Self.embeddingSize else { throw VerifyError.badOutput("\(n) values, expected \(Self.embeddingSize)") }
        var vector = [Float](repeating: 0, count: n)
        for i in 0..<n { vector[i] = result[i].floatValue }
        return Self.normalized(vector)
    }

    // MARK: Decisions

    /// Scores audio against the enrolled profile. nil = can't judge (no usable
    /// profile, model unavailable, or under 0.8 s of speech after trimming).
    func verdict(for audio: [Float]) -> Verdict? {
        guard let profile = usableProfile else { return nil }
        let speech = Self.trimToSpeech(audio)
        guard Double(speech.count) >= Self.minSpeechSeconds * Self.sampleRate else { return nil }
        guard let embedding = try? embedding(for: speech) else { return nil }
        let v = Verdict(score: Self.score(embedding, against: profile), threshold: threshold)
        onMain { self.lastVerdict = v }
        return v
    }

    /// The coordinator's single wake-gate entry point. True whenever we can't
    /// or shouldn't judge (feature off, no profile, model unavailable, audio too
    /// short); false only on a confident reject. Blocking — hop off main.
    func shouldAccept(recentAudio: [Float]) -> Bool {
        guard onlyRespondToMyVoice, hasProfile else { return true }
        guard let v = verdict(for: recentAudio) else { return true }
        return v.accepted
    }

    /// For the approval path (SPEC §12: owner voiceprint for tier ≥2 by voice).
    /// Independent of the wake-gate toggle: whenever a profile exists, says
    /// whether the last ~3 s of audio is the owner. nil = couldn't verify.
    func verifyCurrentSpeaker() -> Bool? {
        guard hasProfile else { return nil }
        return verdict(for: recentAudioProvider(3))?.accepted
    }

    /// Multi-speaker groundwork (SPEC §5.2): which known voice is speaking?
    func identify(_ samples: [Float], among profiles: [String: VoiceProfile]) -> (name: String, score: Float)? {
        let speech = Self.trimToSpeech(samples)
        guard Double(speech.count) >= Self.minSpeechSeconds * Self.sampleRate,
              let embedding = try? embedding(for: speech) else { return nil }
        return Self.identify(embedding, among: profiles, threshold: threshold)
    }
}

/// Tiny online speaker clusterer for the live-meeting loop: each embedding is
/// assigned to the nearest known centroid above `threshold`, else it opens a
/// new "Speaker N". Centroids are running means (re-normalised), so a cluster
/// drifts toward the speaker as more of their speech arrives. Pure — unit-tested.
struct SpeakerClusterer {
    struct Cluster: Equatable {
        var name: String
        var centroid: [Float]
        var count: Int
    }

    let threshold: Float
    private(set) var clusters: [Cluster] = []
    private var unnamed = 0

    /// `known` seeds named clusters (e.g. enrolled attendees) from the mean of
    /// their enrolled embeddings.
    init(threshold: Float = 0.30, known: [String: VoiceProfile] = [:]) {
        self.threshold = threshold
        for name in known.keys.sorted() {
            guard let profile = known[name], !profile.embeddings.isEmpty else { continue }
            clusters.append(Cluster(name: name,
                                    centroid: SpeakerClusterer.mean(profile.embeddings),
                                    count: profile.embeddings.count))
        }
    }

    /// Returns the speaker label for this embedding, updating the centroid.
    mutating func assign(_ embedding: [Float]) -> String {
        let e = SpeakerVerifier.normalized(embedding)
        var bestIndex = -1
        var bestScore: Float = -1
        for (i, c) in clusters.enumerated() {
            let s = SpeakerVerifier.cosine(e, c.centroid)
            if s > bestScore { bestScore = s; bestIndex = i }
        }
        if bestIndex >= 0, bestScore >= threshold {
            var c = clusters[bestIndex]
            let n = Float(c.count)
            var merged = [Float](repeating: 0, count: c.centroid.count)
            for i in 0..<merged.count { merged[i] = (c.centroid[i] * n + e[i]) / (n + 1) }
            c.centroid = SpeakerVerifier.normalized(merged)
            c.count += 1
            clusters[bestIndex] = c
            return c.name
        }
        unnamed += 1
        let name = "Speaker \(unnamed)"
        clusters.append(Cluster(name: name, centroid: e, count: 1))
        return name
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == first.count {
            for i in 0..<v.count { sum[i] += v[i] }
        }
        let n = Float(vectors.count)
        return SpeakerVerifier.normalized(sum.map { $0 / n })
    }
}
