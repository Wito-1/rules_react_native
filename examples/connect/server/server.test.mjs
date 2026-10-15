import assert from "node:assert/strict";
import { test } from "node:test";
import { createClient, createRouterTransport } from "@connectrpc/connect";
import { GreeterService } from "@examples/greeter-proto";
import { routes } from "./routes.mjs";

test("Greet greets and counts", async () => {
  const client = createClient(GreeterService, createRouterTransport(routes));
  const first = await client.greet({ name: "Ada" });
  assert.equal(first.greeting, "Hello, Ada!");
  assert.equal(first.servedBy, "node");
  assert.equal(first.count, 1n);
  const second = await client.greet({ name: "  " });
  assert.equal(second.greeting, "Hello, stranger!");
  assert.equal(second.count, 2n);
});
