import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  RefreshControl,
  SectionList,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import * as Speech from "expo-speech";
import { useIsFocused, useRoute, RouteProp } from "@react-navigation/native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { ApiError, Task } from "../lib/api";
import { groupTasks } from "../lib/taskGroups";
import { RootTabParamList } from "../navigation";
import { useTasks } from "../state/TasksContext";
import { DictateButton } from "../components/DictateButton";
import { PromptCard } from "../components/PromptCard";
import { TaskListRow } from "../components/TaskListRow";
import { TaskDetailView } from "./TaskDetailView";
import { colors, spacing } from "../theme";

const POLL_MS = 10000;

export function TasksScreen() {
  const insets = useSafeAreaInsets();
  const route = useRoute<RouteProp<RootTabParamList, "Tasks">>();
  const focused = useIsFocused();
  const { tasks, prompts, loaded, refresh, answerPrompt, submitRequest } = useTasks();

  const [selectedId, setSelectedId] = useState<string | null>(route.params?.taskId ?? null);
  const [refreshing, setRefreshing] = useState(false);
  const [draft, setDraft] = useState("");
  const [draftSource, setDraftSource] = useState<"text" | "voice">("text");
  const [sending, setSending] = useState(false);
  const [confirmation, setConfirmation] = useState<string | null>(null);

  // A notification tap or a row tap can land here with a task to open.
  useEffect(() => {
    if (route.params?.taskId) setSelectedId(route.params.taskId);
  }, [route.params?.taskId]);

  useEffect(() => {
    if (!focused) return;
    void refresh();
    const interval = setInterval(() => void refresh(), POLL_MS);
    return () => clearInterval(interval);
  }, [focused, refresh]);

  const onRefresh = useCallback(async () => {
    setRefreshing(true);
    await refresh();
    setRefreshing(false);
  }, [refresh]);

  const send = useCallback(async () => {
    const text = draft.trim();
    if (!text || sending) return;
    setSending(true);
    setConfirmation(null);
    try {
      const result = await submitRequest(text, draftSource);
      setDraft("");
      setDraftSource("text");
      setConfirmation(result.confirmation);
      // The confirmation is written to be spoken — same voice as results.
      Speech.speak(result.confirmation, { language: "en-US" });
    } catch (e) {
      if (!(e instanceof ApiError && e.status === 401)) {
        setConfirmation("Couldn't reach the server — try again in a moment.");
      }
    } finally {
      setSending(false);
    }
  }, [draft, draftSource, sending, submitRequest]);

  const sections = useMemo(
    () => groupTasks(tasks).map((g) => ({ key: g.key, title: g.label, data: g.tasks })),
    [tasks],
  );

  const renderItem = useCallback(
    ({ item }: { item: Task }) => <TaskListRow task={item} onPress={() => setSelectedId(item.id)} />,
    [],
  );

  if (selectedId) {
    return (
      <View style={[styles.container, { paddingTop: insets.top + spacing.md }]}>
        <TaskDetailView taskId={selectedId} onBack={() => setSelectedId(null)} />
      </View>
    );
  }

  return (
    <KeyboardAvoidingView
      style={[styles.container, { paddingTop: insets.top + spacing.md }]}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
    >
      <Text style={styles.heading}>Tasks</Text>
      <SectionList
        sections={sections}
        keyExtractor={(item) => item.id}
        renderItem={renderItem}
        renderSectionHeader={({ section }) => (
          <Text style={styles.section}>
            {section.title} · {section.data.length}
          </Text>
        )}
        stickySectionHeadersEnabled={false}
        keyboardShouldPersistTaps="handled"
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={() => void onRefresh()} tintColor={colors.accent} />
        }
        ListHeaderComponent={
          prompts.length > 0 ? (
            <View style={styles.prompts}>
              {prompts.map((p) => (
                <PromptCard
                  key={p.id}
                  prompt={p}
                  highlighted={route.params?.promptId === p.id}
                  onAnswer={(answer) => answerPrompt(p.id, answer)}
                />
              ))}
            </View>
          ) : null
        }
        ListEmptyComponent={
          <Text style={styles.empty}>
            {loaded ? "No tasks yet — ask for something below." : "Loading…"}
          </Text>
        }
        contentContainerStyle={styles.listContent}
      />

      <View style={[styles.composer, { paddingBottom: Math.max(insets.bottom, spacing.sm) }]}>
        {confirmation ? <Text style={styles.confirmation}>{confirmation}</Text> : null}
        <View style={styles.composerRow}>
          <TextInput
            value={draft}
            onChangeText={(t) => {
              setDraft(t);
              setDraftSource("text");
            }}
            placeholder="Ask for something…"
            placeholderTextColor={colors.muted}
            style={styles.input}
            multiline
            editable={!sending}
            returnKeyType="send"
            blurOnSubmit
            onSubmitEditing={() => void send()}
          />
          <DictateButton
            onText={(text) => {
              setDraft(text);
              setDraftSource("voice");
            }}
          />
          <Pressable
            disabled={sending || !draft.trim()}
            onPress={() => void send()}
            style={({ pressed }) => [
              styles.sendButton,
              (pressed || sending || !draft.trim()) && styles.pressed,
            ]}
          >
            <Text style={styles.sendText}>{sending ? "…" : "Send"}</Text>
          </Pressable>
        </View>
      </View>
    </KeyboardAvoidingView>
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
  prompts: {
    marginBottom: spacing.sm,
  },
  section: {
    color: colors.muted,
    fontSize: 12,
    fontWeight: "600",
    letterSpacing: 0.8,
    textTransform: "uppercase",
    marginTop: spacing.sm,
    marginBottom: spacing.sm,
  },
  listContent: {
    paddingBottom: spacing.lg,
  },
  empty: {
    color: colors.muted,
    fontSize: 15,
    textAlign: "center",
    marginTop: spacing.xl,
  },
  composer: {
    borderTopColor: colors.border,
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingTop: spacing.sm,
  },
  confirmation: {
    color: colors.muted,
    fontSize: 14,
    fontStyle: "italic",
    marginBottom: spacing.sm,
  },
  composerRow: {
    flexDirection: "row",
    alignItems: "flex-end",
    gap: spacing.sm,
  },
  input: {
    flex: 1,
    color: colors.text,
    fontSize: 15,
    backgroundColor: colors.surface,
    borderColor: colors.border,
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: spacing.md,
    paddingVertical: 10,
    minHeight: 44,
    maxHeight: 120,
  },
  sendButton: {
    height: 44,
    paddingHorizontal: spacing.md,
    borderRadius: 12,
    backgroundColor: colors.accent,
    justifyContent: "center",
  },
  sendText: {
    color: colors.text,
    fontSize: 15,
    fontWeight: "700",
  },
  pressed: {
    opacity: 0.6,
  },
});
