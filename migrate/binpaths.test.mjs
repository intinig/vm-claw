import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DEFAULT_MAP, rewriteOpenclawConfig, rewriteHarvesterConfig, rewriteShellWrapper, rewriteArgv } from "./binpaths.mjs";

const __dir = path.dirname(fileURLToPath(import.meta.url));

const provider = (cmd) => ({ source: "exec", command: cmd, args: ["read", "op://Vault/Item/password"],
  passEnv: ["OP_SERVICE_ACCOUNT_TOKEN", "HOME"], trustedDirs: ["/Users/admin/.openclaw/bin", "/opt/homebrew"] });

test("rewrites trustedDirs /opt/homebrew to /usr/bin and leaves the wrapper command alone", () => {
  const cfg = { secrets: { providers: { a: provider("/Users/admin/.openclaw/bin/op-nosym"), f: { source: "file", path: "~/.openclaw/state/secrets.json" } } } };
  const { cfg: out, changes } = rewriteOpenclawConfig(structuredClone(cfg), DEFAULT_MAP);
  assert.deepEqual(out.secrets.providers.a.trustedDirs, ["/Users/admin/.openclaw/bin", "/usr/bin"]);
  assert.equal(out.secrets.providers.a.command, "/Users/admin/.openclaw/bin/op-nosym");
  assert.deepEqual(out.secrets.providers.f, cfg.secrets.providers.f);
  assert.equal(changes.length, 1);
});

test("rewrites a provider command that points straight at Homebrew", () => {
  const { cfg: out } = rewriteOpenclawConfig({ secrets: { providers: { a: provider("/opt/homebrew/bin/op") } } }, DEFAULT_MAP);
  assert.equal(out.secrets.providers.a.command, "/usr/bin/op");
});

test("never touches home paths or unrelated strings anywhere in the config", () => {
  const cfg = { agents: { defaults: { workspace: "/Users/admin/.openclaw/workspace" } }, note: "see /opt/homebrew/bin/wacli docs",
    secrets: { providers: { a: provider("/Users/admin/.openclaw/bin/op-nosym") } } };
  const { cfg: out } = rewriteOpenclawConfig(structuredClone(cfg), DEFAULT_MAP);
  assert.equal(out.agents.defaults.workspace, "/Users/admin/.openclaw/workspace");
  assert.equal(out.note, "see /opt/homebrew/bin/wacli docs");
});

test("is idempotent", () => {
  const once = rewriteOpenclawConfig({ secrets: { providers: { a: provider("/opt/homebrew/bin/op") } } }, DEFAULT_MAP).cfg;
  const twice = rewriteOpenclawConfig(structuredClone(once), DEFAULT_MAP);
  assert.deepEqual(twice.cfg, once);
  assert.equal(twice.changes.length, 0);
});

test("harvester wacliBin", () => {
  const { cfg, changes } = rewriteHarvesterConfig({ wacliBin: "/opt/homebrew/bin/wacli", storeDb: "/Users/admin/.wacli/wacli.db" }, DEFAULT_MAP);
  assert.equal(cfg.wacliBin, "/usr/local/bin/wacli");
  assert.equal(cfg.storeDb, "/Users/admin/.wacli/wacli.db");
  assert.equal(changes.length, 1);
});

test("shell wrapper: mapped paths replaced, everything else byte-identical", () => {
  const src = "#!/bin/sh\n# homebrew op is a symlink\n  /opt/homebrew/bin/op \"$@\"\n  sleep 2\n";
  const { text, changes } = rewriteShellWrapper(src, DEFAULT_MAP);
  assert.equal(text, "#!/bin/sh\n# homebrew op is a symlink\n  /usr/bin/op \"$@\"\n  sleep 2\n");
  assert.equal(changes.length, 1);
});

test("argv: only argv[0] is mapped", () => {
  assert.deepEqual(rewriteArgv(["/opt/homebrew/bin/node", "/Users/admin/brain/harvester/harvest.mjs"], DEFAULT_MAP),
    { argv: ["/usr/bin/node", "/Users/admin/brain/harvester/harvest.mjs"], changed: true });
  assert.deepEqual(rewriteArgv(["/usr/bin/node", "x"], DEFAULT_MAP), { argv: ["/usr/bin/node", "x"], changed: false });
});

test("module imports safely via node --input-type=module -e without throwing", async (t) => {
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", `import { DEFAULT_MAP } from '${path.join(__dir, "binpaths.mjs")}'; console.log('ok');`], {
    cwd: __dir,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, `Expected exit 0, got ${result.status}. stderr: ${result.stderr}`);
  assert.match(result.stdout, /ok/, "Expected 'ok' in stdout");
});
