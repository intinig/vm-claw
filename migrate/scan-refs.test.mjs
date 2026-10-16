import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { scan, homeRefs } from "./scan-refs.mjs";

const __dir = path.dirname(fileURLToPath(import.meta.url));

test("finds Homebrew binary references", () => {
  assert.deepEqual(scan("run /opt/homebrew/bin/wacli sync now", []).homebrew, ["/opt/homebrew/bin/wacli"]);
});

test("finds macOS-only commands", () => {
  const r = scan("then launchctl kickstart -k gui/501/x and osascript -e 'x'", []);
  assert.deepEqual(r.macos.sort(), ["launchctl", "osascript"]);
});

test("allow-list suppresses a known-harmless mention", () => {
  assert.deepEqual(scan("historical: we used launchctl on the old VM", [/historical:.*launchctl/]).macos, []);
});

test("does not flag words that contain a command name as a substring", () => {
  assert.deepEqual(scan("xlaunchctl launchctl2 mypbcopy", []).macos, []);
  assert.deepEqual(scan("reopened the openclaw docs", []).macos, []);
});

test("flags macOS commands with absolute paths", () => {
  const r = scan("/bin/launchctl list && /usr/bin/osascript -e 'x'", []);
  assert.deepEqual(r.macos.sort(), ["launchctl", "osascript"]);
});

test("flags macOS commands in markdown code spans", () => {
  assert.deepEqual(scan("Use `launchctl` to manage services and `osascript` for automation", []).macos.sort(), ["launchctl", "osascript"]);
});

test("flags macOS commands with trailing punctuation: semicolon, period, comma, exclamation", () => {
  const r = scan("run pbcopy; run pbpaste. use scutil, check launchctl!", []);
  assert.deepEqual(r.macos.sort(), ["launchctl", "pbcopy", "pbpaste", "scutil"]);
});

test("flags macOS commands in markdown bold: **launchctl**", () => {
  assert.deepEqual(scan("Use **launchctl** to manage services", []).macos, ["launchctl"]);
});

test("flags macOS commands with trailing comma: launchctl,", () => {
  assert.deepEqual(scan("Use launchctl, osascript, or pbcopy to automate", []).macos.sort(), ["launchctl", "osascript", "pbcopy"]);
});

test("does not flag macOS commands in hyphenated words", () => {
  const r = scan("launchctl-helper my-pbcopy imsg-rpc the pre-scutil step", []);
  assert.deepEqual(r.macos, []);
});

test("module imports safely via node --input-type=module -e without throwing", async (t) => {
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", `import { scan } from '${path.join(__dir, "scan-refs.mjs")}'; console.log('ok');`], {
    cwd: __dir,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, `Expected exit 0, got ${result.status}. stderr: ${result.stderr}`);
  assert.match(result.stdout, /ok/, "Expected 'ok' in stdout");
});

test("Homebrew paths with trailing punctuation are cleaned", () => {
  const r = scan("run /opt/homebrew/bin/wacli. and /opt/homebrew/bin/op-", []);
  assert.deepEqual(r.homebrew, ["/opt/homebrew/bin/wacli", "/opt/homebrew/bin/op"]);
});

test("homeRefs counts the old home wherever it is still named, lookalikes excluded", () => {
  assert.equal(homeRefs("cd /Users/admin/brain && ls /Users/admin", "/Users/admin"), 2);
  assert.equal(homeRefs("see /Users/admin.", "/Users/admin"), 1);
  assert.equal(homeRefs("file:///Users/admin/x", "/Users/admin"), 1);
  assert.equal(homeRefs("/Users/administrator /Users/admin-old /Users/admin2", "/Users/admin"), 0);
  assert.equal(homeRefs("", "/Users/admin"), 0);
});

test("homeRefs honours the allow-list", () => {
  assert.equal(homeRefs("historical: lived in /Users/admin\nnow: /Users/admin/x", "/Users/admin", [/^historical:/]), 1);
});

const scanDir = () => fs.mkdtempSync(path.join(os.tmpdir(), "scan-home-"));
const put = (d, rel, body) => { const f = path.join(d, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, body); return f; };
const runScan = (...args) => spawnSync(process.execPath, [path.join(__dir, "scan-refs.mjs"), ...args], { encoding: "utf8" });

