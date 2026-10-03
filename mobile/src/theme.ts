import { DynamicColorIOS, Platform } from "react-native";

/**
 * Single source of truth for the one-accent visual language — now in a light
 * and a dark voice, following the SYSTEM appearance. Each token is an iOS
 * dynamic color, so static StyleSheets adapt live when the phone switches
 * modes with no re-render or theming context; every existing `colors.x` use
 * keeps working untouched. Android has no dynamic colors at this layer and
 * stays on the dark palette until it grows its own theming pass.
 */
const dyn = (dark: string, light: string): string =>
  Platform.OS === "ios"
    ? (DynamicColorIOS({ dark, light }) as unknown as string)
    : dark;

export const colors = {
  bg: dyn("#0B0A12", "#F6F5FA"),
  surface: dyn("#16141F", "#FFFFFF"),
  border: dyn("#2A2740", "#E4E1EE"),
  text: dyn("#F2F0FA", "#191628"),
  muted: dyn("#8B87A0", "#6C6880"),
  accent: "#7C5CFF",
  accentSoft: dyn("#251E45", "#EDE9FD"),
  success: dyn("#4ADE80", "#15803D"),
  warning: dyn("#FFB020", "#A16207"),
  danger: dyn("#FF5C7A", "#DC2626"),
} as const;

/** Plain hex for consumers that require strings (the navigation theme). */
export const palettes = {
  dark: {
    bg: "#0B0A12",
    surface: "#16141F",
    border: "#2A2740",
    text: "#F2F0FA",
  },
  light: {
    bg: "#F6F5FA",
    surface: "#FFFFFF",
    border: "#E4E1EE",
    text: "#191628",
  },
} as const;

export const spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 40,
} as const;
