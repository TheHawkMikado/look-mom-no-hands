import React, { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { Prompt } from "../lib/api";
import { DictateButton } from "./DictateButton";
import { colors, spacing } from "../theme";

interface Props {
  prompt: Prompt;
  /** Drawn with a brighter border when a notification tap pointed here. */
  highlighted?: boolean;
  onAnswer: (answer: string) => Promise<void>;
}

/**
 * A question from the assistant. One tap accepts the default; "Answer
 * differently" opens a field you can type or dictate into.
 */
export function PromptCard({ prompt, highlighted, onAnswer }: Props) {
  const [custom, setCustom] = useState(false);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const send = async (answer: string) => {
    const trimmed = answer.trim();
    if (!trimmed || busy) return;
    setBusy(true);
    setError(null);
    try {
      await onAnswer(trimmed);
    } catch {
      setError("Couldn't send that — try again.");
      setBusy(false);
    }
  };

  return (
    <View style={[styles.card, highlighted && styles.highlighted]}>
      <Text style={styles.badge}>QUESTION</Text>
      <Text style={styles.question}>{prompt.question}</Text>
      {custom ? (
        <View style={styles.answerRow}>
          <TextInput
            value={draft}
            onChangeText={setDraft}
            placeholder="Your answer"
            placeholderTextColor={colors.muted}
            style={styles.input}
            multiline
            autoFocus
            editable={!busy}
          />
          <DictateButton onText={(text) => setDraft(text)} />
        </View>
      ) : null}
      <View style={styles.row}>
        <Pressable
          disabled={busy}
          style={({ pressed }) => [styles.primary, (pressed || busy) && styles.pressed]}
          onPress={() => void send(custom ? draft : prompt.default_answer)}
        >
          <Text style={styles.primaryText} numberOfLines={2}>
            {custom ? "Send answer" : prompt.default_answer || "OK"}
          </Text>
        </Pressable>
        <Pressable
          disabled={busy}
          style={({ pressed }) => [styles.secondary, (pressed || busy) && styles.pressed]}
          onPress={() => {
            setCustom((c) => !c);
            setDraft("");
          }}
        >
          <Text style={styles.secondaryText}>{custom ? "Use default" : "Answer differently"}</Text>
        </Pressable>
      </View>
      {error ? <Text style={styles.error}>{error}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderColor: colors.accent,
    borderWidth: 1,
    borderRadius: 16,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  highlighted: {
    borderWidth: 2,
    backgroundColor: colors.accentSoft,
  },
  badge: {
    color: colors.accent,
    fontSize: 11,
    fontWeight: "700",
    letterSpacing: 1.2,
    marginBottom: spacing.xs,
  },
  question: {
    color: colors.text,
    fontSize: 17,
    fontWeight: "600",
  },
  answerRow: {
    flexDirection: "row",
    alignItems: "flex-end",
    gap: spacing.sm,
    marginTop: spacing.md,
  },
  input: {
    flex: 1,
    color: colors.text,
    fontSize: 15,
    borderColor: colors.border,
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: spacing.md,
    paddingVertical: 10,
    minHeight: 44,
    maxHeight: 120,
  },
  row: {
    flexDirection: "row",
    gap: spacing.sm,
    marginTop: spacing.md,
  },
  primary: {
    flex: 1,
    backgroundColor: colors.accent,
    borderRadius: 12,
    paddingVertical: 12,
    paddingHorizontal: spacing.sm,
    alignItems: "center",
    justifyContent: "center",
  },
  primaryText: {
    color: colors.text,
    fontSize: 15,
    fontWeight: "700",
    textAlign: "center",
  },
  secondary: {
    flex: 1,
    borderColor: colors.border,
    borderWidth: 1,
    borderRadius: 12,
    paddingVertical: 12,
    paddingHorizontal: spacing.sm,
    alignItems: "center",
    justifyContent: "center",
  },
  secondaryText: {
    color: colors.muted,
    fontSize: 14,
    fontWeight: "600",
    textAlign: "center",
  },
  pressed: {
    opacity: 0.7,
  },
  error: {
    color: colors.danger,
    fontSize: 13,
    marginTop: spacing.sm,
  },
});
