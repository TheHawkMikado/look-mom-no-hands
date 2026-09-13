#!/usr/bin/env node
/**
 * The last step of a release: move LATEST_APP_VERSION (and LATEST_APP_NOTES)
 * on Vercel and redeploy, so /api/version tells every installed app. Used by
 * .github/workflows/release.yml; runnable by hand too.
 *
 *   VERCEL_TOKEN=… VERCEL_PROJECT_ID=… [VERCEL_TEAM_ID=…] [VERCEL_DEPLOY_HOOK_URL=…] \
 *     node web/scripts/vercel-set-version.mjs 0.05.260913.abc1234 "What's new"
 */
const [version, notes = ""] = process.argv.slice(2);
if (!version) { console.error("usage: vercel-set-version.mjs <version> [notes]"); process.exit(2); }
const { VERCEL_TOKEN, VERCEL_PROJECT_ID, VERCEL_TEAM_ID, VERCEL_DEPLOY_HOOK_URL } = process.env;
if (!VERCEL_TOKEN || !VERCEL_PROJECT_ID) { console.error("VERCEL_TOKEN and VERCEL_PROJECT_ID are required"); process.exit(2); }

const team = VERCEL_TEAM_ID ? `?teamId=${encodeURIComponent(VERCEL_TEAM_ID)}` : "";
async function api(method, path, body) {
  const res = await fetch(`https://api.vercel.com${path}${team}`, {
    method,
    headers: { authorization: `Bearer ${VERCEL_TOKEN}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json).slice(0, 300)}`);
  return json;
}

async function upsert(key, value) {
  const { envs } = await api("GET", `/v9/projects/${VERCEL_PROJECT_ID}/env`);
  const existing = (envs ?? []).filter((e) => e.key === key && (e.target ?? []).includes("production"));
  if (existing.length) {
    for (const e of existing) await api("PATCH", `/v9/projects/${VERCEL_PROJECT_ID}/env/${e.id}`, { value });
  } else {
    await api("POST", `/v10/projects/${VERCEL_PROJECT_ID}/env`, { key, value, type: "plain", target: ["production"] });
  }
  console.log(`${key} = ${JSON.stringify(value)} (production)`);
}

await upsert("LATEST_APP_VERSION", version);
await upsert("LATEST_APP_NOTES", notes);

// Env changes apply to the NEXT deployment; /api/version reads process.env at
// request time, so redeploy now. A deploy hook is the cleanest trigger.
if (VERCEL_DEPLOY_HOOK_URL) {
  const res = await fetch(VERCEL_DEPLOY_HOOK_URL, { method: "POST" });
  console.log(`redeploy triggered (${res.status})`);
} else {
  // Fall back to redeploying the current production deployment.
  const { deployments } = await api("GET", `/v6/deployments?projectId=${VERCEL_PROJECT_ID}&target=production&limit=1`);
  const cur = deployments?.[0];
  if (!cur) { console.warn("no production deployment to redeploy; set VERCEL_DEPLOY_HOOK_URL"); process.exit(0); }
  await api("POST", `/v13/deployments`, { name: cur.name, deploymentId: cur.uid, target: "production" });
  console.log(`redeployed ${cur.uid}`);
}
console.log(`Every installed app will now see v${version} on its next check.`);
