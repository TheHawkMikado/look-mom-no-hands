import React, { useEffect, useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { getSession, SERVER_URL } from "../lib/api";
import { useAuth } from "../state/AuthContext";
import { colors, spacing } from "../theme";

export function SettingsScreen() {
  const insets = useSafeAreaInsets();
  const { signOut } = useAuth();
  // The email is the load-bearing detail: goals go to the ACCOUNT's Macs, so a
  // phone signed in as the wrong identity fails with no other symptom than
  // "my computer isn't doing it". Bare "Connected" hid exactly that.
  const [email, setEmail] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    getSession()
      .then((s) => {
        if (alive) setEmail(s.email);
      })
      .catch(() => undefined);
    return () => {
      alive = false;
    };
  }, []);

  return (
    <View style={[styles.container, { paddingTop: insets.top + spacing.md }]}>
      <Text style={styles.heading}>Settings</Text>

      <View style={styles.card}>
        <Text style={styles.label}>Account</Text>
        <View style={styles.statusRow}>
          <View style={styles.dot} />
          <Text style={styles.value}>{email ?? "Connected"}</Text>
        </View>
        <Text style={styles.accountHint}>
          Your Mac must be signed in as this same account to receive tasks.
        </Text>
      </View>

      {/* The server URL is shown (not editable) so the user can verify where
          their voice commands are going. */}
      <View style={styles.card}>
        <Text style={styles.label}>Server</Text>
        <Text style={styles.value}>{SERVER_URL}</Text>
      </View>

      <Pressable
        style={({ pressed }) => [styles.signOut, pressed && styles.pressed]}
        onPress={signOut}
      >
        <Text style={styles.signOutText}>Sign out</Text>
      </Pressable>
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
  card: {
    backgroundColor: colors.surface,
    borderRadius: 14,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  label: {
    color: colors.muted,
    fontSize: 12,
    fontWeight: "600",
    letterSpacing: 0.8,
    textTransform: "uppercase",
    marginBottom: spacing.xs,
  },
  statusRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.sm,
  },
  accountHint: {
    color: colors.muted,
    fontSize: 13,
    marginTop: spacing.sm,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: colors.success,
  },
  value: {
    color: colors.text,
    fontSize: 16,
  },
  signOut: {
    marginTop: spacing.lg,
    borderColor: colors.danger,
    borderWidth: 1,
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
  },
  signOutText: {
    color: colors.danger,
    fontSize: 16,
    fontWeight: "600",
  },
  pressed: {
    opacity: 0.7,
  },
});
