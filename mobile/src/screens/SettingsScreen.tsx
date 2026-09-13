import React, { useCallback, useEffect, useState } from "react";
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import {
  AccountSettings,
  getSession,
  getSettings,
  SERVER_URL,
  updateSettings,
} from "../lib/api";
import { deviceTimeZone, normalizeClockTime } from "../lib/clock";
import { syncDeviceRegistration } from "../lib/device";
import { currentPushToken, registerForPush } from "../lib/push";
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

  const [settings, setSettings] = useState<AccountSettings | null>(null);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  // Local drafts for the clock fields so typing "2" doesn't POST "2".
  const [quietStart, setQuietStart] = useState("");
  const [quietEnd, setQuietEnd] = useState("");
  const [briefAt, setBriefAt] = useState("");
  const [saving, setSaving] = useState(false);
  const [saveNote, setSaveNote] = useState<string | null>(null);
  const [pushNote, setPushNote] = useState<string | null>(null);

  const adopt = useCallback((s: AccountSettings) => {
    setSettings(s);
    setQuietStart(s.quiet_hours_start ?? "");
    setQuietEnd(s.quiet_hours_end ?? "");
    setBriefAt(s.daily_brief_at ?? "");
  }, []);

  useEffect(() => {
    let alive = true;
    getSettings()
      .then((s) => {
        if (alive) adopt(s);
      })
      .catch(() => {
        if (alive) setSettingsError("Couldn't load account settings.");
      });
    return () => {
      alive = false;
    };
  }, [adopt]);

  const patch = useCallback(
    async (changes: Partial<AccountSettings>): Promise<boolean> => {
      if (!settings) return false;
      const next = { ...settings, ...changes };
      setSettings(next); // optimistic
      try {
        const saved = await updateSettings(changes);
        // Servers that echo the full row win over our optimistic merge.
        if (saved && typeof saved === "object" && "tz" in saved) {
          adopt({ ...next, ...(saved as Partial<AccountSettings>) });
        }
        return true;
      } catch {
        setSettings(settings);
        return false;
      }
    },
    [settings, adopt],
  );

  const phoneZone = deviceTimeZone();

  const saveSchedule = useCallback(async () => {
    const fields = [
      ["quiet_hours_start", quietStart],
      ["quiet_hours_end", quietEnd],
      ["daily_brief_at", briefAt],
    ] as const;
    const changes: Partial<AccountSettings> = {};
    for (const [key, raw] of fields) {
      if (!raw.trim()) {
        changes[key] = null;
        continue;
      }
      const normalized = normalizeClockTime(raw);
      if (!normalized) {
        setSaveNote("Times are HH:MM, 24-hour — e.g. 22:00.");
        return;
      }
      changes[key] = normalized;
    }
    // Quiet hours need both ends; one without the other means "off".
    if (!changes.quiet_hours_start !== !changes.quiet_hours_end) {
      setSaveNote("Set both a start and an end for quiet hours, or clear both.");
      return;
    }
    setSaving(true);
    setSaveNote(null);
    const ok = await patch(changes);
    setSaving(false);
    setSaveNote(ok ? "Saved." : "Couldn't save — try again.");
  }, [quietStart, quietEnd, briefAt, patch]);

  const togglePush = useCallback(
    async (on: boolean) => {
      setPushNote(null);
      if (on) {
        // Enabling is the moment to ask the OS; a denied prompt leaves the
        // toggle off and says why instead of pretending.
        const token = currentPushToken() ?? (await registerForPush());
        if (!token) {
          setPushNote(
            "Notifications are off for this app in the system settings, or this build can't receive push.",
          );
          return;
        }
        const ok = await patch({ push_enabled: true });
        if (ok) void syncDeviceRegistration(token);
        else setPushNote("Couldn't save — try again.");
      } else {
        const ok = await patch({ push_enabled: false });
        if (ok) void syncDeviceRegistration(null);
        else setPushNote("Couldn't save — try again.");
      }
    },
    [patch],
  );

  return (
    <ScrollView
      style={styles.container}
      contentContainerStyle={[styles.content, { paddingTop: insets.top + spacing.md }]}
      keyboardShouldPersistTaps="handled"
    >
      <Text style={styles.heading}>Settings</Text>

      <View style={styles.card}>
        <Text style={styles.label}>Account</Text>
        <View style={styles.statusRow}>
          <View style={styles.dot} />
          <Text style={styles.value}>{email ?? "Connected"}</Text>
        </View>
        <Text style={styles.hint}>
          Your Mac must be signed in as this same account to receive tasks.
        </Text>
      </View>

      <View style={styles.card}>
        <Text style={styles.label}>Push notifications</Text>
        <View style={styles.switchRow}>
          <Text style={styles.value}>Approvals and questions</Text>
          <Switch
            value={settings?.push_enabled ?? false}
            disabled={!settings}
            onValueChange={(v) => void togglePush(v)}
            trackColor={{ false: colors.border, true: colors.accent }}
            thumbColor={colors.text}
          />
        </View>
        <Text style={styles.hint}>
          {pushNote ??
            "Get pinged when your Mac needs a decision. Off means the app only checks while it's open."}
        </Text>
      </View>

      <View style={styles.card}>
        <Text style={styles.label}>Time zone</Text>
        <Text style={styles.value}>{settings?.tz ?? (settingsError ? "—" : "Loading…")}</Text>
        {settings && phoneZone && phoneZone !== settings.tz ? (
          <Pressable
            style={({ pressed }) => [styles.inlineButton, pressed && styles.pressed]}
            onPress={() => void patch({ tz: phoneZone })}
          >
            <Text style={styles.inlineButtonText}>Use this phone's zone ({phoneZone})</Text>
          </Pressable>
        ) : null}
        <Text style={styles.hint}>Quiet hours and the daily brief follow this zone.</Text>
      </View>

      <View style={styles.card}>
        <Text style={styles.label}>Quiet hours</Text>
        <View style={styles.timeRow}>
          <ClockField value={quietStart} onChange={setQuietStart} placeholder="22:00" />
          <Text style={styles.timeSep}>to</Text>
          <ClockField value={quietEnd} onChange={setQuietEnd} placeholder="07:00" />
        </View>
        <Text style={styles.hint}>No pushes between these times; clear both to turn off.</Text>

        <Text style={[styles.label, { marginTop: spacing.md }]}>Daily brief</Text>
        <View style={styles.timeRow}>
          <ClockField value={briefAt} onChange={setBriefAt} placeholder="08:30" />
        </View>

        <Pressable
          disabled={!settings || saving}
          style={({ pressed }) => [styles.save, (pressed || saving || !settings) && styles.pressed]}
          onPress={() => void saveSchedule()}
        >
          <Text style={styles.saveText}>{saving ? "Saving…" : "Save schedule"}</Text>
        </Pressable>
        {saveNote ? <Text style={styles.hint}>{saveNote}</Text> : null}
        {settingsError ? <Text style={[styles.hint, { color: colors.danger }]}>{settingsError}</Text> : null}
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
    </ScrollView>
  );
}

