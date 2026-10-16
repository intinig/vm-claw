#!/usr/bin/env node
// Rewrite the archive's home (e.g. /Users/admin) to the importing account's home in the structured configuration a
// restore carries over: docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md §2 step 4. JSON files are
// rewritten structurally, keys and string values alike; a few non-JSON config files are rewritten as text. Only the
// home itself is replaced: a path that merely starts with the same letters (/Users/administrator, /Users/admin.bak,
// /x/Users/admin) is left alone. Transcripts (*.jsonl) and databases are never touched (migrate/state-paths.py moves
// the path-keyed SQLite state). Addendum 2026-10-05: Codex's project trust, the Workshop skills, the workspace scripts
// and the memory project annotations move too.
// migrate/scan-refs.mjs --old-home then fails on anything still left in live configuration.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

// Relative to the home. Directories are walked for *.json; node_modules, .git and vault are skipped. Every
// .openclaw/workspace*/skills directory is added at run time.
export const JSON_ROOTS = [".openclaw/openclaw.json", ".openclaw/cron", ".openclaw/skills", "ops", "brain"];
export const TEXT_FILES = [".openclaw/bin/op-nosym", ".openclaw/.env", ".openclaw/gateway.systemd.env", ".ssh/config", "brain/vault/.git/config"];
// Also rewritten as text, where they exist (the same shell globs name them in migrate/lib/home-roots.sh):
// .openclaw/agents/*/agent/codex-home/config.toml (Codex keys project trust by absolute cwd),
// .openclaw/agents/*/agent/workshop-skills/*/SKILL.md, and the scripts directly in .openclaw/workspace*/ and
// .openclaw/workspace*/scripts/ with these extensions. Hidden names are not matched, as by the shell.
export const SCRIPT_EXTS = ["py", "mjs", "js", "sh"];
const SKIP_DIRS = new Set(["node_modules", ".git", "vault"]);

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// The home as a whole path: at the start, after a character that cannot be part of a path (space, quote, =, :,
// comma, brackets, a newline), or right after file://; and followed by /, the end, or such a character.
const homeRe = (from) => new RegExp(`(^|[^\\w.~/-]|file://)${esc(from)}(?=/|$|[^\\w.-])`, "g");

export function rehomeString(s, from, to) {
  let count = 0;
  const text = s.replace(homeRe(from), (_m, pre) => { count++; return pre + to; });
  return { text, count };
}

export function rehomeJson(value, from, to) {
  let count = 0;
  const walk = (v) => {
    if (typeof v === "string") { const r = rehomeString(v, from, to); count += r.count; return r.text; }
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") {
      const out = {};
      for (const [k, x] of Object.entries(v)) {
        const rk = rehomeString(k, from, to);
        count += rk.count;
        // defineProperty, not assignment: a "__proto__" key must stay an own key, not set the prototype.
        if (Object.hasOwn(out, rk.text)) throw new Error(`two keys collide after rewriting: ${rk.text}`);
        Object.defineProperty(out, rk.text, { value: walk(x), enumerable: true, writable: true, configurable: true });
      }
      return out;
    }
    return v;
  };
  return { value: walk(value), count };
}

// Both absolute, different, and neither inside the other (a rewrite into a subdirectory of the old home would match
// its own output on a second run).
// One definition of a usable home, shared with scan-refs.mjs: absolute, no trailing slash, no "..", no "//".
export const validHome = (p) => typeof p === "string" && /^\/[^\0]*[^/]$/.test(p) && !p.includes("//") && !p.split("/").includes("..");
export function validHomes(from, to) {
  return validHome(from) && validHome(to) && from !== to && !to.startsWith(from + "/") && !from.startsWith(to + "/");
}

export function liveRoots(home) {
  let ws = [];
  try { ws = fs.readdirSync(path.join(home, ".openclaw")).filter((n) => n.startsWith("workspace")).map((n) => `.openclaw/${n}/skills`); } catch { /* no state dir */ }
  return { json: [...JSON_ROOTS, ...ws].map((r) => path.join(home, r)), text: [...TEXT_FILES.map((r) => path.join(home, r)), ...addendumTextFiles(home)] };
}

