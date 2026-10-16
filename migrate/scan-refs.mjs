#!/usr/bin/env node
// Scan free text (prompts, skills, notes, scripts) for things that break on Linux:
// Homebrew binary paths without a compat link, and macOS-only commands.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { DEFAULT_MAP } from "./binpaths.mjs";
import { validHome } from "./homepaths.mjs";

// Only names that are not also everyday words: "defaults", "security", "memo" would
// flag ordinary prose in prompts and fail the import for nothing.
const MACOS_ONLY = ["launchctl", "osascript", "pbcopy", "pbpaste", "scutil", "imsg"];

export function scan(text, allow) {
  const lines = text.split("\n").filter((l) => !allow.some((re) => re.test(l)));
  const body = lines.join("\n");
  const brewMatches = body.match(/\/opt\/homebrew\/[\w@./-]*bin\/[\w.-]+/g) ?? [];
  const homebrew = [...new Set(brewMatches.map((m) => m.replace(/[.-]+$/, "")))];
  const macos = MACOS_ONLY.filter((c) => new RegExp(`(?<![\\w-])${c}(?![\\w-])`, "m").test(body));
  return { homebrew, macos };
}

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// --old-home: how often a file still names the archive's home. Counted on the raw text and broader than
// homepaths.mjs on purpose (any occurrence not followed by a name character: /Users/admin. and file:///Users/admin
// count), so whatever the rewrite leaves alone fails closed. Allow-listed lines (SCAN_ALLOW) are skipped.
export function homeRefs(text, oldHome, allow = []) {
  const body = text.split("\n").filter((l) => !allow.some((re) => re.test(l))).join("\n");
  return (body.match(new RegExp(`${esc(oldHome)}(?![\\w-])`, "g")) ?? []).length;
}

function* files(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!["node_modules", ".git", "vault"].includes(e.name)) yield* files(p); }
    else if (/\.(md|mjs|js|sh|json|txt)$/.test(e.name)) yield p;
  }
}

class Coverage extends Error {}
const SKIP = new Set(["node_modules", ".git", "vault"]);
const isText = (f) => {
  const fd = fs.openSync(f, "r");
  try { const b = Buffer.alloc(8192); return !b.subarray(0, fs.readSync(fd, b, 0, 8192, 0)).includes(0); } finally { fs.closeSync(fd); }
};

// The leftover scan reads every regular file under the roots (any name), except transcripts (*.jsonl), the skipped
// directories and binary files (a NUL in the first 8 KiB). A symlinked directory fails closed. Prints paths and
// counts only, never file content.
function* scanFiles(p, explicit) {
  const ls = fs.lstatSync(p);
  const isLink = ls.isSymbolicLink();
  const st = isLink ? fs.statSync(p) : ls;
  if (st.isDirectory()) {
    if (isLink) throw new Coverage(`${p} is a symlinked directory; resolve or allow it explicitly`);
    for (const e of fs.readdirSync(p).sort()) if (!SKIP.has(e)) yield* scanFiles(path.join(p, e), false);
  } else if (st.isFile() && (explicit || !p.endsWith(".jsonl"))) yield p;
}

// Exit code: 0 clean, 1 leftovers; throws Coverage (4) for a missing root, symlinked dir, or nothing scanned.
function scanHome(old, roots, allow) {
  let bad = 0, scanned = 0;
  for (const p of roots) {
    try { fs.lstatSync(p); } catch (e) { throw e.code === "ENOENT" ? new Coverage(`${p}: does not exist`) : e; }
    for (const f of scanFiles(p, true)) {
      if (!isText(f)) continue;
      scanned++;
      const n = homeRefs(fs.readFileSync(f, "utf8"), old, allow);
      if (n) { bad++; console.log(`${f}: ${n} reference(s) to ${old}`); }
    }
  }
  if (!scanned) throw new Coverage("nothing scanned");
  console.log(`scan-refs: ${bad} file(s) still name ${old}`);
  return bad ? 1 : 0;
}

const isMain = Boolean(process.argv[1]) && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href;
if (isMain) {
  const allowFile = process.env.SCAN_ALLOW ?? "";
  const allow = allowFile && fs.existsSync(allowFile)
    ? fs.readFileSync(allowFile, "utf8").split("\n").filter(Boolean).map((l) => new RegExp(l)) : [];
  const args = process.argv.slice(2);
  if (args[0] === "--old-home") {
    const old = args[1];
    if (!validHome(old)) { console.error("usage: scan-refs.mjs --old-home <absolute-path> <file|dir>...   (no trailing slash, no .. or //)"); process.exit(2); }
    try { process.exit(scanHome(old, args.slice(2), allow)); }
    catch (e) {
      console.error(`scan-refs: ${e.message}`);
      process.exit(e instanceof Coverage ? 4 : 3);
    }
  }
  let bad = 0;
  for (const dir of process.argv.slice(2)) {
    if (!fs.existsSync(dir)) continue;
    for (const f of files(dir)) {
      const { homebrew, macos } = scan(fs.readFileSync(f, "utf8"), allow);
      const unmapped = homebrew.filter((h) => !DEFAULT_MAP[h] && !fs.existsSync(h));
      if (unmapped.length || macos.length) { bad++; console.log(`${f}: homebrew=${unmapped.join(",")} macos=${macos.join(",")}`); }
    }
  }
  console.log(`scan-refs: ${bad} file(s) need attention`);
  process.exit(bad ? 1 : 0);
}
