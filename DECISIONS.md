# Decisions

Non-obvious architectural choices, newest first. Every entry: date, the
decision, and why. The spec (SPEC.md §0) asks for this file; the rule is that
anything a future reader might reasonably ask "why on earth?" about goes here.

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
