# Distributing "Look Ma, No Hands"

`./Scripts/package_release.sh` builds a universal (arm64 + x86_64) `.app` and a
drag-to-install `.dmg` at `build/LookMaNoHands-<version>.dmg`.

There are two tiers of "downloadable by anyone", and the difference is entirely
about Apple's Gatekeeper — not the build.

## Tier 1 — Unsigned (what you can ship today, free)

Run with no environment variables:

```sh
./Scripts/package_release.sh
```

The DMG works and installs, **but** because the app isn't notarized, the first
time a downloader opens it macOS blocks it with *"Apple could not verify … is
free of malware."* They get in by either:

- **Right-click the app → Open → Open** (one time), or
- `xattr -dr com.apple.quarantine "/Applications/Look Ma, No Hands.app"`

This is fine for yourself, friends, or testers. It is **not** a clean
"anyone double-clicks and it just works" experience.

## Tier 2 — Signed + Notarized (clean install for anyone, needs Apple Developer)

For a DMG that opens with no warnings on any Mac, you need:

1. An **Apple Developer Program** membership ($99/yr).
2. A **Developer ID Application** certificate (create in Xcode or the developer
   portal; it installs into your login keychain).
3. A **notarytool credential profile** stored once:

   ```sh
   xcrun notarytool store-credentials LookMaNotary \
       --apple-id you@example.com --team-id ABCDE12345 \
       --password <app-specific-password>   # from appleid.apple.com
   ```

Then package with both variables set:

```sh
SIGN_ID="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE="LookMaNotary" \
./Scripts/package_release.sh
```

The script signs with hardened runtime, submits the DMG to Apple, waits for the
ticket, and staples it. The result is a DMG anyone can download and open cleanly.

> `notarytool` and `stapler` both ship with the Command Line Tools (verified at
> notarytool 1.1.2) — full Xcode is not required for packaging or notarization.
> Xcode is still the easiest place to *create* the Developer ID certificate:
> Settings → Accounts → Manage Certificates → `+` → Developer ID Application.

## Not an option: the Mac App Store

Every App Store submission must set `com.apple.security.app-sandbox` to `true`.
This app sets it to `false` on purpose ([App/LookMomNoHands.entitlements](App/LookMomNoHands.entitlements)):
driving other applications means `AXUIElementCreateApplication` /
`AXUIElementPerformAction` against their accessibility trees plus `CGEvent`
posting, and the sandbox grants no entitlement for either. There is no
paperwork, price, or review-notes path around it — the capability simply does
not exist inside the sandbox.

This is why Keyboard Maestro, BetterTouchTool, Raycast, Alfred and Karabiner all
ship direct rather than through the store. Tier 2 above is the equivalent
experience: a notarized DMG opens with no warnings anywhere, and the Apple
Developer membership is what pays for it.

## Version numbers

`#.##.YYMMDD` — marketing version, then the release date:

```
0.02.260730
│    └── released 30 July 2026
└── second release
```

The app compares versions component-wise as numbers, so the date is just a third
component that only ever climbs. Two releases in one day are separated by the
marketing version (`0.02` → `0.03`), which outranks the date.

Every component must be numeric — the comparison reads anything else as `0`, so
a `0.02.260730-beta` would compare *equal* to `0.02.260730` and be invisible as
an update. `v0.1.0` predates the scheme and orders correctly below it (`[0,1,0]`
is behind `[0,2,260730]`), so no forced upgrade is needed to move onto it.

## Cutting a release installed apps can see

`package_release.sh` only produces a DMG. Getting that DMG in front of someone
who already has the app installed takes three more steps, and skipping any one
of them leaves every installed copy reporting "up to date" indefinitely:

| Step | What it is | Who reads it |
|---|---|---|
| `App/Info.plist` | `CFBundleShortVersionString` | the app, about itself |
| GitHub release | tag + attached DMG | `download_url` → `releases/latest` |
| `LATEST_APP_VERSION` | Vercel env var behind `/api/version` | **every installed app** |

`Scripts/release.sh` does all of it except the last (a Vercel env change flips
the update prompt on for everyone at once, so it stays a deliberate act):

```sh
SIGN_ID="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE="LookMaNotary" \
./Scripts/release.sh 0.02 --notes "What changed in this build."
```

You pass the marketing version; today's date is appended (`--date YYMMDD` to
override). It refuses to publish a version that doesn't compare *newer* than the
one in `Info.plist`, since that release would be invisible to every installed app.

It refuses to run from a dirty tree, off `main`, out of sync with `origin`, on
an existing tag, or without a stapled notarisation ticket. `--dry-run` builds
and tags locally without pushing or publishing; `--allow-unsigned` packages
without a Developer ID (recipients get the Gatekeeper block described above).

Afterwards, `curl -s https://nohandsapp.com/api/version` shows exactly what
installed apps will see. If `version` there still reads old, the release has
not happened as far as any user is concerned.

## Where to host the download

Once you have the `.dmg`, host it anywhere static: GitHub Releases (simplest —
attach the DMG to a tagged release), an S3/R2 bucket, or your own site. Notarized
DMGs pass Gatekeeper regardless of where they're downloaded from.

## Note: every user brings their own API key

The app calls the Anthropic API with a key each user enters in the panel (stored
in their Keychain). You are **not** shipping your key. If you'd rather users not
need their own Anthropic account, you'd front the API with your own backend and
bill/meter it — a larger change, not part of this build.
