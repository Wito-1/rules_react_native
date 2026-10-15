import { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import NativeSampleModule from "./specs/NativeSampleModule";

const N = 200_000;

function nthPrimeJs(n: number): number {
  const primes: number[] = [];
  for (let candidate = 2; primes.length < n; candidate++) {
    let isPrime = true;
    for (const p of primes) {
      if (p * p > candidate) break;
      if (candidate % p === 0) {
        isPrime = false;
        break;
      }
    }
    if (isPrime) primes.push(candidate);
  }
  return primes[primes.length - 1];
}

function time(f: () => number): string {
  const start = performance.now();
  const value = f();
  return `${value} in ${Math.round(performance.now() - start)} ms`;
}

export function App() {
  const [text, setText] = useState("Hello from C++");
  const [results, setResults] = useState<{ cxx: string; js: string } | null>(null);
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Pure C++ TurboModule</Text>
      <TextInput style={styles.input} value={text} onChangeText={setText} />
      <Text style={styles.result}>reversed: {NativeSampleModule.reverseString(text)}</Text>
      <Pressable
        style={styles.button}
        onPress={() =>
          setResults({
            cxx: time(() => NativeSampleModule.nthPrime(N)),
            js: time(() => nthPrimeJs(N)),
          })
        }
      >
        <Text style={styles.buttonText}>Find prime #{N.toLocaleString()}</Text>
      </Pressable>
      {results && (
        <>
          <Text style={styles.result}>C++: {results.cxx}</Text>
          <Text style={styles.result}>JS (Hermes): {results.js}</Text>
        </>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, justifyContent: "center", padding: 24, gap: 12 },
  title: { fontSize: 24, fontWeight: "600" },
  input: { borderWidth: 1, borderColor: "#888", borderRadius: 8, padding: 12, fontSize: 16 },
  result: { fontSize: 16 },
  button: { backgroundColor: "#1f6feb", borderRadius: 8, padding: 12, alignItems: "center" },
  buttonText: { color: "white", fontSize: 16 },
});
