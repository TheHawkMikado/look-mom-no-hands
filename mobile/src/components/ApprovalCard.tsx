import React from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { FeedEvent, Verdict } from "../lib/api";
import { colors, spacing } from "../theme";

interface Props {
  event: FeedEvent;
  onDecide: (verdict: Verdict) => void;
}

/** Prominent approve/deny card for an agent command awaiting a verdict. */
export function ApprovalCard({ event, onDecide }: Props) {
  return (
    <View style={styles.card}>
      <Text style={styles.badge}>NEEDS APPROVAL</Text>
      <Text style={styles.title}>{event.title}</Text>
      {event.detail ? <Text style={styles.detail}>{event.detail}</Text> : null}
      <View style={styles.row}>
        <Pressable
          style={({ pressed }) => [styles.approve, pressed && styles.pressed]}
          onPress={() => onDecide("approve")}
        >
          <Text style={styles.approveText}>Approve</Text>
        </Pressable>
        <Pressable
          style={({ pressed }) => [styles.deny, pressed && styles.pressed]}
          onPress={() => onDecide("deny")}
        >
          <Text style={styles.denyText}>Don't run</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderColor: colors.warning,
    borderWidth: 1,
    borderRadius: 16,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  badge: {
    color: colors.warning,
    fontSize: 11,
    fontWeight: "700",
    letterSpacing: 1.2,
    marginBottom: spacing.xs,
  },
  title: {
    color: colors.text,
    fontSize: 17,
    fontWeight: "600",
  },
  detail: {
    color: colors.muted,
    fontSize: 14,
    marginTop: spacing.xs,
  },
  row: {
    flexDirection: "row",
    gap: spacing.sm,
    marginTop: spacing.md,
  },
  approve: {
    flex: 1,
    backgroundColor: colors.accent,
    borderRadius: 12,
    paddingVertical: 12,
    alignItems: "center",
  },
  approveText: {
    color: colors.text,
    fontSize: 15,
    fontWeight: "700",
  },
  deny: {
    flex: 1,
    borderColor: colors.danger,
    borderWidth: 1,
    borderRadius: 12,
    paddingVertical: 12,
    alignItems: "center",
  },
  denyText: {
    color: colors.danger,
    fontSize: 15,
    fontWeight: "700",
  },
  pressed: {
    opacity: 0.7,
  },
});
