import { createNavigationContainerRef } from "@react-navigation/native";

/** Tab routes and their params — the only navigator in the app. */
export type RootTabParamList = {
  Talk: undefined;
  Tasks: { promptId?: string; taskId?: string } | undefined;
  Team: undefined;
  Activity: undefined;
  Settings: undefined;
};

/** Lets non-screen code (the push bridge) navigate: a tapped notification
 *  lands on the approval or the prompt it names. */
export const navigationRef = createNavigationContainerRef<RootTabParamList>();
