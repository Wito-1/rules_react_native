import Constants from "expo-constants";
import { StatusBar } from "expo-status-bar";
import { StyleSheet, Text, View } from "react-native";

export function App() {
  return (
    <View style={styles.screen}>
      <Text style={styles.title}>Expo modules, built by Bazel</Text>
      <Text>expo-constants: {Constants.expoConfig?.name ?? "no app config"}</Text>
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, alignItems: "center", justifyContent: "center", gap: 8 },
  title: { fontSize: 20, fontWeight: "600" },
});
