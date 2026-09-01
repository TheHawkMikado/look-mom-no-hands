import React, { useCallback, useEffect, useState } from "react";
import { Text } from "react-native";
import { StatusBar } from "expo-status-bar";
import * as Linking from "expo-linking";
import { DarkTheme, NavigationContainer } from "@react-navigation/native";
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
import { SignInScreen } from "./src/screens/SignInScreen";
import { TalkScreen } from "./src/screens/TalkScreen";
import { ActivityScreen } from "./src/screens/ActivityScreen";
import { SettingsScreen } from "./src/screens/SettingsScreen";
import { colors } from "./src/theme";

const Tab = createBottomTabNavigator();

const navTheme = {
  ...DarkTheme,
  colors: {
    ...DarkTheme.colors,
    primary: colors.accent,
    background: colors.bg,
    card: colors.surface,
    text: colors.text,
    border: colors.border,
  },
};

function TabIcon({ glyph, color }: { glyph: string; color: string }) {
  return <Text style={{ color, fontSize: 17 }}>{glyph}</Text>;
}

export default function App() {
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
        <StatusBar style="light" />
        <SignInScreen onSignedIn={(t) => void applyToken(t)} />
      </SafeAreaProvider>
    );
  }

  return (
    <SafeAreaProvider>
      <AuthContext.Provider value={{ signOut: () => void applyToken(null) }}>
        <FeedProvider>
          <NavigationContainer theme={navTheme}>
            <StatusBar style="light" />
            <Tab.Navigator
              screenOptions={{
                headerShown: false,
                tabBarActiveTintColor: colors.accent,
                tabBarInactiveTintColor: colors.muted,
                tabBarStyle: {
                  backgroundColor: colors.surface,
                  borderTopColor: colors.border,
                },
              }}
            >
              <Tab.Screen
                name="Talk"
                component={TalkScreen}
                options={{
                  tabBarIcon: ({ color }) => (
                    <TabIcon glyph={"◉"} color={color} />
                  ),
                }}
              />
              <Tab.Screen
                name="Activity"
                component={ActivityScreen}
                options={{
                  tabBarIcon: ({ color }) => (
                    <TabIcon glyph={"☰"} color={color} />
                  ),
                }}
              />
              <Tab.Screen
                name="Settings"
                component={SettingsScreen}
                options={{
                  tabBarIcon: ({ color }) => (
                    <TabIcon glyph={"⚙︎"} color={color} />
                  ),
                }}
              />
            </Tab.Navigator>
          </NavigationContainer>
        </FeedProvider>
      </AuthContext.Provider>
    </SafeAreaProvider>
  );
}