const names = (dir) => { try { return fs.readdirSync(dir).filter((n) => !n.startsWith(".")).sort(); } catch { return []; } };
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
// The .openclaw/workspace* directories (a symlinked one is followed, as the shell glob does).
const workspaceDirs = (home) => names(path.join(home, ".openclaw")).filter((n) => n.startsWith("workspace"))
  .map((n) => path.join(home, ".openclaw", n)).filter(isDir);

function addendumTextFiles(home) {
  const agents = path.join(home, ".openclaw", "agents");
  const out = names(agents).map((a) => path.join(agents, a, "agent", "codex-home", "config.toml"));
  for (const a of names(agents)) {
    const ws = path.join(agents, a, "agent", "workshop-skills");
    for (const s of names(ws)) out.push(path.join(ws, s, "SKILL.md"));
  }
  const script = (n) => SCRIPT_EXTS.some((x) => n.endsWith(`.${x}`));
  for (const w of workspaceDirs(home)) {
    for (const d of [w, path.join(w, "scripts")]) for (const n of names(d)) if (script(n)) out.push(path.join(d, n));
  }
  return out;
}

// Memory project annotations are absolute by design (the project key is `path:<repo root>`): the old home's form, and
// the `~/` form home-relative-fix.sh once wrote (a project key never expands it), both become the new home's. Nothing
// else in a note changes.
const annotationForms = (from) => [`<!-- project: path:${from}/`, "<!-- project: path:~/"];
export function rehomeAnnotations(s, from, to) {
  let count = 0, text = s;
  for (const form of annotationForms(from)) {
    const parts = text.split(form);
    count += parts.length - 1;
    text = parts.join(`<!-- project: path:${to}/`);
  }
  return { text, count };
}

// The notes that carry them: every *.md under each .openclaw/workspace* (hidden names are not matched, as by the shell's
// **; node_modules, .git and vault are skipped). A symlinked directory throws, as in walk(); a symlinked file is yielded
// with link: true (the rewrite leaves it, the zero-count check reads through it).
function* markdownFiles(dir) {
  for (const e of fs.readdirSync(dir).sort()) {   // an unreadable directory throws: never skipped silently
    if (e.startsWith(".") || SKIP_DIRS.has(e)) continue;
    const p = path.join(dir, e);
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink()) {
      let t = null;
      try { t = fs.statSync(p); } catch { /* dangling */ }
      if (t?.isDirectory()) throw new FailClosed(`${p} is a symlinked directory; resolve or allow it explicitly`);
      if (t?.isFile() && e.endsWith(".md")) yield { file: p, link: true };
    } else if (st.isDirectory()) yield* markdownFiles(p);
    else if (st.isFile() && e.endsWith(".md")) yield { file: p, link: false };
  }
}

const TEXT_EXT = /\.(yaml|yml|toml|conf|env)$/;

// Yields { file, kind: "json" | "text" } for what the rewrite handles. A symlinked directory is never followed and
// never skipped silently: it throws, so the import stops and the operator resolves it. (Symlinks to files are skipped.)
function* walk(p, top = true) {
  let st;
  try { st = fs.lstatSync(p); } catch (e) { if (e.code === "ENOENT") return; throw e; }
  if (st.isSymbolicLink()) {
    let t = null;
    try { t = fs.statSync(p); } catch { /* dangling */ }
    if (t?.isDirectory()) throw new FailClosed(`${p} is a symlinked directory; resolve or allow it explicitly`);
    return;
  }
  if (st.isFile()) {
    if (p.endsWith(".json")) yield { file: p, kind: "json" };
    else if (TEXT_EXT.test(p)) yield { file: p, kind: "text" };
    return;
  }
  if (!st.isDirectory()) return;
  for (const e of fs.readdirSync(p).sort()) if (!SKIP_DIRS.has(e)) yield* walk(path.join(p, e), false);
}

class FailClosed extends Error {}

