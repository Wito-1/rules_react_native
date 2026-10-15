import { NativeVehicleInfo, StatusCard, theme } from "@examples/fleet-shared";
import { StyleSheet, Text, View } from "react-native";

export function App() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Fleet Operator</Text>
      <StatusCard title="Vehicles online" value="12 / 14" />
      <StatusCard title="Open alerts" value="3" />
      <StatusCard title="Running on" value={NativeVehicleInfo.getDeviceModel()} />
      <StatusCard title="Role reported by native code" value={NativeVehicleInfo.getAppRole()} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 24, paddingTop: 64, gap: 12 },
  title: { fontSize: 24, fontWeight: "600", color: theme.text },
});