function ClockField({
  value,
  onChange,
  placeholder,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder: string;
}) {
  return (
    <TextInput
      value={value}
      onChangeText={onChange}
      placeholder={placeholder}
      placeholderTextColor={colors.muted}
      keyboardType="numbers-and-punctuation"
      maxLength={5}
      style={styles.timeInput}
    />
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.bg,
  },
  content: {
    paddingHorizontal: spacing.md,
    paddingBottom: spacing.xl,
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
  switchRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: spacing.sm,
  },
  hint: {
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
  inlineButton: {
    marginTop: spacing.sm,
    alignSelf: "flex-start",
    borderColor: colors.accent,
    borderWidth: 1,
    borderRadius: 10,
    paddingVertical: 8,
    paddingHorizontal: spacing.md,
  },
  inlineButtonText: {
    color: colors.accent,
    fontSize: 14,
    fontWeight: "600",
  },
  timeRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.sm,
  },
  timeSep: {
    color: colors.muted,
    fontSize: 14,
  },
  timeInput: {
    width: 84,
    color: colors.text,
    fontSize: 16,
    textAlign: "center",
    borderColor: colors.border,
    borderWidth: 1,
    borderRadius: 10,
    paddingVertical: 8,
    paddingHorizontal: spacing.sm,
  },
  save: {
    marginTop: spacing.md,
    backgroundColor: colors.accent,
    borderRadius: 12,
    paddingVertical: 12,
    alignItems: "center",
  },
  saveText: {
    color: colors.text,
    fontSize: 15,
    fontWeight: "700",
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
