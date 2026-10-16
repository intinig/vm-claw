import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const guardPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "guard.mjs");
// The committed stranded-listener log (tests/acceptance.sh replays it on the guest) and the moment it is replayed at.
const FIXTURE = path.join(path.dirname(guardPath), "fixtures", "stranded-listener");
const REPLAY_AT = "2026-09-30T09:02:00Z";
// Live runs (no --now) are judged against the real clock, so their logs are dated relative to it.
const MIN = 60e3;
const NOW = Date.now();
const ago = (ms) => new Date(NOW - ms).toISOString();

const line = (iso, msg) => JSON.stringify({ 1: msg, _meta: { date: iso } });
const BASE = [line(ago(62 * MIN), "gateway ready"), line(ago(61 * MIN), "Listening for WhatsApp inbound messages (DM + all groups)")];
const STRANDED = [
  line(ago(90e3), "Gateway client authority closed before dispatching cron.list"),
  line(ago(88e3), "The reply channel changed or cannot preserve its sender; delivery was not started."),
];
const LINKED = 'echo "- WhatsApp default: enabled, configured, linked, running, connected"';
const NOT_LINKED = 'echo "- WhatsApp default: enabled, configured, not linked, stopped"';

// An isolated sandbox: a log dir (synthetic, or the committed fixture), a stub `openclaw` that records each call, a
// state file path, and a restart command that only touches a marker.
function sandbox({ logs = [...BASE, ...STRANDED], logDir: fixedLogDir, stub = LINKED, state, withStub = true }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "guard-cli-"));
  const binDir = path.join(dir, "bin");
  fs.mkdirSync(binDir);
  const logDir = fixedLogDir ?? path.join(dir, "logs");
  if (!fixedLogDir) {
    fs.mkdirSync(logDir);
    fs.writeFileSync(path.join(logDir, "openclaw-2026-09-30.log"), logs.join("\n") + "\n");
  }
  if (withStub) fs.writeFileSync(path.join(binDir, "openclaw"), `#!/bin/sh\necho "$@" >> "$STUB_CALLS"\n${stub}\n`, { mode: 0o755 });
  const p = { dir, calls: path.join(dir, "calls.txt"), marker: path.join(dir, "restarted"), stateFile: path.join(dir, "state", "g.json") };
  if (state) {
    fs.mkdirSync(path.dirname(p.stateFile), { recursive: true });
    fs.writeFileSync(p.stateFile, JSON.stringify(state));
  }
  p.run = (extraArgs = []) => spawnSync(process.execPath, [guardPath, ...extraArgs], {
    encoding: "utf8",
    env: {
      // Stub dir only when the stub is wanted; otherwise an empty dir so the real `openclaw` can never be found.
      PATH: withStub ? `${binDir}${path.delimiter}${process.env.PATH}` : binDir,
      GUARD_LOG_DIR: logDir,
      GUARD_STATE: p.stateFile,
      GUARD_RESTART: `touch "${p.marker}"`,
      STUB_CALLS: p.calls,
    },
  });
  p.calledTimes = () => (fs.existsSync(p.calls) ? fs.readFileSync(p.calls, "utf8").trim().split("\n").length : 0);
  p.cleanup = () => fs.rmSync(dir, { recursive: true, force: true });
  return p;
}

test("failing `channels status` yields a skip, never a blind restart, and exits 0", (t) => {
  const s = sandbox({ stub: "exit 1" });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skip: WhatsApp status unknown/);
  assert.match(r.stderr, /status check failed: exit 1/);
  assert.equal(s.calledTimes(), 1);
  assert.equal(fs.existsSync(s.marker), false, "gateway must not be restarted");
  assert.equal(fs.existsSync(s.stateFile), false, "no restart recorded");
});

test("`openclaw` missing from PATH yields a skip and exits 0", (t) => {
  const s = sandbox({ withStub: false });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skip: WhatsApp status unknown/);
  assert.match(r.stderr, /status check failed: ENOENT/);
  assert.equal(fs.existsSync(s.marker), false);
});

