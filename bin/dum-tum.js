#!/usr/bin/env node
/**
 * npx entrypoint — runs install.sh from the package root.
 *   npx github:arjunagi-a-rehman/dum-tum
 *   npx dum-tum          (after published to npm)
 *   npx dum-tum --provider opencode --model anthropic/claude-sonnet-4
 *   npx dum-tum --uninstall
 */
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const installer = path.join(root, "install.sh");

if (!fs.existsSync(installer)) {
  console.error("dum-tum: install.sh not found at", installer);
  process.exit(1);
}

// Ensure executable bit when extracted from npm/github
try {
  fs.chmodSync(installer, 0o755);
} catch (_) {
  /* ignore */
}

const args = process.argv.slice(2);
if (args.some((arg) => arg === "--key" || arg.startsWith("--key="))) {
  console.error("dum-tum: --key is not supported because command-line secrets are process-visible.");
  console.error("Use the matching provider environment variable or the installer's hidden prompt.");
  process.exit(1);
}
const result = spawnSync("bash", [installer, ...args], {
  stdio: "inherit",
  cwd: root,
  env: process.env,
});

if (result.error) {
  console.error("dum-tum: failed to run bash:", result.error.message);
  console.error("Install bash, or run: curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash");
  process.exit(1);
}

process.exit(result.status === null ? 1 : result.status);
