import React, { useCallback, useEffect, useMemo, useState } from "react";
import { FlatList, RefreshControl, StyleSheet, Text, View } from "react-native";
import { useIsFocused } from "@react-navigation/native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { BoardItem, BoardMember, getTeam, TeamSnapshot } from "../lib/api";
import { formatRelative } from "../lib/time";
import { MemberCard } from "../components/MemberCard";
import { colors, spacing } from "../theme";

const POLL_MS = 10000;

type Card =
  | { id: string; kind: "member"; member: BoardMember }
  | { id: string; kind: "unassigned"; items: BoardItem[] };

/** Every teammate's board — bots and humans — polled while this tab is up. */
export function TeamScreen() {
  const insets = useSafeAreaInsets();
  const focused = useIsFocused();
  const [snapshot, setSnapshot] = useState<TeamSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    try {
      setSnapshot(await getTeam());
      setError(null);
    } catch {
      // Keep the last snapshot on screen; just say it's stale.
      setError("Couldn't refresh the board.");
    }
  }, []);

  useEffect(() => {
    if (!focused) return;
    void load();
    const interval = setInterval(() => void load(), POLL_MS);
    return () => clearInterval(interval);
  }, [focused, load]);

  const onRefresh = useCallback(async () => {
    setRefreshing(true);
    await load();
    setRefreshing(false);
  }, [load]);

  const cards = useMemo<Card[]>(() => {
    if (!snapshot) return [];
    const list: Card[] = snapshot.members.map((m) => ({ id: m.id, kind: "member", member: m }));
    if (snapshot.unassigned.length > 0) {
      list.push({ id: "__unassigned", kind: "unassigned", items: snapshot.unassigned });
    }
    return list;
  }, [snapshot]);

  const renderItem = useCallback(({ item }: { item: Card }) => {
    if (item.kind === "unassigned") {
      return <MemberCard name="Unassigned" kind="unassigned" items={item.items} />;
    }
    const m = item.member;
    return <MemberCard name={m.name} kind={m.kind} title={m.title} status={m.status} items={m.items} />;
  }, []);

  return (
    <View style={[styles.container, { paddingTop: insets.top + spacing.md }]}>
      <Text style={styles.heading}>Team</Text>
      {snapshot ? (
        <Text style={styles.summary}>
          {snapshot.counts.in_progress} working · {snapshot.counts.in_review} in review ·{" "}
          {snapshot.counts.blocked} blocked · {snapshot.counts.open} open
          {snapshot.captured_at ? ` · as of ${formatRelative(snapshot.captured_at)}` : ""}
          {error ? ` · ${error}` : ""}
        </Text>
      ) : null}
      <FlatList
        data={cards}
        keyExtractor={(c) => c.id}
        renderItem={renderItem}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={() => void onRefresh()} tintColor={colors.accent} />
        }
        ListEmptyComponent={
          <Text style={styles.empty}>
            {!snapshot
              ? error ?? "Loading…"
              : snapshot.has_paperclip
                ? "Nobody has anything on the board."
                : "No team yet — connect Paperclip on the web to see everyone's board."}
          </Text>
        }
        contentContainerStyle={styles.listContent}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.bg,
    paddingHorizontal: spacing.md,
  },
  heading: {
    color: colors.text,
    fontSize: 28,
    fontWeight: "700",
    marginBottom: spacing.xs,
  },
  summary: {
    color: colors.muted,
    fontSize: 13,
    marginBottom: spacing.md,
  },
  listContent: {
    paddingBottom: spacing.xl,
  },
  empty: {
    color: colors.muted,
    fontSize: 15,
    textAlign: "center",
    marginTop: spacing.xl,
  },
});
