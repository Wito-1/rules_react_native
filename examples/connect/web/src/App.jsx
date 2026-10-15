import { createClient } from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { GreeterService } from "@examples/greeter-proto";
import { useState } from "react";

// Same generated GreeterService the mobile app and the server use.
const client = createClient(GreeterService, createConnectTransport({ baseUrl: "http://localhost:8080" }));

export function App() {
  const [name, setName] = useState("web");
  const [reply, setReply] = useState("");
  return (
    <main style={{ fontFamily: "sans-serif", padding: 32 }}>
      <h1>Greeter (web)</h1>
      <input value={name} onChange={(e) => setName(e.target.value)} />
      <button
        type="button"
        onClick={async () => {
          const res = await client.greet({ name });
          setReply(`${res.greeting} (#${res.count} from ${res.servedBy})`);
        }}
      >
        Greet
      </button>
      <p id="reply">{reply}</p>
    </main>
  );
}
