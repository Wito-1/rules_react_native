// Runs React Native codegen over a directory of JS/TS specs, inside a Bazel action. Same two steps
// as @react-native/gradle-plugin's GenerateCodegenSchemaTask and GenerateCodegenArtifactsTask:
// specs -> schema.json -> Java spec classes (java/) and C++ JNI/Fabric glue (jni/).
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const { createRequire } = require("node:module");
const os = require("node:os");
const path = require("node:path");
const { parseArgs } = require("node:util");

const { values: args } = parseArgs({
  options: {
    "project-root": { type: "string" },
    "js-srcs-dir": { type: "string" },
    "library-name": { type: "string" },
    "java-package": { type: "string" },
    platform: { type: "string", default: "android" },
    "out-java": { type: "string" },
    "out-jni": { type: "string" },
  },
});

function fail(message) {
  console.error(`react_native_codegen: ${message}`);
  process.exit(1);
}

function runNode(script, scriptArgs) {
  const result = spawnSync(process.execPath, [script, ...scriptArgs], { stdio: "inherit" });
  if (result.status !== 0) {
    fail(`${path.basename(script)} exited with ${result.status ?? result.signal}`);
  }
}

const projectRoot = path.resolve(args["project-root"]);
const appRequire = createRequire(path.join(projectRoot, "package.json"));
const rnDir = path.dirname(appRequire.resolve("react-native/package.json"));
const rnRequire = createRequire(path.join(rnDir, "package.json"));
const codegenDir = path.dirname(rnRequire.resolve("@react-native/codegen/package.json"));

const work = fs.mkdtempSync(path.join(os.tmpdir(), "rn-codegen-"));
const schema = path.join(work, "schema.json");
runNode(path.join(codegenDir, "lib/cli/combine/combine-js-to-schema-cli.js"), [
  "--platform",
  args.platform,
  schema,
  path.join(projectRoot, args["js-srcs-dir"]),
]);

const generated = path.join(work, "out");
runNode(path.join(rnDir, "scripts/generate-specs-cli.js"), [
  "--platform",
  args.platform,
  "--schemaPath",
  schema,
  "--outputDir",
  generated,
  "--libraryName",
  args["library-name"],
  "--javaPackageName",
  args["java-package"],
]);

for (const [sub, dest] of [
  ["java", args["out-java"]],
  ["jni", args["out-jni"]],
]) {
  fs.mkdirSync(dest, { recursive: true });
  const src = path.join(generated, sub);
  if (fs.existsSync(src)) {
    fs.cpSync(src, dest, { recursive: true });
  }
}
// The generated CMakeLists.txt is for Gradle's CMake build; Bazel compiles the sources directly.
fs.rmSync(path.join(args["out-jni"], "CMakeLists.txt"), { force: true });
fs.rmSync(work, { recursive: true, force: true });