test("a linked WhatsApp plus a stranded log restarts the gateway and records it (control)", (t) => {
  const s = sandbox({});
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /restart: stranded listener \(2 events\)/);
  assert.equal(s.calledTimes(), 1);
  assert.equal(fs.existsSync(s.marker), true);
  const { restarts } = JSON.parse(fs.readFileSync(s.stateFile, "utf8"));
  assert.equal(restarts.length, 1);
  assert.ok(restarts[0] >= NOW && restarts[0] <= Date.now(), "the restart is recorded at the time it happened");
});

test("during cooldown the gateway status is not queried at all", (t) => {
  const s = sandbox({ state: { restarts: [NOW - 17 * MIN] } });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skip: cooldown/);
  assert.equal(s.calledTimes(), 0, "status must not be called when it cannot change the outcome");
  assert.equal(fs.existsSync(s.marker), false);
});

test("at the daily cap the gateway status is not queried either", (t) => {
  const s = sandbox({ state: { restarts: [6, 5, 4, 3, 2, 1].map((h) => NOW - h * 3600e3) } });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skip: 6 restarts in 24h/);
  assert.equal(s.calledTimes(), 0);
});

test("a quiet log is silent and does not query the gateway status", (t) => {
  const s = sandbox({ logs: BASE });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "");
  assert.equal(s.calledTimes(), 0);
});

test("--now without --dry-run refuses: exit 2, says why, never restarts, records nothing, asks nothing (#41)", (t) => {
  const s = sandbox({ logDir: FIXTURE });
  t.after(s.cleanup);
  const r = s.run(["--now", REPLAY_AT]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /--now replays recorded history; it only runs with --dry-run \(refusing to restart the gateway\)/);
  assert.equal(r.stdout, "");
  assert.equal(fs.existsSync(s.marker), false, "a replay must never restart the gateway");
  assert.equal(fs.existsSync(s.stateFile), false);
  assert.equal(s.calledTimes(), 0);
});

for (const extra of [[], ["--dry-run"]]) {
  test(`--now=<iso> is rejected (${extra.join(" ") || "live"}): exit 2 before any log or state is read`, (t) => {
    const s = sandbox({ logDir: path.join(os.tmpdir(), "guard-cli-no-such-log-dir") });
    t.after(s.cleanup);
    const r = s.run([...extra, `--now=${REPLAY_AT}`]);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /guard: use --now <iso> \(two arguments\); --now=<iso> is not accepted/);
    assert.equal(r.stdout, "");
    assert.equal(fs.existsSync(s.marker), false);
    assert.equal(fs.existsSync(s.stateFile), false);
    assert.equal(s.calledTimes(), 0);
  });
}

test("the committed stranded-listener fixture replays to a restart decision, and only a dry one", (t) => {
  const s = sandbox({ logDir: FIXTURE });
  t.after(s.cleanup);
  const r = s.run(["--dry-run", "--now", REPLAY_AT]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "[dry-run] 2026-09-30T09:02:00.000Z restart: stranded listener (2 events)\n");
  assert.equal(fs.existsSync(s.marker), false);
  assert.equal(fs.existsSync(s.stateFile), false);
  assert.equal(s.calledTimes(), 1, "the linked check is asked once");
});

test("the fixture with WhatsApp not linked replays to a skip (what a rehearsal guest shows)", (t) => {
  const s = sandbox({ logDir: FIXTURE, stub: NOT_LINKED });
  t.after(s.cleanup);
  const r = s.run(["--dry-run", "--now", REPLAY_AT]);
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "[dry-run] 2026-09-30T09:02:00.000Z skip: WhatsApp not linked (2 events)\n");
});

test("the fixture replayed before its stranded events finds none", (t) => {
  const s = sandbox({ logDir: FIXTURE });
  t.after(s.cleanup);
  const r = s.run(["--dry-run", "--now", "2026-09-30T09:00:00Z"]);
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "ok: 0 event(s) in window\n");
  assert.equal(s.calledTimes(), 0);
});
