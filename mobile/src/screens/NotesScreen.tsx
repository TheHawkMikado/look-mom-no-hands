import React, { useCallback, useRef, useState } from "react";
import {
  Alert,
  Pressable,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import * as Clipboard from "expo-clipboard";
import { reportNote } from "../lib/api";
import { splitStopPhrase } from "../lib/wake";
import { useSpeechRecognition } from "../hooks/useSpeechRecognition";
import { useNotes } from "../state/NotesContext";
import { useGoalQueue } from "../state/GoalQueueContext";
import { useTasks } from "../state/TasksContext";
import { Note } from "../lib/notesStore";
import { formatRelative } from "../lib/time";
import { colors, spacing } from "../theme";

/**
 * Otter-style dictation: tap record, watch the live transcript build, tap stop
 * (or say "Adios Mama") and the note is saved ON THE PHONE — readable,
 * copyable, shareable, deletable — then summarized in the background into a
 * title, TLDR, key points and action items. Delivery to the Mac's cursor is a
 * bonus that rides the goal queue when online; the note never depends on it.
 */
export function NotesScreen() {
  const insets = useSafeAreaInsets();
  const { notes, storageError, addNote, attachReport, markSentToMac, deleteNote } = useNotes();
  const { submit } = useGoalQueue();
  const { refresh: refreshTasks } = useTasks();

  const [recording, setRecording] = useState(false);
  const recordingRef = useRef(false);
  /** Finished utterances of the in-progress note. */
  const segmentsRef = useRef<string[]>([]);
  const [draft, setDraft] = useState("");
  /** The tail the engine is still working on. */
  const [livePartial, setLivePartial] = useState("");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [summarizing, setSummarizing] = useState<ReadonlySet<string>>(new Set());

  const summarize = useCallback(
    async (note: Note) => {
      setSummarizing((s) => new Set(s).add(note.id));
      try {
        const report = await reportNote(note.text);
        attachReport(note.id, report);
        const filed = report.tasks?.length ?? 0;
        if (filed > 0) {
          setStatus(`Summarized — ${filed} task${filed === 1 ? "" : "s"} filed to your Tasks tab.`);
          // The Tasks tab polls, but a note's to-dos should be there the
          // moment you look, not a poll later.
          void refreshTasks();
        } else {
          setStatus("Summarized.");
        }
      } catch {
        // The note is safe; the summary is a retryable extra.
        setStatus("Couldn't summarize — open the note and tap Summarize to retry.");
      } finally {
        setSummarizing((s) => {
          const next = new Set(s);
          next.delete(note.id);
          return next;
        });
      }
    },
    [attachReport, refreshTasks],
  );

  const finishNote = useCallback(
    async (finalText?: string) => {
      recordingRef.current = false;
      setRecording(false);
      setLivePartial("");
      const text = [...segmentsRef.current, finalText ?? ""]
        .filter(Boolean)
        .join("\n")
        .trim();
      segmentsRef.current = [];
      setDraft("");
      if (!text) {
        setStatus("Nothing captured — try again.");
        return;
      }
      const note = addNote(text, false);
      setStatus("Saved on this phone — summarizing…");
      void summarize(note);
      try {
        const outcome = await submit(text, "dictation");
        if (outcome === "sent") {
          markSentToMac(note.id);
          setStatus("Saved — and pasting at your Mac's cursor.");
        } else {
          setStatus("Saved — will reach your Mac when online.");
        }
      } catch {
        // The note is already safe locally; Mac delivery is best-effort.
        setStatus("Saved on this phone (couldn't reach your Mac).");
      }
    },
    [addNote, markSentToMac, submit, summarize],
  );

  const finishRef = useRef(finishNote);
  finishRef.current = finishNote;

  const speech = useSpeechRecognition({
    onPartial: (text) => {
      if (recordingRef.current) setLivePartial(text);
    },
    onFinal: () => undefined, // segments carry the text in continuous mode
    onSegment: (segment) => {
      if (!recordingRef.current) return;
      // "Adios Mama" ends the note; words before it still belong to it.
      const beforeStop = splitStopPhrase(segment);
      if (beforeStop !== null) {
        void speech.stop();
        void finishRef.current(beforeStop);
        return;
      }
      segmentsRef.current = [...segmentsRef.current, segment];
      setDraft(segmentsRef.current.join("\n"));
      setLivePartial("");
    },
  });

  const toggleRecording = useCallback(() => {
    if (recordingRef.current) {
      void speech.stop();
      void finishNote();
      return;
    }
    segmentsRef.current = [];
    setDraft("");
    setLivePartial("");
    setStatus(null);
    recordingRef.current = true;
    setRecording(true);
    void speech.start(true);
  }, [speech, finishNote]);

  const copyNote = useCallback(async (note: Note) => {
    await Clipboard.setStringAsync(note.text);
    setStatus("Copied to clipboard.");
  }, []);

  const sendNoteToMac = useCallback(
    async (note: Note) => {
      const outcome = await submit(note.text, "dictation").catch(() => null);
      if (outcome) markSentToMac(note.id);
      setStatus(
        outcome === "sent"
          ? "Pasting at your Mac's cursor."
          : outcome === "queued"
            ? "Will reach your Mac when online."
            : "Couldn't reach the server.",
      );
    },
    [submit, markSentToMac],
  );

  const confirmDelete = useCallback(
    (note: Note) => {
      Alert.alert("Delete note?", note.title, [
        { text: "Cancel", style: "cancel" },
        { text: "Delete", style: "destructive", onPress: () => deleteNote(note.id) },
      ]);
    },
    [deleteNote],
  );

  const liveText = [draft, livePartial].filter(Boolean).join("\n");

  return (
    <View style={[styles.container, { paddingTop: insets.top + spacing.md }]}>
      <View style={styles.recorder}>
        <Pressable
          onPress={toggleRecording}
          style={[styles.recordButton, recording && styles.recordButtonOn]}
        >
          <View style={[styles.recordCore, recording && styles.recordCoreOn]} />
        </Pressable>
        <Text style={styles.hint}>
          {recording
            ? "Listening — tap or say 'Adios Mama' to finish"
            : "Tap to start a note"}
        </Text>
        {status && !recording ? <Text style={styles.status}>{status}</Text> : null}
        {storageError ? <Text style={styles.storageError}>{storageError}</Text> : null}
      </View>

      {recording ? (
        <ScrollView style={styles.liveTranscript} contentContainerStyle={styles.livePad}>
          <Text style={styles.liveText}>
            {liveText || "Say something…"}
          </Text>
        </ScrollView>
      ) : (
        <ScrollView style={styles.list} showsVerticalScrollIndicator={false}>
          {notes.length === 0 ? (
            <Text style={styles.empty}>
              No notes yet. Tap the button and start talking — everything you
              say is saved here, summarized, and lands at your Mac's cursor too.
            </Text>
          ) : (
            notes.map((note) => {
              const expanded = expandedId === note.id;
              const busy = summarizing.has(note.id);
              return (
                <Pressable
                  key={note.id}
                  onPress={() => setExpandedId(expanded ? null : note.id)}
                  style={styles.noteRow}
                >
                  <View style={styles.noteHeader}>
                    <Text style={styles.noteTitle} numberOfLines={expanded ? undefined : 1}>
                      {note.title}
                    </Text>
                    <Text style={styles.noteTime}>{formatRelative(note.createdAt)}</Text>
                  </View>
                  {expanded ? (
                    <>
                      {note.report ? (
                        <NoteReportView report={note.report} />
                      ) : (
                        <Text style={styles.summarizingHint}>
                          {busy ? "Summarizing…" : "No summary yet."}
                        </Text>
                      )}
                      <Text style={styles.sectionLabel}>Transcript</Text>
                      <Text style={styles.noteBody} selectable>
                        {note.text}
                      </Text>
                      <View style={styles.actions}>
                        <Pressable style={styles.action} onPress={() => void copyNote(note)}>
                          <Text style={styles.actionLabel}>Copy</Text>
                        </Pressable>
                        <Pressable
                          style={styles.action}
                          onPress={() => void Share.share({ message: note.text })}
                        >
                          <Text style={styles.actionLabel}>Share</Text>
                        </Pressable>
                        <Pressable
                          style={[styles.action, busy && styles.actionDisabled]}
                          disabled={busy}
                          onPress={() => void summarize(note)}
                        >
                          <Text style={styles.actionLabel}>
                            {busy ? "Summarizing…" : note.report ? "Re-summarize" : "Summarize"}
                          </Text>
                        </Pressable>
                        <Pressable style={styles.action} onPress={() => void sendNoteToMac(note)}>
                          <Text style={styles.actionLabel}>
                            {note.sentToMac ? "Send again" : "Send to Mac"}
                          </Text>
                        </Pressable>
                        <Pressable style={styles.action} onPress={() => confirmDelete(note)}>
                          <Text style={[styles.actionLabel, styles.actionDanger]}>Delete</Text>
                        </Pressable>
                      </View>
                    </>
                  ) : (
                    <Text style={styles.notePreview} numberOfLines={2}>
                      {note.report?.summary || note.text}
                    </Text>
                  )}
                </Pressable>
              );
            })
          )}
        </ScrollView>
      )}
    </View>
  );
}

function NoteReportView({ report }: { report: NonNullable<Note["report"]> }) {
  return (
    <View>
      {report.summary ? (
        <>
          <Text style={styles.sectionLabel}>Summary</Text>
          <Text style={styles.noteBody} selectable>
            {report.summary}
          </Text>
        </>
      ) : null}
      {report.keyPoints.length > 0 ? (
        <>
          <Text style={styles.sectionLabel}>Key points</Text>
          {report.keyPoints.map((p, i) => (
            <Text key={i} style={styles.bullet} selectable>
              {"•  "}
              {p}
            </Text>
          ))}
        </>
      ) : null}
      {report.actionItems.length > 0 ? (
        <>
          <Text style={styles.sectionLabel}>Action items</Text>
          {report.actionItems.map((a, i) => (
            <Text key={i} style={styles.bullet} selectable>
              {"☐  "}
              {a}
            </Text>
          ))}
        </>
      ) : null}
      {report.tasks && report.tasks.length > 0 ? (
        <>
          <Text style={styles.sectionLabel}>Filed as tasks</Text>
          {report.tasks.map((t) => (
            <Text key={t.id} style={styles.bullet} selectable>
              {"→  "}
              {t.title}
              <Text style={styles.taskMeta}>
                {"  ·  "}
                {t.owner_name ?? "you"}
                {"  ·  "}
                {t.status.replace(/_/g, " ")}
              </Text>
            </Text>
          ))}
        </>
      ) : null}
    </View>
  );
}

const RECORD_SIZE = 84;

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.bg,
    paddingHorizontal: spacing.md,
  },
  recorder: {
    alignItems: "center",
    paddingVertical: spacing.md,
  },
  recordButton: {
    width: RECORD_SIZE,
    height: RECORD_SIZE,
    borderRadius: RECORD_SIZE / 2,
    borderWidth: 2,
    borderColor: colors.accent,
    backgroundColor: colors.surface,
    justifyContent: "center",
    alignItems: "center",
  },
  recordButtonOn: {
    backgroundColor: colors.accent,
  },
  recordCore: {
    width: 30,
    height: 30,
    borderRadius: 15,
    backgroundColor: colors.accent,
  },
  recordCoreOn: {
    borderRadius: 6,
    backgroundColor: colors.text,
  },
  hint: {
    color: colors.muted,
    fontSize: 14,
    marginTop: spacing.sm,
  },
  status: {
    color: colors.success,
    fontSize: 13,
    marginTop: spacing.xs,
    textAlign: "center",
  },
  storageError: {
    color: colors.danger,
    fontSize: 13,
    marginTop: spacing.xs,
    textAlign: "center",
  },
  liveTranscript: {
    flex: 1,
  },
  livePad: {
    paddingVertical: spacing.md,
    paddingBottom: spacing.xl,
  },
  liveText: {
    color: colors.text,
    fontSize: 22,
    lineHeight: 32,
  },
  list: {
    flex: 1,
  },
  empty: {
    color: colors.muted,
    fontSize: 15,
    lineHeight: 22,
    marginTop: spacing.lg,
    textAlign: "center",
  },
  noteRow: {
    backgroundColor: colors.surface,
    borderRadius: 12,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  noteHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    gap: spacing.sm,
  },
  noteTitle: {
    color: colors.text,
    fontSize: 16,
    fontWeight: "600",
    flex: 1,
  },
  noteTime: {
    color: colors.muted,
    fontSize: 12,
  },
  notePreview: {
    color: colors.muted,
    fontSize: 14,
    marginTop: 4,
  },
  sectionLabel: {
    color: colors.muted,
    fontSize: 12,
    fontWeight: "700",
    letterSpacing: 0.6,
    textTransform: "uppercase",
    marginTop: spacing.md,
    marginBottom: 4,
  },
  summarizingHint: {
    color: colors.muted,
    fontSize: 13,
    marginTop: spacing.sm,
    fontStyle: "italic",
  },
  noteBody: {
    color: colors.text,
    fontSize: 15,
    lineHeight: 22,
  },
  bullet: {
    color: colors.text,
    fontSize: 15,
    lineHeight: 22,
    paddingLeft: 4,
  },
  taskMeta: {
    color: colors.muted,
    fontSize: 13,
  },
  actions: {
    flexDirection: "row",
    gap: spacing.sm,
    marginTop: spacing.md,
    flexWrap: "wrap",
  },
  action: {
    paddingVertical: 6,
    paddingHorizontal: spacing.md,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: colors.border,
  },
  actionDisabled: {
    opacity: 0.5,
  },
  actionLabel: {
    color: colors.accent,
    fontSize: 13,
    fontWeight: "600",
  },
  actionDanger: {
    color: colors.danger,
  },
});
