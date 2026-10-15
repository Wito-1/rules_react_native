import { createClient } from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { GreeterService } from "@examples/greeter-proto";
import { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";

// The same generated GreeterService the web app and the server use. `greeter_mobile.install`
// runs `adb reverse tcp:8080 tcp:8080`, so localhost here is the development machine.
const client = createClient(GreeterService, createConnectTransport({ baseUrl: "http://localhost:8080" }));

export function App() {
  const [name, setName] = useState("mobile");
  const [reply, setReply] = useState("");
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Greeter (mobile)</Text>
      <TextInput style={styles.input} value={name} onChangeText={setName} />
      <Pressable
        style={styles.button}
        onPress={async () => {
          try {
            const res = await client.greet({ name });
            setReply(`${res.greeting} (#${res.count} from ${res.servedBy})`);
          } catch (e) {
            setReply(`error: ${String(e)}`);
          }
        }}
      >
        <Text style={styles.buttonText}>Greet</Text>
      </Pressable>
      <Text testID="reply">{reply}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 24, paddingTop: 96, gap: 16 },
  title: { fontSize: 24, fontWeight: "600" },
  input: { borderWidth: 1, borderColor: "#999", borderRadius: 6, paddingHorizontal: 8 },
  button: { backgroundColor: "#1f6feb", borderRadius: 6, padding: 12, alignItems: "center" },
  buttonText: { color: "white" },
});
