# Look Ma, No Hands — mobile companion

Push-to-talk voice remote for the macOS agent. Hold the mic, speak a task,
release — it lands on your Mac via nohandsapp.com and the phone reads the
result back when the Mac finishes. Approve or deny agent commands from the
Talk screen.

## Stack

Expo SDK 57 / React Native 0.86 / TypeScript strict. Bottom tabs via
`@react-navigation/bottom-tabs`. Speech-to-text via `expo-speech-recognition`
(on-device engines; replaced `@react-native-voice/voice`, whose result events
never arrived on RN 0.86), text-to-speech via `expo-speech`, token + offline
queue storage via `expo-secure-store`, push via `expo-notifications`.

## Layout

```
App.tsx                          auth gate, deep-link capture, providers, tab navigator
src/navigation.ts                tab param list + navigation ref (push taps navigate through it)
src/theme.ts                     colors + spacing (dark, one accent #7C5CFF)
src/lib/api.ts                   typed client for nohandsapp.com (bearer, 401 -> signed out)
src/lib/auth.ts                  browser sign-in, nohands://auth?token=... parsing, secure storage
src/lib/device.ts                per-install device id + POST /api/app/device (with push token)
src/lib/push.ts                  expo-notifications permission/token/channel/foreground handler
src/lib/notificationData.ts      pure push payload -> approval/prompt target (tested)
src/lib/goalQueue.ts             pure offline goal queue: ordered flush, retry/drop rules (tested)
src/lib/goalQueueStorage.ts      SecureStore adapter for the queue (one key per goal)
src/lib/taskGroups.ts            pure status -> "Your call / Needs approval / Working / Done" (tested)
src/lib/clock.ts                 HH:MM validation for quiet hours / daily brief (tested)
src/lib/pttMachine.ts            pure hold/slide/lock state machine (tested)
src/lib/wake.ts                  pure "hey mama" wake-phrase matching (tested)
src/lib/time.ts                  relative timestamps
src/hooks/useSpeechRecognition.ts  voice engine lifecycle + continuous-mode restarts; routes
                                 results to whichever consumer started the engine last
src/state/GoalQueueContext.tsx   the queue: flush on foreground, on feed success, every 15 s
src/state/FeedContext.tsx        5s feed polling, TTS for done/failed, approvals
src/state/TasksContext.tsx       tasks + prompts, 15 s outstanding poll for the tab badge
src/state/AuthContext.tsx        sign-out plumbing
src/components/PushBridge.tsx    registers device+token, foreground refresh, notification taps
src/components/PromptCard.tsx    a question: accept the default in one tap, or type/dictate
src/components/DictateButton.tsx hold-to-dictate into a text field
src/components/TaskListRow.tsx, MemberCard.tsx, StatusPill.tsx, ApprovalCard.tsx
src/screens/TalkScreen.tsx       mic button, slide-to-lock, approval cards, "queued" banner
src/screens/TasksScreen.tsx      prompts on top, grouped task list, request composer
src/screens/TaskDetailView.tsx   one task: open approval (approve/deny), result, receipts
src/screens/TeamScreen.tsx       every member's board (bots + humans), 10 s poll while visible
src/screens/ActivityScreen.tsx   feed list
src/screens/SettingsScreen.tsx   account, push toggle, tz, quiet hours, daily brief, sign out
src/screens/SignInScreen.tsx     browser sign-in entry
```

## Running

```
npm install
npm run typecheck   # tsc --noEmit
npm test            # jest (pttMachine, wake, goalQueue, taskGroups, notificationData, clock)
```

Then `npx expo run:ios` / `npx expo run:android` (or an EAS dev build).

## Dev build required — not Expo Go

`expo-speech-recognition` ships native code, so speech recognition only
works in a development build (`npx expo prebuild` + `expo run:*`, or EAS).
Everything else (sign-in, feed, approvals, TTS, tasks, team, settings, the
offline queue) works in Expo Go.

## Push notifications

The phone registers for push on sign-in (system permission prompt on first
run) and sends its Expo push token with `POST /api/app/device`
(`{ device, version, pushToken, platform }`). The server pushes approvals
with `data: { approvalId }` and questions with `data: { promptId }`:

- tap on an approval push → Talk tab (the approval card is there);
- tap on a prompt push → Tasks tab with that question highlighted;
- a push that arrives while the app is open refreshes the feed and prompts.

Settings → "Push notifications" toggles `push_enabled` on the account and
re-registers the device with (or without) its token.

### Credentials

- **Expo Go, iOS** — works with no credentials: Expo's own APNs setup
  delivers to Expo Go. The one thing needed is an EAS project id so
  `getExpoPushTokenAsync` can mint a token: run `eas init` once (it writes
  `extra.eas.projectId` into `app.json`). Without it the app silently falls
  back to polling.
- **Expo Go, Android** — remote push was removed from Expo Go in SDK 53;
  use a development build.
