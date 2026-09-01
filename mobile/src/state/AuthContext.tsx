import { createContext, useContext } from "react";

export interface AuthContextValue {
  signOut: () => void;
}

export const AuthContext = createContext<AuthContextValue>({
  signOut: () => undefined,
});

export function useAuth(): AuthContextValue {
  return useContext(AuthContext);
}
