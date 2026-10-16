#!/usr/bin/env node
// Restarts the OpenClaw gateway when its WhatsApp listener is "stranded": the socket
// keeps receiving but replies/tools fail (OpenClaw 2026.9.x, after a config hot reload
// or a watchdog reconnect). Only a full gateway restart rebinds it.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, execSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const WINDOW_MS = 10 * 60e3;
const GRACE_READY_MS = 5 * 60e3;
const GRACE_LISTEN_MS = 2 * 60e3;
const MIN_EVENTS = 2;
const COOLDOWN_MS = 30 * 60e3;
const MAX_PER_DAY = 6;
const SIGNATURES = [
  "reply channel changed or cannot preserve its sender",
  "No active WhatsApp Web listener",
  "Gateway client authority closed before dispatching",
];

export function decide({ lines, now, linked, restarts }) {
  let ready = 0, listen = 0;
  const events = [];
  for (const l of lines) {
    const sig = SIGNATURES.find((s) => l.includes(s));
    const isReady = l.includes('"gateway ready"');
    const isListen = l.includes("Listening for WhatsApp inbound messages");
    if (!sig && !isReady && !isListen) continue;
    let ts;
    try { ts = Date.parse(JSON.parse(l)._meta.date); } catch { continue; }
    if (!Number.isFinite(ts) || ts > now) continue;
    if (isReady) ready = Math.max(ready, ts);
    if (isListen) listen = Math.max(listen, ts);
    if (sig) events.push(ts);
  }
  const floor = Math.max(now - WINDOW_MS, ready + GRACE_READY_MS, listen + GRACE_LISTEN_MS);
  const n = events.filter((t) => t >= floor).length;
  if (n < MIN_EVENTS) return { action: "ok", reason: `${n} event(s) in window`, events: n };
  // linked: true | false | null. null = `openclaw channels status` failed or hung, so we
  // cannot tell whether a restart would help: never restart blind.
  if (linked === null) return { action: "skip", reason: "WhatsApp status unknown", events: n };
  if (!linked) return { action: "skip", reason: "WhatsApp not linked", events: n };
  const day = restarts.filter((t) => now - t < 24 * 3600e3);
  if (day.length && now - day.at(-1) < COOLDOWN_MS) return { action: "skip", reason: "cooldown", events: n };
  if (day.length >= MAX_PER_DAY) return { action: "skip", reason: `${day.length} restarts in 24h`, events: n };
  return { action: "restart", reason: "stranded listener", events: n };
}

function readLines(dir) {
  return fs.readdirSync(dir).filter((f) => /^openclaw-\d{4}-\d{2}-\d{2}\.log$/.test(f)).sort().slice(-2)
    .flatMap((f) => fs.readFileSync(path.join(dir, f), "utf8").split("\n"));
}

const isMain = Boolean(process.argv[1]) && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href;
if (isMain) {
  const args = process.argv.slice(2);
  const dry = args.includes("--dry-run");
  // --now=<iso> would be silently ignored (the replay clock would become the real one): refuse it up front.
  if (args.some((a) => a.startsWith("--now="))) {
    console.error("guard: use --now <iso> (two arguments); --now=<iso> is not accepted");
    process.exit(2);
  }
  // --now replays recorded history. It never acts on it: a replay with --dry-run forgotten must not restart a live
  // gateway (final review, minor #41).
  if (args.includes("--now") && !dry) {
    console.error("guard: --now replays recorded history; it only runs with --dry-run (refusing to restart the gateway)");
    process.exit(2);
  }
  const now = args.includes("--now") ? Date.parse(args[args.indexOf("--now") + 1]) : Date.now();
  const stateFile = process.env.GUARD_STATE ?? path.join(os.homedir(), ".local/state/claw/listener-guard.json");
  const restartCmd = process.env.GUARD_RESTART ?? "systemctl --user restart openclaw-gateway.service";
  let state = { restarts: [] };
  try { state = JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch {}
  const lines = readLines(process.env.GUARD_LOG_DIR ?? "/tmp/openclaw");
  const status = () => execFileSync("openclaw", ["channels", "status"], { encoding: "utf8", timeout: 60e3 }).replace(/\x1b\[[0-9;]*m/g, "");
  const pre = decide({ lines, now, linked: true, restarts: state.restarts });
  if (pre.action === "ok") { if (dry) console.log(`ok: ${pre.reason}`); process.exit(0); }
  let r = pre;
  if (pre.action === "restart") {
    // Only ask the gateway when the answer can change the outcome (cooldown/cap skips don't need it).
    let linked = null;
    try {
      linked = /^- WhatsApp default:.*, linked,/m.test(status());
    } catch (e) {
      const why = e.code ?? (e.status != null ? `exit ${e.status}` : e.signal ?? e.message);
      console.error(`status check failed: ${why}`);
    }
    r = decide({ lines, now, linked, restarts: state.restarts });
  }
  const msg = `${new Date(now).toISOString()} ${r.action}: ${r.reason} (${r.events} events)`;
  console.log(dry ? `[dry-run] ${msg}` : msg);
  if (r.action !== "restart" || dry) process.exit(0);
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, JSON.stringify({ restarts: [...state.restarts.filter((t) => now - t < 24 * 3600e3), now] }));
  execSync(restartCmd, { stdio: "inherit" });
}
