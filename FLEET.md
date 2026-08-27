# Fleet: running goals on your other Macs

Every copy of the app can be a **dispatcher** (say "on the mac mini, pull the
report") and/or a **worker** (accept goals from paired machines). Goals are
delegated whole — the worker runs its own act-observe loop against its own
screen and reports progress back. No screenshots, AX trees, or transcripts
cross the network; every message is Ed25519-signed and only paired machines
are heard.

## Pairing (once per machine pair)

1. On the worker: Dashboard → Agents → Fleet → enable **worker mode**.
2. On the dispatcher: the worker appears under "On your network" → **Pair**.
3. Both machines show a 6-digit code. Approve on the worker **only if the codes
   match** — that comparison is what defeats a machine-in-the-middle.
4. Pairing survives restarts (`fleet-peers.json`); the private key lives in
   each machine's Keychain and never leaves it.

## Provisioning a worker Mac (the honest checklist)

macOS UI automation only works in an **unlocked, logged-in GUI session** — a
locked or headless machine cannot be driven. Per worker, once:

- Sign into the app (its own device seat) and grant **Accessibility**,
  **Screen Recording**, and (if it will take dictation) Microphone + Speech.
  TCC grants are per-machine and cannot be granted remotely. If pastes/clicks
  silently stop after replacing the binary, reset the stale grant:
  `tccutil reset Accessibility com.lookmomnohands.app` (known macOS behavior).
- System Settings → Lock Screen: never require password after sleep, or set
  auto-login. This machine is a robot arm; treat physical access accordingly.
- Energy: prevent sleep on power. For a headless Mac mini, attach a display
  dongle so rendering keeps a real resolution.
- Local network permission: approve the app's Local Network prompt on both
  machines (Bonjour needs it).

## What syncs, what doesn't (the shared brain)

Procedures, vocabulary, knowledge, and agent roles sync to every paired
machine (id-union, newest wins, debounced ~3s). Edits propagate for
procedures, roles, and knowledge (each edit is re-stamped); vocabulary
entries sync as created — edit them on the machine that owns them.
Deliberately NOT synced:

- **Schedules** — a synced schedule would fire on every machine at once. The
  scheduler DOES fail over: if the local Mac is busy at a slot, the goal is
  dispatched to an idle online worker instead of being skipped.
- **Deletes** — removal stays local (v1 has no tombstones; re-delete on the
  other machine if you meant it globally).
- Element memory, paste rules, transcripts, API keys — machine-local.

## Limits (v1, on purpose)

- LAN only (Bonjour). Off-LAN needs a mesh (Tailscale-style) — the pairing and
  signing model won't change when that lands.
- One remote goal at a time per worker (it holds the screen lease); the local
  user always preempts, and the dispatcher hears "the local user took the
  screen."
- Fleet messages are signed but not yet encrypted in transit — treat the LAN
  as trusted, or don't pair across networks you don't own.
