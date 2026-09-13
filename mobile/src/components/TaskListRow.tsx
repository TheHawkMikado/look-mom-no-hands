import React from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { Task } from "../lib/api";
import { taskStatusLabel } from "../lib/taskGroups";
import { formatRelative } from "../lib/time";
import { StatusPill, statusColor } from "./StatusPill";
import { colors, spacing } from "../theme";

interface Props {
  task: Task;
  onPress: () => void;
}

/** One task in the grouped list: title, owner, status pill, age. */
export const TaskListRow = React.memo(function TaskListRow({ task, onPress }: Props) {
  const owner =
    task.owner_kind === "user" ? "You" : task.owner_name ?? (task.owner_kind === "agent" ? "Agent" : "Teammate");
  return (
    <Pressable style={({ pressed }) => [styles.row, pressed && styles.pressed]} onPress={onPress}>
      <View style={styles.body}>
        <Text style={styles.title} numberOfLines={2}>
          {task.title}
        </Text>
        <Text style={styles.meta} numberOfLines={1}>
          {owner}
          {task.paperclip_issue_key ? ` · ${task.paperclip_issue_key}` : ""}
          {` · tier ${task.blast_tier}`}
        </Text>
      </View>
      <View style={styles.side}>
        <StatusPill label={taskStatusLabel(task.status)} color={statusColor(task.status)} />
        <Text style={styles.time}>{formatRelative(task.updated_at)}</Text>
      </View>
    </Pressable>
  );
});

const styles = StyleSheet.create({
  row: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: colors.surface,
    borderRadius: 14,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  pressed: {
    opacity: 0.7,
  },
  body: {
    flex: 1,
    marginRight: spacing.sm,
  },
  title: {
    color: colors.text,
    fontSize: 15,
    fontWeight: "600",
  },
  meta: {
    color: colors.muted,
    fontSize: 12,
    marginTop: 2,
  },
  side: {
    alignItems: "flex-end",
    gap: spacing.xs,
  },
  time: {
    color: colors.muted,
    fontSize: 11,
  },
});
