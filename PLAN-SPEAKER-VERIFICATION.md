# Plan: Speaker verification ("only respond to MY voice")

**Status: approved, not yet implemented.** Owner picked the bundled on-device ML
model route (no Picovoice key, no cloud). This document is the full build plan;
implement it phase by phase and delete the file when everything ships.

## Goal

The app currently wakes for *any* voice that says "Hey Mama" — the TV, a
YouTube video, another person. Add speaker verification so the wake word (and
optionally every command) only works for the enrolled owner's voice. Everything
runs on-device: a bundled Core ML speaker-embedding model turns audio into a
192-dim "voiceprint" vector; cosine similarity against enrolled samples decides
accept/reject.

This is convenience filtering, not security: it's a similarity threshold, not a
password. Fail-open — if the model can't load, verification silently disables
(with a visible dashboard warning) rather than bricking the wake word.

## Model choice

**ECAPA-TDNN** (SpeechBrain `speechbrain/spkrec-ecapa-voxceleb`), converted to
Core ML with the 80-dim log-mel filterbank feature extraction **traced into the
graph**, so Swift feeds raw 16 kHz mono Float32 waveform and gets a 192-dim
embedding out. No feature-extraction code needed in Swift — that's the whole
point of tracing it in.

- Size: ~83 MB fp32 (20.8M params) — convert with fp16 weights → ~42 MB.
  Chunky but under GitHub's 100 MB hard limit; commit the fp16 build only.
- Input: `[1, T]` Float32 waveform at 16 kHz, T flexible (use
  `coremltools.RangeDim` for 8000…160000 samples, i.e. 0.5–10 s — the upper
  bound must cover the 4–6 s enrollment sentences in Phase 4, not just the
  ~2.5 s wake grab).
- Output: `[1, 192]` Float32 embedding.
- Fallback if SpeechBrain tracing fights back: WeSpeaker ResNet34 or NVIDIA
  TitaNet-small via ONNX → `coremltools`. Same interface contract.

## Phase 1 — Model conversion & bundling

