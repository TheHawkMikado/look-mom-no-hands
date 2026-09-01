import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  PanResponder,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { ApiError, submitGoal } from "../lib/api";
import {
  PttEffect,
  PttEvent,
  PttState,
  transition,
} from "../lib/pttMachine";
import { extractCommand } from "../lib/wake";
import { useSpeechRecognition } from "../hooks/useSpeechRecognition";
import { useFeed } from "../state/FeedContext";
import { ApprovalCard } from "../components/ApprovalCard";
import { colors, spacing } from "../theme";

/** Upward drag distance (pt) that arms locked listening, WhatsApp-style. */
const LOCK_SLIDE_DISTANCE = 90;

/** How long to wait for the engine's final result after release before
 * falling back to the last partial, so a release never swallows the goal. */
const FINAL_RESULT_GRACE_MS = 900;

export function TalkScreen() {
  const insets = useSafeAreaInsets();
  const { pendingApprovals, decide, setKeepPolling } = useFeed();

  const [pttState, setPttState] = useState<PttState>("idle");
  const pttRef = useRef<PttState>("idle");
  const [partial, setPartial] = useState("");
  const [status, setStatus] = useState<string | null>(null);

  const lastTranscriptRef = useRef("");
  const awaitingFinalRef = useRef(false);
  const finalTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const sendGoal = useCallback(async (text: string) => {
    const trimmed = text.trim();
    if (!trimmed) {
      setStatus("Didn't catch that — try again.");
      return;
    }
    try {
      await submitGoal(trimmed);
      setStatus("Sent — your Mac is on it.");
    } catch (e) {
      // A 401 already signed the user out; anything else is transient.
      if (!(e instanceof ApiError && e.status === 401)) {
        setStatus("Couldn't reach the server — goal not sent.");
      }
    }
  }, []);

  const speech = useSpeechRecognition({
    onPartial: (text) => {
      lastTranscriptRef.current = text;
      setPartial(text);
    },
    onFinal: (text) => {
      lastTranscriptRef.current = text;
      if (pttRef.current === "locked") {
        // Locked mode: only utterances carrying the wake phrase become goals.
        const command = extractCommand(text);
        setPartial("");
        if (command) void sendGoal(command);
        return;
      }
      if (awaitingFinalRef.current) {
        awaitingFinalRef.current = false;
        if (finalTimerRef.current) clearTimeout(finalTimerRef.current);
        void sendGoal(text);
        return;
      }
      setPartial(text);
    },
  });

  const runEffect = useCallback(
    (effect: PttEffect) => {
      switch (effect) {
        case "startHoldRecognition":
          // A quick re-press can land inside the previous release's grace
          // window; without disarming it, the old timer would fire mid-hold
          // and ship the NEW utterance's half-finished partial as a goal.
          if (finalTimerRef.current) {
            clearTimeout(finalTimerRef.current);
            finalTimerRef.current = null;
          }
          awaitingFinalRef.current = false;
          setStatus(null);
          setPartial("");
          lastTranscriptRef.current = "";
          void speech.start(false);
          break;
        case "sendAndStopRecognition":
          awaitingFinalRef.current = true;
          void speech.stop();
          finalTimerRef.current = setTimeout(() => {
            if (!awaitingFinalRef.current) return;
            awaitingFinalRef.current = false;
            void sendGoal(lastTranscriptRef.current);
          }, FINAL_RESULT_GRACE_MS);
          setPartial("");
          break;
        case "enterLockedListening":
          // Recognition is already running from the hold; just flip it to
          // cycle forever and keep the feed poller alive.
          speech.setContinuous(true);
          setKeepPolling(true);
          setStatus(null);
          break;
        case "stopListening":
          setKeepPolling(false);
          void speech.stop();
          setPartial("");
          setStatus(null);
          break;
      }
    },
    [speech, sendGoal, setKeepPolling],
  );

  const dispatch = useCallback(
    (event: PttEvent) => {
      const result = transition(pttRef.current, event);
      pttRef.current = result.state;
      setPttState(result.state);
      if (result.effect) runEffect(result.effect);
    },
    [runEffect],
  );

  // PanResponder is created once; route through a ref so it always sees the
  // latest dispatch closure.
  const dispatchRef = useRef(dispatch);
  dispatchRef.current = dispatch;

  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onPanResponderGrant: () => {
        if (pttRef.current === "locked") dispatchRef.current("tapStop");
        else dispatchRef.current("pressIn");
      },
      onPanResponderMove: (_evt, gesture) => {
        if (pttRef.current === "holding" && gesture.dy < -LOCK_SLIDE_DISTANCE) {
          dispatchRef.current("slideToLock");
        }
      },
      onPanResponderRelease: () => dispatchRef.current("pressOut"),
      onPanResponderTerminate: () => dispatchRef.current("pressOut"),
    }),
  ).current;

  // Ending up unmounted mid-session must not leave the poller pinned on.
  useEffect(() => {
    return () => {
      setKeepPolling(false);
      if (finalTimerRef.current) clearTimeout(finalTimerRef.current);
    };
  }, [setKeepPolling]);

  const holding = pttState === "holding";
  const locked = pttState === "locked";

  return (
    <View style={[styles.container, { paddingTop: insets.top + spacing.md }]}>
      <View style={styles.approvals}>
        <ScrollView showsVerticalScrollIndicator={false}>
          {pendingApprovals.map((event) => (
            <ApprovalCard
              key={event.id}
              event={event}
              onDecide={(verdict) => {
                if (event.approvalId) void decide(event.approvalId, verdict);
              }}
            />
          ))}
        </ScrollView>
      </View>

      <View style={styles.transcriptZone}>
        {partial ? (
          <Text style={styles.partial} numberOfLines={4}>
            {partial}
          </Text>
        ) : status ? (
          <Text style={styles.status}>{status}</Text>
        ) : speech.error ? (
          <Text style={styles.status}>{speech.error}</Text>
        ) : null}
      </View>

      <View style={styles.micZone}>
        {holding ? (
          <View style={styles.lockTarget}>
            <Text style={styles.lockGlyph}>{"▲"}</Text>
            <Text style={styles.lockHint}>Slide up to lock</Text>
          </View>
        ) : (
          <View style={styles.lockTarget} />
        )}

        <View
          {...panResponder.panHandlers}
          style={[
            styles.micButton,
            holding && styles.micHolding,
            locked && styles.micLocked,
          ]}
        >
          <View
            style={[
              styles.micCore,
              (holding || locked) && styles.micCoreActive,
            ]}
          />
        </View>

        <Text style={styles.hint}>
          {locked
            ? "Listening — say 'Hey Mama', tap to stop"
            : holding
              ? "Release to send"
              : "Hold to talk"}
        </Text>
      </View>
    </View>
  );
}

