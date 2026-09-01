import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import { AppState } from "react-native";
import * as Speech from "expo-speech";
import {
  decideApproval,
  FeedEvent,
  getFeed,
  Verdict,
} from "../lib/api";

const POLL_MS = 5000;
const SPOKEN_DETAIL_CAP = 200;

interface FeedContextValue {
  events: FeedEvent[];
  verdicts: Record<string, Verdict>;
  /** needs_approval events with no verdict yet, newest first. */
  pendingApprovals: FeedEvent[];
  loaded: boolean;
  refresh: () => Promise<void>;
  decide: (approvalId: string, verdict: Verdict) => Promise<void>;
  /** Locked listening keeps polling alive even while the app is backgrounded. */
  setKeepPolling: (on: boolean) => void;
}

const FeedContext = createContext<FeedContextValue | null>(null);

export function useFeed(): FeedContextValue {
  const value = useContext(FeedContext);
  if (!value) throw new Error("useFeed outside FeedProvider");
  return value;
}

export function FeedProvider({ children }: { children: React.ReactNode }) {
  const [events, setEvents] = useState<FeedEvent[]>([]);
  const [verdicts, setVerdicts] = useState<Record<string, Verdict>>({});
  const [loaded, setLoaded] = useState(false);
  const [keepPolling, setKeepPolling] = useState(false);
  const [appActive, setAppActive] = useState(AppState.currentState === "active");
  const lastSpokenIdRef = useRef<string | null>(null);

  const speakNewResults = useCallback((fresh: FeedEvent[]) => {
    if (fresh.length === 0) return;
    // First fetch of the session: mark everything as seen so an old backlog
    // doesn't get read aloud on launch.
    if (lastSpokenIdRef.current === null) {
      lastSpokenIdRef.current = fresh[0].id;
      return;
    }
    const newer: FeedEvent[] = [];
    for (const event of fresh) {
      if (event.id === lastSpokenIdRef.current) break;
      newer.push(event);
    }
    lastSpokenIdRef.current = fresh[0].id;
    // Oldest first so results are announced in the order they happened.
    for (const event of newer.reverse()) {
      if (event.kind !== "goal_done" && event.kind !== "goal_failed") continue;
      const detail = event.detail ? `. ${event.detail.slice(0, SPOKEN_DETAIL_CAP)}` : "";
      Speech.speak(`${event.title}${detail}`, { language: "en-US" });
    }
  }, []);

  const refresh = useCallback(async () => {
    try {
      const feed = await getFeed();
      setEvents(feed.events);
      setVerdicts(feed.verdicts);
      setLoaded(true);
      speakNewResults(feed.events);
    } catch {
      // Polling is best-effort; the next tick retries. A 401 already flipped
      // the app to signed-out via the api client's unauthorized handler.
    }
  }, [speakNewResults]);

  useEffect(() => {
    const sub = AppState.addEventListener("change", (state) => {
      setAppActive(state === "active");
    });
    return () => sub.remove();
  }, []);

  useEffect(() => {
    if (!appActive && !keepPolling) return;
    void refresh();
    const interval = setInterval(() => void refresh(), POLL_MS);
    return () => clearInterval(interval);
  }, [appActive, keepPolling, refresh]);

  const decide = useCallback(
    async (approvalId: string, verdict: Verdict) => {
      // Optimistic: hide the card immediately, reconcile on the next poll.
      setVerdicts((prev) => ({ ...prev, [approvalId]: verdict }));
      try {
        await decideApproval(approvalId, verdict);
      } catch {
        setVerdicts((prev) => {
          const next = { ...prev };
          delete next[approvalId];
          return next;
        });
      }
    },
    [],
  );

  const pendingApprovals = events.filter(
    (e) =>
      e.kind === "needs_approval" &&
      e.approvalId != null &&
      verdicts[e.approvalId] === undefined,
  );

  return (
    <FeedContext.Provider
      value={{
        events,
        verdicts,
        pendingApprovals,
        loaded,
        refresh,
        decide,
        setKeepPolling,
      }}
    >
      {children}
    </FeedContext.Provider>
  );
}
