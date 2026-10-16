import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { assess } from "./backup-health.mjs";

const T = (iso) => Date.parse(iso);
const H = 3600e3;
const NOW = T("2026-10-02T06:00:00Z");
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const name = (ms) => "claw-nightly-" + iso(ms).replace(/[-:]/g, "");
const night = (hoursAgo) => name(NOW - hoursAgo * H);
const stamp = (hoursAgo) => iso(NOW - hoursAgo * H) + "\n";
const run = (o) => assess({ now: NOW, nightlyNames: [night(2)], stampText: stamp(1), ...o });

test("healthy: one line with both ages, rounded down", () => {
  const r = run({ nightlyNames: [night(2.9)], stampText: stamp(0.5) });
  assert.equal(r.ok, true);
  assert.equal(r.line, "backup ok: newest nightly 2h old, host pull 0h old");
});

test("the newest nightly decides, whatever the order of the names", () => {
  const r = run({ nightlyNames: [night(26), night(2), night(50)] });
  assert.equal(r.ok, true);
  assert.match(r.line, /newest nightly 2h old/);
});

test("names are parsed as UTC", () => {
  const r = run({ nightlyNames: ["claw-nightly-20261002T040000Z"], stampText: "2026-10-02T05:00:00Z" });
  assert.equal(r.line, "backup ok: newest nightly 2h old, host pull 1h old");
});

test("an impossible date in a name is not a nightly", () => {
  const r = run({ nightlyNames: ["claw-nightly-20260231T040000Z", "claw-nightly-20261302T040000Z", "claw-nightly-20261002T250000Z", "claw-nightly-20261002T040075Z"] });
  assert.match(r.line, /no nightly backup/);
});

test("no nightly at all", () => {
  const r = run({ nightlyNames: [] });
  assert.equal(r.ok, false);
  assert.match(r.line, /^BACKUP ALERT: .*no nightly backup/);
});

test("names that are not complete nightlies do not count", () => {
  const r = run({ nightlyNames: ["claw-nightly-20261002T040000Z.partial", "claw-nightly-garbageZ", "notes.txt"] });
  assert.equal(r.ok, false);
  assert.match(r.line, /no nightly backup/);
});

test("a newest nightly of exactly 30 h is still fine; one second more is not", () => {
  assert.equal(run({ nightlyNames: [name(NOW - 30 * H)], stampText: stamp(1) }).ok, true);
  const r = run({ nightlyNames: [name(NOW - 30 * H - 1000)] });
  assert.equal(r.ok, false);
  assert.match(r.line, /^BACKUP ALERT: .*newest nightly .*30h old.*limit 30h/);
});

test("maxAgeHours is a parameter", () => {
  assert.equal(run({ nightlyNames: [night(10)], maxAgeHours: 9 }).ok, false);
  assert.equal(run({ nightlyNames: [night(10)], maxAgeHours: 10 }).ok, true);
});

test("a newest nightly 1 h ahead is allowed; a second more is an alarm", () => {
  const ok = run({ nightlyNames: [name(NOW + H)] });
  assert.equal(ok.ok, true);
  assert.match(ok.line, /newest nightly 0h old/);
  const r = run({ nightlyNames: [name(NOW + H + 1000)] });
  assert.equal(r.ok, false);
  assert.match(r.line, /^BACKUP ALERT: .*in the future/);
});

test("stamp missing", () => {
  for (const stampText of [null, undefined]) {
    const r = run({ stampText });
    assert.equal(r.ok, false);
    assert.match(r.line, /^BACKUP ALERT: .*host pull stamp is missing/);
  }
});

test("stamp unparseable", () => {
  for (const stampText of ["", "\n", "yesterday", "2026-13-45T00:00:00Z", "2026-10-02", "2026-10-02T05:00:00Z extra", "2026-02-31T05:00:00Z", "2026-10-02T05:00:00+00:00", "2026-10-02T05:00:00.000Z"]) {
    const r = run({ stampText });
    assert.equal(r.ok, false, JSON.stringify(stampText));
    assert.match(r.line, /^BACKUP ALERT: .*host pull stamp is unreadable/);
  }
});

