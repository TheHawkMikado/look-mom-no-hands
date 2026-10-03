"use client";

import { useState } from "react";

const inputStyle = { marginTop: 6 } as const;

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="dim small" style={{ display: "block", textAlign: "left", marginTop: 14 }}>
      {label}
      {children}
    </label>
  );
}

async function post(url: string, data: Record<string, unknown>) {
  const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error ?? "Something went wrong.");
}

/** The beta-tester application. */
export function ApplyForm() {
  const [f, setF] = useState({ name: "", email: "", role: "", machine: "", use_case: "", social: "", commit_hours: false, commit_forms: false, website: "" });
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState("");
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setF({ ...f, [k]: e.target.type === "checkbox" ? (e.target as HTMLInputElement).checked : e.target.value });

  if (done) {
    return (
      <div className="panel-card" style={{ marginTop: 24 }}>
        <strong>Application in.</strong>
        <p className="dim small" style={{ margin: "6px 0 0" }}>
          Check your inbox for a confirmation. If you get a seat, the licence and install steps come by email.
        </p>
      </div>
    );
  }
  return (
    <form
      className="panel-card"
      style={{ marginTop: 24, textAlign: "left" }}
      onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true); setError("");
        try { await post("/api/beta/apply", f); setDone(true); } catch (err) { setError(err instanceof Error ? err.message : "Something went wrong."); }
        setBusy(false);
      }}
    >
      <Field label="Your name"><input className="field" style={inputStyle} required value={f.name} onChange={set("name")} /></Field>
      <Field label="Email (where the licence goes)"><input className="field" style={inputStyle} type="email" required value={f.email} onChange={set("email")} /></Field>
      <Field label="What do you do all day?"><input className="field" style={inputStyle} placeholder="Real estate investor, agency owner, founder…" value={f.role} onChange={set("role")} /></Field>
      <Field label="Your Mac (model + macOS version)"><input className="field" style={inputStyle} placeholder="MacBook Pro M2, macOS 15" value={f.machine} onChange={set("machine")} /></Field>
      <Field label="What would you hand it first?">
        <textarea className="field" style={inputStyle} rows={4} placeholder="The three things you'd most like to never do with your hands again." value={f.use_case} onChange={set("use_case")} />
      </Field>
      <Field label="Where can I find you? (optional)"><input className="field" style={inputStyle} placeholder="LinkedIn / X / Instagram" value={f.social} onChange={set("social")} /></Field>
      <input type="text" name="website" value={f.website} onChange={set("website")} style={{ display: "none" }} tabIndex={-1} autoComplete="off" />
      <label className="dim small" style={{ display: "flex", gap: 8, alignItems: "flex-start", marginTop: 16 }}>
        <input type="checkbox" checked={f.commit_hours} onChange={set("commit_hours")} />
        <span>I&rsquo;ll put in <strong>5+ hours a month</strong> of real use for three months.</span>
      </label>
      <label className="dim small" style={{ display: "flex", gap: 8, alignItems: "flex-start", marginTop: 8 }}>
        <input type="checkbox" checked={f.commit_forms} onChange={set("commit_forms")} />
        <span>I&rsquo;ll fill in <strong>one feedback form a month</strong>, three in total.</span>
      </label>
      <button className="btn btn-primary" disabled={busy} style={{ marginTop: 18, width: "100%" }}>
        {busy ? "Sending…" : "Apply for a seat"}
      </button>
      {error && <p className="err">{error}</p>}
    </form>
  );
}

/** The monthly feedback form. */
export function FeedbackForm({ month }: { month: string }) {
  const [f, setF] = useState({ email: "", month, hours: "5", score: "7", worked: "", broke: "", wish: "", website: "" });
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState("");
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });

  if (done) {
    return (
      <div className="panel-card" style={{ marginTop: 24 }}>
        <strong>Thank you. Genuinely.</strong>
        <p className="dim small" style={{ margin: "6px 0 0" }}>This is the month&rsquo;s form done. See you next month.</p>
      </div>
    );
  }
  return (
    <form
      className="panel-card"
      style={{ marginTop: 24, textAlign: "left" }}
      onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true); setError("");
        try { await post("/api/beta/feedback", f); setDone(true); } catch (err) { setError(err instanceof Error ? err.message : "Something went wrong."); }
        setBusy(false);
      }}
    >
      <Field label="The email you applied with"><input className="field" style={inputStyle} type="email" required value={f.email} onChange={set("email")} /></Field>
      <div style={{ display: "flex", gap: 12 }}>
        <Field label="Month"><input className="field" style={inputStyle} type="month" value={f.month} onChange={set("month")} /></Field>
        <Field label="Hours used"><input className="field" style={inputStyle} type="number" min={0} max={500} value={f.hours} onChange={set("hours")} /></Field>
        <Field label="Score 0–10"><input className="field" style={inputStyle} type="number" min={0} max={10} value={f.score} onChange={set("score")} /></Field>
      </div>
      <Field label="What worked? What did you actually hand it?"><textarea className="field" style={inputStyle} rows={4} value={f.worked} onChange={set("worked")} /></Field>
      <Field label="What broke, confused you, or made you take over?"><textarea className="field" style={inputStyle} rows={4} value={f.broke} onChange={set("broke")} /></Field>
      <Field label="One thing you wish it did"><textarea className="field" style={inputStyle} rows={3} value={f.wish} onChange={set("wish")} /></Field>
      <input type="text" name="website" value={f.website} onChange={set("website")} style={{ display: "none" }} tabIndex={-1} autoComplete="off" />
      <button className="btn btn-primary" disabled={busy} style={{ marginTop: 18, width: "100%" }}>
        {busy ? "Sending…" : "Send this month's feedback"}
      </button>
      {error && <p className="err">{error}</p>}
    </form>
  );
}
