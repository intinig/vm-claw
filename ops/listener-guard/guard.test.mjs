import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "./guard.mjs";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const T = (iso) => Date.parse(iso);
const line = (iso, msg) => JSON.stringify({ 1: msg, _meta: { date: iso } });
const base = [
  line("2026-09-30T08:00:00Z", "gateway ready"),
  line("2026-09-30T08:00:05Z", "Listening for WhatsApp inbound messages (DM + all groups)"),
];
const stranded = [
  line("2026-09-30T09:00:30Z", "Gateway client authority closed before dispatching cron.list"),
  line("2026-09-30T09:00:32Z", "The reply channel changed or cannot preserve its sender; delivery was not started."),
];

test("restarts on two signature events well after startup", () => {
  const r = decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:02:00Z"), linked: true, restarts: [] });
  assert.equal(r.action, "restart");
  assert.equal(r.events, 2);
});

test("ignores startup noise inside the gateway-ready grace window", () => {
  const noise = [line("2026-09-30T08:02:00Z", "No active WhatsApp Web listener (account: default)"),
                 line("2026-09-30T08:02:30Z", "No active WhatsApp Web listener (account: default)")];
  assert.equal(decide({ lines: [...base, ...noise], now: T("2026-09-30T08:03:00Z"), linked: true, restarts: [] }).action, "ok");
});

test("one event is not enough", () => {
  assert.equal(decide({ lines: [...base, stranded[0]], now: T("2026-09-30T09:02:00Z"), linked: true, restarts: [] }).action, "ok");
});

