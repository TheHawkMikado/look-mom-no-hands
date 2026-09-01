import React, { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { signInWithBrowser } from "../lib/auth";
import { colors, spacing } from "../theme";

interface Props {
  onSignedIn: (token: string) => void;
}

export function SignInScreen({ onSignedIn }: Props) {
  const [busy, setBusy] = useState(false);

  const handleSignIn = async () => {
    setBusy(true);
    try {
      const token = await signInWithBrowser();
      // On Android the redirect can arrive via the Linking listener in
      // App.tsx instead of resolving here — a null token is not a failure.
      if (token) onSignedIn(token);
    } finally {
      setBusy(false);
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.hero}>
        <View style={styles.mark} />
        <Text style={styles.title}>Look Ma, No Hands</Text>
        <Text style={styles.subtitle}>Voice remote for your Mac</Text>
      </View>
      <Pressable
        style={({ pressed }) => [
          styles.button,
          (pressed || busy) && styles.pressed,
        ]}
        disabled={busy}
        onPress={() => void handleSignIn()}
      >
        <Text style={styles.buttonText}>
          {busy ? "Waiting for browser…" : "Sign in"}
        </Text>
      </Pressable>
      <Text style={styles.footnote}>
        Signs in at nohandsapp.com in your browser.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.bg,
    justifyContent: "center",
    paddingHorizontal: spacing.lg,
  },
  hero: {
    alignItems: "center",
    marginBottom: spacing.xl * 2,
  },
  mark: {
    width: 72,
    height: 72,
    borderRadius: 36,
    borderWidth: 3,
    borderColor: colors.accent,
    marginBottom: spacing.lg,
  },
  title: {
    color: colors.text,
    fontSize: 30,
    fontWeight: "700",
    textAlign: "center",
  },
  subtitle: {
    color: colors.muted,
    fontSize: 16,
    marginTop: spacing.sm,
  },
  button: {
    backgroundColor: colors.accent,
    borderRadius: 14,
    paddingVertical: 16,
    alignItems: "center",
  },
  buttonText: {
    color: colors.text,
    fontSize: 17,
    fontWeight: "700",
  },
  pressed: {
    opacity: 0.7,
  },
  footnote: {
    color: colors.muted,
    fontSize: 13,
    textAlign: "center",
    marginTop: spacing.md,
  },
});
