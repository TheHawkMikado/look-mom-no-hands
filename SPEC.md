# Look Ma, No Hands — Build Spec

**Owner:** Hawk Mikado · **Version:** 0.2 (Sept 2026) · **Source:** the Cowork
build brief (v0.1), reconciled against the code that already exists in this
repo. Where v0.1 and the codebase disagreed, the resolution is recorded in
DECISIONS.md and summarised in §0.1 below.

This is the master brief. Read it first, then work one phase at a time (§9).
Each phase ends with a demo that must pass before the next phase starts.

-----

## 0. How to use this document

- §1 (Product Thesis) and §3 (Non-Negotiable Principles) are the constitution.
  When a design choice is ambiguous, resolve it in their favour.
- Work **one phase at a time**. Each phase ends with a demo script.
- Log every non-obvious architectural choice in `DECISIONS.md` with the date
  and reason.
- `MODEL_ROUTING.md` is the living routing table (§7). Never hardcode a model
  inside a feature; always go through the router.
- Do not build execution capabilities Paperclip already provides. Integrate.
- Every feature that spends money, messages a human, publishes content, or
  changes data outside our own database goes through the Approval Gate (§6).
  No exceptions, including in dev.
- `SYSTEM-REQUIREMENTS.md` states what each machine role needs. Keep it true.

### 0.1 Reconciliation with the existing codebase (what changed from v0.1)

| v0.1 said | v0.2 does | Why (see DECISIONS.md) |
|---|---|---|
| Tauri/Electron desktop app | Keep the native Swift Mac app | It already does most of Phase 1; a rewrite loses on-device speech + Accessibility |
| Phone as PWA | Keep the Expo native app | Background audio and push need native; it already has push-to-talk and approval cards |
| Supabase + Upstash | Existing Postgres over a connection string; Vercel cron | Stripe, auth, licensing, secrets already live there; no vendor SDK needed |
| Paperclip required | Paperclip optional, removable, default local Docker | Owner wants cloud only by choice; fast path must not depend on it |
| "Not a voice-control-for-your-keyboard app" | Screen control stays as the **Local Runner** capability, tier-gated | It is the one execution path nothing else provides; demoted from identity, not removed |
| Monorepo with new packages | One repo, three surfaces: `Sources/` (Mac), `mobile/` (phone), `web/` (service) | They exist and ship |

-----

## 1. Product Thesis

**One sentence:** No Hands is a voice-first chief of staff that is with you
wherever you are, listens, figures out what needs to be done, and gets it
done — by agents first, other humans second, and you only as a last resort.

**What the user actually does in the app (only two things):**

1. **Talk to it** (or type). "Book me a table for four at seven." "Put out a
   blog post about this." "Call a tow truck." "What's outstanding from
   yesterday's meeting?"
2. **Let it sit in the room.** Start a live session in a meeting, run the
   introduction ritual so it learns who's who, and let it capture, extract and
   triage everything that comes out of the conversation.

Everything else — task graphs, agents, budgets, approvals, memory — lives
behind those two surfaces. The user should never have to open a board, a
dashboard or a settings screen to get value.

**Who it's for (v1):** Hawk. Then a small cohort of founder/operators who run
multiple things and are their own bottleneck. Do not design for enterprise.

**Why it wins:** Grok Bot, Claude Cowork and Paperclip all execute. Plaud and
Limitless listen. None combine (a) always-with-you presence, (b) identity-
aware voice, (c) a private brain that never leaves your device, and (d)
reverse-order delegation that treats the user as the last resort. No Hands is
the front door those tools don't have.

**Speed is a feature.** Spoken request → spoken confirmation in under 5 s.
Anything on that path runs on-device or as one short model call. Delegation,
drafting and follow-up happen after the confirmation, never before it.

-----

## 2. What No Hands Is NOT

- Not primarily a voice-control-for-your-keyboard app. Screen control remains
  as the Local Runner (§4.1) but is no longer the product's identity.
- Not a cloud agent farm. Execution is delegated to Paperclip, cloud sandboxes
  or local runners; No Hands does not compete on agent infrastructure.
- Not a project-management tool the user looks at. The bot holds the state
  and initiates; the human only answers.
