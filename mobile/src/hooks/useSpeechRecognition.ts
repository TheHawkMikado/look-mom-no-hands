import { useCallback, useMemo, useRef, useState } from "react";
import {
  ExpoSpeechRecognitionModule,
  useSpeechRecognitionEvent,
} from "expo-speech-recognition";
import { takeSegment } from "../lib/segments";

/** Default silence that ends an utterance in continuous mode — right for
 * note-taking, where a cut only decides where a paragraph break lands.
 * Consumers for whom a cut is destructive (a task split mid-command ran as
 * "open" without its "amazon.com") pass a longer gap to start(). */
const DEFAULT_SEGMENT_SILENCE_MS = 1200;

export interface StartOptions {
  /** Silence gap, in ms, that cuts a segment in continuous mode. */
  silenceMs?: number;
}

interface SpeechCallbacks {
  onPartial: (text: string) => void;
  onFinal: (text: string) => void;
  /**
   * Continuous mode only: one spoken utterance, cut on a silence gap. This is
   * the channel locked mode and note-taking must consume — iOS delivers
   * continuous results as one cumulative transcript whose isFinal essentially
   * never fires mid-session, so `onFinal` cannot be relied on there.
   */
  onSegment?: (text: string) => void;
}

/**
 * The native engine is a singleton and every hook instance hears every event.
 * With more than one consumer mounted (Talk's mic, a dictate button on Tasks),
 * results are routed to whichever instance started the engine last; the owner
 * is only ever reassigned by a start, never cleared, so a final result that
 * lands after stop() still reaches the instance that asked for it.
 */
let engineOwner = 0;
let nextInstanceId = 1;

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
  const instanceIdRef = useRef(0);
  if (instanceIdRef.current === 0) instanceIdRef.current = nextInstanceId++;

  const continuousRef = useRef(false);
  const restartTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // True while our own stop→start is in flight, so the end/error events that
  // teardown fires don't schedule a second, session-killing restart.
  const restartingRef = useRef(false);
  const [error, setError] = useState<string | null>(null);

  // Segmentation state: how much of the cumulative transcript has already been
  // handed out as segments, plus the silence timer that cuts the next one.
  const processedRef = useRef(0);
  const transcriptRef = useRef("");
  const silenceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const silenceMsRef = useRef(DEFAULT_SEGMENT_SILENCE_MS);

  const clearSilenceTimer = useCallback(() => {
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
  }, []);

  const cutSegment = useCallback(() => {
    const { segment, processed } = takeSegment(
      processedRef.current,
      transcriptRef.current,
    );
    processedRef.current = processed;
    if (segment) callbacksRef.current.onSegment?.(segment);
  }, []);

  const startEngine = useCallback(async () => {
    restartingRef.current = true;
    engineOwner = instanceIdRef.current;
    try {
      const permission = await ExpoSpeechRecognitionModule.requestPermissionsAsync();
      if (!permission.granted) {
        setError("Microphone or speech permission denied — enable both in Settings.");
        return;
      }
      // A restart begins a fresh native transcript; the segment counter must
      // follow it or the first words after a restart would be sliced away.
      transcriptRef.current = "";
      processedRef.current = 0;
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
    if (engineOwner !== instanceIdRef.current) return;
    const text = event.results?.[0]?.transcript;
    if (!text) return;
    transcriptRef.current = text;
    if (event.isFinal) {
      callbacksRef.current.onFinal(text);
      // A real final is a hard utterance boundary — cut immediately rather
      // than waiting out the silence window.
      if (continuousRef.current) {
        clearSilenceTimer();
        cutSegment();
      }
      return;
    }
    callbacksRef.current.onPartial(text);
    if (continuousRef.current) {
      clearSilenceTimer();
      silenceTimerRef.current = setTimeout(cutSegment, silenceMsRef.current);
    }
  });

  useSpeechRecognitionEvent("end", () => {
    if (engineOwner !== instanceIdRef.current) return;
    // Whatever was said just before the engine ended must not evaporate.
    if (continuousRef.current) {
      clearSilenceTimer();
      cutSegment();
    }
    if (!continuousRef.current || restartingRef.current) return;
    if (restartTimerRef.current) clearTimeout(restartTimerRef.current);
    // Small delay: restarting the instant the engine ends races native teardown.
    restartTimerRef.current = setTimeout(() => void startEngine(), 400);
  });

  useSpeechRecognitionEvent("error", (event) => {
    if (engineOwner !== instanceIdRef.current) return;
    // "no-speech" is the engine giving up on silence, not a failure — the
    // continuous restart path handles it; surfacing it would cry wolf.
    if (event.error === "no-speech" || event.error === "aborted") return;
    setError(event.message || event.error || "Speech recognition error");
  });

  const start = useCallback(
    async (continuous: boolean, options: StartOptions = {}) => {
      continuousRef.current = continuous;
      silenceMsRef.current = options.silenceMs ?? DEFAULT_SEGMENT_SILENCE_MS;
      await startEngine();
    },
    [startEngine],
  );

  const stop = useCallback(async () => {
    continuousRef.current = false;
    clearSilenceTimer();
    if (restartTimerRef.current) clearTimeout(restartTimerRef.current);
    try {
      ExpoSpeechRecognitionModule.stop();
    } catch {
      // Already stopped — nothing to unwind.
    }
  }, [clearSilenceTimer]);

  // Stable identity: consumers put this in dep arrays, and a fresh object per
  // render would silently defeat every useCallback built on top of it.
  return useMemo(() => ({ start, stop, error }), [start, stop, error]);
}
