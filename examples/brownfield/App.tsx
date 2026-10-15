import { StyleSheet, Text, View } from "react-native";

export interface ProfileProps {
  name?: string;
  openedFrom?: string;
}

/** The only React Native screen in an otherwise native app; props arrive from the Intent. */
export function App({ name, openedFrom }: ProfileProps) {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>React Native profile</Text>
      <Text style={styles.greeting}>Hello, {name ?? "stranger"}!</Text>
      <Text>Opened from {openedFrom ?? "?"}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, alignItems: "center", justifyContent: "center", gap: 12 },
  title: { fontSize: 24, fontWeight: "600" },
  greeting: { fontSize: 20, color: "#1f6feb" },
});
