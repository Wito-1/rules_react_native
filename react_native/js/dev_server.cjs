// Runs Metro as a React Native dev server for debug builds: Fast Refresh, reload from the dev
// menu, and the React Native DevTools debugger. The `react-native start` equivalent; the bits of
// the optional @react-native-community/cli-server-api it relies on (/status, /message) are
// implemented here so apps don't need the community CLI.
"use strict";

const { createRequire } = require("node:module");
const path = require("node:path");
const { parseArgs } = require("node:util");
const { loadMetroConfig } = require("./metro_config.cjs");

const { values: args } = parseArgs({
  options: {
    "project-root": { type: "string", default: "." },
    host: { type: "string", default: "localhost" },
    port: { type: "string", default: "8081" },
  },
});

async function main() {
  const projectRoot = path.resolve(args["project-root"]);
  const port = Number(args.port);
  const devServerUrl = `http://${args.host}:${port}`;
  const { config: baseConfig, req } = await loadMetroConfig(projectRoot, { hermetic: false });
  const Metro = req.cli("metro");
  const { Terminal } = req.cli("metro-core");
  const { createDevMiddleware } = req.cli("@react-native/dev-middleware");

  const reporter = new Metro.TerminalReporter(new Terminal(process.stdout));
  const config = Metro.mergeConfig(baseConfig, { reporter, server: { port } });
  const { middleware, websocketEndpoints } = createDevMiddleware({
    serverBaseUrl: devServerUrl,
    logger: { info: console.info, warn: console.warn, error: console.error },
  });
  // DevSupportManager probes this before loading JS from the server; the CLI's server-api answers
  // it in a stock setup.
  const status = (request, response, next) => {
    if (request.url === "/status") {
      response.end("packager-status:running");
      return;
    }
    next();
  };

  // The app's packager connection. DevSupportManager only offers "Open DevTools" once this is
  // connected, and it is how reload/dev-menu commands reach the app: every message is relayed to
  // the other connected clients.
  const ws = createRequire(req.cli.resolve("metro/package.json"))("ws");
  // ws 7 (Metro's) exports Server; ws 8 renamed it WebSocketServer.
  const messageServer = new (ws.WebSocketServer ?? ws.Server)({ noServer: true });
  messageServer.on("connection", (socket) => {
    socket.on("message", (data) => broadcast(messageServer, data.toString(), socket));
  });

  await Metro.runServer(config, {
    host: args.host,
    unstable_extraMiddleware: [status, middleware],
    websocketEndpoints: { ...websocketEndpoints, "/message": messageServer },
  });
  console.info(`Metro is serving ${projectRoot} on ${devServerUrl}`);
  if (process.stdin.isTTY) {
    console.info("Press r to reload the app, d to open its dev menu.");
    process.stdin.setRawMode(true);
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (key) => {
      if (key === "\u0003") {
        process.exit(0);
      } else if (key === "r") {
        broadcast(messageServer, JSON.stringify({ version: 2, method: "reload" }));
      } else if (key === "d") {
        broadcast(messageServer, JSON.stringify({ version: 2, method: "devMenu" }));
      }
    });
  }
}

function broadcast(server, message, except) {
  for (const client of server.clients) {
    if (client !== except && client.readyState === client.OPEN) {
      client.send(message);
    }
  }
}

main().catch((err) => {
  console.error(err?.stack ?? String(err));
  process.exit(1);
});
