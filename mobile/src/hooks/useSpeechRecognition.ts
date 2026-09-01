import { useCallback, useEffect, useRef, useState } from "react";
import Voice, {
  SpeechErrorEvent,
  SpeechResultsEvent,
} from "@react-native-voice/voice";

interface SpeechCallbacks {
  onPartial: (text: string) => void;
  onFinal: (text: string) => void;
}

/**
 * Thin lifecycle wrapper around @react-native-voice/voice.
 *
 * Both platforms end recognition sessions on their own (iOS caps at about a
 * minute, Android stops after a silence timeout), so in continuous mode we
 * restart the engine whenever it reports end/error. Callbacks are kept in a
 * ref so the native listeners are registered exactly once.
 *
 * NOTE: @react-native-voice/voice needs a dev build (expo prebuild / EAS) —
 * it is not available in Expo Go.
 *
 * TODO(dev-build): background listening for locked mode.
 * - iOS: UIBackgroundModes ["audio"] is declared, but SFSpeechRecognizer is
 *   still suspended in the background unless an AVAudioSession is kept active
 *   (native module or config-plugin work).
 * - Android: start a microphone foreground service (persistent notification)
 *   when locked mode begins; the FOREGROUND_SERVICE(_MICROPHONE) permissions
 *   are declared in app.json but no service exists yet.
 */
export function useSpeechRecognition(callbacks: SpeechCallbacks) {
  const callbacksRef = useRef(callbacks);
  callbacksRef.current = callbacks;

  const continuousRef = useRef(false);
  const restartTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [error, setError] = useState<string | null>(null);

  const startEngine = useCallback(async () => {
    try {
      // A stale session can leave the recognizer "busy"; stop before start
      // makes restarts idempotent.
      await Voice.stop().catch(() => undefined);
      await Voice.start("en-US");
      setError(null);
    } catch {
      setError("Speech recognition unavailable");
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

  /** Flip an already-running session into continuous (locked) mode. */
  const setContinuous = useCallback((value: boolean) => {
    continuousRef.current = value;
  }, []);

  const stop = useCallback(async () => {
    continuousRef.current = false;
    if (restartTimerRef.current) clearTimeout(restartTimerRef.current);
    await Voice.stop().catch(() => undefined);
  }, []);

  return { start, stop, setContinuous, error };
}