1. **`Scripts/convert_speaker_model.py`** (new): loads the SpeechBrain model,
   wraps `compute_features → mean_var_norm → embedding_model` in a single
   `nn.Module`, traces with a flexible time dim, converts via `coremltools`
   (fp16, `minimum_deployment_target=macOS14`), writes
   `SpeakerEmbedder.mlpackage`. One-time run; requires
   `python3 -m pip install "torch<=2.5" speechbrain coremltools` — the torch
   pin matters: coremltools' `torch.stft` conversion (which SpeechBrain's
   Fbank uses) is broken on torch ≥ 2.6 (apple/coremltools#2504). If tracing
   still fights back, swap the STFT for a conv1d melspec (adobe-research/
   convmelspec) before falling back to a different model.
2. Compile and commit the **compiled** model (SwiftPM won't run coremlcompiler):
   `xcrun coremlcompiler compile SpeakerEmbedder.mlpackage Sources/LookMomNoHands/Resources/`
   → commit `Sources/LookMomNoHands/Resources/SpeakerEmbedder.mlmodelc/`.
3. **`Package.swift`**: add `resources: [.copy("Resources/SpeakerEmbedder.mlmodelc")]`
   to the executable target.
4. **`Scripts/common.sh` `assemble_app()`**: SwiftPM emits the resources as
   `.build/<config>/LookMomNoHands_LookMomNoHands.bundle` next to the binary —
   copy it into `Contents/Resources/` of the .app (the generated
   `Bundle.module` accessor checks `Bundle.main.resourceURL`, which is
   `Contents/Resources` in a bundle, so this Just Works both from
   `swift test` and the assembled app).

## Phase 2 — `SpeakerVerifier.swift` (new)

Loads the model once (lazy, off-main), exposes:

```swift
func embedding(for samples: [Float]) throws -> [Float]   // 16 kHz mono in, 192-dim unit-normalized out
static func cosine(_ a: [Float], _ b: [Float]) -> Float   // pure, unit-tested
static func trimToSpeech(_ samples: [Float], rate: Double) -> [Float]  // energy-gate leading/trailing silence; pure, unit-tested
```

- Reject inputs shorter than ~0.8 s after trimming (return nil decision — too
  little audio to judge; the caller treats nil as "accept" to avoid false
  lockouts on clipped wake words).
- Decision helper: score an utterance against a profile =
  **max** cosine over the enrolled embeddings (max, not mean — the owner's
  voice varies between samples; max against any enrolled sample is the
  standard multi-enrollment trick).

## Phase 3 — Audio plumbing in `VoiceListener.swift`

Standby keeps `captureAudio` off by design (no ambient buffering —
`armCaptureForCurrentMode` in AppCoordinator), and the tap runs at the mic's
native rate (usually 48 kHz). Verification needs the *recent* audio at the
moment the wake phrase matches, so:

- Add an always-on **ring buffer of the last ~4 s at 16 kHz mono Float32**
  (~256 KB — cheap enough to run in standby, unlike the unbounded
  `captureSamples` buffer). Fill it in the existing tap callback next to
  `captureIfNeeded`, guarded by its own lock (audio thread writes, main reads).
- Resample native→16 kHz with **`AVAudioConverter`** created once per format
  (the tap format is fixed for the engine's life). Don't hand-roll decimation.
- Expose `func recentAudio(seconds: Double) -> [Float]` (snapshot under lock).
- This buffer is separate from and unrelated to the Scribe `captureSamples`
  path — do not merge them; Scribe wants native rate Int16, this wants 16 kHz
  Float, and their lifetimes differ.

## Phase 4 — Enrollment (UI + persistence)

- **`VoiceProfile`** in `Models.swift`: `[[Float]]` embeddings + `createdAt` +
  `modelVersion: String` (bump when the .mlmodelc changes; a version mismatch
  invalidates the profile and prompts re-enrollment — embeddings from
  different models aren't comparable).
- Persist as `voiceprint.json` in the same app-support dir `AppStore` already
  uses. Local file only; never leaves the machine.
- **Dashboard**: new "Voice identity" `Section` in `SettingsTab`
  (`DashboardView.swift`) with:
  - Enroll flow: guided recording of **5 samples**. Prompts: "Hey Mama" ×2
    (wake-word audio is the main thing verified — enroll the actual phrase),
    plus 3 natural sentences ~4–6 s each. Reuse the existing recording pill /
    `onLevel` metering for feedback. After each sample: embed, and if its max
    cosine against the previous samples is < 0.45, warn "that one sounded
    different — noisy? try again" and let them redo it.
  - Toggle **"Only respond to my voice"** (`UserDefaults`, follows the exact
    `didSet`-persist pattern of `visionClickEnabled` in `AppCoordinator.swift`).
    Disabled/greyed until a profile exists. Default off.
  - Strictness picker: Lenient 0.22 / Normal 0.30 / Strict 0.40 (cosine
    threshold; SpeechBrain's own `verify_batch` defaults to 0.25, and typical
    ECAPA operating thresholds sit around 0.25–0.35).
  - "Re-enroll" and "Delete voiceprint" buttons.
  - Warning row if the model failed to load (verification inert).

## Phase 5 — Runtime gating in `AppCoordinator.swift`

- **Wake gate** (the core feature): in `handlePartial`, standby branch
  (`case .standby` — currently `if Self.wakePhrases.contains(...) { beginSession() }`),
  when verification is on: grab `listener.recentAudio(seconds: 2.5)`, trim to
  speech, embed, score vs profile. Pass → `beginSession()`. Fail →
  `store.log("wake", "ignored — voice didn't match (score 0.18)")` and stay in
  standby. Also gate `liveStartPhrases`/`dictateStartPhrases` the same way —
  they're wake-equivalent entry points.
  - Embedding must not block the main thread: hop to a background task, and on
    pass call `beginSession()` back on main. Flexible input shapes can push
    Core ML off the Neural Engine onto CPU/GPU (apple/coremltools#2370), but
    even CPU inference on ~2.5 s of audio lands well under 200 ms —
    imperceptible against the existing ~1 s silence gates.
  - Log the score on *success* too (debug-level) — it's the only way to tune
    the threshold on a real device.
- **Per-command gate** (secondary, settable): optional "verify every command"
  toggle, default **off** — once a session is open, gating each clause risks
  dropping the owner's own commands mid-flow and doubles inference chatter.
  When on, check in `finalizeCommand` before processing; on fail, log and
  discard the utterance but keep the session open.
- Nil decision (too-short audio, model unloaded) always accepts.

## Phase 6 — Tests + verification

- Unit tests (pure funcs, existing `Tests/LookMomNoHandsTests` style): cosine
  correctness, `trimToSpeech` on synthetic silence-speech-silence signals, ring
  buffer wraparound, profile JSON round-trip, model-version mismatch
  invalidation, threshold decision table.
- Model smoke test: load the bundled .mlmodelc, embed 1 s of synthetic audio,
  assert 192-dim output and self-similarity ≈ 1.0 for identical input.
- `swift build` + `swift test` must pass; then `Scripts/build_app.sh` and a
  **real-device check** (see memory note `nohands-verification-needs`): enroll,
  confirm own voice wakes it, confirm a YouTube video saying "hey mama" does
  not, watch scores in the Activity tab, tune default threshold if needed.

## Sharp edges (why the plan is shaped this way)

- **Don't touch the recognition tap/engine.** The single-engine, cycle-the-
  request design in `VoiceListener` is load-bearing (see its header comment and
  commit e231333 — AEC broke the wake word). Verification only *reads* audio
  via a new ring buffer; it must not reconfigure the input node.
- **Wake audio is short.** "Hey Mama" is ~1 s; the ring buffer grab will
  include ambient audio before it. `trimToSpeech` + max-over-enrollment keeps
  this workable; enrolling the wake phrase itself matters most.
- **Fail-open everywhere.** A missing model, a nil decision, or a load error
  must never stop the app from waking — this feature filters annoyance, it is
  not auth.
- **Model and profile are coupled** via `modelVersion` — swapping the .mlmodelc
  without bumping it produces garbage scores that look like a threshold bug.
