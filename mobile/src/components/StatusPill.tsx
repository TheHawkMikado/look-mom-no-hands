import React from "react";
import { StyleSheet, Text, View } from "react-native";
import { colors } from "../theme";

/** Colour for a status string from either the task pipeline or Paperclip. */
export function statusColor(status: string): string {
  const s = status.toLowerCase();
  if (s === "done" || s === "approved" || s === "closed" || s === "completed") return colors.success;
  if (s === "failed" || s === "denied" || s === "blocked" || s === "cancelled" || s === "canceled") return colors.danger;
  if (s === "awaiting_approval" || s === "needs_decision" || s === "in_review" || s === "review") return colors.warning;
  if (s === "in_progress" || s === "dispatching" || s === "approved" || s === "active") return colors.accent;
  return colors.muted;
}

interface Props {
  label: string;
  /** Defaults to a colour derived from the label itself. */
  color?: string;
}

/** Small bordered pill, tinted by status. */
export function StatusPill({ label, color }: Props) {
  const tint = color ?? statusColor(label);
  return (
    <View style={[styles.pill, { borderColor: tint }]}>
      <Text style={[styles.text, { color: tint }]} numberOfLines={1}>
        {label.replace(/_/g, " ")}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  pill: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 8,
    paddingVertical: 2,
    alignSelf: "flex-start",
  },
  text: {
    fontSize: 11,
    fontWeight: "700",
    letterSpacing: 0.4,
    textTransform: "uppercase",
  },
});
