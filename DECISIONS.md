# Decisions

Non-obvious architectural choices, newest first. Every entry: date, the
decision, and why. The spec (SPEC.md §0) asks for this file; the rule is that
anything a future reader might reasonably ask "why on earth?" about goes here.

## 2026-09-13 — Diarization by on-device embeddings, not a cloud STT

SPEC §14 left streaming STT + diarization open. Phase 2 keeps Apple Speech
(on-device, already the wake/command engine) and does diarization itself:
`VoiceListener` now hands out each recognition result's timed segments,
`TurnBuilder` groups them into turns on pauses, `MeetingAudioWindow` cuts
the turn's audio out of the 8 s ring buffer, and the bundled speaker model
(`SpeakerVerifier.embedding`) turns it into a voiceprint that is matched
against enrolled attendees (`identify`) or an online `SpeakerClusterer`
("Speaker 2"). Reason: zero audio leaves the Mac (§4.3), no new vendor, and
the same model already gates the wake word. The cost is accuracy on short
overlapping turns; if the Phase 2 demo misses the ≥95 % attribution target,
a cloud streaming STT goes behind the `stt` route as a per-call choice.

## 2026-09-13 — The transcript stays local; only item text goes to the web

A live meeting's labelled transcript lives in memory and in the Local Brain
(`brain/meetings/<date>-<slug>.md`, one file rewritten as the meeting goes).
Exactly two things leave the Mac: the new stretch of transcript sent to the
`task_extract` model call (SPEC §4.3 allows the text of the model call
itself), and, at the end, each action item as its own
`POST /api/app/tasks { text: "<title>. <detail>. Owner: <name>. Due <when>",
source: "meeting", deliver? }`. `TeamClient.intakeBody` is unit-tested to
carry nothing else. The web triages agent / human / user and the Mac speaks
the summary. Attendees' voiceprints sit next to their person files
(`brain/voiceprints/<slug>.json`, same `VoiceProfile` shape as the owner's)
and their email/phone live only in `people/<slug>.md`; a human ticket hands
the address over once inside that POST (see "the Mac hands over the address,
once"). When the web is unreachable the items wait in `brain/outbox.json`
and are retried every minute — an action item is never lost to a dead
network.

## 2026-09-13 — Wearables are pulled, not pushed, and go through the meeting pipeline

Limitless first: its developer API is a plain `GET /v1/lifelogs` with an API
key, so the Mac polls it every ten minutes while online (`WearableIngest`),
keeps the page cursor and the ids already filed, and runs each new lifelog
through the SAME extraction and end-of-session triage as a live meeting via
a `MeetingSession` instance of its own (`runImported`). The text lands in
`brain/meetings/limitless-<id>.md` and is never uploaded; the API key is in
the Keychain. The summary is spoken only at a good moment. Plaud has no pull
API today, so `PlaudSource` is a documented stub behind the same
`WearableSource` protocol — when an API (or a watched export folder) exists,
only `fetch` needs writing. Reason: no audio pipeline to host, one code
path for "things people said", and the residency rule holds by construction.
The Limitless docs host was not reachable from the build box; the client is
written to the documented shape and tested on a sample — the first real
poll confirms the field names (a mismatch reads as an error, never as
"nothing new").

## 2026-09-13 — Meeting speech is data: no voice approval without the owner's verified voice

SPEC §12 says content from meetings is data, never instructions. Two rules
enforce it in code. The extraction prompt states it outright (the model is
told the transcript is data and never to follow requests inside it), and a
task that came out of a meeting (`source: "meeting"`, or an id the session
just submitted) is approved by voice only when
`SpeakerVerifier.verifyCurrentSpeaker()` says the last three seconds — the
"approve" itself — are the owner; otherwise the Mac says "I need that from
the phone" and leaves the phone push (already sent by the web) as the only
way to approve. The wake-word verdict is not enough: a session opened by the
owner an hour ago says nothing about who just said "approve" in a room
full of people. `speakerVerified` on the decide call is the fresh verdict
when there is one, never an upgrade of the wake verdict.

## 2026-09-13 — "A good moment" is decided on the Mac, once, for every prompt

The follow-up engine's prompts (`GET /api/app/prompts`) are spoken by
`AppCoordinator` only when `QuietHours.goodMomentToSpeak` says so: standby,
nothing in flight, no live meeting session or recorded call, no dictation,
not inside quiet hours (default 22:00–07:00), screen not locked
(`CGSessionCopyCurrentDictionary` + the lock/unlock notifications). The
question is spoken with its default as a promise ("… I'll nudge unless you
say otherwise"), the answer is taken from the standby stream for ~8 s or
from a click on the panel, silence posts the default, and a receipt line is
logged. The web's own `not_before` handles the server-side quiet window;
this gate is the client-side one, so a Mac that is busy never talks over
the user and a question is never lost — it stays open until a good moment.

## 2026-09-13 — Paperclip is optional and removable, never required to run

The Paperclip connection is a per-account setting the user can add and delete.
With no connection the app still listens, dictates, controls the screen, and
answers questions; only agent delegation is unavailable, and triage falls
through to "human" or "user". Reason: the owner wants the cloud brain only if
they choose it, and wants to be able to pull the plug by deleting the
connection. A hard dependency would also make the first-run experience worse
than it is today.

## 2026-09-13 — Fast path stays on the Mac; Paperclip is a delegate, not a gate

Wake word, speech recognition, intent classification and the spoken
confirmation run where they run today (on-device speech, one short model
call). Paperclip is only consulted after a task has been extracted and the
user has heard the one-sentence confirmation. Reason: the owner's stated
priority is response speed. Nothing on the hot path may wait on a network
round trip to a control plane.

## 2026-09-13 — Keep the native Swift Mac app (no Tauri/Electron rewrite)

The Cowork spec proposed a web-shell desktop app. The existing app is ~14k
lines of Swift that already does on-device speech, wake word, hotkeys, TTS,
Accessibility-based screen control, meeting join/record, fleet delegation,
licensing and in-app updates, with an approved on-device speaker-verification
plan (PLAN-SPEAKER-VERIFICATION.md). A rewrite would spend weeks recovering
Apple Speech, Accessibility and TCC handling. The Swift app is the spec's
Presence layer, Local Brain host and Local Runner.

## 2026-09-13 — Keep the Expo phone app (no PWA)

The spec proposed a PWA. A PWA cannot do background audio or reliable push on
iOS. The existing Expo app already has push-to-talk, an activity feed,
approval cards and per-device sign-in.

## 2026-09-13 — Keep the existing Postgres + auth; no Supabase/Upstash SDKs

The web service already runs on Vercel with plain Postgres over a connection
string, Stripe billing, Apple/Google/magic-link sign-in and encrypted per-
account secrets. Supabase can host the Postgres if wanted; nothing in code
depends on it. Scheduling for the follow-up engine (Phase 3) will use Vercel
cron first and only reach for a queue when cron is insufficient.

## 2026-09-13 — Residency is a column and a build-failing test, not a policy

Every new table carries `residency text NOT NULL CHECK (residency IN
('local','cloud'))`, and `lib/residency.ts` is the single choke point for
cloud writes. `lib/residency.test.ts` fails the test run if a local-tagged
object reaches a cloud write path. This extends the existing convention that
the relay carries status text only and never transcripts or screenshots.

## 2026-09-13 — Approvals reuse the phone's existing approval cards

The Approval Gate emits `needs_approval` events with an `approval_id` into the
same `agent_events` table the phone and /status page already poll, and reads
verdicts from `agent_approvals`. Reason: the phone app needs zero changes to
approve a Phase 0 task, and there is exactly one approval mechanism to audit.

## 2026-09-13 — The model router lives in the web service and is served to clients

`routing_scores` is a table; `MODEL_ROUTING.md` is its human-readable seed.
Clients (Mac, phone) fetch `GET /api/app/routing` and cache it, so no client
hardcodes a model. The Swift app currently hardcodes two models; it moves to
the router in Phase 1. Reason: one routing table, refreshed by evals, applied
everywhere.

## 2026-09-13 — Paperclip runs on the user's own machine by default, cloud by choice

Default install is Docker on the owner's Mac (or a PC) via
`Scripts/paperclip/up.sh`. Moving it to a VPS is a URL change in the
connection setting. Reason: the owner has never got Paperclip working; the
setup has to be one command, and the app must do the company/agent creation
so the user never has to open the Paperclip board.

## 2026-09-13 — Two connection modes, one state machine

A Paperclip on the user's own machine is unreachable from the web service, so
a small bridge (`Scripts/paperclip/bridge.mjs`) polls the account's work list
and reports what it observed; a Paperclip on a VPS is called directly by the
web service. Both feed the same `advance()` in `web/lib/tasks.ts`, so "the
draft is ready" is decided in exactly one place and the bridge holds no
state. Verified end to end in both modes on 2026-09-13
(`web/scripts/phase0-demo.mjs`).

## 2026-09-13 — Updates install themselves (owner's call), still through the signature gate

The earlier trust line was "notify, never install". The owner asked for the
opposite: every release goes live and every Mac keeps itself current. So
`UpdateChecker.autoInstall` (default on, one switch in the panel) installs a
newer build as soon as the app is idle — never mid-dictation or mid-goal —
once per version (a failed attempt is shown, not retried). What did NOT
move: AppUpdater's Developer ID requirement. Automatic means no click, not
less checking. Translocated or DMG-mounted copies install to /Applications;
a swap that cannot succeed fails before the app quits.

## 2026-09-13 — Releases are cut by CI on every merge to main

`.github/workflows/release.yml` on macOS runners: build + tests on PRs;
sign, notarise, package, tag, publish, and bump Vercel on main. The commit
made by the workflow uses the Actions token, which GitHub never re-triggers
on, so there is no loop. Without signing secrets it builds and stops — an
unsigned release would reach nobody.

## 2026-09-13 — Team boards: every member's work, bots included, without opening Paperclip

`web/lib/team.ts` snapshots every open issue per assignee (agents and human
members) on each sync round or bridge report, overlays No Hands tasks that
never reached Paperclip, and serves it at `/team` and `GET /api/app/team`.
Titles, statuses and owners only — descriptions and comments stay in
Paperclip (residency).

## 2026-09-13 — The previous build is kept, and "revert" is one click

The update swap moves the replaced bundle to `updates/previous/` instead of
deleting it and records `previous.json` only after the move succeeds.
Settings › Version offers "Revert to v<previous>", which goes through the
same Developer ID signature gate as an update. After a revert the automatic
installer skips exactly the version reverted from, so it cannot bounce the
user straight back; a manual "Update now" still can. Reason: the owner
wants "go back to the last version that worked on this computer" without a
download or a Finder ritual.

## 2026-09-13 — Team steps ride the existing planner, not a second model call

Delegation ("have the content agent draft…"), "what's outstanding" and
spoken verdicts are step kinds the one existing planner call can emit,
decoded into `ActionPlan.teamSteps` alongside screen steps. Reason: the hot
path stays one model call; a separate intent classifier before the planner
would add a network round trip to every command.

## 2026-09-13 — Outbound calls go through Vapi (not Retell, not raw Twilio)

SPEC §14 left the call provider open. v1 uses Vapi: `web/lib/vapi.ts` builds
a transient assistant per call (goal, constraints, the caller's preferences
handed over by the Mac for that call only, and the hard rule never to commit
money above the approved tier), places it with `POST /call`, and reads the
end-of-call report from Vapi's server-URL webhook (`/api/calls/vapi`). Reason:
one API gives us telephony, STT, the realtime model and the post-call
analysis (`analysis.structuredData`) we need for a structured outcome, so
there is no audio pipeline to host and the model behind the call still comes
from the router (`call_agent_realtime`). Retell is equivalent and could be a
second `provider`; raw Twilio + a realtime model would mean running our own
media server, which is the "cloud agent farm" §2 says we are not. Residency:
`calls` stores the provider call id, status, a two-sentence summary, a few
typed outcome fields and the cost — never the number dialled, a transcript
or a recording (`artifactPlan.recordingEnabled: false`). The Vapi and GHL
docs hosts were unreachable from the build box, so both clients follow the
documented v1/v2 shapes as widely used and are unit-tested against fakes;
the first real call will confirm the field names.

## 2026-09-13 — Human tickets: the Mac hands over the address, once

A task assigned to a person goes out by email or SMS, but Persons live on
the Mac (§4.3). So `POST /api/app/tasks` and `POST /api/app/tasks/:id/deliver`
accept `deliver: { channel, to, name }`, use `to` for that one send, and keep
only the channel and the name on the task. A reminder later is therefore a
`deliver_reminder` prompt the Mac fulfils with a fresh hand-off, never a blind
send from the cloud. Messaging a teammate is tier 2 and a client tier 3 (§6);
the account's `auto_deliver_tier` (default 1) says how far tickets go without
a card, so by default the owner is asked once per ticket.

## 2026-09-13 — Prompts are how the bot initiates; push is best-effort

The follow-up engine never talks to the user directly. It writes a `prompts`
row — one question with a default, dated `not_before` inside quiet hours —
and the Mac speaks it when idle (`GET /api/app/prompts`), while the phone gets
the same question as an Expo push. Push is bounded (4 s) and swallowed on
failure: a phone that is off must never stall an approval. Expo receipts are
collected by the cron so uninstalled apps drop their tokens.

## 2026-09-13 — Evals measure the rules engine too, and an unrunnable candidate scores 0

`web/lib/evals/run.ts` runs every `routing_scores` row that has a fixture
set. Deterministic sets (intent, extraction, triage) are scored exactly —
a case passes only when every expected field matches — and the `local`
provider is the actual rules engine in extract.ts/triage.ts, so the table
can be measured with no model key at all. Rubric sets (summaries, short
copy) go through the `eval_judge` route and are skipped, with a warning and
the seed score left in place, when there is no key: unmeasured is not the
same as wrong. A `local` model the runner has no engine for is scored 0:
nothing may route to code that does not exist. Reason: the seed is an
opinion; the demo inserts a candidate claiming 0.99 and shows the winner
change back once it is measured. The seed never clobbers a measured score
(router.ts), so scores only ever move by evidence after the first run.
Fixtures are realistic and the engine's misses are recorded in
MODEL_ROUTING.md rather than papered over.

## 2026-09-13 — The Shared Brain scrubber is deterministic and sits on the only write path

`web/lib/brain.ts` replaces emails, URLs with ids, phones, cards, SSNs,
street addresses, dollar amounts, dates and introduced names ("I'm X",
"with X", "for X") with placeholders, in a fixed order, with no model in
the loop. `prepareCandidate` is the only way a promotion_queue row is built
and it scrubs unconditionally, then refuses to return if an email or phone
survived; publishing re-scrubs and refuses again. The classifier's
heuristics decide alone when certain (first-person facts → never; two or
more process signals → generic) and the `promotion_classify` model only
breaks the borderline, on scrubbed text. Consent is one question, default
no, and a no is final. Publishing attributes a SOP to
sha256(email + SESSION_SECRET), never an email. Reason: §4.3 says zero
personal data by construction; a model-based scrubber would make that a
probability, and a test can only enforce a function that always runs.

## 2026-09-13 — The ad process is a project with a cap; 80% asks, the cap refuses

`web/lib/projects.ts` turns an `ad_process` intake into a `projects` row
with the spoken cap and seven `project_steps` — research, angles, variants,
image prompts, compliance, the owner's review gate (tier 2), publish/fund
(tier 3 when there is a budget, tier 2 staging otherwise) — filed as
Paperclip issues under the task's issue when the connection is direct, in
the "Ad process" template project from `bootstrap.mjs --ads`. Spend goes
through `POST /api/app/projects/:id/spend`, is a receipt on the task,
asks the owner once at 80% via the same goal_progress event the phone
already renders, and is refused (409) when it would cross the cap. Reason:
§6 — money is tier 3 and a false low tier costs money; the cap is enforced
where the spend is recorded, not where the agent promises to behave.


## 2026-10-03 — No two builds ever share a version number

The first unsigned pre-release reused the plist version of the last signed
release, so the old app and the new one both said 0.04.260905.c13ad41 and
the owner could not tell them apart. Every build the pipeline packages now
stamps its own milestone.update.YYMMDD.commit version (the release.sh
scheme) into the plist for that build, plus `LMNHBuildFlavor = unsigned`,
which the app shows next to the version. The stamp is not committed for
unsigned builds; signed releases keep committing theirs through release.sh.

## 2026-10-03 — Secret beta: $99 for life, BETA## codes

- **Offer.** One plan, `beta`: $99 one-time, BYOK, unlimited devices, no
  sub-users, never expires. Sold only from `/beta`, which is unlinked, carries
  `robots: noindex` in its metadata and is disallowed in `/robots.txt`
  (along with /admin, /account, /status, /team and /api).
- **Codes are a formula, not a list.** `BETA##` means `##` dollars off, 1–99.
  `BETA99` makes the seat free. Nothing is created in Stripe for a code; the
  server computes the price (`lib/beta.ts`) and charges that exact amount via
  `price_data`. Stripe promotion codes are disabled on that checkout so the
  two cannot stack.
- **Free seats need a sign-in.** A $0 price never reaches Stripe; the licence
  is minted for the signed-in account in `/api/checkout/beta`. That also stops
  anonymous minting with a leaked BETA99.
- **Every redemption is logged** in `beta_redemptions` (email, code, discount,
  paid, licence key) and shown on `/admin › Beta`, where the whole programme
  can be closed and reopened (setting `beta_enabled`).

## 2026-10-03 — Signed releases over self-installing unsigned builds

The owner's Mac did not see the unsigned pre-releases, and that is by design:
the version manifest only moves on a signed release, and the updater pins the
Developer ID. Offered two ways out (teach unsigned apps to accept unsigned
updates, or add the signing secrets) and the owner chose signing as the more
secure path. `Scripts/setup_release_secrets.sh` makes that one command on the
Mac holding the certificate: it exports the identity, verifies the notary
login with Apple, finds the Vercel project, stores the ten secrets with `gh`,
and dispatches the first signed release. The unsigned path stays as the
fallback for a repo without secrets, never as something the app installs.

## 2026-10-03 — The Chrome extension is a browser-side hand, not a screenshot

The owner's ask: read "every element and piece of code on the page" so the
assistant knows exactly where to click instead of guessing from screenshots.

- **Shape.** A Manifest V3 extension (`chrome-extension/`) with a content
  script that walks the live DOM — open shadow roots and same-origin frames
  included — and returns a numbered map: `[e12] button "Send"`, every link
  with its destination, every field with its value and placeholder, headings,
  a text excerpt. Actions (click, type, select, scroll, hover, press, tabs)
  take the ref. Refs are re-numbered on every read, so a stale ref is an
  error, never a guess.
- **Transport.** One WebSocket from the extension to the Mac app on
  `127.0.0.1:47831` (`ChromeHand.swift`, Network.framework). Loopback only,
  paired with a six-character code shown in Settings. No cloud hop: page
  content goes where the Accessibility snapshot already goes (the planner
  prompt for that command) and nowhere else.
- **Where it plugs in.** When a Chromium browser is in front and the extension
  is connected, the planner's screen block is the page map instead of the
  Accessibility tree, and `performClick` tries the extension first (exact ref,
  else a clear best match against real elements) before the AX → learned →
  vision → teach ladder. Typing goes through the extension too (native value
  setter + input/change events, so React-style forms notice). Everything else
  is unchanged, and Safari/Firefox keep the old path.
- **Distribution.** Unpacked, not the Web Store: the app bundles the extension,
  copies it to Application Support on launch (so an app update doesn't move it
  from under Chrome), and Settings shows the folder plus the pairing code.
  Every release also attaches `chrome-extension-<version>.zip`. A Web Store
  listing is an owner decision later; nothing here depends on it.
- **Proof.** `chrome-extension/test/smoke.mjs` loads the real extension into
  Chromium under Playwright, plays the Mac app over the socket, and drives a
  fixture page: map, find, click (incl. shadow DOM), type, select, Enter
  submits, scroll, html, text, tabs, screenshot. Runs on every PR (Linux job).

## 2026-10-03 — "Open ChatGPT": the app, or Chrome? Ask once, remember

Owner's call after the first real session: when something is both an
installed app and a website, the assistant should ask which one they want
and save the answer. Implemented in `OpenPreferenceStore.swift` and the
coordinator's `openWithPreference`:

- An open step is a candidate when the thing has a Mac app installed AND a
  web twin — from the planner (`url` on `open_app` for web apps) or a
  built-in table (ChatGPT, Slack, Notion, Spotify, Zoom, Gmail…). Native-only
  apps and plain websites never trigger the question.
- Order of precedence: the command's own words ("…in Chrome", "the app") →
  the remembered choice → ask. The question is spoken and shown on the
  panel with two buttons; a spoken or clicked answer within ten seconds is
  remembered per thing. No answer opens the installed app and remembers
  nothing, so a missed question never locks in a guess.
- "Chrome" means Google Chrome when installed, else the default browser.
- Memory › Where things open lists the choices; removing one re-asks.

## 2026-10-03 — Chrome extension: real icon, one-click install, automatic pairing

- The extension carries the app's own icon (Assets/png, rendered from
  Assets/icon.svg) instead of a placeholder.
- Install is one click once the Chrome Web Store listing exists
  (`chrome-extension/STORE.md` is the owner's checklist; the privacy policy
  it needs is `/chrome-extension/privacy`). Chrome allows no silent install
  by a Mac app, and a forced-install policy would brand the browser "managed
  by your organization", so the store is the right path.
- Pairing is automatic: Settings › Install Chrome extension opens
  `nohandsapp.com/chrome-extension#code=<pairing code>`. A content script on
  that page alone reads the code from the URL fragment (which browsers never
  send to a server), stores it, and the extension reconnects announcing it.
  On install the background script injects the same script into an
  already-open setup tab, so no reload is needed. Covered by the Playwright
  smoke test.

## 2026-10-03 — Beta testers: ten free lifetime seats for real use and honest forms

Owner wants to promote on social media: 10 free seats in exchange for 5+
hours of use a month and one feedback form a month, for three months.

- `/testers` is the public application (name, email, what they do, their
  Mac, what they'd hand it first, two commitment checkboxes). It shows seats
  left, counted from accepted applications.
- `/admin › Beta testers` lists applications; **Accept** mints a free
  lifetime `beta` licence (same plan as the $99 offer), records it as a
  TESTER redemption, and emails the key with the install steps and the
  feedback-form link. Decline just marks it.
- `/testers/feedback` is the monthly form (hours, score, what worked, what
  broke, one wish), listed in admin. No login: the email they applied with
  is the key, which is enough for ten known people.
- The posts live in `marketing/beta-testers-posts.md`.
