import React, { useCallback, useEffect, useState } from "react";
import { Text, useColorScheme } from "react-native";
import { StatusBar } from "expo-status-bar";
import * as Linking from "expo-linking";
import {
  DarkTheme,
  DefaultTheme,
  NavigationContainer,
} from "@react-navigation/native";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { SafeAreaProvider } from "react-native-safe-area-context";
import * as api from "./src/lib/api";
import {
  clearToken,
  loadToken,
  parseAuthRedirect,
  saveToken,
} from "./src/lib/auth";
import { AuthContext } from "./src/state/AuthContext";
import { FeedProvider } from "./src/state/FeedContext";
import { GoalQueueProvider } from "./src/state/GoalQueueContext";
import { TasksProvider, useTasks } from "./src/state/TasksContext";
import { PushBridge } from "./src/components/PushBridge";
import { NotesProvider } from "./src/state/NotesContext";
import { SignInScreen } from "./src/screens/SignInScreen";
import { TalkScreen } from "./src/screens/TalkScreen";
import { NotesScreen } from "./src/screens/NotesScreen";
import { TasksScreen } from "./src/screens/TasksScreen";
import { TeamScreen } from "./src/screens/TeamScreen";
import { ActivityScreen } from "./src/screens/ActivityScreen";
import { SettingsScreen } from "./src/screens/SettingsScreen";
import { navigationRef, RootTabParamList } from "./src/navigation";
import { colors, palettes } from "./src/theme";

const Tab = createBottomTabNavigator<RootTabParamList>();

/** React Navigation wants plain strings, so it gets per-scheme palettes
 *  rather than the dynamic tokens the rest of the app uses. */
function navTheme(scheme: "light" | "dark") {
  const base = scheme === "dark" ? DarkTheme : DefaultTheme;
  const p = palettes[scheme];
  return {
    ...base,
    colors: {
      ...base.colors,
      primary: colors.accent,
      background: p.bg,
      card: p.surface,
      text: p.text,
      border: p.border,
    },
  };
}

function TabIcon({ glyph, color }: { glyph: string; color: string }) {
  return <Text style={{ color, fontSize: 17 }}>{glyph}</Text>;
}

/** Inside the providers so the Tasks tab can wear its badge. */
function Tabs() {
  const { badgeCount } = useTasks();
  return (
    <Tab.Navigator
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.muted,
        tabBarStyle: {
          backgroundColor: colors.surface,
          borderTopColor: colors.border,
        },
        tabBarBadgeStyle: { backgroundColor: colors.accent, color: colors.text },
      }}
    >
      <Tab.Screen
        name="Talk"
        component={TalkScreen}
        options={{
          tabBarIcon: ({ color }) => <TabIcon glyph={"◉"} color={color} />,
        }}
      />
      <Tab.Screen
        name="Notes"
        component={NotesScreen}
        options={{
          tabBarIcon: ({ color }) => <TabIcon glyph={"✎"} color={color} />,
        }}
      />
      <Tab.Screen
        name="Tasks"
        component={TasksScreen}
        options={{
          tabBarIcon: ({ color }) => <TabIcon glyph={"✓"} color={color} />,
          tabBarBadge: badgeCount > 0 ? badgeCount : undefined,
        }}
      />
      <Tab.Screen
        name="Team"
        component={TeamScreen}
        options={{
          tabBarIcon: ({ color }) => <TabIcon glyph={"⁂"} color={color} />,
        }}
      />
      <Tab.Screen
        name="Activity"
        component={ActivityScreen}
        options={{
          tabBarIcon: ({ color }) => <TabIcon glyph={"☰"} color={color} />,
        }}
      />
      <Tab.Screen
        name="Settings"
        component={SettingsScreen}
        options={{
          tabBarIcon: ({ color }) => <TabIcon glyph={"⚙︎"} color={color} />,
        }}
      />
    </Tab.Navigator>
  );
}

export default function App() {
  const scheme = useColorScheme() === "light" ? "light" : "dark";
  const [token, setTokenState] = useState<string | null>(null);
  const [booted, setBooted] = useState(false);

  const applyToken = useCallback(async (next: string | null) => {
    api.setToken(next);
    setTokenState(next);
    if (next) await saveToken(next);
    else await clearToken();
  }, []);

  useEffect(() => {
    void loadToken().then((stored) => {
      api.setToken(stored);
      setTokenState(stored);
      setBooted(true);
    });
  }, []);

  useEffect(() => {
    // Any 401 from any call flips the whole app to signed-out.
    api.setUnauthorizedHandler(() => void applyToken(null));

    // Android delivers the nohands://auth redirect as a plain deep link
    // rather than through openAuthSessionAsync's result, so listen here too.
    const sub = Linking.addEventListener("url", ({ url }) => {
      const fromLink = parseAuthRedirect(url);
      if (fromLink) void applyToken(fromLink);
    });
    void Linking.getInitialURL().then((url) => {
      if (!url) return;
      const fromColdStart = parseAuthRedirect(url);
      if (fromColdStart) void applyToken(fromColdStart);
    });
    return () => {
      sub.remove();
      api.setUnauthorizedHandler(null);
    };
  }, [applyToken]);

  if (!booted) return null; // splash stays visible while the token loads

  if (!token) {
    return (
      <SafeAreaProvider>
        <StatusBar style="auto" />
        <SignInScreen onSignedIn={(t) => void applyToken(t)} />
      </SafeAreaProvider>
    );
  }

  return (
    <SafeAreaProvider>
      <AuthContext.Provider value={{ signOut: () => void applyToken(null) }}>
        <GoalQueueProvider>
          <NotesProvider>
          <FeedProvider>
            <TasksProvider>
              <NavigationContainer ref={navigationRef} theme={navTheme(scheme)}>
                <StatusBar style="auto" />
                <PushBridge />
                <Tabs />
              </NavigationContainer>
            </TasksProvider>
          </FeedProvider>
          </NotesProvider>
        </GoalQueueProvider>
      </AuthContext.Provider>
    </SafeAreaProvider>
  );
}
