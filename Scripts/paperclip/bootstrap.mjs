#!/usr/bin/env node
/**
 * One-command Paperclip setup for No Hands. Idempotent — run it as often as
 * you like.
 *
 *   node Scripts/paperclip/bootstrap.mjs
 *
 * Creates (or finds) the "No Hands" company, the two starter agents
 * (Content Drafter, Researcher) wired to the scripts in ./agents, and writes
 * Scripts/paperclip/.connection.json for the bridge and the Mac app.
 *
 * Then registers the connection with your No Hands account if you give it an
 * app token (NOHANDS_APP_TOKEN, or --token): sign in once at
 * https://nohandsapp.com/app/login?client=bridge and paste what it shows.
 *
 * Options / env:
 *   PAPERCLIP_URL      default http://localhost:3100
 *   NOHANDS_API        default https://nohandsapp.com
 *   NOHANDS_APP_TOKEN  register the connection (bridge mode)
 *   --direct           register in direct mode (the web service can reach
 *                      PAPERCLIP_URL itself — a VPS, not your laptop)
 *   --ads              only create the "Ad process" goal + project template
 *                      (SPEC.md §9 Phase 5) in the company and exit; the web
 *                      service files each run's step issues into it
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined; };

// Scripts/paperclip/.env (written by up.sh) carries the drafter's model key.
const envFile = resolve(HERE, ".env");
const dotenv = existsSync(envFile)
  ? Object.fromEntries(readFileSync(envFile, "utf8").split("\n").filter((l) => l && !l.startsWith("#") && l.includes("=")).map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }))
  : {};

const PAPERCLIP_URL = (opt("--paperclip") || process.env.PAPERCLIP_URL || "http://localhost:3100").replace(/\/+$/, "");
const NOHANDS_API = (opt("--api") || process.env.NOHANDS_API || "https://nohandsapp.com").replace(/\/+$/, "");
const TOKEN = opt("--token") || process.env.NOHANDS_APP_TOKEN || "";
const MODE = flag("--direct") ? "direct" : "bridge";
const ANTHROPIC_KEY = process.env.ANTHROPIC_API_KEY || dotenv.ANTHROPIC_API_KEY || "";

async function pc(method, path, body) {
  const res = await fetch(`${PAPERCLIP_URL}${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = text; }
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${typeof json === "string" ? json : JSON.stringify(json)}`);
  return json;
}

// 1. Reachable?
try {
  await pc("GET", "/api/health");
} catch (e) {
  console.error(`Paperclip is not reachable at ${PAPERCLIP_URL}. Start it with ./Scripts/paperclip/up.sh\n(${e.message})`);
  process.exit(1);
}

// 2. Company.
const companies = await pc("GET", "/api/companies");
let company = companies.find((c) => c.name === "No Hands");
if (!company) {
  company = await pc("POST", "/api/companies", {
    name: "No Hands",
    description: "The team behind Hawk's voice-first chief of staff. Agents draft, research and build; the owner approves.",
  });
  console.log(`Created company "No Hands" (${company.id})`);
} else {
  console.log(`Company "No Hands" exists (${company.id})`);
}

// 2b. --ads: the Phase 5 template. A company goal ("why") and a project
// ("what") named "Ad process"; lib/projects.ts finds the project by name and
// files each run's seven step issues into it. Idempotent.
if (flag("--ads")) {
  const goals = await pc("GET", `/api/companies/${company.id}/goals`);
  let goal = goals.find((g) => g.title === "Ad process");
  if (!goal) {
    goal = await pc("POST", `/api/companies/${company.id}/goals`, {
      title: "Ad process",
      description: "Hawk's multi-model ad-creation workflow: research the offer → 3 angles → 5 copy variants per angle → image prompts → compliance/brand check → owner review gate (tier 2) → publish/fund within the cap (tier 3). Budget cap and review gate live in No Hands.",
      level: "company",
      status: "active",
    });
    console.log(`Created goal "Ad process" (${goal.id})`);
  } else {
    console.log(`Goal "Ad process" exists (${goal.id})`);
  }
  const projects = await pc("GET", `/api/companies/${company.id}/projects`);
  let project = projects.find((p) => p.name === "Ad process");
  if (!project) {
    project = await pc("POST", `/api/companies/${company.id}/projects`, {
      name: "Ad process",
      description: "Template project for ad runs. Each run from No Hands adds seven step issues here, under the task's issue. Nothing is published or funded before the owner's review gate.",
      goalIds: [goal.id],
      status: "in_progress",
    });
    console.log(`Created project "Ad process" (${project.id})`);
  } else {
    console.log(`Project "Ad process" exists (${project.id})`);
  }
  console.log(`Ad process template ready: goal ${goal.id}, project ${project.id}`);
  process.exit(0);
}

// 3. Starter agents on the process adapter, pointing at ./agents/*.mjs.
// Paperclip's role field is a fixed enum; the *title* carries the real job,
// and No Hands matches on name/title/capabilities, not the enum.
const node = process.execPath;
const drafterScript = resolve(HERE, "agents", "drafter.mjs");
const STARTERS = [
  {
    name: "Content Drafter",
    role: "general",
    title: "Content Drafter",
    capabilities: "Blog posts, social copy, newsletters, emails, scripts. Drafts and hands back for approval; never publishes.",
    script: drafterScript,
  },
  {
    name: "Researcher",
    role: "researcher",
    title: "Researcher",
    capabilities: "Research and synthesis: compare options, dig up facts, summarise sources into a brief.",
    script: drafterScript, // same contract; the prompt reads the issue
  },
];
const existing = await pc("GET", `/api/companies/${company.id}/agents`);
const agents = [];
for (const s of STARTERS) {
  const adapterConfig = {
    command: node,
    args: [s.script],
    cwd: HERE,
    env: { ...(ANTHROPIC_KEY ? { ANTHROPIC_API_KEY: ANTHROPIC_KEY } : {}) },
    timeoutSec: 300,
  };
  let a = existing.find((x) => x.name === s.name);
  if (a) {
    a = await pc("PATCH", `/api/agents/${a.id}`, { title: s.title, capabilities: s.capabilities, adapterType: "process", adapterConfig });
    console.log(`Updated agent ${s.name} (${a.id})`);
  } else {
    a = await pc("POST", `/api/companies/${company.id}/agents`, {
      name: s.name, role: s.role, title: s.title, capabilities: s.capabilities, adapterType: "process", adapterConfig,
    });
    console.log(`Created agent ${s.name} (${a.id})`);
  }
  agents.push({ id: a.id, name: a.name, role: a.role, title: a.title ?? s.title, capabilities: a.capabilities ?? s.capabilities });
}
if (!ANTHROPIC_KEY) console.log("Note: no ANTHROPIC_API_KEY in Scripts/paperclip/.env — the Content Drafter will post stub drafts.");

// 4. Local connection file for the bridge / Mac app.
const connection = { url: PAPERCLIP_URL, company_id: company.id, agents, mode: MODE, api: NOHANDS_API, created_at: new Date().toISOString() };
writeFileSync(resolve(HERE, ".connection.json"), JSON.stringify(connection, null, 2) + "\n");
console.log(`Wrote ${resolve(HERE, ".connection.json")}`);

// 5. Register with the No Hands account, if we can.
if (!TOKEN) {
  console.log(`\nTo connect this Paperclip to your No Hands account:\n  1. open ${NOHANDS_API}/app/login?client=bridge and copy the token\n  2. rerun: NOHANDS_APP_TOKEN=<token> node Scripts/paperclip/bootstrap.mjs\n  3. keep the bridge running: node Scripts/paperclip/bridge.mjs`);
  process.exit(0);
}
const res = await fetch(`${NOHANDS_API}/api/app/paperclip/connection`, {
  method: "POST",
  headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
  body: JSON.stringify({ url: PAPERCLIP_URL, companyId: company.id, mode: MODE, agents }),
});
const out = await res.json().catch(() => ({}));
if (!res.ok) {
  console.error(`Registering the connection failed (${res.status}): ${out.error ?? JSON.stringify(out)}`);
  process.exit(1);
}
writeFileSync(resolve(HERE, ".connection.json"), JSON.stringify({ ...connection, token: TOKEN }, null, 2) + "\n");
console.log(`Connected to your No Hands account in ${MODE} mode with ${agents.length} agents.`);
if (MODE === "bridge") console.log("Keep the bridge running so tasks flow: node Scripts/paperclip/bridge.mjs");