- Not a hardware product in v1. Wearables come via integrations first.
- Not an "everything app" at launch. Front door and meeting loop at an A grade
  before anything else.

-----

## 3. Non-Negotiable Principles

1. **Reverse-order delegation.** For every action item: can an agent do it? If
   not, can another human on the team? Only then does it reach the user, and
   only as a decision or approval, never as a task.
2. **The bot initiates, the human answers.** Follow-ups, nudges and status come
   to the user by voice at the right moment.
3. **Two brains, hard wall between them.** Local Brain (personal, private,
   on-device) and Shared Brain (generic processes, routing scores, SOPs).
   Nothing crosses from Local to Shared without the promotion pipeline (§8)
   and explicit consent.
4. **Blast-radius approvals.** Draft freely. Ask before publishing. Require
   spoken/explicit approval before spending money or contacting a third party.
   Thresholds are user-configurable; defaults are conservative.
5. **Every task carries a receipt.** Who asked, who did it, which model, what
   it cost, what changed.
6. **Reliability over breadth.** A feature ships when it works every time.
7. **Multi-model by design, eval-driven routing.** No model is privileged.
8. **Consent is built into the ritual.** Recording a meeting begins with a
   spoken consent line. Design for all-party-consent states.
9. **Fast path first.** No network round trip to a control plane before the
   user hears the confirmation.

-----

## 4. System Architecture

### 4.1 Components

```
PRESENCE LAYER (where the user is)
├─ Mac app (Sources/) — always-on, on-device speech, Local Brain host, Local Runner
├─ Phone app (mobile/) — push-to-talk, approvals, activity
└─ Wearable ingest (Phase 6) — Plaud / Limitless → audio in
        │ audio / text / events
CORE (web/ on Vercel + Mac-resident pieces)
├─ Speech pipeline (Mac): STT, wake, speaker ID, diarization (Phase 2)
├─ Intent & extraction: utterance → Task via the router
├─ Triage engine: reverse-order delegation + blast-radius tiers
├─ Approval Gate: tiers, pending approvals, voice/push prompts, receipts
├─ Follow-up engine (Phase 3): check-ins, nudges, escalation by voice
├─ Model router: routing_scores, served to clients
└─ Memory: Local Brain (Mac, private) + Shared Brain (cloud, generic)
        │ dispatch
EXECUTION LAYER (delegated)
├─ Paperclip (optional, self-hosted or VPS): agent org, tasks, budgets, gates
├─ Local Runner (Mac): apps, URLs, clicks, keystrokes, files, AppleScript
│   └─ Browser Runner (Chrome-family extension): ref-based page snapshot,
│      click/type/select/wait by ref; paired over loopback (DECISIONS 2026-09-15)
├─ Outbound voice (Phase 3): calls to humans
├─ Cloud sandbox agents (via Paperclip adapters): long unattended jobs
└─ Human tickets: tasks assigned to team members (email/SMS/GHL)
```

### 4.2 Deployment shape

- **Mac app** — native Swift menu-bar app. Hosts the Local Brain (on-disk
  store under `~/Library/Application Support/LookMaNoHands/`, encrypted-at-
  rest key in Keychain from Phase 1), the always-on mic pipeline and the Local
  Runner. The only place personal content is stored at rest.
- **Web service** — Next.js on Vercel, plain Postgres. Hosts the Shared Brain,
  the router, the Approval Gate, the triage engine, the sync API and billing.
  Stores no personal content: task titles, statuses, owners, receipts, routing
  scores, promoted SOPs.
- **Phone** — Expo app. Push-to-talk, approvals, activity. Holds only a subset
  (recent tasks, pending approvals).
- **Paperclip** — Docker on the owner's Mac or PC by default
  (`Scripts/paperclip/up.sh`); a small VPS when it must run while the Mac
  sleeps. The connection is a per-account setting the user can delete.

### 4.3 Data residency rule (enforced in code)

- Raw audio, transcripts, contact details, financials, anything about the
  user's life: **Local Brain only.**
- Task titles, statuses, owners, receipts, routing scores, promoted SOPs: cloud.
- Every stored object carries `residency: 'local' | 'cloud'`. The sync layer
  refuses to upload any object tagged local. `web/lib/residency.ts` is the one
  choke point for cloud writes and `web/lib/residency.test.ts` fails the test
  run if a local object reaches it.

