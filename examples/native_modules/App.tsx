import { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import GreetingView from "./specs/GreetingViewNativeComponent";
import NativeLocalStorage from "./specs/NativeLocalStorage";

const KEY = "greeting";

export function App() {
  const [draft, setDraft] = useState("");
  const [stored, setStored] = useState<string | null>(() => NativeLocalStorage.getItem(KEY));
  const [lastNativeEvent, setLastNativeEvent] = useState("none yet");

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Codegen from Bazel</Text>

      <Text style={styles.label}>TurboModule (NativeLocalStorage)</Text>
      <TextInput style={styles.input} placeholder="Type something" value={draft} onChangeText={setDraft} />
      <View style={styles.row}>
        <Pressable
          style={styles.button}
          onPress={() => {
            NativeLocalStorage.setItem(draft, KEY);
            setStored(NativeLocalStorage.getItem(KEY));
          }}
        >
          <Text style={styles.buttonText}>Save</Text>
        </Pressable>
        <Pressable
          style={styles.button}
          onPress={() => {
            NativeLocalStorage.removeItem(KEY);
            setStored(NativeLocalStorage.getItem(KEY));
          }}
        >
          <Text style={styles.buttonText}>Clear</Text>
        </Pressable>
      </View>
      <Text testID="stored">Stored: {stored ?? "(nothing)"}</Text>

      <Text style={styles.label}>Fabric component (GreetingView)</Text>
      <GreetingView
        style={styles.greeting}
        text={`Hello, ${stored ?? "stranger"}!`}
        onGreetingPress={(e) => setLastNativeEvent(e.nativeEvent.text)}
      />
      <Text testID="event">Native event: {lastNativeEvent}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 24, paddingTop: 64, gap: 12 },
  title: { fontSize: 24, fontWeight: "600" },
  label: { marginTop: 16, fontWeight: "600" },
  input: { borderWidth: 1, borderColor: "#999", borderRadius: 6, paddingHorizontal: 8 },
  row: { flexDirection: "row", gap: 12 },
  button: { backgroundColor: "#1f6feb", borderRadius: 6, paddingHorizontal: 16, paddingVertical: 8 },
  buttonText: { color: "white" },
  greeting: { height: 56, alignSelf: "stretch" },
});
