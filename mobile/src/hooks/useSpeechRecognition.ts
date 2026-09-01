import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Voice, {
  SpeechErrorEvent,
  SpeechResultsEvent,
} from "@react-native-voice/voice";

interface SpeechCallbacks {
  onPartial: (text: string) => void;
  onFinal: (text: string) => void;
}

/**
 * Lifecycle wrapper around @react-native-voice/voice: both platforms end
 * recognition sessions on their own (iOS ~1min cap, Android silence timeout),
 * so continuous mode restarts the engine on end/error. Needs a dev build, not
 * Expo Go; locked-mode BACKGROUND survival needs native work on both
 * platforms — the per-platform specifics live in mobile/README.md.
 */
export function useSpeechRecognition(callbacks: SpeechCallbacks) {
  const callbacksRef = useRef(callbacks);
  callbacksRef.current = callbacks;

  const continuousRef = useRef(false);
  const restartTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // True while startEngine's own stop→start is in flight. The defensive
  // Voice.stop() below fires onSpeechEnd/onSpeechError, and letting those
  // schedule ANOTHER restart tears down each fresh session ~400ms in — locked
  // mode turns deaf in a restart storm.
  const restartingRef = useRef(false);
  const [error, setError] = useState<string | null>(null);

  const startEngine = useCallback(async () => {
    restartingRef.current = true;
    try {
      // A stale session can leave the recognizer "busy"; stop before start
      // makes restarts idempotent.
      await Voice.stop().catch(() => undefined);
      await Voice.start("en-US");
      setError(null);
    } catch {
      setError("Speech recognition unavailable");
    } finally {
      restartingRef.current = false;
    }
  }, []);

  useEffect(() => {
    Voice.onSpeechPartialResults = (e: SpeechResultsEvent) => {
      const text = e.value?.[0];
      if (text) callbacksRef.current.onPartial(text);
    };
    Voice.onSpeechResults = (e: SpeechResultsEvent) => {
      const text = e.value?.[0];
      if (text) callbacksRef.current.onFinal(text);
    };

    const cycleIfContinuous = () => {
      if (!continuousRef.current) return;
      if (restartingRef.current) return;   // our own stop→start echo, not a real session end
      if (restartTimerRef.current) clearTimeout(restartTimerRef.current);
      // Small delay: restarting the instant the engine ends races the native
      // teardown on both platforms.
      restartTimerRef.current = setTimeout(() => void startEngine(), 400);
    };
    Voice.onSpeechEnd = cycleIfContinuous;
    Voice.onSpeechError = (_e: SpeechErrorEvent) => cycleIfContinuous();

    return () => {
      if (restartTimerRef.current) clearTimeout(restartTimerRef.current);
      continuousRef.current = false;
      void Voice.destroy().then(() => Voice.removeAllListeners());
    };
  }, [startEngine]);

  const start = useCallback(
    async (continuous: boolean) => {
      continuousRef.current = continuous;
      await startEngine();
    },
    [startEngine],
  );

  const stop = useCallback(async () => {
    continuousRef.current = false;
    if (restartTimerRef.current) clearTimeout(restartTimerRef.current);
    await Voice.stop().catch(() => undefined);
  }, []);

  // Stable identity: consumers put this in dep arrays, and a fresh object per
  // render would silently defeat every useCallback built on top of it.
  return useMemo(() => ({ start, stop, error }), [start, stop, error]);
}
