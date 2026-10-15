import { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";

export function App() {
  const [count, setCount] = useState(0);
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Hello from Bazel</Text>
      <Pressable style={styles.button} onPress={() => setCount((c) => c + 1)}>
        <Text style={styles.buttonText}>Pressed {count} times</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, alignItems: "center", justifyContent: "center" },
  title: { fontSize: 24, fontWeight: "600", marginBottom: 24 },
  button: { backgroundColor: "#1f6feb", borderRadius: 8, paddingHorizontal: 20, paddingVertical: 12 },
  buttonText: { color: "white", fontSize: 16 },
});
