import { StyleSheet, Text, View } from "react-native";
import {
  initialWindowMetrics,
  SafeAreaProvider,
  SafeAreaView,
  useSafeAreaInsets,
} from "react-native-safe-area-context";

function Insets() {
  const insets = useSafeAreaInsets();
  return (
    <View style={styles.card}>
      <Text style={styles.title}>react-native-safe-area-context</Text>
      <Text>
        insets (hook): top {insets.top.toFixed(1)}, bottom {insets.bottom.toFixed(1)}
      </Text>
      <Text>
        initial metrics (TurboModule): top {initialWindowMetrics?.insets.top.toFixed(1) ?? "none"}
      </Text>
    </View>
  );
}

export function App() {
  return (
    <SafeAreaProvider initialMetrics={initialWindowMetrics}>
      {/* SafeAreaView is a Fabric component with a hand-written C++ shadow node. */}
      <SafeAreaView style={styles.screen} edges={["top", "bottom"]}>
        <View style={styles.banner}>
          <Text style={styles.bannerText}>Below the status bar, padded in C++</Text>
        </View>
        <Insets />
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: "#fde68a" },
  banner: { backgroundColor: "#1f6feb", padding: 12 },
  bannerText: { color: "white", fontSize: 16 },
  card: { margin: 16, padding: 16, borderRadius: 8, backgroundColor: "white", gap: 6 },
  title: { fontSize: 18, fontWeight: "600" },
});