- **Development / production builds (EAS)** —
  - iOS: an **APNs key** (.p8, from the Apple Developer portal under Keys,
    with the Apple Push Notifications service enabled). `eas credentials`
    (or the first `eas build`) uploads it; Expo's push service signs with
    it. Team id is already in `app.json` (`ios.appleTeamId`).
  - Android: an **FCM V1 service-account JSON** from the Firebase project
    that owns `com.nohands.mobile`, uploaded with
    `eas credentials` → Android → Google Service Account Key (for FCM V1),
    plus that project's `google-services.json` referenced from
    `android.googleServicesFile` in `app.json`.
- The **server** sends through Expo's push API
  (`https://exp.host/--/api/v2/push/send`) with the stored token; no
  APNs/FCM secrets live on the server. Enable "Enhanced Security for Push
  Notifications" on the Expo account and set the access token server-side
  if the project turns it on.

Simulators and emulators never receive remote push; the app registers the
device without a token there and keeps polling.

## Offline queue

Goals spoken or typed while offline (or when `POST /api/app/goals` fails
with a network error / 5xx / 429) are queued in SecureStore — one key per
goal, oldest first — and the Talk screen shows "Queued — will send when
online" plus a standing banner with the count. Delivery is strictly in
order: the queue stops at the first retryable failure; a goal the server
rejects outright (4xx) is dropped so it can't block what's behind it. A
flush is attempted on return to foreground, after every successful feed
poll (the cheapest "we're online" signal without a NetInfo dependency), and
every 15 s while anything is waiting. Once anything is queued, new goals
go behind it rather than straight to the network. `src/lib/goalQueue.ts`
is pure (storage and send injected) and covered by jest.

### Background listening caveats

Locked mode ("Hey Mama") is wired for foreground use. Keeping the mic hot with
the screen off needs native work that config alone cannot provide:

- **iOS** — `UIBackgroundModes: ["audio"]` is declared in `app.json`, but
  `SFSpeechRecognizer` sessions still get suspended in the background unless an
  active `AVAudioSession` is maintained (native module or config-plugin work in
  the dev-build phase).
- **Android** — `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MICROPHONE`
  permissions are declared, but an actual foreground service (persistent
  notification) must be added in the dev-build phase; Expo config plugins do
  not create one. Until then, locked mode survives only while the app is
  foregrounded.

## API contract notes / assumptions

- All calls hit `https://nohandsapp.com` with `Authorization: Bearer <token>`.
- Sign-in opens `/app/login?client=mobile`; the site redirects to
  `nohands://auth?token=<bearer>`. Both delivery paths are handled:
  `openAuthSessionAsync`'s result (iOS) and a `Linking` URL event (Android).
- `approvalId` is treated as optional/nullable on non-approval events.
- Locked-mode goals are sent as normalized text (lowercased, punctuation
  stripped) since matching happens on the normalized transcript.
- The feed is assumed to be a reasonable window of recent events; the app
  tracks `lastSpokenId` in memory and, on first fetch of a session, marks the
  backlog as already spoken so launch is silent.
- Settings shows a "Connected" state instead of an email — the contract has no
  endpoint that returns the account email.
- `GET /api/app/tasks?limit=100` → `{ tasks }` (newest first) is grouped
  client-side: Your call = `needs_decision`; Needs approval =
  `awaiting_approval`; Working = `triaged | dispatching | in_progress |
  approved | assigned`; Done = `done | denied | failed`. Unknown statuses
  fall into Working. `GET /api/app/tasks/{id}` → `{ task, approvals,
  receipts }`; an approval row id is the same id the feed calls
  `approvalId`, so the detail view decides through
  `POST /api/app/approvals/decide`. `POST /api/app/tasks { text, source }`
  → `{ intent, confirmation, task }`; the confirmation is spoken and shown.
- `GET /api/app/tasks/outstanding` → `{ tasks }` feeds the Tasks tab badge
  (prompts + tasks in Your call / Needs approval), polled every 15 s.
- `GET /api/app/prompts` → `{ prompts: [{ id, question, default_answer,
  kind }] }` (a bare array is tolerated); `POST /api/app/prompts/{id}/answer
  { answer }`. Answering removes the card optimistically.
- `GET /api/app/team` → `{ members: [{ id, kind, name, title, status,
  items: [{ id, key, title, status, updated_at, source, tier }] }],
  unassigned, counts, captured_at, has_paperclip }`.
- `GET/POST /api/app/settings` → `{ tz, quiet_hours_start, quiet_hours_end,
  daily_brief_at, push_enabled }`; POST sends a partial patch; times are
  "HH:MM" 24-hour or null; the phone offers its own IANA zone when it differs.
- `POST /api/app/device { device, version, pushToken, platform }` — `device`
  is a random per-install id kept in SecureStore; `pushToken` is null when
  push is off/denied.
