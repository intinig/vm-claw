#!/usr/bin/env node
// Daily check, run inside the guest: is both halves of the backup chain alive? The guest's nightly
// (~/backups/claw-nightly-*Z) and the host's pull + restic job (host/pull-backups.sh writes
// ~/backups/.host-pull-ok into the guest only after a fully successful run).
// Prints one line. Exit 0 healthy, 1 alarm ("BACKUP ALERT: ..."), 2 internal error.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const HOUR = 3600e3;
const MAX_FUTURE_MS = HOUR;
const NAME_RE = /^claw-nightly-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;

// Exactly YYYY-MM-DDTHH:MM:SSZ: Date.parse also takes other forms and rolls Feb 31 over, so compare it back.
function isoTime(text) {
  const s = text.trim();
  const ts = Date.parse(s);
  return Number.isFinite(ts) && new Date(ts).toISOString() === s.replace("Z", ".000Z") ? ts : null;
}

function nightlyTime(n) {
  const m = NAME_RE.exec(n);
  return m ? isoTime(`${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z`) : null;
}

const hours = (ms) => Math.max(0, Math.floor(ms / HOUR));

export function assess({ now, nightlyNames, stampText, maxAgeHours = 30 }) {
  const limitMs = maxAgeHours * HOUR;
  const problems = [];
  let nightlyAge = null, stampAge = null;

  const times = nightlyNames.map(nightlyTime).filter((t) => t !== null);
  if (times.length === 0) {
    problems.push("no nightly backup in ~/backups (the guest's nightly timer has not produced one)");
  } else {
    const age = now - Math.max(...times);
    if (age > limitMs) problems.push(`newest nightly is ${hours(age)}h old (limit ${maxAgeHours}h): the guest's nightly timer has stopped`);
    else if (age < -MAX_FUTURE_MS) problems.push(`newest nightly is dated ${Math.floor(-age / 60e3)} min in the future (limit 60 min): check the guest's clock`);
    else nightlyAge = age;
  }

  if (stampText == null) {
    problems.push("host pull stamp is missing (the host's pull-backups job has never succeeded, or stopped writing it)");
  } else {
    const ts = isoTime(stampText);
    if (ts === null) {
      problems.push("host pull stamp is unreadable");
    } else {
      const age = now - ts;
      if (age < 0) problems.push("host pull stamp is in the future: check the clocks");
      else if (age > limitMs) problems.push(`host pull is ${hours(age)}h old (limit ${maxAgeHours}h): the host's pull-backups job has stopped succeeding`);
      else stampAge = age;
    }
  }

  if (problems.length) return { ok: false, line: `BACKUP ALERT: ${problems.join("; ")}` };
  return { ok: true, line: `backup ok: newest nightly ${hours(nightlyAge)}h old, host pull ${hours(stampAge)}h old` };
}

const isMain = Boolean(process.argv[1]) && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href;
if (isMain) {
  const fail = (msg) => { console.error(`backup-health: ${msg}`); process.exit(2); };
  const args = process.argv.slice(2);
  const now = args.includes("--now") ? Date.parse(args[args.indexOf("--now") + 1]) : Date.now();
  if (!Number.isFinite(now)) fail("--now needs a timestamp");
  const dir = path.join(os.homedir(), "backups");
  let nightlyNames = [];
  try {
    nightlyNames = fs.readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
  } catch (e) {
    // A missing directory means no backup was ever made: an alarm, not a fault of this check.
    if (e.code !== "ENOENT") fail(`cannot read ${dir}: ${e.code ?? e.message}`);
  }
  const stampFile = path.join(dir, ".host-pull-ok");
  let stampText = null;
  try {
    stampText = fs.readFileSync(stampFile, "utf8");
  } catch (e) {
    if (e.code !== "ENOENT") fail(`cannot read ${stampFile}: ${e.code ?? e.message}`);
  }
  const r = assess({ now, nightlyNames, stampText });
  console.log(r.line);
  process.exit(r.ok ? 0 : 1);
}
