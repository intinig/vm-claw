import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { rehomeString, rehomeJson, rehomeAnnotations, validHomes, JSON_ROOTS, TEXT_FILES, SCRIPT_EXTS } from "./homepaths.mjs";

const __dir = path.dirname(fileURLToPath(import.meta.url));
const O = "/Users/admin", N = "/home/sebastian";
const re = (s) => rehomeString(s, O, N);

test("the home itself, alone or as a prefix, becomes the new home", () => {
  assert.deepEqual(re("/Users/admin"), { text: "/home/sebastian", count: 1 });
  assert.deepEqual(re("/Users/admin/"), { text: "/home/sebastian/", count: 1 });
  assert.deepEqual(re("/Users/admin/.openclaw/bin/op-nosym"), { text: "/home/sebastian/.openclaw/bin/op-nosym", count: 1 });
});

test("paths that only look alike are left alone", () => {
  for (const s of ["/Users/administrator/x", "/Users/admin2", "/Users/admin.bak", "/Users/admin-old/x", "/x/Users/admin/y", "relative/Users/admin", "~/Users/admin"]) {
    assert.deepEqual(re(s), { text: s, count: 0 }, s);
  }
});

test("embedded paths in commands, assignments, lists and file URLs are rewritten, each one", () => {
  assert.deepEqual(re("sh -lc 'node /Users/admin/brain/h.mjs && cat /Users/admin/x'"),
    { text: "sh -lc 'node /home/sebastian/brain/h.mjs && cat /home/sebastian/x'", count: 2 });
  assert.equal(re("PATH=/Users/admin/bin:/Users/admin/.local/bin:/usr/bin").text, "PATH=/home/sebastian/bin:/home/sebastian/.local/bin:/usr/bin");
  assert.equal(re("file:///Users/admin/notes/a.md").text, "file:///home/sebastian/notes/a.md");
  assert.equal(re('{"dir":"/Users/admin/q"}').text, '{"dir":"/home/sebastian/q"}');
  assert.equal(re("Host vault\n  IdentityFile /Users/admin/.ssh/key\n").text, "Host vault\n  IdentityFile /home/sebastian/.ssh/key\n");
});

test("JSON: string values and keys at any depth; other values untouched", () => {
  const cfg = {
    secrets: { providers: { op: { source: "exec", command: `${O}/.openclaw/bin/op-nosym`, trustedDirs: [`${O}/.openclaw/bin`, "/usr/bin"], timeoutMs: 5000, enabled: true, extra: null } } },
    agents: { defaults: { workspace: `${O}/.openclaw/workspace` } },
    installs: { [`${O}/.openclaw/extensions/x`]: { at: 1 } },
    note: "/Users/administrator stays",
  };
  const { value, count } = rehomeJson(structuredClone(cfg), O, N);
  assert.equal(count, 4);
  assert.equal(value.secrets.providers.op.command, `${N}/.openclaw/bin/op-nosym`);
  assert.deepEqual(value.secrets.providers.op.trustedDirs, [`${N}/.openclaw/bin`, "/usr/bin"]);
  assert.equal(value.secrets.providers.op.timeoutMs, 5000);
  assert.equal(value.secrets.providers.op.enabled, true);
  assert.equal(value.secrets.providers.op.extra, null);
  assert.equal(value.agents.defaults.workspace, `${N}/.openclaw/workspace`);
  assert.deepEqual(Object.keys(value.installs), [`${N}/.openclaw/extensions/x`]);
  assert.equal(value.note, "/Users/administrator stays");
});

test("idempotent: a second pass finds nothing", () => {
  const once = rehomeJson({ a: `${O}/x`, b: [O] }, O, N).value;
  assert.deepEqual(rehomeJson(structuredClone(once), O, N), { value: once, count: 0 });
});

test("homes must be absolute, different and not nested", () => {
  assert.equal(validHomes(O, N), true);
  for (const [a, b] of [[O, O], ["Users/admin", N], [O, "home/sebastian"], [O, `${O}/sub`], [`${N}/sub`, N], [O, "/home/../x"], [O, "/home/sebastian/"], [undefined, N]]) {
    assert.equal(validHomes(a, b), false, `${a} -> ${b}`);
  }
});

test("the roots are the spec's live configuration", () => {
  assert.deepEqual(JSON_ROOTS, [".openclaw/openclaw.json", ".openclaw/cron", ".openclaw/skills", "ops", "brain"]);
  assert.deepEqual(TEXT_FILES, [".openclaw/bin/op-nosym", ".openclaw/.env", ".openclaw/gateway.systemd.env", ".ssh/config", "brain/vault/.git/config"]);
  assert.deepEqual(SCRIPT_EXTS, ["py", "mjs", "js", "sh"]);
});

