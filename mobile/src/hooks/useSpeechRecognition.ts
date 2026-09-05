import { useCallback, useMemo, useRef, useState } from "react";
import {
  ExpoSpeechRecognitionModule,
  useSpeechRecognitionEvent,
} from "expo-speech-recognition";

interface SpeechCallbacks {
  onPartial: (text: string) => void;
  onFinal: (text: string) => void;
}

/**
 * Lifecycle wrapper around expo-speech-recognition. (Its predecessor,
 * @react-native-voice/voice, started without error on current React Native but
 * its result events never arrived — the app looked deaf with nothing to show.)
 * Continuous mode is native here; the restart-on-end path is only a backstop
 * for platforms that still end sessions early. Locked-mode BACKGROUND survival
 * still needs native work — see mobile/README.md.
 */
export function useSpeechRecognition(callbacks: SpeechCallbacks) {
  const callbacksRef = useRef(callbacks);
  callbacksRef.current = callbacks;

  const continuousRef = useRef(false);
  const restartTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // True while our own stop→start is in flight, so the end/error events that
  // teardown fires don't schedule a second, session-killing restart.
  const restartingRef = useRef(false);
  const [error, setError] = useState<string | null>(null);

  const startEngine = useCallback(async () => {
    restartingRef.current = true;
    try {
      const permission = await ExpoSpeechRecognitionModule.requestPermissionsAsync();
      if (!permission.granted) {
        setError("Microphone or speech permission denied — enable both in Settings.");
        return;
      }
      ExpoSpeechRecognitionModule.start({
        lang: "en-US",
        interimResults: true,
        continuous: continuousRef.current,
      });
      setError(null);
    } catch (e) {
      setError(`Speech recognition unavailable${e instanceof Error ? `: ${e.message}` : ""}`);
    } finally {
      restartingRef.current = false;
    }
  }, []);

  useSpeechRecognitionEvent("result", (event) => {
    const text = event.results?.[0]?.transcript;
    if (!text) return;
    if (event.isFinal) callbacksRef.current.onFinal(text);
    else callbacksRef.current.onPartial(text);
  });

  useSpeechRecognitionEvent("end", () => {
    if (!continuousRef.current || restartingRef.current) return;
    if (restartTimerRef.current) clearTimeout(restartTimerRef.current);
    // Small delay: restarting the instant the engine ends races native teardown.
    restartTimerRef.current = setTimeout(() => void startEngine(), 400);
  });

  useSpeechRecognitionEvent("error", (event) => {
    // "no-speech" is the engine giving up on silence, not a failure — the
    // continuous restart path handles it; surfacing it would cry wolf.
    if (event.error === "no-speech" || event.error === "aborted") return;
    setError(event.message || event.error || "Speech recognition error");
  });

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
    try {
      ExpoSpeechRecognitionModule.stop();
    } catch {
      // Already stopped — nothing to unwind.
    }
  }, []);

  // Stable identity: consumers put this in dep arrays, and a fresh object per
  // render would silently defeat every useCallback built on top of it.
  return useMemo(() => ({ start, stop, error }), [start, stop, error]);
}
