# System requirements

What No Hands needs to run well, per machine role. "Minimum" means it works;
"Recommended" means it feels instant, which is the product's whole point.

There are three roles. One machine can hold all three.

| Role | What it does | Mac | PC (Windows / Linux) |
|---|---|---|---|
| **Presence** | The always-on voice app: wake word, speech, screen control, meetings | Native app (shipped) | Not yet built; use the phone app + a Mac or a hosted Paperclip |
| **Brain host** | Runs Paperclip (agents, tasks, budgets, approvals) | Docker on the Mac, or a VPS | Docker Desktop / WSL2, or a VPS |
| **Phone** | Push-to-talk, approvals, activity | iOS 16+ | Android 10+ |

## Mac — the voice app (Presence role)

| | Minimum | Recommended |
|---|---|---|
| macOS | 14 Sonoma | 15 or newer |
| Chip | Intel (2019+) or any Apple Silicon | Apple Silicon M1 or newer |
| Memory | 8 GB | 16 GB |
| Free disk | 500 MB | 2 GB (meeting recordings and notes grow) |
| Microphone | Built-in | Headset or array mic in shared rooms |
| Network | Any (speech is on-device) | Wired or strong Wi-Fi for cloud model calls |
| Permissions | Microphone, Speech Recognition, Accessibility | + Screen Recording (vision fallback), Calendar (meetings) |

Notes:
- Speech recognition and the wake word run on-device, so the app listens and
  transcribes offline. Model calls (intent, extraction, drafting) need a
  network and take ~1–2 s on Apple Silicon with a good connection.
- Speaker verification (PLAN-SPEAKER-VERIFICATION.md) adds a ~42 MB Core ML
  model; it runs comfortably on any Apple Silicon and on Intel with a small
  latency cost.
- Intel Macs work but Apple Silicon is the recommended target: on-device
  speech and Core ML are markedly faster, and battery life on laptops matters
  for an always-listening app.

## Mac or PC — hosting Paperclip yourself (Brain host role)

Paperclip is a Node.js server plus Postgres. `Scripts/paperclip/up.sh` runs
it in Docker.

| | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4 cores |
| Memory | 4 GB free for Docker | 8 GB free for Docker |
| Free disk | 10 GB | 40 GB (agent workspaces and run logs) |
| Software | Docker Desktop (Mac/Windows) or Docker Engine (Linux) | same |
| Windows | 10 22H2 / 11 with WSL2 enabled | Windows 11 with WSL2 |
| Uptime | Awake while you want agents working | Always on (see below) |

Notes:
- Agents only work while the host is awake. A laptop that sleeps pauses the
  company. For "it works while my Mac sleeps", host Paperclip on a small
  VPS (2 vCPU / 4 GB / 40 GB is enough for one person) and point the
  connection at it. That is a URL change, not a reinstall.
- Local agents that run a CLI (Claude Code, Codex) need that CLI installed and
  signed in on the host. Cloud or sandbox agents do not.
- A Windows PC is a perfectly good Brain host today even though there is no
  Windows voice app: run Paperclip there, use the phone app to talk, and the
  Mac (if any) as the Local Runner.

## Phone

| | Minimum | Recommended |
|---|---|---|
| iOS | 16 | 17+ |
| Android | 10 | 13+ |
| Network | Any | Always-on data for push approvals |

## What is not required

- No GPU anywhere. Nothing runs a local LLM in v1.
- No open ports on your network. The Mac and phone poll the web service; the
  Mac calls Paperclip; nothing calls into your machines.
- No always-on internet for dictation or wake word. Only delegation and
  drafting need it.