const MIC_SIZE = 148;

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.bg,
    paddingHorizontal: spacing.md,
  },
  approvals: {
    maxHeight: 260,
  },
  transcriptZone: {
    flex: 1,
    justifyContent: "flex-end",
    alignItems: "center",
    paddingBottom: spacing.lg,
  },
  partial: {
    color: colors.text,
    fontSize: 24,
    fontWeight: "600",
    textAlign: "center",
    lineHeight: 32,
  },
  status: {
    color: colors.muted,
    fontSize: 18,
    textAlign: "center",
  },
  micZone: {
    alignItems: "center",
    paddingBottom: spacing.xl + spacing.md,
  },
  lockTarget: {
    height: 64,
    justifyContent: "center",
    alignItems: "center",
    marginBottom: spacing.md,
  },
  lockGlyph: {
    color: colors.accent,
    fontSize: 18,
  },
  lockHint: {
    color: colors.muted,
    fontSize: 13,
    marginTop: 2,
  },
  micButton: {
    width: MIC_SIZE,
    height: MIC_SIZE,
    borderRadius: MIC_SIZE / 2,
    borderWidth: 2,
    borderColor: colors.accent,
    backgroundColor: colors.surface,
    justifyContent: "center",
    alignItems: "center",
  },
  micHolding: {
    backgroundColor: colors.accentSoft,
    transform: [{ scale: 1.08 }],
  },
  micLocked: {
    backgroundColor: colors.accent,
  },
  micCore: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: colors.accent,
  },
  micCoreActive: {
    backgroundColor: colors.text,
  },
  hint: {
    color: colors.muted,
    fontSize: 16,
    marginTop: spacing.lg,
  },
});
