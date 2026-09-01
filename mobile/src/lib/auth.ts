import * as SecureStore from "expo-secure-store";
import * as WebBrowser from "expo-web-browser";
import { SERVER_URL } from "./api";

const TOKEN_KEY = "nohands_bearer_token";

export const LOGIN_URL = `${SERVER_URL}/app/login?client=mobile`;
export const AUTH_REDIRECT = "nohands://auth";

export function loadToken(): Promise<string | null> {
  return SecureStore.getItemAsync(TOKEN_KEY);
}

export function saveToken(token: string): Promise<void> {
  return SecureStore.setItemAsync(TOKEN_KEY, token);
}

export function clearToken(): Promise<void> {
  return SecureStore.deleteItemAsync(TOKEN_KEY);
}

/** Extract the bearer token from a nohands://auth?token=... redirect, or null. */
export function parseAuthRedirect(url: string): string | null {
  if (!url.startsWith(AUTH_REDIRECT)) return null;
  const match = /[?&]token=([^&#]+)/.exec(url);
  return match ? decodeURIComponent(match[1]) : null;
}

/**
 * Open the hosted login page in the system browser. On iOS the auth session
 * resolves with the redirect URL directly; on Android the redirect may arrive
 * as a Linking "url" event instead, which App.tsx also listens for — so a null
 * here is not necessarily a failed sign-in.
 */
export async function signInWithBrowser(): Promise<string | null> {
  const result = await WebBrowser.openAuthSessionAsync(LOGIN_URL, AUTH_REDIRECT);
  if (result.type === "success") return parseAuthRedirect(result.url);
  return null;
}
