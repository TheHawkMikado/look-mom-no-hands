# Look Ma, No Hands — mobile companion

Push-to-talk voice remote for the macOS agent. Hold the mic, speak a task,
release — it lands on your Mac via nohandsapp.com and the phone reads the
result back when the Mac finishes. Approve or deny agent commands from the
Talk screen.

## Stack

Expo SDK 57 / React Native 0.86 / TypeScript strict. Bottom tabs via
`@react-navigation/bottom-tabs`. Speech-to-text via `@react-native-voice/voice`
(on-device engines), text-to-speech via `expo-speech`, token storage via
`expo-secure-store`.

## Layout

```
App.tsx                          auth gate, deep-link capture, tab navigator
src/theme.ts                     colors + spacing (dark, one accent #7C5CFF)
src/lib/api.ts                   typed client for nohandsapp.com (bearer, 401 -> signed out)
src/lib/auth.ts                  browser sign-in, nohands://auth?token=... parsing, secure storage
src/lib/pttMachine.ts            pure hold/slide/lock state machine (tested)
src/lib/wake.ts                  pure "hey mama" wake-phrase matching (tested)
src/lib/time.ts                  relative timestamps
src/hooks/useSpeechRecognition.ts  voice engine lifecycle + continuous-mode restarts
src/state/FeedContext.tsx        5s feed polling, TTS for done/failed, approvals
src/state/AuthContext.tsx        sign-out plumbing
src/screens/TalkScreen.tsx       mic button, slide-to-lock, approval cards
src/screens/ActivityScreen.tsx   feed list
src/screens/SettingsScreen.tsx   connection state, server URL, sign out
src/screens/SignInScreen.tsx     browser sign-in entry
```

## Running

```
npm install
npm run typecheck   # tsc --noEmit
npm test            # jest (pttMachine + wake)
```

Then `npx expo run:ios` / `npx expo run:android` (or an EAS dev build).

## Dev build required — not Expo Go

`@react-native-voice/voice` ships native code, so speech recognition only
works in a development build (`npx expo prebuild` + `expo run:*`, or EAS).
Everything else (sign-in, feed, approvals, TTS) works in Expo Go.

### Background listening caveats

Locked mode ("Hey Mama") is wired for foreground use. Keeping the mic hot with
the screen off needs native work that config alone cannot provide:

- **iOS** — `UIBackgroundModes: ["audio"]` is declared in `app.json`, but
  `SFSpeechRecognizer` sessions still get suspended in the background unless an
  active audio session is maintained. See the TODO in
  `src/hooks/useSpeechRecognition.ts`.
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
