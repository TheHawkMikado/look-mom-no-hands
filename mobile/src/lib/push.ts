import { Platform } from "react-native";
import * as Notifications from "expo-notifications";

/**
 * Expo push registration. Works in Expo Go on iOS and in any dev/production
 * build; Expo Go on Android dropped remote push in SDK 53, so there this
 * resolves null and the app keeps polling instead. Production builds need the
 * APNs key / FCM credentials described in mobile/README.md.
 */

const ANDROID_CHANNEL_ID = "default";

let cachedToken: string | null = null;

/** The token from the last successful registration this process, if any. */
export function currentPushToken(): string | null {
  return cachedToken;
}

/** Show pushes that arrive while the app is open (approvals are urgent). */
export function configureForegroundPresentation(): void {
  Notifications.setNotificationHandler({
    handleNotification: async () => ({
      shouldShowBanner: true,
      shouldShowList: true,
      shouldPlaySound: true,
      shouldSetBadge: false,
    }),
  });
}

/**
 * Ask for permission (system prompt on first call) and fetch the Expo push
 * token. Null when denied or when this runtime can't do remote push (simulator,
 * Android Expo Go, missing EAS projectId) — the caller registers the device
 * without a token and the app stays on polling.
 */
export async function registerForPush(): Promise<string | null> {
  try {
    if (Platform.OS === "android") {
      await Notifications.setNotificationChannelAsync(ANDROID_CHANNEL_ID, {
        name: "Approvals and questions",
        importance: Notifications.AndroidImportance.HIGH,
      });
    }
    const existing = await Notifications.getPermissionsAsync();
    const status = existing.granted
      ? existing
      : await Notifications.requestPermissionsAsync({
          ios: { allowAlert: true, allowBadge: true, allowSound: true },
        });
    if (!status.granted) return null;
    // projectId comes from app.json extra.eas.projectId (set by `eas init`);
    // without it expo-notifications throws and we fall back to polling.
    const { data } = await Notifications.getExpoPushTokenAsync();
    cachedToken = data;
    return data;
  } catch {
    return null;
  }
}

/** Current OS-level permission without prompting — for the Settings toggle. */
export async function pushPermissionGranted(): Promise<boolean> {
  try {
    return (await Notifications.getPermissionsAsync()).granted;
  } catch {
    return false;
  }
}
