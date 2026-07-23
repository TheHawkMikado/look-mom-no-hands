"use client";

import { useState } from "react";
import { Lockup } from "@/components/Logo";

/**
 * Sign-in. One field, because the address used at checkout is the only identity
 * we hold — there is nothing else to ask for.
 */
export default function Login() {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "sending" | "sent">("idle");
  const [error, setError] = useState("");
  const [devLink, setDevLink] = useState("");

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
              Use the email address you subscribed with. We&rsquo;ll send a link — no
              password to remember.
            </p>
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