test("project annotations: the old home's and the ~ form become the new home's, and nothing else changes", () => {
  const src = [
    `<!-- project: path:${O}/.openclaw/workspace -->`,
    "<!-- project: path:~/.openclaw/workspace -->",
    `prose naming ${O}/brain stays, and so does path:${O}/x outside an annotation`,
    `<!-- project: path:${O}istrator/x -->`,
    `<!-- project: path:${O}/a --> then <!-- project: path:~/b -->`,
  ].join("\n");
  const { text, count } = rehomeAnnotations(src, O, N);
  assert.equal(count, 4);
  assert.equal(text, [
    `<!-- project: path:${N}/.openclaw/workspace -->`,
    `<!-- project: path:${N}/.openclaw/workspace -->`,
    `prose naming ${O}/brain stays, and so does path:${O}/x outside an annotation`,
    `<!-- project: path:${O}istrator/x -->`,
    `<!-- project: path:${N}/a --> then <!-- project: path:${N}/b -->`,
  ].join("\n"));
  assert.deepEqual(rehomeAnnotations(text, O, N), { text, count: 0 });
});

function fixtureHome() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), "homepaths-"));
  const w = (rel, body, mode = 0o600) => { const f = path.join(h, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, body); fs.chmodSync(f, mode); return f; };
  const files = {
    config: w(".openclaw/openclaw.json", JSON.stringify({ secrets: { providers: { op: { command: `${O}/.openclaw/bin/op-nosym`, trustedDirs: [`${O}/.openclaw/bin`] } } }, agents: { defaults: { workspace: `${O}/.openclaw/workspace` } } }, null, 2) + "\n"),
    jobs: w(".openclaw/cron/jobs.json", JSON.stringify({ jobs: [{ id: "j1", payload: { kind: "command", argv: ["/usr/bin/node", `${O}/brain/harvester/harvest.mjs`] } }] }) + "\n"),
    skill: w(".openclaw/workspace-vera/skills/s/config.json", JSON.stringify({ dir: `${O}/brain/queue` }) + "\n"),
    ops: w("ops/bench/cfg.json", JSON.stringify({ out: `${O}/backups` }) + "\n"),
    harvester: w("brain/harvester/config.json", JSON.stringify({ storeDb: `${O}/.wacli/wacli.db` }) + "\n"),
    clean: w("brain/harvester/other.json", '{ "same": "bytes", "x": 1 }\n'),
    wrapper: w(".openclaw/bin/op-nosym", `#!/bin/sh\n# from ${O}/.openclaw/bin\nexec /usr/bin/op "$@"\n`, 0o755),
    sshcfg: w(".ssh/config", `Host vault\n  IdentityFile ${O}/.ssh/ocsb_vault\n`),
    gitcfg: w("brain/vault/.git/config", `[core]\n\tsshCommand = ssh -i ${O}/.ssh/ocsb_vault\n`),
    modules: w("brain/harvester/node_modules/x/package.json", JSON.stringify({ path: `${O}/x` })),
    vaultJson: w("brain/vault/notes.json", JSON.stringify({ path: `${O}/x` })),
    transcript: w(".openclaw/agents/main/sessions/s.jsonl", JSON.stringify({ text: `ls ${O}/brain` }) + "\n"),
    agentJson: w(".openclaw/agents/main/agent/models.json", JSON.stringify({ path: `${O}/x` })),
    broken: w("brain/queue/bad.json", `{"cut off": "${O}/x`),
  };
  return { h, files };
}
const run = (...args) => spawnSync(process.execPath, [path.join(__dir, "homepaths.mjs"), ...args], { encoding: "utf8" });

