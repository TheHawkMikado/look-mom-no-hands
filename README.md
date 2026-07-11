# Look Ma, No Hands

A voice-first macOS app that controls your screen entirely by voice — built for
hands-free use. Say a wake word, then dictate a note or issue a screen command.

Native SwiftUI menu-bar app for Apple Silicon (macOS 14+). Speech is recognized
**on-device** (Apple Speech); the intelligence (command routing, summaries) runs
through the **Anthropic Messages API** (Claude).

## What it does

1. **Wake word** — continuous on-device listening for "Hey Mama".
2. **Two capture modes** after waking:
   - **Command** → Claude parses it into a screen action (click / type / scroll /
     open app) and it's executed via the Accessibility API + CGEvent.
   - **Dictation** → say "take a note"; it records until you pause, then Claude
     returns a **TLDR summary + action items + cleaned transcript** (Wisprflow-style).

## Architecture

| File | Role |
|---|---|
| [LookMomNoHandsApp.swift](Sources/LookMomNoHands/LookMomNoHandsApp.swift) | `@main` menu-bar app + panel UI |
| [AppCoordinator.swift](Sources/LookMomNoHands/AppCoordinator.swift) | Orchestrates wake → transcribe → Claude → act |
| [VoiceListener.swift](Sources/LookMomNoHands/VoiceListener.swift) | Single always-on speech pipeline (wake word + transcription) |
| [ClaudeClient.swift](Sources/LookMomNoHands/ClaudeClient.swift) | Messages API: forced-tool routing + json_schema report |
| [ScreenController.swift](Sources/LookMomNoHands/ScreenController.swift) | Accessibility tree search + CGEvent click/type/scroll |
| [AppStore.swift](Sources/LookMomNoHands/AppStore.swift) | Disk-backed transcript store + activity log |
| [DashboardView.swift](Sources/LookMomNoHands/DashboardView.swift) | Dashboard window: transcripts + activity tabs |
| [Models.swift](Sources/LookMomNoHands/Models.swift) | Shared value types + frozen app-identity strings |
| [KeychainStore.swift](Sources/LookMomNoHands/KeychainStore.swift) | API key storage |

## Data & dashboard

Everything is stored locally under `~/Library/Application Support/LookMaNoHands/`:

- **`transcripts.jsonl`** — one JSON object per command / dictation, appended forever
  (id, date, kind, transcript, and for dictations the summary + action items).
- **`activity.log`** — a timestamped log of everything the app does, one line per
  event: `ISO8601: [subsystem] message` (subsystems: `app`, `wake`, `asr`,
  `claude`, `action`, `dictation`, `error`).

Open the **Dashboard** button in the menu-bar panel for a searchable view of all
transcripts and the live activity stream, with copy / reveal-in-Finder.

## Build & run

```sh
./Scripts/build_app.sh          # builds + assembles + ad-hoc signs build/LookMomNoHands.app
open build/LookMomNoHands.app
```

`swift build` alone compiles/typechecks but the permission prompts and TCC grants
need the real `.app` bundle the script produces. `swift test` runs the pure-logic
suite in `Tests/` — it needs a full Xcode toolchain (Command Line Tools alone
ship no XCTest).

### First-run setup

1. Enter your Anthropic API key in the menu-bar panel (stored in Keychain).
   Or, for dev, export `LMNH_ANTHROPIC_API_KEY` before launching.
2. Grant permissions in **System Settings → Privacy & Security**:
   - **Microphone** and **Speech Recognition** — prompted on first launch.
   - **Accessibility** — add the app manually; required to click and type.
3. Click **Start listening**, say the wake word, then speak a command.

## Model choices

- **Command routing** uses `claude-haiku-4-5` with forced tool use — low latency
  for the click-on-screen hot path.
- **Dictation reports** use `claude-opus-4-8` with `output_config.format` +
  adaptive thinking — quality where it matters.

Swap models in [ClaudeClient.swift](Sources/LookMomNoHands/ClaudeClient.swift).

## Status / next steps

Working skeleton, compiles and bundles clean. Natural extensions:
- Vision fallback: when the Accessibility search misses, send a screenshot to
  Claude and click by returned coordinates (ScreenCaptureKit + Screen Recording
  permission — deliberately not shipped until it's wired up).
- Streaming transcription display in the panel.
- Custom/trainable wake word (Porcupine) if the Apple phrase match is too loose.
