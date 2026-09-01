import { NextResponse } from "next/server";

/**
 * GET /api/version — the update manifest the desktop app polls.
 *
 * Deliberately dependency-free: no database, no Stripe, no auth. An update check
 * must succeed even when everything else is down, and it must not leak who is
 * running the app, so this reveals nothing and needs nothing. The app compares
 * the returned `version` against its own bundle version and shows a nudge if it
 * is behind — it never auto-downloads.
 *
 * Driven by env vars so a release is a Vercel config change, not a code deploy:
 * cut the DMG, upload it, bump LATEST_APP_VERSION, done.
 */

export const runtime = "nodejs";

export async function GET() {
  const site = process.env.SITE_URL ?? "https://nohandsapp.com";

  const body = {
    // Latest version, as V#.##.YYMMDD.COMMIT ("0.04.260901.a1b2c3d") — set it
    // to the FULL version release.sh prints, commit included: the app orders
    // on the first three components and treats the commit as an identity, so a
    // value pasted without the commit makes a same-day respin invisible to
    // every installed copy. The fallback predates the scheme and can only
    // under-report (nags nobody).
    version: process.env.LATEST_APP_VERSION ?? "0.1.0",
    // Where the app sends the user to get it. The GitHub "latest release" page
    // is a good default — it always points at the newest DMG.
    download_url:
      process.env.NEXT_PUBLIC_DOWNLOAD_URL ??
      "https://github.com/TheHawkMikado/look-mom-no-hands/releases/latest",
    // Direct DMG asset for the in-app one-click updater. Computed from the
    // version because the release script's asset naming is frozen
    // (LookMaNoHands-<version>.dmg under tag v<version>); override with
    // LATEST_APP_DMG_URL if hosting ever moves. Absent (null) on old manifests
    // → the app falls back to the download page.
    dmg_url:
      process.env.LATEST_APP_DMG_URL ??
      (process.env.LATEST_APP_VERSION
        ? `https://github.com/TheHawkMikado/look-mom-no-hands/releases/download/v${process.env.LATEST_APP_VERSION}/LookMaNoHands-${process.env.LATEST_APP_VERSION}.dmg`
        : null),
    // Optional human-readable "what's new", shown under the nudge. Blank is fine.
    notes: process.env.LATEST_APP_NOTES ?? "",
    // The oldest version still allowed to run. Lets you force an upgrade if a
    // release has a security fix or a breaking server-contract change. The app
    // treats "you are below this" as a hard prompt rather than a soft nudge.
    minimum_version: process.env.MINIMUM_APP_VERSION ?? "0.0.0",
    site,
  };

  return NextResponse.json(body, {
    headers: {
      // Cache at the edge for 5 minutes: the app polls at most a few times a
      // day, and this keeps a launch-day spike off the function.
      "Cache-Control": "public, s-maxage=300, stale-while-revalidate=600",
    },
  });
}
