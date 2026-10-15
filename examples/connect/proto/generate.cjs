// Runs `buf generate` with protoc-gen-es inside a Bazel action. Both come from node_modules; the
// plugin is handed to buf as `node <script>` so it doesn't depend on a launcher finding runfiles.
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const { createRequire } = require("node:module");
const os = require("node:os");
const path = require("node:path");

const [pkgDir, outDir] = process.argv.slice(2);
const req = createRequire(path.resolve(pkgDir, "package.json"));
const pkgRoot = (name) => path.dirname(req.resolve(`${name}/package.json`));
const buf = path.join(pkgRoot("@bufbuild/buf"), "bin", "buf");
const plugin = path.join(pkgRoot("@bufbuild/protoc-gen-es"), "bin", "protoc-gen-es");

const work = fs.mkdtempSync(path.join(os.tmpdir(), "buf-"));
const template = path.join(work, "buf.gen.json");
fs.writeFileSync(
  template,
  JSON.stringify({
    version: "v2",
    plugins: [{ local: [process.execPath, plugin], out: outDir, opt: ["target=js+dts", "import_extension=js"] }],
  }),
);
const result = spawnSync(process.execPath, [buf, "generate", pkgDir, "--template", template], {
  stdio: "inherit",
  env: { ...process.env, BUF_CACHE_DIR: path.join(work, "cache") },
});
fs.rmSync(work, { recursive: true, force: true });
process.exit(result.status ?? 1);
