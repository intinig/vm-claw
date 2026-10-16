import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const __dir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.dirname(__dir);

// Helper to create temp directory structure
function createTempFixture() {
  const tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "ziel-cli-test-"));
  const openclaw = path.join(tmpHome, ".openclaw");
  const brain = path.join(tmpHome, "brain", "harvester");
  const bin = path.join(openclaw, "bin");

  fs.mkdirSync(openclaw, { recursive: true });
  fs.mkdirSync(brain, { recursive: true });
  fs.mkdirSync(bin, { recursive: true });

  // Create openclaw.json with exec provider containing /opt/homebrew in trustedDirs
  const openclawConfig = {
    secrets: {
      providers: {
        op: {
          source: "exec",
          command: "/opt/homebrew/bin/op",
          args: ["read", "op://Vault/Item/password"],
          passEnv: ["OP_SERVICE_ACCOUNT_TOKEN", "HOME"],
          trustedDirs: ["/Users/admin/.openclaw/bin", "/opt/homebrew"]
        }
      }
    }
  };
  const openclawRaw = JSON.stringify(openclawConfig, null, 2) + "\n";
  const openclawPath = path.join(openclaw, "openclaw.json");
  fs.writeFileSync(openclawPath, openclawRaw);
  fs.chmodSync(openclawPath, 0o600);

  // Create harvester config with Homebrew wacliBin
  const harvesterConfig = {
    wacliBin: "/opt/homebrew/bin/wacli",
    storeDb: "/Users/admin/.wacli/wacli.db"
  };
  const harvesterRaw = JSON.stringify(harvesterConfig, null, 2) + "\n";
  const harvesterPath = path.join(brain, "config.json");
  fs.writeFileSync(harvesterPath, harvesterRaw);
  fs.chmodSync(harvesterPath, 0o600);

  // Create shell wrapper calling /opt/homebrew/bin/op
  const wrapperRaw = "#!/bin/sh\n# homebrew op wrapper\n/opt/homebrew/bin/op \"$@\"\n";
  const wrapperPath = path.join(bin, "op-nosym");
  fs.writeFileSync(wrapperPath, wrapperRaw);
  fs.chmodSync(wrapperPath, 0o755);

  return { tmpHome, openclawRaw, harvesterRaw, wrapperRaw, openclawPath, harvesterPath, wrapperPath };
}

