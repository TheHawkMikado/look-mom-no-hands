import { createPrivateKey, randomBytes, sign as edSign } from "node:crypto";

/**
 * Licence key minting and Ed25519 entitlement-token signing.
 *
 * The Swift app ships only the public half of this keypair and verifies tokens
 * locally, so the customer's app never needs to reach us after activation. That
 * puts one hard constraint on this file: the claims JSON below must stay
 * field-for-field identical to `LicenseClaims` in
 * Sources/LookMomNoHands/LicenseStore.swift, and the signature must cover the
 * raw JSON bytes — not the base64 of them.
 */

/**
 * Crockford-style base32: no I, L, O or U. Customers retype these off an email,
 * and the excluded letters are exactly the ones misread as 1/0 or typed as V.
 */
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export function mintLicenceKey(): string {
  const groups: string[] = [];
  for (let g = 0; g < 3; g++) {
    // rejection-free: 32 symbols divides 256 evenly, so a plain modulo of a
    // random byte is uniform here.
    const bytes = randomBytes(4);
    groups.push([...bytes].map((b) => ALPHABET[b % 32]).join(""));
  }
  return `NOHANDS-${groups.join("-")}`;
}

/** Normalises what a customer pasted: case, stray spaces, smart dashes. */
export function normaliseKey(input: string): string {
  return input
    .trim()
    .toUpperCase()
    .replace(/[‐-―]/g, "-")
    .replace(/\s+/g, "");
}

/**
 * Ed25519 PKCS#8 DER is a fixed 16-byte prelude followed by the 32-byte seed,
 * so we can rebuild a usable KeyObject from the raw seed the setup script
 * printed without carrying a PEM around in an env var.
 */
const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

function privateKey() {
  const hex = process.env.LICENSE_SIGNING_KEY;
  if (!hex) throw new Error("LICENSE_SIGNING_KEY is not set");
  const seed = Buffer.from(hex.trim(), "hex");
  if (seed.length !== 32) {
    throw new Error(`LICENSE_SIGNING_KEY must be 32 bytes of hex, got ${seed.length}`);
  }
  return createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519_PREFIX, seed]),
    format: "der",
    type: "pkcs8",
  });
}

export interface Claims {
  email: string;
  plan: string;
  /** Seconds since epoch; 0 means perpetual. */
  exp: number;
  issuedAt: number;
  device: string;
}

const b64url = (b: Buffer) => b.toString("base64url");

/**
 * Produces `base64url(claimsJSON).base64url(signature)`. Deliberately not a JWT:
 * there is one algorithm and one issuer, so a header would only add a field an
 * attacker could try to talk us out of (the `alg: none` family of bugs).
 */
export function signToken(claims: Claims): string {
  const payload = Buffer.from(JSON.stringify(claims), "utf8");
  const signature = edSign(null, payload, privateKey());
  return `${b64url(payload)}.${b64url(signature)}`;
}
