import React, { useState } from "react";
import { Pressable, StyleSheet, Text } from "react-native";
import { useSpeechRecognition } from "../hooks/useSpeechRecognition";
import { colors } from "../theme";

interface Props {
  /** Receives partial and final transcripts as they arrive. */
  onText: (text: string, final: boolean) => void;
}

/** Hold-to-dictate into a text field — a compact cousin of the Talk mic. */
export function DictateButton({ onText }: Props) {
  const [holding, setHolding] = useState(false);
  const speech = useSpeechRecognition({
    onPartial: (text) => onText(text, false),
    onFinal: (text) => onText(text, true),
  });

  return (
    <Pressable
      onPressIn={() => {
        setHolding(true);
        void speech.start(false);
      }}
      onPressOut={() => {
        setHolding(false);
        void speech.stop();
      }}
      accessibilityLabel="Hold to dictate"
      style={[styles.button, holding && styles.holding]}
    >
      <Text style={[styles.glyph, holding && styles.glyphOn]}>{"◉"}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    width: 44,
    height: 44,
    borderRadius: 22,
    borderWidth: 1,
    borderColor: colors.accent,
    backgroundColor: colors.surface,
    justifyContent: "center",
    alignItems: "center",
  },
  holding: {
    backgroundColor: colors.accent,
  },
  glyph: {
    color: colors.accent,
    fontSize: 18,
  },
  glyphOn: {
    color: colors.text,
  },
});
