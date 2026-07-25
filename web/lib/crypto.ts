import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

/**
 * Symmetric encryption for secrets we must store *and* read back — the account's
 * Anthropic and ElevenLabs API keys, which the signed-in app fetches. Unlike the
 * licence signing key (asymmetric) or session cookies (HMAC, never decrypted),
 * these need to come back out in plaintext to hand to the app, so AES-256-GCM
 * with a server-held key is the right primitive: authenticated (GCM tag detects
 * tampering) and reversible.
 *
 * The key is derived from KEY_ENCRYPTION_SECRET so any sufficiently long random
 * string works as the env value; rotating it makes existing ciphertexts
 * undecryptable (they'd need re-entry), which is the expected trade for a key
 * rotation.
 */

const ALGO = "aes-256-gcm";

function key(): Buffer {
  const secret = process.env.KEY_ENCRYPTION_SECRET;
  if (!secret) throw new Error("KEY_ENCRYPTION_SECRET is not set");
  // Fold any-length secret into the 32 bytes AES-256 needs.
  return createHash("sha256").update(secret, "utf8").digest();
}

/** Returns `iv.tag.ciphertext`, all base64url — self-describing, one string to store. */
export function encryptSecret(plain: string): string {
  const iv = randomBytes(12); // 96-bit nonce, the GCM standard
  const cipher = createCipheriv(ALGO, key(), iv);
  const enc = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [iv, tag, enc].map((b) => b.toString("base64url")).join(".");
}

/** Inverse of encryptSecret. Returns null if the value is malformed or tampered
 *  with (bad GCM tag) rather than throwing, so a corrupt row can't 500 a route. */
export function decryptSecret(stored: string): string | null {
  try {
    const [ivB64, tagB64, dataB64] = stored.split(".");
    if (!ivB64 || !tagB64 || !dataB64) return null;
    const decipher = createDecipheriv(ALGO, key(), Buffer.from(ivB64, "base64url"));
    decipher.setAuthTag(Buffer.from(tagB64, "base64url"));
    const dec = Buffer.concat([
      decipher.update(Buffer.from(dataB64, "base64url")),
      decipher.final(),
    ]);
    return dec.toString("utf8");
  } catch {
    return null;
  }
}