test("a stamp of exactly 30 h is fine; one second more is an alarm", () => {
  assert.equal(run({ stampText: iso(NOW - 30 * H) }).ok, true);
  const r = run({ stampText: iso(NOW - 30 * H - 1000) });
  assert.equal(r.ok, false);
  assert.match(r.line, /^BACKUP ALERT: .*host pull .*30h old.*limit 30h/);
});

test("a stamp in the future is an alarm, with no allowance", () => {
  assert.equal(run({ stampText: iso(NOW) }).ok, true);
  const r = run({ stampText: iso(NOW + 1000) });
  assert.equal(r.ok, false);
  assert.match(r.line, /^BACKUP ALERT: .*host pull stamp is in the future/);
});

test("every problem is named in the one line", () => {
  const r = run({ nightlyNames: [night(40)], stampText: null });
  assert.equal(r.ok, false);
  assert.ok(!r.line.includes("\n"));
  assert.match(r.line, /^BACKUP ALERT: .*newest nightly.*40h old.*host pull stamp is missing/);
  const r2 = run({ nightlyNames: [], stampText: "junk" });
  assert.match(r2.line, /^BACKUP ALERT: .*no nightly backup.*host pull stamp is unreadable/);
});

// --- the CLI, on a scratch HOME ---
const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "backup-health.mjs");
function cli(setup) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "bh-"));
  try {
    setup(home);
    const r = spawnSync(process.execPath, [script, "--now", iso(NOW)], { env: { ...process.env, HOME: home }, encoding: "utf8" });
    return { code: r.status, out: r.stdout, err: r.stderr };
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
}
const mkNights = (home, ...names) => {
  for (const n of names) fs.mkdirSync(path.join(home, "backups", n), { recursive: true });
};

test("CLI: healthy exits 0 with exactly one line", () => {
  const r = cli((h) => {
    mkNights(h, night(2), night(26));
    fs.mkdirSync(path.join(h, "backups", name(NOW - 1 * H) + ".partial"));
    fs.writeFileSync(path.join(h, "backups", ".host-pull-ok"), stamp(1));
  });
  assert.equal(r.code, 0);
  assert.equal(r.out, "backup ok: newest nightly 2h old, host pull 1h old\n");
});

test("CLI: only directories count as nightlies", () => {
  const r = cli((h) => {
    fs.mkdirSync(path.join(h, "backups"));
    fs.writeFileSync(path.join(h, "backups", night(2)), "a file, not a backup");
    fs.writeFileSync(path.join(h, "backups", ".host-pull-ok"), stamp(1));
  });
  assert.equal(r.code, 1);
  assert.match(r.out, /^BACKUP ALERT: .*no nightly backup/);
});

test("CLI: an alarm exits 1 with one BACKUP ALERT line", () => {
  const r = cli((h) => mkNights(h, night(40)));
  assert.equal(r.code, 1);
  assert.match(r.out, /^BACKUP ALERT: .*40h old.*host pull stamp is missing.*\n$/);
  assert.equal(r.out.trim().split("\n").length, 1);
});

test("CLI: no backups directory at all is an alarm, not a crash", () => {
  const r = cli(() => {});
  assert.equal(r.code, 1);
  assert.match(r.out, /^BACKUP ALERT: .*no nightly backup/);
});

test("CLI: an unreadable ~/backups exits 2 with a message", () => {
  const r = cli((h) => fs.writeFileSync(path.join(h, "backups"), "not a directory"));
  assert.equal(r.code, 2);
  assert.match(r.err, /backup-health: cannot read \S*backups: /);
  assert.equal(r.out, "");
});

test("CLI: an unreadable stamp exits 2 with a message", () => {
  const r = cli((h) => {
    mkNights(h, night(2));
    fs.mkdirSync(path.join(h, "backups", ".host-pull-ok"));
  });
  assert.equal(r.code, 2);
  assert.match(r.err, /backup-health: cannot read .*host-pull-ok/);
});