// Write next to the target, give it the target's mode, rename over: a crash never leaves a half-written config.
function writeAtomic(f, body) {
  const mode = fs.statSync(f).mode & 0o777;
  const tmp = path.join(path.dirname(f), `.${path.basename(f)}.homepaths-${process.pid}`);
  try {
    fs.writeFileSync(tmp, body, { mode });
    fs.chmodSync(tmp, mode);
    fs.renameSync(tmp, f);
  } catch (e) {
    try { fs.rmSync(tmp, { force: true }); } catch { /* best effort */ }
    throw e;
  }
}

// Read-only, for rehome.sh prepare: the walk of the memory notes the rewrite does, over a home's live workspaces. What it
// would refuse mid-downtime (a symlinked directory, a directory it cannot read) it refuses here, before the downtime.
function checkNotes(home) {
  const ws = workspaceDirs(home);
  const notes = ws.flatMap((w) => [...markdownFiles(w)]);
  console.log(`homepaths: ${notes.length} memory note(s) in ${ws.length} workspace(s), no symlinked directory`);
}

// Note: the leftover scan is deliberately broader than this rewrite: a name like /Users/admin.bak is left alone here
// and flagged there (fail closed).
function main() {
  const args = process.argv.slice(2);
  if (args[0] === "--check-notes") {
    if (args.length !== 2 || !validHome(args[1])) {
      console.error("usage: homepaths.mjs --check-notes <home>   (an absolute home; reads its workspaces, writes nothing)");
      process.exit(2);
    }
    return checkNotes(args[1]);
  }
  const [from, to] = args;
  if (!validHomes(from, to)) {
    console.error("usage: homepaths.mjs <old-home> <new-home>   (two different absolute homes, neither inside the other)");
    process.exit(2);
  }
  const { json, text } = liveRoots(to);
  let files = 0;
  const seen = new Set();
  for (const root of json) {
    for (const { file: f, kind } of walk(root)) {
      if (seen.has(f)) continue;
      seen.add(f);
      let src;
      try { src = fs.readFileSync(f, "utf8"); } catch (e) { throw new Error(`${f}: cannot read (${e.code ?? e.message})`); }
      let out, count;
      if (kind === "json") {
        let cfg;
        try { cfg = JSON.parse(src); } catch { console.log(`homepaths: ${f}: not valid JSON, left for the scan`); continue; }
        const r = rehomeJson(cfg, from, to);
        count = r.count;
        out = JSON.stringify(r.value, null, 2) + "\n";
      } else {
        const r = rehomeString(src, from, to);
        count = r.count;
        out = r.text;
      }
      if (!count) continue;
      writeAtomic(f, out);
      files++;
      console.log(`homepaths: ${f}: ${count} path(s)`);
    }
  }
  for (const f of text) {
    let st;
    try { st = fs.lstatSync(f); } catch { continue; }
    if (!st.isFile()) continue;
    const { text: out, count } = rehomeString(fs.readFileSync(f, "utf8"), from, to);
    if (!count) continue;
    writeAtomic(f, out);
    files++;
    console.log(`homepaths: ${f}: ${count} path(s)`);
  }
  const notes = workspaceDirs(to).flatMap((w) => [...markdownFiles(w)]);
  for (const { file: f, link } of notes) {
    if (link) continue;
    const { text: out, count } = rehomeAnnotations(fs.readFileSync(f, "utf8"), from, to);
    if (!count) continue;
    writeAtomic(f, out);
    files++;
    console.log(`homepaths: ${f}: ${count} project annotation(s)`);
  }
  // Neither old form is left in any note, a symlinked note's target included: fail closed otherwise.
  const left = notes.map(({ file: f }) => [f, rehomeAnnotations(fs.readFileSync(f, "utf8"), from, to).count]).filter(([, n]) => n);
  for (const [f, n] of left) console.log(`homepaths: ${f}: ${n} old project annotation(s) left`);
  if (left.length) throw new FailClosed(`${left.length} file(s) still carry old project annotations (see above)`);
  console.log(`homepaths: ${files} file(s) rewritten from ${from} to ${to}`);
}

const isMain = Boolean(process.argv[1]) && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href;
if (isMain) {
  try { main(); } catch (e) { console.error(`homepaths: error: ${e.message}`); process.exit(3); }
}
