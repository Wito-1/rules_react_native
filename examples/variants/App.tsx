import { StyleSheet, Text, View } from "react-native";
import { env } from "./env";

export interface VariantProps {
  nativeApiUrl?: string;
}

/** JS reads the variant from a generated module; native code from BuildConfig. They must agree. */
export function App({ nativeApiUrl }: VariantProps) {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>{env.name}</Text>
      <Text>JS env.apiUrl: {env.apiUrl}</Text>
      <Text>BuildConfig.API_URL: {nativeApiUrl}</Text>
      <Text style={styles.match}>{nativeApiUrl === env.apiUrl ? "native and JS agree" : "MISMATCH"}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, alignItems: "center", justifyContent: "center", gap: 12, padding: 24 },
  title: { fontSize: 28, fontWeight: "600" },
  match: { color: "#16a34a", fontWeight: "600" },
});
