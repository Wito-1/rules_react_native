import { Image, PixelRatio, StyleSheet, Text, View } from "react-native";

export function App() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Assets from Bazel</Text>
      {/* Metro emits dot.png, dot@2x.png and dot@3x.png as drawable-{m,xh,xxh}dpi resources; Android
          picks one per screen density. Each is a different color: red 1x, green 2x, blue 3x. */}
      <Image source={require("./images/dot.png")} style={styles.dot} testID="dot" />
      <Text>PixelRatio {PixelRatio.get()}</Text>
      <Text style={styles.custom}>Custom font: Pacifico</Text>
      <Text>Default font, for comparison</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, alignItems: "center", justifyContent: "center", gap: 16 },
  title: { fontSize: 24, fontWeight: "600" },
  dot: { width: 96, height: 96 },
  // Loaded from assets/fonts/Pacifico.ttf by React Native's font manager.
  custom: { fontFamily: "Pacifico", fontSize: 28 },
});
