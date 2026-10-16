#!/usr/bin/env node
// Rewrite Homebrew binary paths in OpenClaw's structured config to their Debian
// locations. Home paths are deliberately untouched: the guest keeps /Users/admin.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export const DEFAULT_MAP = {
  "/opt/homebrew/bin/op": "/usr/bin/op",
  "/opt/homebrew/bin/node": "/usr/bin/node",
  "/opt/homebrew/opt/node@24/bin/node": "/usr/bin/node",
  "/opt/homebrew/bin/wacli": "/usr/local/bin/wacli",
  "/opt/homebrew/bin/sag": "/usr/local/bin/sag",
  "/opt/homebrew/bin/openclaw": "/usr/bin/openclaw",
};

export function rewriteOpenclawConfig(cfg, map) {
  const changes = [];
  for (const [name, p] of Object.entries(cfg?.secrets?.providers ?? {})) {
    if (p?.source !== "exec") continue;
    if (map[p.command]) { changes.push(`secrets.providers.${name}.command: ${p.command} -> ${map[p.command]}`); p.command = map[p.command]; }
    if (Array.isArray(p.trustedDirs)) {
      p.trustedDirs = p.trustedDirs.map((d) => {
        if (d !== "/opt/homebrew") return d;
        changes.push(`secrets.providers.${name}.trustedDirs: /opt/homebrew -> /usr/bin`);
        return "/usr/bin";
      });
    }
  }
  return { cfg, changes };
}

export function rewriteHarvesterConfig(cfg, map) {
  const changes = [];
  if (map[cfg.wacliBin]) { changes.push(`wacliBin: ${cfg.wacliBin} -> ${map[cfg.wacliBin]}`); cfg.wacliBin = map[cfg.wacliBin]; }
  return { cfg, changes };
}

export function rewriteShellWrapper(text, map) {
  const changes = [];
  let out = text;
  for (const [from, to] of Object.entries(map)) {
    if (out.includes(from)) { out = out.split(from).join(to); changes.push(`${from} -> ${to}`); }
  }
  return { text: out, changes };
}

export function rewriteArgv(argv, map) {
  if (!map[argv[0]]) return { argv, changed: false };
  return { argv: [map[argv[0]], ...argv.slice(1)], changed: true };
}

function rewriteJsonFile(file, fn) {
  if (!fs.existsSync(file)) return [];
  const { cfg, changes } = fn(JSON.parse(fs.readFileSync(file, "utf8")), DEFAULT_MAP);
  if (changes.length) {
    fs.copyFileSync(file, `${file}.pre-binpaths`);
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
  }
  return changes.map((c) => `${path.basename(file)}: ${c}`);
}

const isMain = Boolean(process.argv[1]) && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href;
if (isMain) {
  const home = process.argv[2] ?? process.env.HOME;
  const out = [
    ...rewriteJsonFile(`${home}/.openclaw/openclaw.json`, rewriteOpenclawConfig),
    ...rewriteJsonFile(`${home}/brain/harvester/config.json`, rewriteHarvesterConfig),
  ];
  const wrapper = `${home}/.openclaw/bin/op-nosym`;
  if (fs.existsSync(wrapper)) {
    const { text, changes } = rewriteShellWrapper(fs.readFileSync(wrapper, "utf8"), DEFAULT_MAP);
    if (changes.length) { fs.copyFileSync(wrapper, `${wrapper}.pre-binpaths`); fs.writeFileSync(wrapper, text); }
    out.push(...changes.map((c) => `op-nosym: ${c}`));
  }
  for (const line of out) console.log(line);
  console.log(`binpaths: ${out.length} change(s)`);
}