test("CLI: rewrites the live config under the new home, and nothing else", (t) => {
  const { h, files } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  const before = Object.fromEntries(Object.entries(files).map(([k, f]) => [k, fs.readFileSync(f, "utf8")]));
  const r = run(O, h);
  assert.equal(r.status, 0, r.stderr);
  const now = (k) => fs.readFileSync(files[k], "utf8");
  for (const k of ["config", "jobs", "skill", "ops", "harvester", "wrapper", "sshcfg", "gitcfg"]) {
    assert.ok(!now(k).includes(O), `${k} still names ${O}`);
    assert.ok(now(k).includes(h), `${k} names the new home`);
  }
  assert.equal(JSON.parse(now("config")).secrets.providers.op.command, `${h}/.openclaw/bin/op-nosym`);
  assert.deepEqual(JSON.parse(now("jobs")).jobs[0].payload.argv, ["/usr/bin/node", `${h}/brain/harvester/harvest.mjs`]);
  for (const k of ["clean", "modules", "vaultJson", "transcript", "agentJson", "broken"]) assert.equal(now(k), before[k], `${k} must be byte-identical`);
  assert.match(r.stdout, /bad\.json: not valid JSON, left for the scan/);
  assert.match(r.stdout, /homepaths: 8 file\(s\) rewritten from \/Users\/admin to /);
  assert.equal(fs.statSync(files.config).mode & 0o777, 0o600);
  assert.equal(fs.statSync(files.wrapper).mode & 0o777, 0o755);
  const again = run(O, h);
  assert.equal(again.status, 0);
  assert.match(again.stdout, /homepaths: 0 file\(s\) rewritten/);
});

test("CLI: bad homes are a usage error and change nothing", (t) => {
  const { h, files } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  const before = fs.readFileSync(files.config, "utf8");
  for (const args of [[], [O], [O, O], ["Users/admin", h], [h, `${h}/sub`]]) {
    const r = run(...args);
    assert.equal(r.status, 2, JSON.stringify(args));
    assert.match(r.stderr, /usage: homepaths\.mjs/);
  }
  assert.equal(fs.readFileSync(files.config, "utf8"), before);
});

test("CLI: yaml/yml/toml/conf/env files are rewritten too, and the scan then passes", (t) => {
  const { h } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  const names = ["a.yaml", "a.yml", "a.toml", "a.conf", "prod.env"];
  for (const n of names) { fs.writeFileSync(path.join(h, "brain/harvester", n), `dir: ${O}/x\n`); }
  const r = run(O, h);
  assert.equal(r.status, 0, r.stderr);
  for (const n of names) assert.equal(fs.readFileSync(path.join(h, "brain/harvester", n), "utf8"), `dir: ${h}/x\n`, n);
  const sc = spawnSync(process.execPath, [path.join(__dir, "scan-refs.mjs"), "--old-home", O, path.join(h, "brain/harvester")], { encoding: "utf8" });
  assert.equal(sc.status, 0, sc.stdout + sc.stderr);
});

test("CLI: a symlinked directory in a root stops the rewrite, naming it", (t) => {
  const { h } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  fs.mkdirSync(path.join(h, "elsewhere"));
  fs.symlinkSync(path.join(h, "elsewhere"), path.join(h, "brain/linked"));
  const r = run(O, h);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /brain\/linked is a symlinked directory; resolve or allow it explicitly/);
});

test("CLI: atomic writes keep the mode and leave no temp file", (t) => {
  const { h, files } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  assert.equal(run(O, h).status, 0);
  assert.equal(fs.statSync(files.config).mode & 0o777, 0o600);
  assert.equal(fs.statSync(files.wrapper).mode & 0o777, 0o755);
  for (const f of Object.values(files)) assert.deepEqual(fs.readdirSync(path.dirname(f)).filter((n) => n.includes(".homepaths-")), [], f);
});

test("CLI: an unreadable file is an I/O error (exit 3), not 'not valid JSON'", (t) => {
  if (process.getuid?.() === 0) return t.skip("root reads anything");
  const { h, files } = fixtureHome();
  t.after(() => { fs.chmodSync(files.ops, 0o600); fs.rmSync(h, { recursive: true, force: true }); });
  fs.chmodSync(files.ops, 0o000);
  const r = run(O, h);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /homepaths: error: .*cfg\.json: cannot read/);
  assert.doesNotMatch(r.stdout, /ops\/bench\/cfg\.json: not valid JSON/);
});

test("JSON: a __proto__ key survives; keys that collide after rewriting throw", () => {
  const src = JSON.parse(`{"__proto__": {"p": "${O}/x"}, "a": 1}`);
  const { value, count } = rehomeJson(src, O, N);
  assert.equal(count, 1);
  assert.deepEqual(Object.keys(value), ["__proto__", "a"]);
  assert.equal(Object.getPrototypeOf(value), Object.prototype);
  assert.equal(JSON.parse(JSON.stringify(value))["__proto__"].p, `${N}/x`);
  assert.throws(() => rehomeJson({ [`${O}/k`]: 1, [`${N}/k`]: 2 }, O, N), /collide/);
});

