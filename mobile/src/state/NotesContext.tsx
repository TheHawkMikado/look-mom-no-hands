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
  parseNotes,
  sortNotes,
} from "../lib/notesStore";

export interface NotesContextValue {
  /** Newest first. */
  notes: readonly Note[];
  addNote: (text: string, sentToMac: boolean) => Note;
  markSentToMac: (id: string) => void;
  deleteNote: (id: string) => void;
}

export const NotesContext = createContext<NotesContextValue | null>(null);

export function useNotes(): NotesContextValue {
  const value = useContext(NotesContext);
  if (!value) throw new Error("useNotes outside NotesProvider");
  return value;
}

export function NotesProvider({ children }: { children: React.ReactNode }) {
  const storeRef = useRef<NoteFileStore | null>(null);
  if (!storeRef.current) storeRef.current = createNoteFileStore();
  const [notes, setNotes] = useState<readonly Note[]>([]);

  useEffect(() => {
    let alive = true;
    void storeRef.current!.read().then((raw) => {
      if (alive && raw) setNotes(sortNotes(parseNotes(raw)));
    });
    return () => {
      alive = false;
    };
  }, []);

  const persist = useCallback((next: readonly Note[]) => {
    setNotes(next);
    void storeRef.current!.write(JSON.stringify(next));
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
      };
      persist([note, ...notes]);
      return note;
    },
    [notes, persist],
  );

  const markSentToMac = useCallback(
    (id: string) => {
      persist(notes.map((n) => (n.id === id ? { ...n, sentToMac: true } : n)));
    },
    [notes, persist],
  );

  const deleteNote = useCallback(
    (id: string) => {
      persist(notes.filter((n) => n.id !== id));
    },
    [notes, persist],
  );

  const value = useMemo<NotesContextValue>(
    () => ({ notes, addNote, markSentToMac, deleteNote }),
    [notes, addNote, markSentToMac, deleteNote],
  );

  return <NotesContext.Provider value={value}>{children}</NotesContext.Provider>;
}