-----

## 5. Core Flows

### 5.1 Direct request ("talk to it")

1. Wake (push-to-talk on phone; wake word or hotkey on Mac; text fallback).
2. Speaker verification against the enrolled owner voiceprint (Phase 1). Not
   the owner → ignore, or "I only take instructions from Hawk" if addressed.
3. STT → intent: question | task | decision | note | smalltalk.
4. Task: extraction → structured Task (§10) → Triage (5.3) → one-sentence
   spoken confirmation ("I'll have the content agent draft that and bring it
   to you by 3.").
5. Question: answer from Local Brain + Shared Brain + tools. Never ask what
   the brain already knows.
6. Receipt.

### 5.2 Live meeting session ("let it sit in the room") — Phase 2

1. Consent line spoken or displayed.
2. Introduction ritual: enrol each attendee's voiceprint; returning attendees
   recognised automatically.
3. Live diarized transcript, local-first.
4. Continuous extraction: action items, decisions, open questions, commitments.
5. End of session → triage pass → spoken summary: what agents took, what went
   to which human, what needs the user.
6. Human tickets sent to attendees with the user's approval tier applied.

### 5.3 Triage engine (reverse-order delegation)

For each extracted Task:

1. **Agent-capable?** Match against the connected Paperclip company's agents
   (role, capabilities) and Local Runner capabilities. Confident match →
   Paperclip issue with owner = agent, budget from the request or default
   tier, review gate per blast radius. No Paperclip connection → skip.
2. **Else human-team-capable?** Match against Person records (Local Brain,
   Phase 2). Clear owner → human ticket + follow-up.
3. **Else user.** Reaches the user only as a decision or approval, phrased as
   a question with a default.
4. Every path attaches a blast-radius tier (§6) and a receipt.

### 5.4 Follow-up engine (the bot initiates) — Phase 3

- Every task has `due_at`, `check_in_at`, `escalate_at`.
- Cron wakes on `check_in_at`; not done → nudge the owner.
- On `escalate_at`, bring it to the user by voice at a good moment (not mid-
  meeting; respects Do Not Disturb), as one question with a default.
- Daily "what's outstanding" on demand and at a user-set time.

### 5.5 Outbound calls — Phase 3

Provider TBD (Vapi/Retell vs Twilio + realtime model). Free actions
(reservations) auto-execute at tier 1; paid actions require tier 3 approval
before the call commits.

-----

## 6. Approval Gate and Blast-Radius Tiers

| Tier | Examples | Default behaviour |
|---|---|---|
| 0 — Internal | Drafts, research, summaries, memory writes | Auto |
| 1 — Reversible external, no money | Reservations, calendar holds, internal notes | Auto, notify after |
| 2 — Public or team-facing | Publish blog/social, email a team member a task, update site copy | Ask (voice or push), batchable |
| 3 — Money or third-party commitment | Pay for anything, sign up for a service, commit a vendor, email a client | Explicit spoken/typed approval, per item |
| 4 — Irreversible / high stakes | Delete data, cancel contracts, legal/financial above ceiling | Explicit approval + confirmation phrase |

- Budgets: a project carries a hard cap; every child task draws from it.
  Paperclip enforces per-agent; No Hands enforces per-project. 80% → check-in.
- Approvals are voice-native and speaker-verified (Phase 1). Push with one-tap
  approve is the fallback and is what Phase 0 ships (the phone app's existing
  approval cards).
- Tier 3+ approvals originating from a meeting session require a phone push in
  addition to voice (Phase 2).

-----

## 7. Model Router

See `MODEL_ROUTING.md` for the current table. Task types: stt, diarization,
speaker_id, intent_classify, task_extract, summarize_meeting,
draft_copy_short, draft_copy_long, research_synthesize, code_change,
image_prompt, call_agent_realtime, triage_decision.

- Routing table = `routing_scores` (task_type, model, provider, score,
  cost_per_1k, latency_p50, last_evaluated_at), seeded from
  `web/lib/routing-seed.ts`, served at `GET /api/app/routing`.
- Selection: highest score above the quality floor, tie-break on cost, then
  latency. Latency-first task types invert the tie-break.
- Phase 4 adds eval sets per task type and a weekly eval job.
- Scores are generic → Shared Brain.

-----

## 8. Memory

### 8.1 Local Brain (Mac, private)
People (with voiceprints), preferences, commitments, facts, transcripts,
receipts with detail. Readable markdown-style context files plus an index.
The phone syncs a subset. Phase 1 formalises what today lives across the
knowledge, vocabulary, element-memory and transcript stores.

### 8.2 Shared Brain (cloud, generic)
SOP templates, skill definitions, routing scores, capability maps. Zero
personal data by construction (§4.3).

### 8.3 Promotion pipeline (Phase 4)
Classifier flags generic learnings → scrubber replaces specifics → user asked
once by voice, default no → review queue → versioned publish attributable to
a source user id only.

-----

## 9. Build Phases

**Status (2026-09-13):** every phase below has a first implementation on
`main`. What is real code and what still needs a credential or a device:

| Phase | Built | Needs from the owner |
|---|---|---|
| 0 Foundation | tasks, tiers, gate, router, Paperclip (direct + bridge), receipts, team boards | — |
| 1 Voice front door | speaker enrolment + verification (on-device model), delegation from the planner, spoken confirmation, Local Brain, router client, rollback | enrol your voice once in Settings › Voice identity |
| 2 Meeting loop | consent line, introduction ritual, diarized transcript, extraction, triage, spoken summary, human tickets | GoHighLevel key for SMS; Resend for email |
| 3 Follow-ups + calls | check-ins, nudges, escalation by voice at a good moment, daily brief, push, outbound calls | Vapi key + number for calls; phone push credentials (EAS) |
| 4 Evals + Shared Brain | fixtures, eval runner, weekly cron, scrubber, consent, admin review, SOP API | an Anthropic key for model candidates and the judge |
| 5 Ad process | intake with a budget cap, project + 7 step issues in Paperclip, 80% check-in, spend cap | your real ad steps replacing the generic template |
| 6 Wearables + hardening | Limitless ingest, quiet hours, lock/meeting-aware speaking, outbox, meeting-approval channel rule | Limitless API key; Plaud when their API allows |



### Phase 0 — Foundation
- SPEC.md, DECISIONS.md, MODEL_ROUTING.md, SYSTEM-REQUIREMENTS.md.
- Web schema (§10) with residency + build-failing test.
- Approval Gate with tiers and receipts, reusing the phone's approval cards.
- Router with seeded `routing_scores`, served to clients.
- Paperclip: one-command local install, one-command bootstrap (company,
  Content Drafter, Researcher, API key, connection registered), connection
  add/remove API. Task intake → extraction → triage → Paperclip issue →
  draft → approval → receipt.
- **Demo:** POST a text task → triage → Paperclip task created → agent drafts
  → approval requested → approved on the phone → receipt visible.

### Phase 1 — Voice front door
Mac: owner voiceprint enrolment + verification (PLAN-SPEAKER-VERIFICATION.md);
intent classification on utterances; the Mac's planner calls the task intake
instead of only the screen planner; spoken confirmation; the Mac reads the
router instead of hardcoding models; Local Brain formalised. Phone: unchanged
except push for approvals.
**Demo:** "have the content agent draft a post about X and bring it to me" on
the Mac → task in Paperclip → draft → approval on the phone → approve → receipt.

### Phase 2 — Live meeting loop
Consent line, introduction ritual, per-attendee voiceprints, diarized live
transcript, continuous extraction, end-of-meeting triage, voice summary,
human tickets via email/SMS.
**Demo:** real 20-minute meeting with two other people; ≥90% of action items
captured and correctly triaged.

### Phase 3 — Follow-up engine + outbound calls
Cron check-ins, nudges, escalation by voice at a good moment; outbound call
agent with a tier-1 and a tier-3 flow.

### Phase 4 — Eval-driven router + Shared Brain
Eval sets per task type, weekly eval job, promotion pipeline.

### Phase 5 — First real business workflow
Hawk's multi-model ad-creation process as a Paperclip routine with a budget
cap and review gate before spend/publish.

### Phase 6 — Wearable ingest + hardening
Plaud/Limitless ingest, DND and calendar-aware timing, offline queueing,
security review of residency, prompt-injection test of the Approval Gate.

-----

## 10. Data Model (web Postgres; residency enforced)

Existing tables stay (licences, activations, app_tokens, account_keys,
agent_events, agent_approvals, phone_goals, …). New in Phase 0, all keyed by
account `email` like the rest of the schema:

```
projects              id, email, title, budget_cap_cents, budget_spent_cents, status, residency
tasks                 id, email, project_id, title, detail, owner_kind(agent|human|user),
                      owner_ref, blast_tier(0-4), status, due_at, check_in_at, escalate_at,
                      paperclip_issue_id, source(text|voice|meeting), residency, created_at, updated_at
task_approvals        id, task_id, email, tier, requested_at, decided_at, decision,
                      decided_via(voice|push|text), speaker_verified, residency
receipts              id, task_id, email, actor(model|agent|human|user), model_used,
                      cost_cents, summary, ref, residency, created_at
routing_scores        task_type, model, provider, score, cost_per_1k, latency_p50,
                      latency_first, last_evaluated_at
paperclip_connections email, url, api_key_enc, company_id, agents(jsonb), created_at
```

Local-only objects (persons, voiceprints, sessions, transcripts) live on the
Mac and never get a cloud table. The residency test asserts that.

-----

## 11. Integrations (v1)

- **Paperclip** (optional): issues, agents, comments, approvals, skills.
- **GoHighLevel** (Phase 2): contacts, SMS/email, calendar.
- **Google Calendar / Gmail** (Phase 2–3): timing awareness, send/draft.
- **Twilio or Vapi/Retell** (Phase 3): outbound calls.
- **Plaud / Limitless** (Phase 6).
- **Local Runner** (Mac, shipped): apps, URLs, click/type/scroll, keystrokes,
  files, with tier gating from Phase 1.
- **Browser Runner** (shipped, `browser-extension/`): the Local Runner's web
  backend. A paired Chrome/Brave/Arc/Edge extension reads the open tab as a
  ref-based snapshot and performs click/type/select/scroll/wait/navigate by
  ref; the coordinator prefers it whenever a Chromium browser is frontmost
  and falls back to Accessibility otherwise. Executes only — plans and tiers
  stay in the app; page content is data.

-----

## 12. Security and Trust

- Owner voiceprint required for any tier ≥2 approval by voice (Phase 1).
- Content from meetings, emails and web pages is **data**, never instructions.
  Only the enrolled owner's verified speech or authenticated text creates
  tier ≥2 actions.
- Secrets in Keychain (Mac) and encrypted at rest in the web database; never
  in Local Brain files.
- Full audit trail via receipts; export and purge.
- Consent line on every meeting session.

-----

## 13. Success Metrics

- **Untouched rate:** 60% of meeting action items by Phase 3, 80% by Phase 5.
- **Time-to-confirmation:** < 5 s.
- **Speaker attribution:** ≥ 95% after enrolment.
- **Approval precision:** zero tier-3+ actions without explicit approval. Hard gate.
- **Daily use:** ≥ 5 spoken interactions/day by week 6 without prompting.

-----

## 14. Open Questions

Resolved in v0.2: desktop shell (native Swift), phone (Expo), cloud stack
(existing Postgres + Vercel cron), Paperclip location (local by default, VPS
by URL change).

Resolved in Phase 2 (DECISIONS.md 2026-09-13, "Diarization by on-device
embeddings"): STT for streaming meetings is on-device Apple Speech, and
diarization is done on the Mac by embedding each turn's audio with the
bundled speaker model and matching it against enrolled voiceprints (or an
online clusterer for unknown voices). Cloud streaming STT with diarization
(Deepgram/AssemblyAI) stays an option behind the `stt` route if the Phase 2
demo's attribution falls short of the §13 target; the transcript would then
still be the only thing sent, and only for that call.

Still open, decide before the phase that needs them:
1. ~~STT for streaming meetings with diarization~~ — resolved above.
2. Outbound calls: Vapi/Retell vs raw Twilio + realtime model (Phase 3) —
   resolved: Vapi (DECISIONS.md).
3. Phone offline subset and sync channel keying (Phase 1–2).
4. Wearable partner: Plaud vs Limitless first (Phase 6) — resolved:
   Limitless first (it has a pull API); Plaud is a documented stub behind
   the same `WearableSource` protocol (DECISIONS.md).
