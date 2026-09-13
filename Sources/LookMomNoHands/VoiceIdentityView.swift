import SwiftUI

/// "Voice identity" settings section (PLAN-SPEAKER-VERIFICATION.md, Phase 4).
/// Self-contained: drop `VoiceIdentitySection()` into SettingsTab's Form. It
/// talks to `SpeakerVerifier.shared` and reads enrollment audio from the
/// running VoiceListener's 16 kHz ring buffer, so it needs nothing from the
/// coordinator. Enrollment = 5 guided samples (the wake phrase twice, then
/// three natural sentences); each is embedded and checked against the earlier
/// ones so a noisy take can be redone before it poisons the voiceprint.
struct VoiceIdentitySection: View {
    @ObservedObject private var verifier: SpeakerVerifier
    private let recentAudio: (Double) -> [Float]
    private let log: (String) -> Void

    /// - Parameters:
    ///   - verifier: defaults to the app-wide singleton.
    ///   - recentAudio: seconds → 16 kHz mono samples; defaults to the live
    ///     listener's ring buffer.
    ///   - log: optional sink for activity-log lines (e.g. `store.log("voice", $0)`).
    init(verifier: SpeakerVerifier = .shared,
         recentAudio: ((Double) -> [Float])? = nil,
         log: @escaping (String) -> Void = { _ in }) {
        _verifier = ObservedObject(wrappedValue: verifier)
        self.recentAudio = recentAudio ?? { seconds in VoiceListener.active?.recentAudio(seconds: seconds) ?? [] }
        self.log = log
    }

    private struct Prompt {
        let title: String
        let text: String
        let seconds: Double
    }

    // The wake phrase is what gets verified most, so it's enrolled as itself;
    // the sentences give the model a wider sample of the voice.
    private static let prompts: [Prompt] = [
        Prompt(title: "Say the wake phrase", text: "Hey Mama", seconds: 2.5),
        Prompt(title: "Say it once more", text: "Hey Mama", seconds: 2.5),
        Prompt(title: "Read this sentence", text: "Hey Mama, open my calendar and show me what's on for tomorrow afternoon.", seconds: 6),
        Prompt(title: "Read this sentence", text: "Please remind me to send the invoice before lunch and call the bank after.", seconds: 6),
        Prompt(title: "Read this sentence", text: "The quick brown fox jumps over the lazy dog down by the riverbank.", seconds: 6),
    ]