test("binpaths CLI: applies rewrites and creates backups", (t) => {
  const fixture = createTempFixture();
  const { tmpHome, openclawRaw, harvesterRaw, wrapperRaw, openclawPath, harvesterPath, wrapperPath } = fixture;
  try {
    // Run binpaths CLI
    const result = spawnSync(process.execPath, [path.join(__dir, "binpaths.mjs"), tmpHome], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    assert.equal(result.status, 0, `CLI failed: ${result.stderr}`);

    // Verify changes were made
    const openclaw = path.join(tmpHome, ".openclaw");
    const openclawJson = JSON.parse(fs.readFileSync(openclawPath, "utf8"));
    assert.equal(openclawJson.secrets.providers.op.command, "/usr/bin/op", "command should be rewritten");
    assert.equal(openclawJson.secrets.providers.op.trustedDirs[1], "/usr/bin", "trustedDirs should be rewritten");

    const harvesterJson = JSON.parse(fs.readFileSync(harvesterPath, "utf8"));
    assert.equal(harvesterJson.wacliBin, "/usr/local/bin/wacli", "wacliBin should be rewritten");

    const wrapper = fs.readFileSync(wrapperPath, "utf8");
    assert.match(wrapper, /\/usr\/bin\/op/, "wrapper should contain rewritten path");

    // Verify backups exist with exact original content
    const openclawBackup = path.join(openclaw, "openclaw.json.pre-binpaths");
    const harvesterBackup = path.join(tmpHome, "brain", "harvester", "config.json.pre-binpaths");
    const wrapperBackup = path.join(openclaw, "bin", "op-nosym.pre-binpaths");

    assert(fs.existsSync(openclawBackup), "openclaw.json backup should exist");
    assert(fs.existsSync(harvesterBackup), "config.json backup should exist");
    assert(fs.existsSync(wrapperBackup), "op-nosym backup should exist");

    // Verify backup content matches original raw string exactly (strict equality, not JSON.parse)
    const openclawBackupContent = fs.readFileSync(openclawBackup, "utf8");
    assert.equal(openclawBackupContent, openclawRaw, "openclaw.json backup should have exact original content");

    const harvesterBackupContent = fs.readFileSync(harvesterBackup, "utf8");
    assert.equal(harvesterBackupContent, harvesterRaw, "config.json backup should have exact original content");

    const wrapperBackupContent = fs.readFileSync(wrapperBackup, "utf8");
    assert.equal(wrapperBackupContent, wrapperRaw, "wrapper backup should have exact original content");

    // Verify file modes: JSON files 0o600, wrapper 0o755
    const openclawMode = fs.statSync(openclawPath).mode & 0o777;
    const harvesterMode = fs.statSync(harvesterPath).mode & 0o777;
    const wrapperMode = fs.statSync(wrapperPath).mode & 0o777;
    assert.equal(openclawMode, 0o600, "openclaw.json should have mode 0o600");
    assert.equal(harvesterMode, 0o600, "config.json should have mode 0o600");
    assert.equal(wrapperMode, 0o755, "wrapper should have mode 0o755");

    // Capture raw content after first run for idempotency check
    const openclawAfterFirst = fs.readFileSync(openclawPath, "utf8");
    const harvesterAfterFirst = fs.readFileSync(harvesterPath, "utf8");
    const wrapperAfterFirst = fs.readFileSync(wrapperPath, "utf8");
    const openclawBackupAfterFirst = fs.readFileSync(openclawBackup, "utf8");
    const harvesterBackupAfterFirst = fs.readFileSync(harvesterBackup, "utf8");
    const wrapperBackupAfterFirst = fs.readFileSync(wrapperBackup, "utf8");

    // Second run should report 0 changes and maintain byte-identical files
    const result2 = spawnSync(process.execPath, [path.join(__dir, "binpaths.mjs"), tmpHome], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    assert.equal(result2.status, 0, `Second run failed: ${result2.stderr}`);
    assert.match(result2.stdout, /binpaths: 0 change\(s\)/, "Second run should report 0 changes");

    // Verify files are byte-identical after second run
    const openclawAfterSecond = fs.readFileSync(openclawPath, "utf8");
    const harvesterAfterSecond = fs.readFileSync(harvesterPath, "utf8");
    const wrapperAfterSecond = fs.readFileSync(wrapperPath, "utf8");

    assert.equal(openclawAfterSecond, openclawAfterFirst, "openclaw.json should be byte-identical after second run");
    assert.equal(harvesterAfterSecond, harvesterAfterFirst, "config.json should be byte-identical after second run");
    assert.equal(wrapperAfterSecond, wrapperAfterFirst, "wrapper should be byte-identical after second run");

    // Verify backups are unchanged after second run (contain original content)
    const openclawBackupAfterSecond = fs.readFileSync(openclawBackup, "utf8");
    const harvesterBackupAfterSecond = fs.readFileSync(harvesterBackup, "utf8");
    const wrapperBackupAfterSecond = fs.readFileSync(wrapperBackup, "utf8");

    assert.equal(openclawBackupAfterSecond, openclawRaw, "openclaw backup should remain original after second run");
    assert.equal(harvesterBackupAfterSecond, harvesterRaw, "harvester backup should remain original after second run");
    assert.equal(wrapperBackupAfterSecond, wrapperRaw, "wrapper backup should remain original after second run");

    // Verify modes remain unchanged after second run
    assert.equal(fs.statSync(openclawPath).mode & 0o777, 0o600, "openclaw.json mode should remain 0o600");
    assert.equal(fs.statSync(harvesterPath).mode & 0o777, 0o600, "config.json mode should remain 0o600");
    assert.equal(fs.statSync(wrapperPath).mode & 0o777, 0o755, "wrapper mode should remain 0o755");
  } finally {
    fs.rmSync(tmpHome, { recursive: true });
  }
});

test("scan-refs CLI: exits 1 on dir with macOS commands", (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ziel-scan-test-"));
  try {
    // Create a file with a macOS-only command
    fs.writeFileSync(path.join(tmpDir, "test.md"), "Use launchctl to manage services\n");

    const result = spawnSync(process.execPath, [path.join(__dir, "scan-refs.mjs"), tmpDir], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    assert.equal(result.status, 1, "Should exit 1 when macOS commands found");
    assert.match(result.stdout, /launchctl/, "Should report the macOS command");
  } finally {
    fs.rmSync(tmpDir, { recursive: true });
  }
});

test("scan-refs CLI: exits 0 on clean dir", (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ziel-scan-test-"));
  try {
    // Create a clean file with no macOS commands or Homebrew paths
    fs.writeFileSync(path.join(tmpDir, "test.md"), "This is a clean file with no problematic references\n");

    const result = spawnSync(process.execPath, [path.join(__dir, "scan-refs.mjs"), tmpDir], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    assert.equal(result.status, 0, "Should exit 0 when no problems found");
    assert.match(result.stdout, /scan-refs: 0 file\(s\) need attention/, "Should report 0 files");
  } finally {
    fs.rmSync(tmpDir, { recursive: true });
  }
});

test("binpaths CLI through symlinked path behaves identically to direct path", (t) => {
  const fixture = createTempFixture();
  const { tmpHome } = fixture;
  const tmpSymlinks = fs.mkdtempSync(path.join(os.tmpdir(), "ziel-symlink-test-"));
  try {
    // Create symlink to binpaths.mjs
    const symlinkPath = path.join(tmpSymlinks, "binpaths.mjs");
    fs.symlinkSync(path.resolve(path.join(__dir, "binpaths.mjs")), symlinkPath);

    // Run via symlink
    const resultViaSymlink = spawnSync(process.execPath, [symlinkPath, tmpHome], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    assert.equal(resultViaSymlink.status, 0, `CLI via symlink failed: ${resultViaSymlink.stderr}`);

    // Verify changes were applied (same as direct run)
    const openclaw = path.join(tmpHome, ".openclaw");
    const openclawJson = JSON.parse(fs.readFileSync(path.join(openclaw, "openclaw.json"), "utf8"));
    assert.equal(openclawJson.secrets.providers.op.command, "/usr/bin/op", "symlink run should rewrite command");
  } finally {
    fs.rmSync(tmpHome, { recursive: true });
    fs.rmSync(tmpSymlinks, { recursive: true });
  }
});
