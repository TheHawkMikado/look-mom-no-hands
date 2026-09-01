import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
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
  /** needs_approval events with no verdict yet, newest first, deduped. */
  pendingApprovals: FeedEvent[];
  loaded: boolean;
  refresh: () => Promise<void>;
  decide: (approvalId: string, verdict: Verdict) => Promise<void>;
  /** Locked listening keeps polling alive even while the app is backgrounded.
   *  (Today that only helps on platforms where the JS thread stays alive —
   *  true background survival is the native pass documented in the README.) */
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
  const [serverVerdicts, setServerVerdicts] = useState<Record<string, Verdict>>({});
  // Optimistic verdicts live SEPARATELY and overlay the server's: a poll
  // response computed before the decide committed must not resurrect the
  // approval card (tap Approve, card flashes back, user taps Deny — the
  // second tap would silently lose to first-decision-wins).
  const [optimisticVerdicts, setOptimisticVerdicts] = useState<Record<string, Verdict>>({});
  const [loaded, setLoaded] = useState(false);
  const [keepPolling, setKeepPolling] = useState(false);
  const [appActive, setAppActive] = useState(AppState.currentState === "active");
  const lastSpokenIdRef = useRef<string | null>(null);

  const speakNewResults = useCallback((fresh: FeedEvent[]) => {
    const anchor = lastSpokenIdRef.current;
    // First SUCCESSFUL fetch sets the anchor even when the feed is empty ("" =
    // no history, everything later is new). Anchoring only on the first
    // non-empty fetch muted the very first result a fresh account ever gets.
    if (anchor === null) {
      lastSpokenIdRef.current = fresh[0]?.id ?? "";
      return;
    }
    if (fresh.length === 0) return;
    const newer: FeedEvent[] = [];
    let anchorFound = anchor === "";
    if (anchor === "") {
      newer.push(...fresh);
    } else {
      for (const event of fresh) {
        if (event.id === anchor) {
          anchorFound = true;
          break;
        }
        newer.push(event);
      }
    }
    lastSpokenIdRef.current = fresh[0].id;
    // Anchor pruned past retention (backgrounded through a busy stretch):
    // resync silently rather than reading the entire window aloud.
    if (!anchorFound) return;
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
      setLoaded(true);
      // null = server said 304: nothing changed, no state churn, no re-render.
      if (feed === null) return;
      setEvents(feed.events);
      setServerVerdicts(feed.verdicts);
      // Server confirmations retire their optimistic overlays.
      setOptimisticVerdicts((prev) => {
        const next = { ...prev };
        for (const id of Object.keys(next)) if (feed.verdicts[id]) delete next[id];
        return next;
      });
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
      // Optimistic: hide the card immediately, reconcile when a poll confirms.
      setOptimisticVerdicts((prev) => ({ ...prev, [approvalId]: verdict }));
      try {
        const { recorded } = await decideApproval(approvalId, verdict);
        // recorded:false = someone decided first and OUR verdict lost — keeping
        // the overlay would show the user the opposite of what actually ran.
        if (!recorded) {
          setOptimisticVerdicts((prev) => {
            const next = { ...prev };
            delete next[approvalId];
            return next;
          });
        }
      } catch {
        setOptimisticVerdicts((prev) => {
          const next = { ...prev };
          delete next[approvalId];
          return next;
        });
      }
    },
    [],
  );

  const verdicts = useMemo(
    () => ({ ...serverVerdicts, ...optimisticVerdicts }),
    [serverVerdicts, optimisticVerdicts],
  );

  const pendingApprovals = useMemo(() => {
    // Dedupe by approvalId: the Mac may re-report a needs_approval for the
    // same decision, and two cards for one question invites two verdicts.
    const seen = new Set<string>();
    return events.filter((e) => {
      if (e.kind !== "needs_approval" || e.approvalId == null) return false;
      if (verdicts[e.approvalId] !== undefined || seen.has(e.approvalId)) return false;
      seen.add(e.approvalId);
      return true;
    });
  }, [events, verdicts]);

  const value = useMemo(
    () => ({ events, pendingApprovals, loaded, refresh, decide, setKeepPolling }),
    [events, pendingApprovals, loaded, refresh, decide],
  );

  return <FeedContext.Provider value={value}>{children}</FeedContext.Provider>;
}
