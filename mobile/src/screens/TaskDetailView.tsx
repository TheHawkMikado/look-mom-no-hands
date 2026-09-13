import React, { useCallback, useEffect, useState } from "react";
import {
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { getTask, TaskDetail, TaskReceipt, Verdict } from "../lib/api";
import { taskStatusLabel } from "../lib/taskGroups";
import { formatRelative } from "../lib/time";
import { useFeed } from "../state/FeedContext";
import { StatusPill, statusColor } from "../components/StatusPill";
import { colors, spacing } from "../theme";

interface Props {
  taskId: string;
  onBack: () => void;
}

/** One task: what it is, who has it, the open approval, and its receipts. */
export function TaskDetailView({ taskId, onBack }: Props) {
  const { decide } = useFeed();
  const [detail, setDetail] = useState<TaskDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    try {
      setDetail(await getTask(taskId));
      setError(null);
    } catch {
      setError("Couldn't load this task.");
    }
  }, [taskId]);

  useEffect(() => {
    void load();
  }, [load]);

  const onRefresh = useCallback(async () => {
    setRefreshing(true);
    await load();
    setRefreshing(false);
  }, [load]);

  const openApproval = detail?.approvals.find((a) => !a.decided_at) ?? null;

  const onDecide = async (verdict: Verdict) => {
    if (!openApproval) return;
    // Same first-decision-wins path the Talk card uses; the feed's optimistic
    // overlay hides the card there too.
    await decide(openApproval.id, verdict);
    setTimeout(() => void load(), 800);
  };

  return (
    <View style={styles.container}>
      <Pressable onPress={onBack} style={styles.back} hitSlop={12}>
        <Text style={styles.backText}>{"‹ Tasks"}</Text>
      </Pressable>
      <ScrollView
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={() => void onRefresh()} tintColor={colors.accent} />
        }
        contentContainerStyle={styles.content}
      >
        {!detail ? (
          <Text style={styles.empty}>{error ?? "Loading…"}</Text>
        ) : (
          <>
            <Text style={styles.title}>{detail.task.title}</Text>
            <View style={styles.pillRow}>
              <StatusPill
                label={taskStatusLabel(detail.task.status)}
                color={statusColor(detail.task.status)}
              />
              <Text style={styles.meta}>
                {ownerLabel(detail)}
                {detail.task.paperclip_issue_key ? ` · ${detail.task.paperclip_issue_key}` : ""}
                {` · tier ${detail.task.blast_tier}`}
              </Text>
            </View>
            {detail.task.detail ? <Text style={styles.detail}>{detail.task.detail}</Text> : null}
            {detail.task.confirmation ? (
              <Text style={styles.confirmation}>"{detail.task.confirmation}"</Text>
            ) : null}
            {detail.task.result ? (
              <View style={styles.card}>
                <Text style={styles.label}>Result</Text>
                <Text style={styles.body}>{detail.task.result}</Text>
              </View>
            ) : null}

            {openApproval ? (
              <View style={[styles.card, styles.approvalCard]}>
                <Text style={[styles.label, { color: colors.warning }]}>Needs your approval</Text>
                <Text style={styles.body}>{openApproval.question}</Text>
                <View style={styles.row}>
                  <Pressable
                    style={({ pressed }) => [styles.approve, pressed && styles.pressed]}
                    onPress={() => void onDecide("approve")}
                  >
                    <Text style={styles.approveText}>Approve</Text>
                  </Pressable>
                  <Pressable
                    style={({ pressed }) => [styles.deny, pressed && styles.pressed]}
                    onPress={() => void onDecide("deny")}
                  >
                    <Text style={styles.denyText}>Don't run</Text>
                  </Pressable>
                </View>
              </View>
            ) : null}

            <Text style={styles.section}>Receipts</Text>
            {detail.receipts.length === 0 ? (
              <Text style={styles.empty}>No receipts yet.</Text>
            ) : (
              detail.receipts.map((r) => <ReceiptRow key={r.id} receipt={r} />)
            )}
          </>
        )}
      </ScrollView>
    </View>
  );
}

function ownerLabel(detail: TaskDetail): string {
  const t = detail.task;
  if (t.owner_kind === "user") return "Your call";
  return t.owner_name ?? (t.owner_kind === "agent" ? "Agent" : "Teammate");
}

function ReceiptRow({ receipt }: { receipt: TaskReceipt }) {
  const cost = receipt.cost_cents > 0 ? ` · $${(receipt.cost_cents / 100).toFixed(2)}` : "";
  return (
    <View style={styles.receipt}>
      <View style={styles.receiptHead}>
        <Text style={styles.receiptActor}>
          {receipt.actor}
          {receipt.actor_ref ? ` · ${receipt.actor_ref}` : ""}
          {receipt.model_used ? ` · ${receipt.model_used}` : ""}
          {cost}
        </Text>
        <Text style={styles.receiptTime}>{formatRelative(receipt.created_at)}</Text>
      </View>
      <Text style={styles.body}>{receipt.summary}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  back: {
    paddingVertical: spacing.sm,
    alignSelf: "flex-start",
  },
  backText: {
    color: colors.accent,
    fontSize: 17,
    fontWeight: "600",
  },
  content: {
    paddingBottom: spacing.xl,
  },
  title: {
    color: colors.text,
    fontSize: 22,
    fontWeight: "700",
    marginBottom: spacing.sm,
  },
  pillRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.sm,
    marginBottom: spacing.sm,
    flexWrap: "wrap",
  },
  meta: {
    color: colors.muted,
    fontSize: 13,
  },
  detail: {
    color: colors.text,
    fontSize: 15,
    lineHeight: 21,
    marginBottom: spacing.sm,
  },
  confirmation: {
    color: colors.muted,
    fontSize: 14,
    fontStyle: "italic",
    marginBottom: spacing.md,
  },
  card: {
    backgroundColor: colors.surface,
    borderRadius: 14,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  approvalCard: {
    borderColor: colors.warning,
    borderWidth: 1,
  },
  label: {
    color: colors.muted,
    fontSize: 12,
    fontWeight: "600",
    letterSpacing: 0.8,
    textTransform: "uppercase",
    marginBottom: spacing.xs,
  },
  body: {
    color: colors.text,
    fontSize: 14,
    lineHeight: 20,
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
  section: {
    color: colors.muted,
    fontSize: 12,
    fontWeight: "600",
    letterSpacing: 0.8,
    textTransform: "uppercase",
    marginTop: spacing.md,
    marginBottom: spacing.sm,
  },
  receipt: {
    backgroundColor: colors.surface,
    borderRadius: 12,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  receiptHead: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginBottom: spacing.xs,
    gap: spacing.sm,
  },
  receiptActor: {
    flex: 1,
    color: colors.accent,
    fontSize: 12,
    fontWeight: "600",
  },
  receiptTime: {
    color: colors.muted,
    fontSize: 11,
  },
  empty: {
    color: colors.muted,
    fontSize: 14,
    textAlign: "center",
    marginTop: spacing.md,
  },
});
