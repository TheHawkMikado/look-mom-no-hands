/**
 * Local notes — the phone's own copy of every dictation, Otter-style. The
 * note on the phone is the source of truth: it exists the moment recording
 * stops, whether or not the Mac or the network ever hears about it. Storage is
 * one JSON file in the app's documents directory; at a few KB per note that
 * stays cheap well past a thousand notes.
 *
 * Pure helpers (title, sorting, serialization) are separated from the file I/O
 * so they run under jest without native modules.
 */

/** What the server's summarizer returns — same shape as the Mac's reports. */
export interface NoteReport {
  title: string;
  summary: string;
  keyPoints: string[];
  actionItems: string[];
}

export interface Note {
  id: string;
  title: string;
  text: string;
  /** ISO timestamps. */
  createdAt: string;
  updatedAt: string;
  /** Whether this note was also delivered to the Mac's cursor. */
  sentToMac: boolean;
  /** Summary / key points / action items, once generated. */
  report?: NoteReport | null;
}

export function newNoteId(now: number = Date.now()): string {
  return `${now.toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

/** First few words of the text, cleaned up — the list row's one-liner until
 *  a report supplies a real title. */
export function deriveTitle(text: string, maxWords = 6): string {
  const words = text.trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return "Untitled note";
  const head = words.slice(0, maxWords).join(" ");
  return words.length > maxWords ? `${head}…` : head;
}

/** Newest first. */
export function sortNotes(notes: readonly Note[]): Note[] {
  return [...notes].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

/** Parse the persisted file, dropping anything that isn't a well-formed note —
 *  a corrupt entry must not take the whole notebook down with it. */
export function parseNotes(raw: string): Note[] {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (n): n is Note =>
        typeof n === "object" &&
        n !== null &&
        typeof (n as Note).id === "string" &&
        typeof (n as Note).text === "string" &&
        typeof (n as Note).createdAt === "string",
    );
  } catch {
    return [];
  }
}

export interface NoteFileStore {
  /** null when no notebook has been written yet. Throws on a real read error. */
  read(): Promise<string | null>;
  /** Throws when the save fails — the caller surfaces it rather than letting
   *  notes silently evaporate between launches. */
  write(raw: string): Promise<void>;
}

/** The real store, created lazily so jest never touches expo-file-system. */
export function createNoteFileStore(): NoteFileStore {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { File, Paths } = require("expo-file-system") as typeof import("expo-file-system");
  const file = new File(Paths.document, "notes.json");
  return {
    async read() {
      if (!file.exists) return null;
      return file.textSync();
    },
    async write(raw: string) {
      // write() does not promise to create a missing file; the first save
      // after install must create it or every note is lost on relaunch.
      if (!file.exists) file.create();
      file.write(raw);
    },
  };
}
