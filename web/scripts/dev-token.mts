/**
 * Mint an app bearer token for local development without going through the
 * browser sign-in. Needs DATABASE_URL (reads .env.local via tsx --env-file).
 *
 *   npx tsx --env-file=.env.local scripts/dev-token.mts you@example.com
 */
import { createAppToken, ensureSchema } from "@/lib/db";

const email = process.argv[2];
if (!email) {
  console.error("usage: dev-token.ts <email>");
  process.exit(2);
}
await ensureSchema();
console.log(await createAppToken(email.toLowerCase(), "dev-token"));
process.exit(0);
