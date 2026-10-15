import http from "node:http";
import { connectNodeAdapter } from "@connectrpc/connect-node";
import { routes } from "./routes.mjs";

const port = Number(process.env.PORT ?? 8080);
const connect = connectNodeAdapter({ routes });

// The web app runs on another origin (Vite's dev server); allow it, and the Connect headers.
const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Connect-Protocol-Version, Connect-Timeout-Ms");
  if (req.method === "OPTIONS") {
    res.writeHead(204).end();
    return;
  }
  connect(req, res);
});
server.listen(port, "0.0.0.0", () => console.log(`GreeterService on http://localhost:${port}`));
