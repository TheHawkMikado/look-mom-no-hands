import React, { useCallback, useState } from "react";
import {
  FlatList,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { FeedEvent, FeedEventKind } from "../lib/api";
import { formatRelative } from "../lib/time";
import { useFeed } from "../state/FeedContext";
import { colors, spacing } from "../theme";

const KIND_META: Record<FeedEventKind, { glyph: string; color: string }> = {
  goal_started: { glyph: "▸", color: colors.accent },
  goal_progress: { glyph: "…", color: colors.muted },
  needs_approval: { glyph: "!", color: colors.warning },
  goal_done: { glyph: "✓", color: colors.success },
  goal_failed: { glyph: "✕", color: colors.danger },
};

// Memoized: rows are keyed by immutable event id, and the poll replaces the
// whole events array on every change — while an agent is running (exactly when
// the user watches this screen), identity comparison prunes the re-renders.
const EventRow = React.memo(function EventRow({ event }: { event: FeedEvent }) {
  const meta = KIND_META[event.kind] ?? KIND_META.goal_progress;
  return (
    <View style={styles.row}>
      <View style={[styles.iconCircle, { borderColor: meta.color }]}>
        <Text style={[styles.icon, { color: meta.color }]}>{meta.glyph}</Text>
      </View>
      <View style={styles.rowBody}>
        <Text style={styles.title} numberOfLines={1}>
          {event.title}
        </Text>
        {event.detail ? (
          <Text style={styles.detail} numberOfLines={2}>
            {event.detail}
          </Text>
        ) : null}
      </View>
      <Text style={styles.time}>{formatRelative(event.createdAt)}</Text>
    </View>
  );
});

export function ActivityScreen() {
  const insets = useSafeAreaInsets();
  const { events, loaded, refresh } = useFeed();
  const [refreshing, setRefreshing] = useState(false);

  const onRefresh = useCallback(async () => {
    setRefreshing(true);
    await refresh();
    setRefreshing(false);
  }, [refresh]);

  const renderItem = useCallback(
    ({ item }: { item: FeedEvent }) => <EventRow event={item} />,
    [],
  );

  return (
    <View style={[styles.container, { paddingTop: insets.top + spacing.md }]}>
      <Text style={styles.heading}>Activity</Text>
      <FlatList
        data={events}
        keyExtractor={(item) => item.id}
        renderItem={renderItem}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={() => void onRefresh()}
            tintColor={colors.accent}
          />
        }
        ListEmptyComponent={
          <Text style={styles.empty}>
            {loaded
              ? "Nothing yet — hold the mic and ask for something."
              : "Loading…"}
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
    marginBottom: spacing.md,
  },
  listContent: {
    paddingBottom: spacing.xl,
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: colors.surface,
    borderRadius: 14,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  iconCircle: {
    width: 32,
    height: 32,
    borderRadius: 16,
    borderWidth: 1.5,
    justifyContent: "center",
    alignItems: "center",
    marginRight: spacing.md,
  },
  icon: {
    fontSize: 15,
    fontWeight: "700",
  },
  rowBody: {
    flex: 1,
    marginRight: spacing.sm,
  },
  title: {
    color: colors.text,
    fontSize: 15,
    fontWeight: "600",
  },
  detail: {
    color: colors.muted,
    fontSize: 13,
    marginTop: 2,
  },
  time: {
    color: colors.muted,
    fontSize: 12,
  },
  empty: {
    color: colors.muted,
    fontSize: 15,
    textAlign: "center",
    marginTop: spacing.xl,
  },
});