test("--old-home CLI: names each file that still has it, skips transcripts and the vault, scans explicit files whatever their name", (t) => {
  const d = scanDir();
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  put(d, "brain/prompts/p.md", "Read /Users/admin/brain/queue first.\n");
  put(d, "brain/ok.md", "Read ~/brain/queue first.\n");
  put(d, "brain/sessions.jsonl", '{"t":"/Users/admin/x"}\n');
  put(d, "brain/vault/note.md", "/Users/admin/old\n");
  put(d, "brain/node_modules/m/index.js", "/Users/admin\n");
  const wrapper = put(d, "bin/op-nosym", "# /Users/admin/.openclaw/bin\n");
  const r = runScan("--old-home", "/Users/admin", path.join(d, "brain"), wrapper);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /brain\/prompts\/p\.md: 1 reference\(s\) to \/Users\/admin/);
  assert.match(r.stdout, /bin\/op-nosym: 1 reference\(s\) to \/Users\/admin/);
  assert.doesNotMatch(r.stdout, /ok\.md|sessions\.jsonl|vault|node_modules/);
  assert.match(r.stdout, /scan-refs: 2 file\(s\) still name \/Users\/admin/);
});

test("--old-home CLI: clean roots exit 0; a missing or relative home is a usage error", (t) => {
  const d = scanDir();
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  put(d, "brain/ok.md", "Read ~/brain/queue first.\n");
  const ok = runScan("--old-home", "/Users/admin", path.join(d, "brain"));
  assert.equal(ok.status, 0);
  assert.match(ok.stdout, /scan-refs: 0 file\(s\) still name \/Users\/admin/);
  for (const args of [["--old-home"], ["--old-home", "Users/admin", d], ["--old-home", "/Users/admin/", d], ["--old-home", "//", d], ["--old-home", "/Users/../x", d], ["--old-home", "/Users//admin", d], ["--old-home", "/", d]]) {
    const r = runScan(...args);
    assert.equal(r.status, 2, JSON.stringify(args));
    assert.match(r.stderr, /usage: scan-refs\.mjs --old-home/);
  }
});

test("--old-home CLI: no vacuous pass (missing root, all roots missing, nothing scanned)", (t) => {
  const d = scanDir();
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  put(d, "brain/ok.md", "fine\n");
  fs.mkdirSync(path.join(d, "empty"));
  const gone = path.join(d, "absent");
  let r = runScan("--old-home", "/Users/admin", path.join(d, "brain"), gone);
  assert.equal(r.status, 4);
  assert.match(r.stderr, /scan-refs: .*absent: does not exist/);
  r = runScan("--old-home", "/Users/admin", gone, path.join(d, "gone2"));
  assert.equal(r.status, 4);
  r = runScan("--old-home", "/Users/admin", path.join(d, "empty"));
  assert.equal(r.status, 4);
  assert.match(r.stderr, /scan-refs: nothing scanned/);
});

test("--old-home CLI: reads any file name, skips binaries, never prints content", (t) => {
  const d = scanDir();
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  put(d, "c/app.cfg", "token=SECRETVALUE path=/Users/admin/x\n");
  put(d, "c/blob.bin", Buffer.concat([Buffer.from("/Users/admin/x"), Buffer.from([0, 1, 2])]));
  put(d, "c/clean.md", "nothing\n");
  const r = runScan("--old-home", "/Users/admin", path.join(d, "c"));
  assert.equal(r.status, 1);
  assert.match(r.stdout, /app\.cfg: 1 reference\(s\)/);
  assert.doesNotMatch(r.stdout + r.stderr, /blob\.bin|SECRETVALUE/);
});

test("--old-home CLI: a symlinked directory in a root fails closed, naming it", (t) => {
  const d = scanDir();
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  put(d, "c/a.md", "fine\n");
  put(d, "real/b.md", "/Users/admin\n");
  fs.symlinkSync(path.join(d, "real"), path.join(d, "c/link"));
  const r = runScan("--old-home", "/Users/admin", path.join(d, "c"));
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /c\/link is a symlinked directory; resolve or allow it explicitly/);
});