    @State private var enrolling = false
    @State private var index = 0
    @State private var samples: [[Float]] = []
    @State private var recording = false
    @State private var progress: Double = 0
    @State private var busy = false
    @State private var timer: Timer?
    @State private var pending: (embedding: [Float], score: Float)?   // consistency warning awaiting a choice
    @State private var message: String?
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Section("Voice identity") {
            if let why = verifier.modelStatus.failureReason {
                Label("Voice verification is off — \(why)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            if enrolling {
                enrollmentRows
            } else {
                statusRows
            }

            Toggle("Only respond to my voice", isOn: $verifier.onlyRespondToMyVoice)
                .disabled(!verifier.hasProfile)
            Text("When on, “Hey Mama” only works for the enrolled voice — the TV, a video, or someone else saying it is ignored. It's a similarity check, not a password: if it ever locks you out, turn it off here.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Strictness", selection: $verifier.strictness) {
                ForEach(SpeakerVerifier.Strictness.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(!verifier.hasProfile)
            Toggle("Also verify every command in a session", isOn: $verifier.verifyEveryCommand)
                .disabled(!verifier.hasProfile || !verifier.onlyRespondToMyVoice)
            Text("Off by default: once a session is open, checking each command risks dropping your own words mid-flow.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { verifier.prepare() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    // MARK: Status (not enrolling)

    @ViewBuilder
    private var statusRows: some View {
        if let profile = verifier.profile {
            if profile.isCompatible {
                LabeledContent("Voiceprint") {
                    Text("Enrolled \(profile.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(profile.embeddings.count) samples")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Your voiceprint was made with an older model — please re-enroll.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            Text("No voiceprint yet. Enrollment records five short samples on this Mac; nothing leaves the machine.")
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button(verifier.profile == nil ? "Enroll my voice…" : "Re-enroll…") { beginEnrollment() }
                .disabled(verifier.modelStatus.failureReason != nil)
            if verifier.hasProfile {
                Button(testing ? "Listening…" : "Test my voice") { runTest() }
                    .disabled(testing)
                Button("Delete voiceprint", role: .destructive) {
                    verifier.deleteProfile()
                    testResult = nil
                    message = nil
                    log("voiceprint deleted")
                }
            }
        }
        if let testResult {
            Text(testResult).font(.caption).foregroundStyle(.secondary)
        }
        if let message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        if verifier.hasProfile, let v = verifier.lastVerdict {
            Text("Last check: score \(String(format: "%.2f", v.score)) vs threshold \(String(format: "%.2f", v.threshold)) — \(v.accepted ? "matched" : "rejected")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Enrollment flow

    @ViewBuilder
    private var enrollmentRows: some View {
        let prompt = Self.prompts[min(index, Self.prompts.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample \(index + 1) of \(Self.prompts.count) — \(prompt.title)")
                .font(.caption).foregroundStyle(.secondary)
            Text("“\(prompt.text)”").font(.body.weight(.medium))
            if recording {
                ProgressView(value: progress)
                Text("Listening… speak now.").font(.caption).foregroundStyle(.secondary)
            } else if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analysing…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let pending {
                Label("That one sounded different from the others (similarity \(String(format: "%.2f", pending.score))) — noisy room? Try again.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    Button("Try again") { self.pending = nil }
                    Button("Use anyway") { accept(pending.embedding); self.pending = nil }
                }
            } else {
                if let message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Record") { startRecording(seconds: prompt.seconds) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { cancelEnrollment() }
                }
            }
        }
    }

    private func beginEnrollment() {
        enrolling = true
        index = 0
        samples = []
        pending = nil
        message = nil
        testResult = nil
        verifier.prepare()
    }

    private func cancelEnrollment() {
        timer?.invalidate(); timer = nil
        enrolling = false
        recording = false
        busy = false
        pending = nil
        samples = []
        message = nil
    }

    /// Counts down `seconds` while the always-on ring buffer fills, then grabs
    /// exactly that window. No engine changes, no new tap — the listener keeps
    /// doing what it does.
    private func startRecording(seconds: Double) {
        message = nil
        recording = true
        progress = 0
        let start = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            let elapsed = Date().timeIntervalSince(start)
            progress = min(1, elapsed / seconds)
            if elapsed >= seconds {
                t.invalidate()
                finishRecording(seconds: seconds)
            }
        }
    }

    private func finishRecording(seconds: Double) {
        recording = false
        let audio = recentAudio(seconds)
        let speech = SpeakerVerifier.trimToSpeech(audio)
        guard Double(speech.count) >= SpeakerVerifier.minSpeechSeconds * SpeakerVerifier.sampleRate else {
            message = audio.isEmpty
                ? "No audio — the microphone isn't listening right now."
                : "Didn't hear enough speech. Speak a little louder or closer to the mic and try again."
            return
        }
        busy = true
        let previous = samples
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try verifier.embedding(for: speech) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .failure(let error):
                    message = "Couldn't analyse that sample: \(error)"
                case .success(let embedding):
                    if previous.isEmpty {
                        accept(embedding)
                    } else {
                        let score = SpeakerVerifier.score(embedding, against: VoiceProfile(embeddings: previous))
                        if score < SpeakerVerifier.enrollmentConsistencyFloor {
                            pending = (embedding, score)
                        } else {
                            accept(embedding)
                        }
                    }
                }
            }
        }
    }

    private func accept(_ embedding: [Float]) {
        samples.append(embedding)
        index += 1
        message = nil
        guard index >= Self.prompts.count else { return }
        do {
            try verifier.saveProfile(embeddings: samples)
            message = "Voiceprint saved (\(samples.count) samples)."
            log("voiceprint enrolled (\(samples.count) samples)")
        } catch {
            message = "Couldn't save the voiceprint: \(error.localizedDescription)"
        }
        enrolling = false
        samples = []
    }

    /// Records ~3 s and shows the score — the only way to tune the threshold
    /// on a real device.
    private func runTest() {
        testing = true
        testResult = "Say something for three seconds…"
        let seconds = 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let audio = recentAudio(seconds)
            DispatchQueue.global(qos: .userInitiated).async {
                let verdict = verifier.verdict(for: audio)
                DispatchQueue.main.async {
                    testing = false
                    if let verdict {
                        testResult = String(format: "Score %.2f vs threshold %.2f — %@",
                                            verdict.score, verdict.threshold,
                                            verdict.accepted ? "that's you." : "wouldn't have matched.")
                        log(String(format: "voice test: score %.2f (threshold %.2f)", verdict.score, verdict.threshold))
                    } else if let why = verifier.modelStatus.failureReason {
                        testResult = "Couldn't test — \(why)"
                    } else {
                        testResult = "Didn't hear enough speech to judge — try again."
                    }
                }
            }
        }
    }
}
