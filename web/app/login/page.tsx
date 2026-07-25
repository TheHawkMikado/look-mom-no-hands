"use client";

import { useEffect, useState } from "react";
import { Lockup } from "@/components/Logo";

/** Messages for the ?error=… a failed callback redirects back with. */
const ERRORS: Record<string, string> = {
  expired: "That sign-in link has expired or was already used. Request a new one.",
  missing: "That link was incomplete. Request a new one.",
  failed: "Something went wrong signing in. Try again.",
  google: "Google sign-in didn't complete. Try again.",
  google_state: "Google sign-in expired before it finished. Try again.",
  google_unconfigured: "Google sign-in isn't set up yet.",
  apple: "Apple sign-in didn't complete. Try again.",
  apple_state: "Apple sign-in expired before it finished. Try again.",
  apple_unconfigured: "Apple sign-in isn't set up yet.",
};

/**
 * Sign-in. One field, because the address used at checkout is the only identity
 * we hold — there is nothing else to ask for.
 */
export default function Login() {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "sending" | "sent">("idle");
  const [error, setError] = useState("");
  const [devLink, setDevLink] = useState("");

  // A failed sign-in callback bounces back here with ?error=… — surface it.
  // Read from window rather than useSearchParams to avoid a Suspense boundary.
  useEffect(() => {
    const code = new URLSearchParams(window.location.search).get("error");
    if (code) setError(ERRORS[code] ?? "Couldn't sign you in. Try again.");
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setState("sending");
    setError("");
    try {
      const res = await fetch("/api/auth/request", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error ?? "Couldn't send the link.");
        setState("idle");
        return;
      }
      if (data.devLink) setDevLink(data.devLink);
      setState("sent");
    } catch {
      setError("Network error — try again.");
      setState("idle");
    }
  }

  return (
    <div className="wrap">
      <div className="receipt">
        <p style={{ marginBottom: 28 }}>
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </p>

        {state === "sent" ? (
          <>
            <h1 style={{ fontSize: 30 }}>Check your email</h1>
            <p style={{ color: "var(--muted)" }}>
              If <strong>{email}</strong> has an account, a sign-in link is on its way.
              It works once and expires in 20 minutes.
            </p>
            {devLink && (
              <p style={{ marginTop: 20, fontSize: 13 }}>
                <a href={devLink}>Dev-only sign-in link</a>
              </p>
            )}
          </>
        ) : (
          <>
            <h1 style={{ fontSize: 30 }}>Sign in</h1>
            <p style={{ color: "var(--muted)", marginBottom: 24 }}>
              Use the email address you subscribed with — with Google, or a link we
              email you. No password to remember.
            </p>

            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              <a
                className="btn btn-ghost"
                href="/api/auth/google"
                style={{ width: "100%", justifyContent: "center", gap: 10 }}
              >
                <GoogleG />
                Continue with Google
              </a>
              <a
                className="btn btn-ghost"
                href="/api/auth/apple"
                style={{ width: "100%", justifyContent: "center", gap: 10 }}
              >
                <AppleLogo />
                Continue with Apple
              </a>
            </div>

            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 12,
                color: "var(--muted)",
                fontSize: 13,
                margin: "18px 0",
              }}
            >
              <span style={{ flex: 1, height: 1, background: "var(--line, #e6e2d8)" }} />
              or
              <span style={{ flex: 1, height: 1, background: "var(--line, #e6e2d8)" }} />
            </div>

            <form onSubmit={submit} style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
              <input
                type="email"
                required
                autoFocus
                placeholder="you@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="field"
                style={{ flex: "1 1 240px" }}
              />
              <button className="btn btn-primary" disabled={state === "sending"}>
                {state === "sending" ? "Sending…" : "Email me a link"}
              </button>
            </form>
            {error && <p className="err">{error}</p>}
          </>
        )}

        <p style={{ marginTop: 40 }}>
          <a className="btn btn-ghost" href="/">
            Back to nohandsapp.com
          </a>
        </p>
      </div>
    </div>
  );
}

/** Google's four-colour "G", inline so there's no asset to load or CSP to widen. */
function GoogleG() {
  return (
    <svg width="17" height="17" viewBox="0 0 18 18" aria-hidden="true">
      <path
        fill="#4285F4"
        d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92c1.7-1.57 2.68-3.88 2.68-6.62z"
      />
      <path
        fill="#34A853"
        d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.8.54-1.84.86-3.04.86-2.34 0-4.32-1.58-5.02-3.7H.96v2.34A9 9 0 0 0 9 18z"
      />
      <path
        fill="#FBBC05"
        d="M3.98 10.72a5.4 5.4 0 0 1 0-3.44V4.94H.96a9 9 0 0 0 0 8.12l3.02-2.34z"
      />
      <path
        fill="#EA4335"
        d="M9 3.58c1.32 0 2.5.46 3.44 1.35l2.58-2.58C13.47.9 11.43 0 9 0A9 9 0 0 0 .96 4.94l3.02 2.34C4.68 5.16 6.66 3.58 9 3.58z"
      />
    </svg>
  );
}

/** Apple logo, inline (currentColor so it matches the button text). */
function AppleLogo() {
  return (
    <svg width="15" height="17" viewBox="0 0 14 17" fill="currentColor" aria-hidden="true">
      <path d="M11.62 8.87c-.02-1.9 1.55-2.8 1.62-2.85-.88-1.29-2.26-1.47-2.75-1.49-1.17-.12-2.28.69-2.87.69-.59 0-1.5-.67-2.47-.65-1.27.02-2.44.74-3.1 1.87-1.32 2.3-.34 5.7.95 7.56.63.91 1.38 1.93 2.36 1.9.95-.04 1.31-.61 2.46-.61 1.14 0 1.47.61 2.47.59 1.02-.02 1.66-.93 2.29-1.85.72-1.06 1.02-2.08 1.03-2.14-.02-.01-1.97-.76-1.99-3.01l.47-.35zM9.7 3.29c.52-.63.87-1.51.78-2.39-.75.03-1.66.5-2.2 1.13-.48.55-.9 1.44-.79 2.29.84.06 1.69-.42 2.21-1.03z" />
    </svg>
  );
}
