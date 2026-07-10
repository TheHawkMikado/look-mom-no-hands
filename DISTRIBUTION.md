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

> Notarization requires full **Xcode** (for `notarytool`/`stapler`). You currently
> have only Command Line Tools — installing Xcode from the App Store covers this.
> The universal *build* itself works fine on Command Line Tools.

## Where to host the download

Once you have the `.dmg`, host it anywhere static: GitHub Releases (simplest —
attach the DMG to a tagged release), an S3/R2 bucket, or your own site. Notarized
DMGs pass Gatekeeper regardless of where they're downloaded from.

## Note: every user brings their own API key

The app calls the Anthropic API with a key each user enters in the panel (stored
in their Keychain). You are **not** shipping your key. If you'd rather users not
need their own Anthropic account, you'd front the API with your own backend and
bill/meter it — a larger change, not part of this build.
