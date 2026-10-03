import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  createNoteFileStore,
  deriveTitle,
  newNoteId,
  Note,
  NoteFileStore,
  NoteReport,
  parseNotes,
  sortNotes,
} from "../lib/notesStore";

export interface NotesContextValue {
  /** Newest first. */
  notes: readonly Note[];
  /** Why the last load or save failed, if it did — shown on the Notes tab so
   *  a broken notebook is never a silent one. */
  storageError: string | null;
  addNote: (text: string, sentToMac: boolean) => Note;
  attachReport: (id: string, report: NoteReport) => void;
  markSentToMac: (id: string) => void;
  deleteNote: (id: string) => void;
}

export const NotesContext = createContext<NotesContextValue | null>(null);

export function useNotes(): NotesContextValue {
  const value = useContext(NotesContext);
  if (!value) throw new Error("useNotes outside NotesProvider");
  return value;
}

const describe = (e: unknown): string => (e instanceof Error ? e.message : String(e));

export function NotesProvider({ children }: { children: React.ReactNode }) {
  const storeRef = useRef<NoteFileStore | null>(null);
  const [notes, setNotes] = useState<readonly Note[]>([]);
  const [storageError, setStorageError] = useState<string | null>(null);
  // Mutations read the latest list from a ref, so two quick updates (save a
  // note, then attach its report) never clobber each other with stale state.
  const notesRef = useRef<readonly Note[]>([]);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        storeRef.current = createNoteFileStore();
        const raw = await storeRef.current.read();
        if (!alive) return;
        const loaded = raw ? sortNotes(parseNotes(raw)) : [];
        notesRef.current = loaded;
        setNotes(loaded);
      } catch (e) {
        if (alive) setStorageError(`Couldn't load notes: ${describe(e)}`);
      }
    })();
    return () => {
      alive = false;
    };
  }, []);

  const persist = useCallback((next: readonly Note[]) => {
    notesRef.current = next;
    setNotes(next);
    const store = storeRef.current;
    if (!store) {
      setStorageError("Couldn't save notes: storage not available");
      return;
    }
    store
      .write(JSON.stringify(next))
      .then(() => setStorageError(null))
      .catch((e) => setStorageError(`Couldn't save notes: ${describe(e)}`));
  }, []);

  const addNote = useCallback(
    (text: string, sentToMac: boolean): Note => {
      const now = new Date().toISOString();
      const note: Note = {
        id: newNoteId(),
        title: deriveTitle(text),
        text,
        createdAt: now,
        updatedAt: now,
        sentToMac,
        report: null,
      };
      persist([note, ...notesRef.current]);
      return note;
    },
    [persist],
  );

  const update = useCallback(
    (id: string, patch: (n: Note) => Note) => {
      persist(notesRef.current.map((n) => (n.id === id ? patch(n) : n)));
    },
    [persist],
  );

  const attachReport = useCallback(
    (id: string, report: NoteReport) => {
      update(id, (n) => ({
        ...n,
        report,
        // The model's headline beats the first-six-words placeholder.
        title: report.title || n.title,
        updatedAt: new Date().toISOString(),
      }));
    },
    [update],
  );

  const markSentToMac = useCallback(
    (id: string) => update(id, (n) => ({ ...n, sentToMac: true })),
    [update],
  );

  const deleteNote = useCallback(
    (id: string) => persist(notesRef.current.filter((n) => n.id !== id)),
    [persist],
  );

  const value = useMemo<NotesContextValue>(
    () => ({ notes, storageError, addNote, attachReport, markSentToMac, deleteNote }),
    [notes, storageError, addNote, attachReport, markSentToMac, deleteNote],
  );

  return <NotesContext.Provider value={value}>{children}</NotesContext.Provider>;
}