test("CLI: colliding keys are an error (exit 3) and the file is untouched", (t) => {
  const { h, files } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  fs.writeFileSync(files.ops, JSON.stringify({ [`${O}/k`]: 1, [`${h}/k`]: 2 }));
  const before = fs.readFileSync(files.ops, "utf8");
  const r = run(O, h);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /collide/);
  assert.equal(fs.readFileSync(files.ops, "utf8"), before);
});

// Addendum 2026-10-05 (state-path migration): Codex's project trust, the Workshop skills, the workspace scripts and the
// memory project annotations move with the home too.
test("CLI: Codex trust, Workshop skills, workspace scripts and project annotations are rewritten, and only those", (t) => {
  const { h } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  const w = (rel, body, mode = 0o644) => { const f = path.join(h, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, body); fs.chmodSync(f, mode); return f; };
  const f = {
    codex: w(".openclaw/agents/main/agent/codex-home/config.toml", `model = "m"\n\n[projects."${O}/.openclaw/workspace"]\ntrust_level = "trusted"\n`),
    skill: w(".openclaw/agents/main/agent/workshop-skills/charts/SKILL.md", `Run python3 ${O}/.openclaw/workspace/gen_chart.py first.\n`),
    py: w(".openclaw/workspace/gen_chart.py", `OUT = "${O}/.openclaw/workspace/charts"\n`, 0o755),
    mjs: w(".openclaw/workspace/generate_qr.mjs", `const out = '${O}/qr.png';\n`),
    js: w(".openclaw/workspace-vera/generate_whatsapp_qr.js", `require('${O}/brain/x');\n`),
    sh: w(".openclaw/workspace/scripts/run.sh", `cd ${O}/brain && ./go\n`, 0o755),
    scriptPy: w(".openclaw/workspace/scripts/fetch_stocks.py", `p = "${O}/brain/stocks"\n`),
    memory: w(".openclaw/workspace/memory/2026-09-01.md", `<!-- project: path:${O}/.openclaw/workspace -->\nNotes about ${O}/brain.\n`),
    dreams: w(".openclaw/workspace/DREAMS.md", "<!-- project: path:~/.openclaw/workspace -->\n".repeat(3)),
    deepMd: w(".openclaw/workspace-vera/memory/deep/x.md", `<!-- project: path:${O}/.openclaw/workspace-vera -->\n`),
    // Left alone: not a covered name or place, hidden, skipped, a skill's other files, history.
    txt: w(".openclaw/workspace/notes.txt", `${O}/x\n`),
    deepPy: w(".openclaw/workspace/scripts/lib/deep.py", `${O}/x\n`),
    dataPy: w(".openclaw/workspace/data/x.py", `${O}/x\n`),
    hiddenSh: w(".openclaw/workspace/.hidden.sh", `${O}/x\n`),
    hiddenMd: w(".openclaw/workspace/.cache/x.md", `<!-- project: path:${O}/x -->\n`),
    modulesMd: w(".openclaw/workspace/node_modules/p/README.md", `<!-- project: path:${O}/x -->\n`),
    skillOther: w(".openclaw/agents/main/agent/workshop-skills/charts/notes.txt", `${O}/x\n`),
    rollout: w(".openclaw/agents/main/agent/codex-home/sessions/r.jsonl", `${O}/x\n`),
    agentsMd: w(".openclaw/agents/main/agent/AGENTS.md", `<!-- project: path:${O}/x -->\n`),
  };
  const before = Object.fromEntries(Object.entries(f).map(([k, p]) => [k, fs.readFileSync(p, "utf8")]));
  const r = run(O, h);
  assert.equal(r.status, 0, r.stderr);
  const now = (k) => fs.readFileSync(f[k], "utf8");
  assert.equal(now("codex"), `model = "m"\n\n[projects."${h}/.openclaw/workspace"]\ntrust_level = "trusted"\n`);
  assert.equal(now("skill"), `Run python3 ${h}/.openclaw/workspace/gen_chart.py first.\n`);
  assert.equal(now("py"), `OUT = "${h}/.openclaw/workspace/charts"\n`);
  assert.equal(now("mjs"), `const out = '${h}/qr.png';\n`);
  assert.equal(now("js"), `require('${h}/brain/x');\n`);
  assert.equal(now("sh"), `cd ${h}/brain && ./go\n`);
  assert.equal(now("scriptPy"), `p = "${h}/brain/stocks"\n`);
  assert.equal(now("memory"), `<!-- project: path:${h}/.openclaw/workspace -->\nNotes about ${O}/brain.\n`, "only the annotation moves");
  assert.equal(now("dreams"), `<!-- project: path:${h}/.openclaw/workspace -->\n`.repeat(3));
  assert.equal(now("deepMd"), `<!-- project: path:${h}/.openclaw/workspace-vera -->\n`);
  for (const k of ["txt", "deepPy", "dataPy", "hiddenSh", "hiddenMd", "modulesMd", "skillOther", "rollout", "agentsMd"]) {
    assert.equal(now(k), before[k], `${k} must be byte-identical`);
  }
  assert.equal(fs.statSync(f.py).mode & 0o777, 0o755);
  assert.equal(fs.statSync(f.sh).mode & 0o777, 0o755);
  assert.match(r.stdout, /DREAMS\.md: 3 project annotation\(s\)/);
  assert.match(r.stdout, /homepaths: 18 file\(s\) rewritten from \/Users\/admin to /);
  const again = run(O, h);
  assert.equal(again.status, 0, again.stderr);
  assert.match(again.stdout, /homepaths: 0 file\(s\) rewritten/);
});

