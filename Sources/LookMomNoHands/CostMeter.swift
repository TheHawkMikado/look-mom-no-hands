import Foundation

/// Measures what the app actually costs to run, so pricing rests on real numbers
/// instead of estimates.
///
/// Every Anthropic response carries a `usage` block (input/output/cache tokens);
/// Scribe bills by audio seconds; ElevenLabs by characters. We price each with
/// the rates below and bucket it into **controller** (screen-control: command
/// parsing, vision fallback, spoken replies, app-docs research) vs **dictation**
/// (transcription, cleanup, reports, notes Q&A). Active time is inferred from the
/// cadence of events, giving an approximate $/hr per bucket.
///
/// All figures are per-device and persist across launches; reset from the
/// dashboard before a measured dogfooding run.
@MainActor
final class CostMeter: ObservableObject {
    static let shared = CostMeter()

    @Published private(set) var controller = Bucket()
    @Published private(set) var dictation = Bucket()

    /// A gap between two events in the same bucket longer than this doesn't count
    /// as active time — it's a break, not usage.
    private let gapThreshold: TimeInterval = 180

    private let defaultsKey = "cost-meter-v1"

    private init() { load() }

    // MARK: - Rates ($ per token / second / character), verified July 2026.

    private struct Rate { let input, output, cacheRead, cacheWrite: Double }
    private static let haiku = Rate(input: 1e-6, output: 5e-6, cacheRead: 0.10e-6, cacheWrite: 1.25e-6)
    private static let opus  = Rate(input: 5e-6, output: 25e-6, cacheRead: 0.50e-6, cacheWrite: 6.25e-6)
    /// ElevenLabs batch Scribe: $0.22 per hour of audio.
    private static let sttPerSecond = 0.22 / 3600.0
    /// ElevenLabs Flash v2.5 TTS — approximate per-character rate (minor; spoken
    /// replies are short and capped).
    private static let ttsPerChar = 0.00007

    enum Kind {
        case command, vision, appDocs     // controller
        case cleanup, report, answer      // dictation
        var isController: Bool {
            switch self { case .command, .vision, .appDocs: return true; default: return false }
        }
    }

    struct Bucket: Codable {
        var cost: Double = 0
        var calls: Int = 0
        var tokensIn: Int = 0
        var tokensOut: Int = 0
        var activeSeconds: Double = 0
        var lastEventEpoch: Double = 0

        /// Approximate cost per active hour. Needs a little accumulated time to be
        /// meaningful, so it reads 0 until there's more than a minute of activity.
        var perHour: Double { activeSeconds > 60 ? cost / (activeSeconds / 3600) : 0 }
    }

    // MARK: - Recording (callable from any thread; hops to the main actor)

    nonisolated func recordClaude(kind: Kind, model: String?, usage: [String: Any]) {
        let rate = (model?.contains("opus") == true) ? Self.opus : Self.haiku
        let inp = usage["input_tokens"] as? Int ?? 0
        let out = usage["output_tokens"] as? Int ?? 0
        let cr = usage["cache_read_input_tokens"] as? Int ?? 0
        let cw = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cost = Double(inp) * rate.input + Double(out) * rate.output
                 + Double(cr) * rate.cacheRead + Double(cw) * rate.cacheWrite
        let tin = inp + cr + cw
        Task { @MainActor in self.add(controller: kind.isController, cost: cost, tin: tin, tout: out) }
    }

    /// Scribe transcription — bill by the audio duration, which doubles as the
    /// bucket's active time (you were dictating for exactly that long).
    nonisolated func recordAudio(seconds: Double) {
        guard seconds > 0 else { return }
        let cost = seconds * Self.sttPerSecond
        Task { @MainActor in self.add(controller: false, cost: cost, seconds: seconds) }
    }

    /// ElevenLabs spoken reply (controller side).
    nonisolated func recordTTS(chars: Int) {
        guard chars > 0 else { return }
        let cost = Double(chars) * Self.ttsPerChar
        Task { @MainActor in self.add(controller: true, cost: cost) }
    }

    private func add(controller isCtrl: Bool, cost: Double, tin: Int = 0, tout: Int = 0, seconds: Double? = nil) {
        var b = isCtrl ? controller : dictation
        let now = Date().timeIntervalSince1970
        b.cost += cost
        b.calls += 1
        b.tokensIn += tin
        b.tokensOut += tout
        if let seconds {
            b.activeSeconds += seconds
        } else if b.lastEventEpoch > 0, now - b.lastEventEpoch < gapThreshold {
            b.activeSeconds += now - b.lastEventEpoch
        }
        b.lastEventEpoch = now
        if isCtrl { controller = b } else { dictation = b }
        save()
    }

    func reset() {
        controller = Bucket()
        dictation = Bucket()
        save()
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = ["controller": controller, "dictation": dictation]
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode([String: Bucket].self, from: data)
        else { return }
        controller = snapshot["controller"] ?? Bucket()
        dictation = snapshot["dictation"] ?? Bucket()
    }
}
