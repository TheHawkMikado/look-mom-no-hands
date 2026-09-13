import { Platform } from "react-native";
import * as SecureStore from "expo-secure-store";
import { registerDevice } from "./api";
import appConfig from "../../app.json";

/**
 * The phone's identity toward POST /api/app/device. There's no expo-device or
 * expo-application in the tree, so the id is a random string minted once per
 * install and kept in SecureStore (it survives app updates, not reinstalls —
 * the same lifetime a push token has anyway).
 */
const DEVICE_ID_KEY = "nohands_device_id";

export const APP_VERSION: string = appConfig.expo.version;

let cachedId: string | null = null;

export async function getDeviceId(): Promise<string> {
  if (cachedId) return cachedId;
  let id: string | null = null;
  try {
    id = await SecureStore.getItemAsync(DEVICE_ID_KEY);
  } catch {
    id = null;
  }
  if (!id) {
    id = `phone-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    try {
      await SecureStore.setItemAsync(DEVICE_ID_KEY, id);
    } catch {
      // Unavailable storage: the id lasts for this process only.
    }
  }
  cachedId = id;
  return id;
}

/**
 * Register (or re-register) this phone with its current push token. Called on
 * sign-in and whenever the token or the push toggle changes. Best-effort: a
 * failure here must never block the app, so callers fire-and-forget it.
 */
export async function syncDeviceRegistration(pushToken: string | null): Promise<boolean> {
  try {
    await registerDevice({
      device: await getDeviceId(),
      version: APP_VERSION,
      pushToken,
      platform: Platform.OS,
    });
    return true;
  } catch {
    return false;
  }
}