test("CLI: a symlinked directory inside a workspace stops the annotation rewrite, naming it", (t) => {
  const { h } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  fs.mkdirSync(path.join(h, "elsewhere"));
  fs.mkdirSync(path.join(h, ".openclaw/workspace"), { recursive: true });
  fs.symlinkSync(path.join(h, "elsewhere"), path.join(h, ".openclaw/workspace/linked"));
  const r = run(O, h);
  assert.equal(r.status, 3, r.stdout + r.stderr);
  assert.match(r.stderr, /workspace\/linked is a symlinked directory; resolve or allow it explicitly/);
});

test("CLI: a symlinked note is left as it is, and an old annotation behind it fails the run", (t) => {
  const { h } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  const target = path.join(h, "shared.md");
  fs.writeFileSync(target, `<!-- project: path:${O}/.openclaw/workspace -->\n`);
  fs.mkdirSync(path.join(h, ".openclaw/workspace"), { recursive: true });
  fs.symlinkSync(target, path.join(h, ".openclaw/workspace/MEMORY.md"));
  const r = run(O, h);
  assert.equal(r.status, 3, r.stdout + r.stderr);
  assert.match(r.stdout, /workspace\/MEMORY\.md: 1 old project annotation\(s\) left/);
  assert.match(r.stderr, /1 file\(s\) still carry old project annotations/);
  assert.equal(fs.readFileSync(target, "utf8"), `<!-- project: path:${O}/.openclaw/workspace -->\n`, "the link's target is not ours to rewrite");
  fs.writeFileSync(target, "<!-- project: path:/srv/other -->\n");
  assert.equal(run(O, h).status, 0);
});

// Fix round 1, minor 4: rehome.sh prepare runs the same walk over admin's live workspaces, read-only, before the downtime.
test("CLI --check-notes: the import's note walk, read-only; a symlinked directory in a workspace fails, naming it", (t) => {
  const { h } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  const note = path.join(h, ".openclaw/workspace/memory/2026-09-01.md");
  fs.mkdirSync(path.dirname(note), { recursive: true });
  fs.writeFileSync(note, `<!-- project: path:${O}/.openclaw/workspace -->\n`);
  fs.mkdirSync(path.join(h, ".openclaw/workspace-vera"), { recursive: true });
  fs.writeFileSync(path.join(h, ".openclaw/workspace-vera/DREAMS.md"), "<!-- project: path:~/.openclaw/workspace-vera -->\n");
  let r = run("--check-notes", h);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /homepaths: 2 memory note\(s\) in 2 workspace\(s\), no symlinked directory/);
  assert.equal(fs.readFileSync(note, "utf8"), `<!-- project: path:${O}/.openclaw/workspace -->\n`, "a check rewrites nothing");
  fs.mkdirSync(path.join(h, "elsewhere"));
  fs.symlinkSync(path.join(h, "elsewhere"), path.join(h, ".openclaw/workspace/memory/linked"));
  r = run("--check-notes", h);
  assert.equal(r.status, 3, r.stdout + r.stderr);
  assert.match(r.stderr, /workspace\/memory\/linked is a symlinked directory; resolve or allow it explicitly/);
});

test("CLI --check-notes: one absolute home, nothing else", () => {
  for (const args of [["--check-notes"], ["--check-notes", "rel/home"], ["--check-notes", "/a", "/b"]]) {
    assert.equal(run(...args).status, 2, args.join(" "));
  }
});
