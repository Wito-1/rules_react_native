import { NavigationContainer } from "@react-navigation/native";
import { createNativeStackNavigator, type NativeStackScreenProps } from "@react-navigation/native-stack";
import { useState } from "react";
import { StyleSheet, Text, View } from "react-native";
import { GestureDetector, GestureHandlerRootView, RectButton, useTapGesture } from "react-native-gesture-handler";
import { SafeAreaProvider } from "react-native-safe-area-context";
import Svg, { Circle, Rect } from "react-native-svg";

type Routes = { Home: undefined; Details: { taps: number } };
const Stack = createNativeStackNavigator<Routes>();

function Home({ navigation }: NativeStackScreenProps<Routes, "Home">) {
  const [taps, setTaps] = useState(0);
  const tap = useTapGesture({ onActivate: () => setTaps((t) => t + 1), runOnJS: true });
  return (
    <View style={styles.screen}>
      <Text style={styles.title}>react-native-gesture-handler</Text>
      <GestureDetector gesture={tap}>
        <View style={styles.target}>
          <Text style={styles.targetText}>Tapped {taps} times</Text>
        </View>
      </GestureDetector>
      <RectButton style={styles.button} onPress={() => navigation.navigate("Details", { taps })}>
        <Text style={styles.buttonText}>Push a native screen</Text>
      </RectButton>
    </View>
  );
}

function Details({ route }: NativeStackScreenProps<Routes, "Details">) {
  return (
    <View style={styles.screen}>
      <Text style={styles.title}>react-native-screens + react-native-svg</Text>
      <Svg width={200} height={100}>
        <Rect x={10} y={10} width={80} height={80} fill="#1f6feb" />
        <Circle cx={150} cy={50} r={40} fill="#f59e0b" />
      </Svg>
      <Text>Pushed after {route.params.taps} taps</Text>
    </View>
  );
}

export function App() {
  return (
    <GestureHandlerRootView style={styles.root}>
      <SafeAreaProvider>
        <NavigationContainer>
          <Stack.Navigator>
            <Stack.Screen name="Home" component={Home} options={{ title: "Ecosystem" }} />
            <Stack.Screen name="Details" component={Details} />
          </Stack.Navigator>
        </NavigationContainer>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  screen: { flex: 1, padding: 24, gap: 16 },
  title: { fontSize: 18, fontWeight: "600" },
  target: { height: 120, borderRadius: 8, backgroundColor: "#dbeafe", alignItems: "center", justifyContent: "center" },
  targetText: { fontSize: 16 },
  button: { backgroundColor: "#1f6feb", borderRadius: 8, padding: 14, alignItems: "center" },
  buttonText: { color: "white", fontSize: 16 },
});
