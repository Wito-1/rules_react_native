import { StyleSheet, Text, View } from "react-native";
import { theme } from "./theme";

export interface StatusCardProps {
  title: string;
  value: string;
}

/** Shared between the driver and operator apps; a change here rebuilds both bundles only. */
export function StatusCard({ title, value }: StatusCardProps) {
  return (
    <View style={styles.card}>
      <Text style={styles.title}>{title}</Text>
      <Text style={styles.value}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: { backgroundColor: theme.surface, borderRadius: 8, padding: 16, alignSelf: "stretch" },
  title: { color: theme.text, opacity: 0.7 },
  value: { color: theme.primary, fontSize: 20, fontWeight: "600" },
});
