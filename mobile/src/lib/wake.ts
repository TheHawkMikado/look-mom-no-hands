/**
 * Wake-phrase matching for locked listening mode. Pure functions only.
 *
 * Recognizers mangle "Hey Mama" in predictable ways ("hey momma", "a mama"),
 * so we match a small variant list against a normalized transcript and return
 * whatever follows the phrase. The returned command is the normalized text —
 * the backend receives lowercase, punctuation-free goals from locked mode.
 */

export const WAKE_VARIANTS = ["hey mama", "hey momma"] as const;
/** Recognizer mishearings of the wake phrase itself. A real wake phrase opens
 *  the utterance, so these only count at position 0 — matched mid-sentence,
 *  "send a message to a mama in my contacts" would truncate to "in my
 *  contacts" and ship a mangled goal. */
export const WAKE_VARIANTS_AT_START = ["a mama"] as const;

/** Lowercase, strip punctuation, collapse whitespace. */
export function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * If the utterance contains a wake variant (on word boundaries), return the
 * command text after the LAST occurrence — continuous recognition can stack
 * several attempts into one transcript and only the freshest one counts.
 * Returns null when there is no wake phrase or nothing follows it.
 */
export function extractCommand(utterance: string): string | null {
  const norm = normalize(utterance);
  let commandStart = -1;

  for (const variant of WAKE_VARIANTS) {
    let from = 0;
    for (;;) {
      const idx = norm.indexOf(variant, from);
      if (idx === -1) break;
      const end = idx + variant.length;
      const startsWord = idx === 0 || norm[idx - 1] === " ";
      const endsWord = end === norm.length || norm[end] === " ";
      if (startsWord && endsWord && end > commandStart) {
        commandStart = end;
      }
      from = idx + 1;
    }
  }

  // The loose mishearing variants only count as an opener, and never override
  // a real wake phrase found later in a stacked transcript.
  if (commandStart === -1) {
    for (const variant of WAKE_VARIANTS_AT_START) {
      if (norm.startsWith(variant + " ")) {
        commandStart = variant.length;
        break;
      }
    }
  }

  if (commandStart === -1) return null;
  const command = norm.slice(commandStart).trim();
  return command.length > 0 ? command : null;
}