test("skips when WhatsApp is not linked — a restart cannot help", () => {
  assert.equal(decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:02:00Z"), linked: false, restarts: [] }).action, "skip");
});

test("respects the 30-minute cooldown", () => {
  const r = decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:02:00Z"), linked: true, restarts: [T("2026-09-30T08:45:00Z")] });
  assert.equal(r.action, "skip");
  assert.match(r.reason, /cooldown/);
});

test("gives up after 6 restarts in 24h", () => {
  const six = [1, 2, 3, 4, 5, 6].map((h) => T("2026-09-30T00:00:00Z") + h * 3600e3 - 3600e3 * 0.5);
  const r = decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:02:00Z"), linked: true, restarts: six });
  assert.equal(r.action, "skip");
  assert.match(r.reason, /6 restarts/);
});

test("ignores lines from the future when replaying history", () => {
  assert.equal(decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:00:31Z"), linked: true, restarts: [] }).action, "ok");
});

// ---- Fix round 1: pin every spec rule and constant. Each test below exists to kill a
// specific mutation of guard.mjs (see the fix report's mutation table).
const MIN = 60e3;
const HOUR = 3600e3;
const NOW = T("2026-09-30T09:02:00Z");
const two = (msg, a = "2026-09-30T09:00:30Z", b = "2026-09-30T09:00:32Z") => [line(a, msg), line(b, msg)];
const relistening = line("2026-09-30T09:00:00Z", "Listening for WhatsApp inbound messages (DM + all groups)");

test("events older than the 10-minute window do not count", () => {
  const r = decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:11:40Z"), linked: true, restarts: [] });
  assert.equal(r.action, "ok");
  assert.equal(r.events, 0);
});

test("ready grace applies on its own: events 2-3 min after gateway ready are ignored", () => {
  const ready = [line("2026-09-30T08:00:00Z", "gateway ready")];
  const noise = two("No active WhatsApp Web listener (account: default)", "2026-09-30T08:02:00Z", "2026-09-30T08:02:30Z");
  assert.equal(decide({ lines: [...ready, ...noise], now: T("2026-09-30T08:03:00Z"), linked: true, restarts: [] }).action, "ok");
});

test("events just after the 5-minute ready grace count", () => {
  const ready = [line("2026-09-30T08:00:00Z", "gateway ready")];
  const events = two("No active WhatsApp Web listener (account: default)", "2026-09-30T08:05:10Z", "2026-09-30T08:05:20Z");
  assert.equal(decide({ lines: [...ready, ...events], now: T("2026-09-30T08:06:00Z"), linked: true, restarts: [] }).action, "restart");
});

test("a mid-run reconnect marker silences events for 2 minutes", () => {
  const events = two("No active WhatsApp Web listener (account: default)", "2026-09-30T09:01:00Z", "2026-09-30T09:01:10Z");
  const r = decide({ lines: [...base, relistening, ...events], now: T("2026-09-30T09:01:30Z"), linked: true, restarts: [] });
  assert.equal(r.action, "ok");
  assert.equal(r.events, 0);
});

test("the same events 3 minutes after the reconnect marker count", () => {
  const events = two("No active WhatsApp Web listener (account: default)", "2026-09-30T09:03:00Z", "2026-09-30T09:03:10Z");
  const r = decide({ lines: [...base, relistening, ...events], now: T("2026-09-30T09:03:30Z"), linked: true, restarts: [] });
  assert.equal(r.action, "restart");
  assert.equal(r.events, 2);
});

for (const [name, msg] of [
  ["reply channel changed", "The reply channel changed or cannot preserve its sender; delivery was not started."],
  ["no active listener", "No active WhatsApp Web listener (account: default)"],
  ["gateway client authority closed", "Gateway client authority closed before dispatching cron.list"],
]) {
  test(`signature alone triggers a restart: ${name}`, () => {
    const r = decide({ lines: [...base, ...two(msg)], now: NOW, linked: true, restarts: [] });
    assert.equal(r.action, "restart");
    assert.equal(r.events, 2);
  });
}

test("unrelated log lines never count as events", () => {
  const r = decide({ lines: [...base, ...two("message received from a contact")], now: NOW, linked: true, restarts: [] });
  assert.equal(r.action, "ok");
  assert.equal(r.events, 0);
});

test("a restart 31 minutes ago is outside the cooldown", () => {
  const r = decide({ lines: [...base, ...stranded], now: NOW, linked: true, restarts: [NOW - 31 * MIN] });
  assert.equal(r.action, "restart");
});

test("a restart 29 minutes ago is still inside the cooldown", () => {
  const r = decide({ lines: [...base, ...stranded], now: NOW, linked: true, restarts: [NOW - 29 * MIN] });
  assert.equal(r.action, "skip");
  assert.match(r.reason, /cooldown/);
});

test("five restarts in 24h do not reach the cap of six", () => {
  const five = [5, 4, 3, 2, 1].map((h) => NOW - h * HOUR);
  assert.equal(decide({ lines: [...base, ...stranded], now: NOW, linked: true, restarts: five }).action, "restart");
});

test("a restart older than 24h is pruned and does not count toward the cap", () => {
  const restarts = [NOW - 25 * HOUR, ...[5, 4, 3, 2, 1].map((h) => NOW - h * HOUR)];
  assert.equal(decide({ lines: [...base, ...stranded], now: NOW, linked: true, restarts }).action, "restart");
});

test("not linked is reported ahead of an active cooldown", () => {
  const r = decide({ lines: [...base, ...stranded], now: NOW, linked: false, restarts: [NOW - 15 * MIN] });
  assert.equal(r.action, "skip");
  assert.match(r.reason, /not linked/);
});

test("not linked is reported ahead of the daily cap", () => {
  const six = [6, 5, 4, 3, 2, 1].map((h) => NOW - h * HOUR);
  const r = decide({ lines: [...base, ...stranded], now: NOW, linked: false, restarts: six });
  assert.equal(r.action, "skip");
  assert.match(r.reason, /not linked/);
});

test("unknown WhatsApp status (linked: null) skips instead of restarting blind", () => {
  const r = decide({ lines: [...base, ...stranded], now: NOW, linked: null, restarts: [] });
  assert.equal(r.action, "skip");
  assert.match(r.reason, /status unknown/);
  assert.equal(r.events, 2);
});

test("unknown WhatsApp status below the event threshold is still ok", () => {
  const r = decide({ lines: [...base, stranded[0]], now: NOW, linked: null, restarts: [] });
  assert.equal(r.action, "ok");
});

test("the committed stranded-listener fixture decides restart at its replay time, on its two stranded events", () => {
  const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "stranded-listener");
  const lines = fs.readdirSync(dir).flatMap((f) => fs.readFileSync(path.join(dir, f), "utf8").split("\n"));
  assert.deepEqual(decide({ lines, now: Date.parse("2026-09-30T09:02:00Z"), linked: true, restarts: [] }),
    { action: "restart", reason: "stranded listener", events: 2 });
});
