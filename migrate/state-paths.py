#!/usr/bin/env python3
"""One-time move of OpenClaw 2026.9.7's path-keyed SQLite state from another home to this one, and its post-start check.

OpenClaw 2026.9.7 keys parts of its SQLite state by absolute path: the cron store, workspace identity, memory and plugin
state, Skill Workshop targets, the exec-approvals socket and Codex's thread index. After a cross-home import
(/Users/admin -> /home/sebastian) the new gateway would see none of it. Upstream has no relocation, so migrate/import.sh
runs this right after the restored state lands and before any `openclaw` command opens it (spec 2026-10-02, addendum
2026-10-05). History (transcripts, run text, diagnostics, caches) stays as it is.

The semantics (which column, how 2026.9.7 uses it, how each derived value is computed) are the research in
.superpowers/sdd/2026-10-02-bot-user-sebastian/state-path-classification.md; "#n" and "Dn" below are its table rows
and derived values, "§8" its recipe.

  migrate --old OLD --new NEW [--state DIR]
      Pinned to OpenClaw 2026.9.7, state schema 19 and Codex migration 57. Refuses state the new home already owns.
      Rewrites and recomputes in one transaction per database, then runs the fail-closed post-check (old-home text
      only in the history allow-list, unchanged row counts, integrity_check, foreign_key_check) before anything is
      committed. Writes DIR/rehome-state-paths.json for the check. DIR (default NEW/.openclaw) is where the databases
      are; the identity checks always look at NEW/.openclaw.
  check --home HOME --cron-total N [--state DIR]
      The post-start checks (§8.5), read-only: the automation count admin's gateway listed (N), no duplicate cron
      declarations, workspace rows and aliases and the exec-approvals socket under HOME only, no plugin-state key under
      an old workspace hash, Workshop proposal statuses unchanged, and the same history allow-list.
  preflight --home OLD
      Before anything is stopped (rehome.sh prepare, as the old home's account): python 3.9+ with sqlite3, the version
      pin as migrate reads it, and a dry run of migrate on copies of OLD's live databases (opened mode=ro, copied with
      the backup API) laid out under a scratch new home in a private $TMPDIR dir, removed on exit. Read-only on OLD.

Exit 0 on success, 1 on a refusal or a failed check (a refused migrate commits nothing), 2 on a usage error, 3 when
migrate committed part of its work and then failed (the state is inconsistent: import a fresh copy). Prints
table.column names, counts and paths relative to the new home: never a row value. Python 3.9+, standard library only.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import signal
import sys
import tempfile
import time
from urllib.request import pathname2url
try:
    import sqlite3
except ImportError:   # preflight says so; nothing else can run without it
    sqlite3 = None

PIN_OPENCLAW = "2026.9.7"
PIN_STATE_SCHEMA = 19
PIN_CODEX_MIGRATION = 57
MIN_PYTHON = (3, 9)
OPENCLAW_PACKAGE = "/usr/lib/node_modules/openclaw/package.json"   # read, not `openclaw --version`: no CLI may touch the state
RECORD = "rehome-state-paths.json"
STATE_DB = "state/openclaw.sqlite"
TRANSIENT_LEASE_TABLES = ("agent_database_leases", "state_leases")   # a running gateway's; empty in a backup
CRON_KEY_TABLES = ("cron_jobs", "cron_run_receipts", "cron_job_scratch")                                 # #1-#3
PLAIN_PATH_COLUMNS = (("session_watch_cursors", "watcher_store_path"), ("skill_usage", "skill_file"),   # #9, #10, #12
                      ("skill_workshop_proposal_rollbacks", "target_skill_file"))
# The columns that may keep naming the old home (§1 HISTORY-KEEP). Inside the JSON ones the functional fields are still
# checked (state_leftovers). Any other table or column that names the old home fails: one a later OpenClaw adds too.
STATE_HISTORY = frozenset([
    ("cron_jobs", "state_json"), ("task_runs", "detail_json"), ("task_runs", "terminal_summary"),
    ("skill_workshop_proposals", "record_json"), ("skill_workshop_proposal_rollbacks", "previous_content"),
    ("skill_workshop_proposal_events", "payload_json"), ("plugin_state_entries", "value_json"),
    ("plugin_state_entries", "entry_key"), ("plugin_blob_entries", "metadata_json"), ("config_machine_state", "value_json"),
    ("config_health_entries", "config_path"), ("backup_runs", "archive_path"), ("diagnostic_events", "payload_json"),
    ("migration_runs", "report_json"), ("migration_sources", "source_path"), ("migration_sources", "report_json"),
    ("subagent_runs", "payload_json")])
CODEX_HISTORY = frozenset([("threads", "title"), ("threads", "first_user_message"), ("threads", "preview")])   # #51


class Refuse(Exception):
    """A pin, precondition, rewrite expectation or post-check failed: nothing is committed."""


class Partial(Exception):
    """A COMMIT failed after an earlier database committed: the state is inconsistent."""


class Usage(Exception):
    pass


def say(msg):
    print("state-paths: " + msg, flush=True)


def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def tok(s):
    """The JSON string token JSON.stringify writes for s (the same for these values)."""
    return json.dumps(s, ensure_ascii=False)


# --- derived values (§2) ------------------------------------------------------------------------------------------
def workspace_key(path):
    """D1: createWorkspaceStateIdentity; also D2's memoryCoreWorkspaceStateKey and D4's prefix (canonical paths only)."""
    return sha(path)


def memory_host_prefix(path):
    """D3: memoryHostWorkspacePrefix."""
    return sha(path)[:24]


def codex_home_id(codex_home):
    """D5: codexCatalogHomeIdFromCanonicalPath."""
    return hashlib.sha256(b"openclaw:codex-session-catalog-home:v1\0" + codex_home.encode("utf-8")).hexdigest()


def managed_thread_key(home_id, thread_id):
    """D5: managedThreadStoreKey."""
    return "sha256:" + hashlib.sha256(b"openclaw:codex-managed-thread:v1\0" + home_id.encode("utf-8") + b"\0"
                                      + thread_id.encode("utf-8")).hexdigest()


# --- homes --------------------------------------------------------------------------------------------------------
def valid_home(p):
    """Absolute, no trailing slash, no "//" or ".." (homepaths.mjs validHome)."""
    return (isinstance(p, str) and len(p) > 1 and p.startswith("/") and not p.endswith("/") and "//" not in p
            and ".." not in p.split("/") and "\0" not in p)


class Homes:
    def __init__(self, old, new):
        if not (valid_home(old) and valid_home(new) and old != new and not new.startswith(old + "/")
                and not old.startswith(new + "/")):
            raise Usage("two different absolute homes, neither inside the other")
        self.old, self.new = old, new
        self.ost, self.nst = old + "/.openclaw", new + "/.openclaw"
        self.old_cron_key = self.ost + "/cron/jobs.json"   # #1: path.resolve(<configDir>/cron/jobs.json)
        self.new_cron_key = self.nst + "/cron/jobs.json"
        self.old_socket = self.ost + "/exec-approvals.sock"   # #8
        self.new_socket = self.nst + "/exec-approvals.sock"

    def under_old(self, p):
        return isinstance(p, str) and p.startswith(self.old + "/")

    def map(self, p):
        if not self.under_old(p):
            raise Refuse("a value expected under the old home is not")
        return self.new + p[len(self.old):]

    def rel(self, p):
        """p relative to the new home, for messages (a directory name, never a row value)."""
        return os.path.relpath(p, self.new) if p.startswith(self.new + "/") else os.path.basename(p)


# --- database helpers ---------------------------------------------------------------------------------------------
def q(name):
    return '"%s"' % name.replace('"', '""')


def one(con, sql, *args):
    return con.execute(sql, args).fetchone()[0]


def tables(con):
    """Every table, virtual ones and their shadow tables included."""
    return [r[0] for r in con.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%' "
                                      "order by name")]


def columns(con, table):
    return [r[1] for r in con.execute("pragma table_info(%s)" % q(table))]


def counts(con):
    """Rows per table, virtual tables left out (their shadow tables are counted)."""
    return {t: one(con, "select count(*) from %s" % q(t)) for (t,) in con.execute(
        "select name from sqlite_master where type='table' and name not like 'sqlite_%' and sql not like 'CREATE VIRTUAL%'")}


def old_home_columns(con, needle):
    """(table, column, rows) for every column whose text names needle."""
    out = []
    for t in tables(con):
        for c in columns(con, t):
            n = one(con, "select count(*) from %s where instr(cast(%s as text), ?) > 0" % (q(t), q(c)), needle)
            if n:
                out.append((t, c, n))
    return out


def open_rw(path, label):
    """Open for the migration: no file is created, foreign keys on, and the write lock taken at once (timeout 0)."""
    if not os.path.isfile(path):
        raise Refuse(label + ": database missing")
    con = sqlite3.connect("file:" + pathname2url(path) + "?mode=rw", uri=True, isolation_level=None, timeout=0)
    con.execute("PRAGMA foreign_keys=ON")
    try:
        con.execute("BEGIN IMMEDIATE")
    except sqlite3.OperationalError as e:
        con.close()
        raise Refuse("%s: cannot take the write lock (%s): is a gateway, doctor or CLI running on this state?" % (label, e))
    return con


def open_ro(path, label):
    """Open for the check: read-only, and one read transaction so every query sees the same snapshot."""
    if not os.path.isfile(path):
        raise Refuse(label + ": database missing")
    con = sqlite3.connect("file:" + pathname2url(path) + "?mode=ro", uri=True, isolation_level=None, timeout=10)
    con.execute("PRAGMA query_only=ON")
    con.execute("BEGIN")
    return con


def expect(con, sql, args, n_expected, what):
    n = con.execute(sql, args).rowcount
    if n != n_expected:
        raise Refuse("%s: changed %d row(s), expected %d" % (what, n, n_expected))


def check_integrity(con, label):
    if con.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        raise Refuse(label + ": integrity_check is not ok")
    if con.execute("PRAGMA foreign_key_check").fetchall():
        raise Refuse(label + ": foreign_key_check found violations")


def proposal_statuses(con):
    """proposal_id -> status, from the table's status column, else record_json's $.status. None when a status cannot be
    read that way: the check then says the statuses were not recorded (the migration itself never fails on this)."""
    try:
        if "status" in columns(con, "skill_workshop_proposals"):
            rows = con.execute("select proposal_id, status from skill_workshop_proposals").fetchall()
        else:
            rows = con.execute("select proposal_id, json_extract(record_json, '$.status') "
                               "from skill_workshop_proposals").fetchall()
    except sqlite3.Error:
        return None
    if not all(isinstance(p, str) and isinstance(s, str) for p, s in rows):
        return None
    return dict(rows)


# --- the post-check, shared by migrate and check ------------------------------------------------------------------
def old_outside_imessage(node, old, inside=False):
    """True if old appears in node outside an iMessage install record (§9 U4: its record stays at the old path)."""
    if isinstance(node, str):
        return old in node and not inside
    if isinstance(node, list):
        return any(old_outside_imessage(x, old, inside) for x in node)
    if isinstance(node, dict):
        here = inside or any(isinstance(node.get(f), str) and "imessage" in node[f].lower()
                             for f in ("id", "pluginId", "name", "packageName"))
        for k, v in node.items():
            kin = here or "imessage" in k.lower()
            if (old in k and not kin) or old_outside_imessage(v, old, kin):
                return True
    return False


def state_leftovers(con, h, old_ws_keys, old_home_ids, post_start):
    """The fail-closed scan of §8.2 step 8, as reasons (empty when clean): old-home text outside the history allow-list,
    old homes in functional JSON fields, plugin-state keys still derived from an old path, workspace keys that are not
    sha256 of their path. After the first start (post_start) the installed-plugin index, which OpenClaw rebuilds, may
    name the old home only in the iMessage install record (U4); before it, it is left for that rebuild (#34)."""
    old, why = h.old, []
    for t, c, n in old_home_columns(con, old):
        if (t, c) not in STATE_HISTORY:
            why.append("%s.%s names the old home in %d row(s): unclassified, or not rewritten" % (t, c, n))
    field_zero = [
        ("task_runs storeKey", "select count(*) from task_runs where instr(json_extract(detail_json,'$.storeKey'),?)>0"),
        ("Workshop proposal targets", "select count(*) from skill_workshop_proposals where instr(json_extract(record_json,"
         "'$.target.skillDir'),?)>0 or instr(json_extract(record_json,'$.target.skillFile'),?)>0"),
        ("config_machine_state", "select count(*) from config_machine_state where instr(value_json,?)>0 "
         "and state_key<>'plugins.installedIndex'"),
        ("plugin_state_entries keys", "select count(*) from plugin_state_entries where instr(entry_key,?)>0 "
         "and not (plugin_id='imessage' and namespace='imessage.recovery-cursor')"),
    ]
    for label, sql in field_zero:
        if con.execute(sql, (old,) * sql.count("?")).fetchone()[0]:
            why.append("the old home is left in " + label)
    if post_start:
        for (v,) in con.execute("select value_json from config_machine_state where state_key='plugins.installedIndex' "
                                "and instr(value_json,?)>0", (old,)):
            if old_outside_imessage(json.loads(v), old):
                why.append("config_machine_state plugins.installedIndex names the old home outside the iMessage install record")
    old_catalogs = set("session-catalog-resident." + i for i in old_home_ids)
    for pid, ns, v in con.execute("select plugin_id, namespace, value_json from plugin_state_entries "
                                  "where instr(value_json,?)>0", (old,)).fetchall():
        if (pid, ns) == ("memory-core", "memory-host.events") or (pid == "codex" and ns in old_catalogs):
            continue   # event payloads (#30) and the old Codex catalog cache (#31): history
        if pid == "memory-core" and ns in ("short-term-recall", "dreaming-memory-backups"):
            j = json.loads(v)
            if (isinstance(j, dict) and isinstance(j.get("value"), dict)
                    and old not in json.dumps({k: x for k, x in j.items() if k != "value"})
                    and old not in json.dumps({k: x for k, x in j["value"].items() if k not in ("snippet", "content")})):
                continue   # recall snippets and backup content (#30): history
        msg = "plugin_state_entries %s/%s: the old home in a functional field" % (pid, ns[:40])
        if msg not in why:
            why.append(msg)
    n = 0
    for p in list(old_ws_keys) + [sha(h.old_cron_key)]:
        n += one(con, "select count(*) from plugin_state_entries where substr(entry_key,1,24)=?", p[:24])
    if n:
        why.append("plugin_state_entries: %d key(s) still derived from an old path" % n)
    for wk, wp in con.execute("select workspace_key, workspace_path from workspace_setup_state where workspace_path is not null"):
        if wk != workspace_key(wp):
            why.append("workspace_setup_state: a key is not sha256 of its path (D1)")
            break
    for ak, ap, wk, wp in con.execute("select alias_key, alias_path, workspace_key, workspace_path from workspace_path_aliases"):
        if not (isinstance(ap, str) and isinstance(wp, str) and ak == workspace_key(ap) and wk == workspace_key(wp)):
            why.append("workspace_path_aliases: a key is not sha256 of its path (D1)")
            break
    return why


# --- migrate ------------------------------------------------------------------------------------------------------
def pin_version(package):
    """The installed OpenClaw's version from its package.json, the same for migrate and preflight."""
    try:
        with open(package) as fh:
            version = json.load(fh)["version"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise Refuse("cannot read the OpenClaw version from %s (%s)" % (package, type(e).__name__))
    if version != PIN_OPENCLAW:
        raise Refuse("pinned to OpenClaw %s, found %s: re-research the state paths for this version"
                     % (PIN_OPENCLAW, version))


class Migration:
    def __init__(self, h, state_dir, package):
        self.h, self.state_dir, self.package = h, state_dir, package
        self.cons = []   # every open database, the state first

    def run(self):
        h = self.h
        pin_version(self.package)
        record_path = os.path.join(self.state_dir, RECORD)
        if os.path.lexists(record_path):
            raise Refuse(RECORD + " exists: state-paths already ran on this state")
        s = self.state = self.open(STATE_DB)
        schema = one(s, "select schema_version from schema_meta where meta_key='primary'")
        if schema != PIN_STATE_SCHEMA:
            raise Refuse("the state schema is %s, not %d" % (schema, PIN_STATE_SCHEMA))
        self.refuse_touched_state()
        self.ws = self.workspaces()
        self.cx = self.codex_homes()
        self.wsk = dict((workspace_key(o), (workspace_key(n), o, n)) for o, n in self.ws.items())
        self.home_ids = dict((codex_home_id(o), codex_home_id(n)) for o, n in self.cx.items())
        codex = []
        for o, n in sorted(self.cx.items()):
            rel = os.path.relpath(n, h.nst) + "/state_5.sqlite"
            if os.path.isfile(os.path.join(self.state_dir, rel)):
                c = self.open(rel)
                level = one(c, "select max(version) from _sqlx_migrations")
                if level != PIN_CODEX_MIGRATION:
                    raise Refuse("%s: migration level is %s, not %d" % (rel, level, PIN_CODEX_MIGRATION))
                codex.append((rel, c))
        self.refuse_touched_identity(codex)
        statuses = proposal_statuses(s)
        before = counts(s)

        moved = self.move_cron_keys()
        self.rewrite_cron_argv()
        self.move_workspace_identity()
        self.move_exec_socket()
        self.move_plain_columns()
        self.move_workshop_targets()
        self.move_plugin_state()
        why = state_leftovers(s, h, self.wsk, self.home_ids, post_start=False)
        if counts(s) != before:
            why.append("row counts changed")
        if why:
            raise Refuse("; ".join(why))
        check_integrity(s, STATE_DB)
        for rel, c in codex:
            self.move_codex_threads(rel, c)
        say("post-check passed: old-home text only in the history allow-list, row counts unchanged, integrity ok")

        record = {"format": 1, "openclaw": PIN_OPENCLAW, "old_home": h.old, "new_home": h.new,
                  "old_workspace_keys": sorted(self.wsk), "old_codex_home_ids": sorted(self.home_ids),
                  "cron_jobs": moved, "cron_jobs_total": one(s, "select count(*) from cron_jobs"),
                  "workspace_setup_rows": one(s, "select count(*) from workspace_setup_state"),
                  "workspace_alias_rows": one(s, "select count(*) from workspace_path_aliases"),
                  "exec_approvals_rows": one(s, "select count(*) from exec_approvals_config"),
                  "proposal_statuses": statuses}
        self.commit(record_path, record)
        say("OK: %s and %d Codex database(s) committed; %s written" % (STATE_DB, len(codex), RECORD))

    def open(self, rel):
        con = open_rw(os.path.join(self.state_dir, rel), rel)
        self.cons.append(con)
        return con

    def workspaces(self):
        """Old workspace path -> new, for every workspace_setup_state row under the old home (#6). Each new one must
        exist and be canonical: the derived keys hash the realpath (D1-D4)."""
        h, ws = self.h, {}
        for (p,) in self.state.execute("select workspace_path from workspace_setup_state where workspace_path is not null"):
            if h.under_old(p):
                ws[p] = h.map(p)
        if not ws:
            raise Refuse("workspace_setup_state names no workspace under the old home: is --old the archive's home?")
        for n in sorted(ws.values()):
            if not os.path.isdir(n) or os.path.realpath(n) != n:
                raise Refuse("%s: a workspace of the old state is missing under the new home, or is not canonical "
                             "(a symlink): its derived keys would differ" % h.rel(n))
        return ws

    def codex_homes(self):
        """Old Codex home -> new, for every agents/<id>/agent/codex-home of the new state dir (#14-#17, D5)."""
        h, cx = self.h, {}
        agents = os.path.join(h.nst, "agents")
        for a in sorted(os.listdir(agents)) if os.path.isdir(agents) else []:
            n = os.path.join(agents, a, "agent", "codex-home")
            if os.path.lexists(n):
                if not os.path.isdir(n) or os.path.realpath(n) != n:
                    raise Refuse("%s: a Codex home is not canonical (a symlink): its home id would differ" % h.rel(n))
                cx[h.ost + n[len(h.nst):]] = n
        return cx

    # The new home owns nothing yet (§3): otherwise a gateway, doctor or CLI already ran on this state, and the rewrite
    # would collide with what it made or double it. In two parts: what needs no workspace or Codex home first.
    TOUCHED = (": a gateway, doctor or CLI already ran on this state, or an earlier state-paths migrate committed part "
               "of its work; import a fresh copy of the archive")

    def refuse_touched_state(self):
        s, h = self.state, self.h
        for t in CRON_KEY_TABLES:
            if one(s, "select count(*) from %s where store_key=?" % t, h.new_cron_key):
                raise Refuse("%s.store_key already has rows under the new cron key%s" % (t, self.TOUCHED))
        for t, c in (("skill_usage", "skill_file"), ("session_watch_cursors", "watcher_store_path"),
                     ("config_health_entries", "config_path"), ("exec_approvals_config", "socket_path")):
            if one(s, "select count(*) from %s where substr(%s,1,?)=?" % (t, c), len(h.new) + 1, h.new + "/"):
                raise Refuse("%s.%s already names the new home%s" % (t, c, self.TOUCHED))

    def refuse_touched_identity(self, codex):
        s, h, hint = self.state, self.h, self.TOUCHED
        for nh, o, n in self.wsk.values():
            if one(s, "select count(*) from workspace_setup_state where workspace_key=? or workspace_path=?", nh, n):
                raise Refuse("workspace_setup_state already has rows for a workspace under the new home" + hint)
            if one(s, "select count(*) from workspace_path_aliases where alias_key=? or workspace_key=? or alias_path=? "
                      "or workspace_path=?", nh, nh, n, n):
                raise Refuse("workspace_path_aliases already has rows for a workspace under the new home" + hint)
            if one(s, "select count(*) from plugin_state_entries where substr(entry_key,1,24)=?", nh[:24]):
                raise Refuse("plugin_state_entries already has keys derived from a workspace under the new home" + hint)
        for nid in self.home_ids.values():
            if one(s, "select count(*) from plugin_state_entries where plugin_id='codex' and (namespace=? or "
                      "(namespace='app-server-managed-threads' and instr(value_json,?)>0))",
                   "session-catalog-resident." + nid, nid):
                raise Refuse("plugin_state_entries already has Codex rows for a Codex home under the new home" + hint)
        for rel, c in codex:
            if one(c, "select count(*) from threads where substr(cwd,1,?)=? or substr(rollout_path,1,?)=?",
                   len(h.new) + 1, h.new + "/", len(h.new) + 1, h.new + "/"):
                raise Refuse("%s: threads already name the new home%s" % (rel, hint))

    # 1. The cron partition key (#1-#3) and the run-history partition in task_runs (#4).
    def move_cron_keys(self):
        s, ok, nk = self.state, self.h.old_cron_key, self.h.new_cron_key
        moved = {}
        for t in CRON_KEY_TABLES:
            moved[t] = one(s, "select count(*) from %s where store_key=?" % t, ok)
            expect(s, "update %s set store_key=? where store_key=?" % t, (nk, ok), moved[t], t + ".store_key")
        member_old, member_new = '"storeKey":' + tok(ok), '"storeKey":' + tok(nk)
        rows = s.execute("select task_id, detail_json from task_runs where runtime='cron' "
                         "and json_extract(detail_json,'$.storeKey')=?", (ok,)).fetchall()
        for tid, dj in rows:
            if dj.count(member_old) != 1:
                raise Refuse("task_runs.detail_json: the storeKey member is not the one compact member the rewrite expects")
            s.execute("update task_runs set detail_json=? where task_id=?", (dj.replace(member_old, member_new), tid))
        say("cron store key: %s, task_runs %d" % (", ".join("%s %d" % kv for kv in sorted(moved.items())), len(rows)))
        return moved["cron_jobs"]

    # 2. Command automations: the old home only in payload.argv elements (#5); the grant revision is invalidated the
    #    way materializeCronRowAgentOwners does for an in-place job_json rewrite (#25, D6).
    def rewrite_cron_argv(self):
        s, h, n = self.state, self.h, 0
        for jid, jj in s.execute("select job_id, job_json from cron_jobs where store_key=? and instr(job_json,?)>0",
                                 (h.new_cron_key, h.old + "/")).fetchall():
            exp = json.loads(jj)
            payload = exp.get("payload") if isinstance(exp, dict) else None
            argv = payload.get("argv") if isinstance(payload, dict) else None
            if not isinstance(argv, list):
                raise Refuse("cron_jobs.job_json: the old home outside payload.argv")
            new = jj
            for a in sorted(set(x for x in argv if h.under_old(x))):
                new = new.replace(tok(a), tok(h.map(a)))
            payload["argv"] = [h.map(x) if h.under_old(x) else x for x in argv]
            if json.loads(new) != exp or (h.old + "/") in new:
                raise Refuse("cron_jobs.job_json: the old home outside payload.argv elements")
            expect(s, "update cron_jobs set job_json=?, grant_definition_revision=NULL, grant_definition_generation="
                      "coalesce(grant_definition_generation,0)+1, grant_definition_updated_at=NULL "
                      "where store_key=? and job_id=?", (new, h.new_cron_key, jid), 1, "cron_jobs.job_json")
            n += 1
        say("command automations: %d argv rewritten, grant revision invalidated" % n)

    # 3. Workspace identity (#6, #7, #20, #21, #26): the transaction doctor's rebindRepointedWorkspaceAlias performs —
    #    insert the new row, move the bootstrap hashes, delete the old row, one plain self-alias for the new path.
    def move_workspace_identity(self):
        s = self.state
        keep = [c for c in columns(s, "workspace_setup_state") if c not in ("workspace_key", "workspace_path")]
        rest = "".join(", " + q(c) for c in keep)
        now = int(time.time() * 1000)
        for oh, (nh, o, n) in sorted(self.wsk.items()):
            expect(s, "insert into workspace_setup_state (workspace_key, workspace_path%s) select ?, ?%s "
                      "from workspace_setup_state where workspace_key=? and workspace_path=?" % (rest, rest),
                   (nh, n, oh, o), 1, "workspace_setup_state (a row whose key is sha256 of its path)")
            s.execute("update workspace_generated_bootstrap_hashes set workspace_key=? where workspace_key=?", (nh, oh))
            expect(s, "delete from workspace_setup_state where workspace_key=?", (oh,), 1, "workspace_setup_state")
            if one(s, "select count(*) from workspace_path_aliases where workspace_key=? and not "
                      "(alias_key=? and alias_path=? and workspace_path=?)", oh, oh, o, o):
                raise Refuse("workspace_path_aliases: a workspace has aliases other than its plain self-alias")
            expect(s, "delete from workspace_path_aliases where workspace_key=?", (oh,), 1, "workspace_path_aliases")
            expect(s, "insert into workspace_path_aliases (alias_key, alias_path, workspace_key, workspace_path, "
                      "updated_at_ms) values (?,?,?,?,?)", (nh, n, nh, n, now), 1, "workspace_path_aliases")
        say("workspace identity: %d workspace(s) moved, keys recomputed" % len(self.wsk))

    # 4. The exec-approvals socket: the column and the same value inside raw_json (#8).
    def move_exec_socket(self):
        s, h, n = self.state, self.h, 0
        for key, raw, sp in s.execute("select config_key, raw_json, socket_path from exec_approvals_config "
                                      "where instr(raw_json,?)>0 or instr(socket_path,?)>0", (h.old, h.old)).fetchall():
            if sp != h.old_socket or not isinstance(raw, str) or raw.count(tok(h.old_socket)) != 1:
                raise Refuse("exec_approvals_config: socket_path and $.socket.path are not the one default socket of the old state dir")
            new = raw.replace(tok(h.old_socket), tok(h.new_socket))
            j = json.loads(new)
            if h.old in new or not isinstance(j.get("socket"), dict) or j["socket"].get("path") != h.new_socket:
                raise Refuse("exec_approvals_config.raw_json names the old home outside $.socket.path")
            s.execute("update exec_approvals_config set raw_json=?, socket_path=? where config_key=?", (new, h.new_socket, key))
            n += 1
        say("exec-approvals socket: %d row(s)" % n)

    # 5. Plain path columns: every old-home value must be a prefix hit (#9, #10, #12).
    def move_plain_columns(self):
        s, h = self.state, self.h
        cut = len(h.old) + 1
        done = []
        for t, c in PLAIN_PATH_COLUMNS:
            n = one(s, "select count(*) from %s where instr(%s,?)>0" % (t, c), h.old)
            expect(s, "update %s set %s = ? || substr(%s, ?) where substr(%s,1,?) = ?" % (t, c, c, c),
                   (h.new, cut, cut, h.old + "/"), n, "%s.%s" % (t, c))
            done.append("%s.%s %d" % (t, c, n))
        say("path columns: " + ", ".join(done))

    # 6. Skill Workshop proposal targets, $.target.skillDir and skillFile only (#11); $.evidence stays (#29).
    def move_workshop_targets(self):
        s, h, n = self.state, self.h, 0
        for pid, rj in s.execute("select proposal_id, record_json from skill_workshop_proposals where instr(record_json,?)>0",
                                 (h.old + "/",)).fetchall():
            exp, new = json.loads(rj), rj
            target = exp.get("target") if isinstance(exp, dict) else None
            if not isinstance(target, dict):
                raise Refuse("skill_workshop_proposals.record_json: the old home in a proposal without a target")
            for f in ("skillDir", "skillFile"):
                v = target.get(f)
                if h.under_old(v):
                    new = new.replace(tok(v), tok(h.map(v)))
                    target[f] = h.map(v)
            if json.loads(new) != exp:
                raise Refuse("skill_workshop_proposals.record_json: the target rewrite would touch other fields")
            if new != rj:
                s.execute("update skill_workshop_proposals set record_json=? where proposal_id=?", (new, pid))
                n += 1
        say("Workshop proposal targets: %d proposal(s)" % n)

    # 7. Plugin state: memory-core (#13, #22, #23 / D2, D3), artifact provenance (#23 / D4), Codex bindings and managed
    #    threads (#14, #15, #24 / D5).
    def move_plugin_state(self):
        s, h, wsk = self.state, self.h, self.wsk
        ps = "update plugin_state_entries set entry_key=?, value_json=? where plugin_id=? and namespace=? and entry_key=?"
        n = {"memory-core": 0, "provenance": 0, "codex": 0}
        for ns, k, v in s.execute("select namespace, entry_key, value_json from plugin_state_entries "
                                  "where plugin_id='memory-core'").fetchall():
            if ns in ("memory-host.events", "memory-host.event-cursors"):   # key = sha256(ws)[:24] + ":..." (D3)
                hit = [oh for oh in wsk if oh[:24] == k[:24]]
                if len(hit) != 1 or k[24:25] != ":":
                    raise Refuse("plugin_state_entries memory-core/%s: a key is not prefixed by an old workspace's hash" % ns)
                s.execute(ps, (memory_host_prefix(wsk[hit[0]][2]) + k[24:], v, "memory-core", ns, k))   # payloads: history
                n["memory-core"] += 1
                continue
            j = json.loads(v)
            oh = k[:64]
            if (oh not in wsk or k[64:65] != ":" or not isinstance(j, dict) or j.get("workspaceKey") != oh
                    or j.get("workspaceDir") != wsk[oh][1] or not isinstance(j.get("key"), str) or k[65:] != sha(j["key"])):
                raise Refuse("plugin_state_entries memory-core/%s: a row is not sha256(workspace):sha256(key) for an old "
                             "workspace (D2)" % ns)
            nh, o, nw = wsk[oh]
            new = v.replace(tok(oh), tok(nh)).replace(tok(o), tok(nw))
            j["workspaceKey"], j["workspaceDir"] = nh, nw
            pk = j["value"].get("projectKey") if isinstance(j.get("value"), dict) else None
            if isinstance(pk, str) and ("path:" + o) in pk:   # the active project key is path:<workspace> (§7 N2)
                npk = pk.replace("path:" + o, "path:" + nw)
                new = new.replace(tok(pk), tok(npk))
                j["value"]["projectKey"] = npk
            if json.loads(new) != j:
                raise Refuse("plugin_state_entries memory-core/%s: the rewrite would touch other fields" % ns)
            s.execute(ps, (nh + k[64:], new, "memory-core", ns, k))
            n["memory-core"] += 1
        for k, v in s.execute("select entry_key, value_json from plugin_state_entries where "
                              "plugin_id='core:memory-artifact-provenance' and namespace='workspace-files'").fetchall():
            j = json.loads(v)
            oh = k[:64]
            if oh not in wsk or k[64:65] != ":" or not isinstance(j, dict) or j.get("workspaceKey") != oh:
                raise Refuse("plugin_state_entries artifact provenance: a key is not an old workspace hash (D4)")
            new = v.replace(tok(oh), tok(wsk[oh][0]))
            j["workspaceKey"] = wsk[oh][0]
            if json.loads(new) != j:
                raise Refuse("plugin_state_entries artifact provenance: the rewrite would touch other fields")
            s.execute(ps, (wsk[oh][0] + k[64:], new, "core:memory-artifact-provenance", "workspace-files", k))
            n["provenance"] += 1
        for k, v in s.execute("select entry_key, value_json from plugin_state_entries where plugin_id='codex' "
                              "and namespace='app-server-managed-threads'").fetchall():
            j = json.loads(v)
            oh = j.get("sourceHomeId") if isinstance(j, dict) else None
            if oh not in self.home_ids or not isinstance(j.get("threadId"), str) or k != managed_thread_key(oh, j["threadId"]):
                raise Refuse("plugin_state_entries codex managed thread: a key is not derived from an old Codex home (D5)")
            nid = self.home_ids[oh]
            new = v.replace(tok(oh), tok(nid))
            j["sourceHomeId"] = nid
            if h.under_old(j.get("rolloutPath")):
                new = new.replace(tok(j["rolloutPath"]), tok(h.map(j["rolloutPath"])))
                j["rolloutPath"] = h.map(j["rolloutPath"])
            if json.loads(new) != j or h.old in new:
                raise Refuse("plugin_state_entries codex managed thread: the old home outside rolloutPath")
            s.execute(ps, (managed_thread_key(nid, j["threadId"]), new, "codex", "app-server-managed-threads", k))
            n["codex"] += 1
        for k, v in s.execute("select entry_key, value_json from plugin_state_entries where plugin_id='codex' "
                              "and namespace='app-server-thread-bindings' and instr(value_json,?)>0", (h.old,)).fetchall():
            j = json.loads(v)
            binding = j.get("binding") if isinstance(j, dict) else None
            if not isinstance(binding, dict):
                raise Refuse("plugin_state_entries codex binding: the old home outside binding")
            new = v
            for f in ("cwd", "appServerRuntimeFingerprint"):
                x = binding.get(f)
                if isinstance(x, str) and (h.old + "/") in x:
                    new = new.replace(tok(x), tok(x.replace(h.old + "/", h.new + "/")))
                    binding[f] = x.replace(h.old + "/", h.new + "/")
            if json.loads(new) != j or h.old in new:
                raise Refuse("plugin_state_entries codex binding: the old home outside binding.cwd and "
                             "binding.appServerRuntimeFingerprint")
            s.execute(ps, (k, new, "codex", "app-server-thread-bindings", k))
            n["codex"] += 1
        say("plugin state: memory-core %(memory-core)d, artifact provenance %(provenance)d, codex %(codex)d "
            "(keys recomputed)" % n)

    # 9. Codex's own thread index (#16, #17); its text columns are history (#51). The same allow-list scan as the state.
    def move_codex_threads(self, rel, c):
        h = self.h
        cut = len(h.old) + 1
        before = counts(c)
        for col in ("rollout_path", "cwd"):
            n = one(c, "select count(*) from threads where instr(%s,?)>0" % col, h.old)
            expect(c, "update threads set %s = ? || substr(%s, ?) where substr(%s,1,?) = ?" % (col, col, col),
                   (h.new, cut, cut, h.old + "/"), n, "%s: threads.%s" % (rel, col))
        why = ["%s: %s.%s names the old home in %d row(s): unclassified, or not rewritten" % (rel, t, col, n)
               for t, col, n in old_home_columns(c, h.old) if (t, col) not in CODEX_HISTORY]
        if counts(c) != before:
            why.append(rel + ": row counts changed")
        if why:
            raise Refuse("; ".join(why))
        check_integrity(c, rel)

    # 10. Commit: the record goes next to the state first, under a temporary name, and takes its place once every
    #     database has committed.
    def commit(self, record_path, record):
        tmp = "%s.tmp-%d" % (record_path, os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(record, fh, indent=1, sort_keys=True)
            fh.write("\n")
        committed = 0
        try:
            for con in self.cons:
                con.execute("COMMIT")
                committed += 1
        except Exception as e:
            os.remove(tmp)
            if committed:
                raise Partial("COMMIT failed (%s) after %d of %d database(s) committed: the state is inconsistent; "
                              "import a fresh copy of the archive" % (type(e).__name__, committed, len(self.cons)))
            raise
        try:
            os.replace(tmp, record_path)
            for con in self.cons:
                con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except Exception as e:
            raise Partial("every database committed, but then %s: %s; the check needs %s in place"
                          % (type(e).__name__, e, RECORD))
        self.close()

    def rollback(self):
        for con in self.cons:
            try:
                if con.in_transaction:
                    con.execute("ROLLBACK")
            except sqlite3.Error:
                pass
        self.close()

    def close(self):
        for con in self.cons:
            con.close()
        self.cons = []


# --- check ----------------------------------------------------------------------------------------------------------
def run_check(home, cron_total, state_dir):
    failures = []

    def item(name, reasons):
        if reasons:
            failures.append(name)
            print("state-paths check: FAIL %s: %s" % (name, "; ".join(reasons)), flush=True)
        else:
            print("state-paths check: ok   " + name, flush=True)

    try:
        with open(os.path.join(state_dir, RECORD)) as fh:
            rec = json.load(fh)
    except OSError:
        item("record", ["no %s: state-paths migrate never completed on this state" % RECORD])
        return 1
    except ValueError:
        item("record", [RECORD + " is not valid JSON"])
        return 1
    if rec.get("format") != 1 or rec.get("new_home") != home:
        item("record", [RECORD + " was written for another home or by another version of this script"])
        return 1
    h = Homes(rec["old_home"], home)
    new_prefix = (len(h.new) + 1, h.new + "/")
    con = open_ro(os.path.join(state_dir, STATE_DB), STATE_DB)
    try:
        # The automations admin's gateway listed before the switch, all in the active cron store now (§8.5). A gateway
        # whose store key is not the migrated one sees none of them and seeds its own: no row may sit under another key,
        # and the table holds what the migration left (rehome.sh verify also compares the gateway's own count).
        n = one(con, "select count(*) from cron_jobs where store_key=?", h.new_cron_key)
        outside = one(con, "select count(*) from cron_jobs where store_key is null or store_key<>?", h.new_cron_key)
        total = one(con, "select count(*) from cron_jobs")
        item("automations", ([] if n == cron_total else ["the cron store holds %d, admin's gateway listed %d" % (n, cron_total)])
             + (["%d cron_jobs row(s) outside the migrated cron store key" % outside] if outside else [])
             + ([] if total == rec.get("cron_jobs_total") else
                ["cron_jobs has %d row(s), the migration left %s" % (total, rec.get("cron_jobs_total"))]))
        # A gateway that did not find its declarations seeds them again (§3).
        if "declaration_key" in columns(con, "cron_jobs"):
            d = one(con, "select count(*) from (select declaration_key from cron_jobs where store_key=? and "
                         "declaration_key is not null group by declaration_key having count(*) > 1)", h.new_cron_key)
            item("cron declarations", ["%d declaration_key(s) duplicated in the active cron store" % d] if d else [])
        else:
            item("cron declarations", ["cron_jobs has no declaration_key column (not the 2026.9.7 schema)"])
        # Workspace rows and aliases: the migrated ones, under the new home only; no fresh setup row (§8.5).
        why = []
        for t, cols, want in (("workspace_setup_state", ("workspace_path",), rec.get("workspace_setup_rows")),
                              ("workspace_path_aliases", ("alias_path", "workspace_path"), rec.get("workspace_alias_rows"))):
            parts = []
            total = one(con, "select count(*) from %s" % t)
            if total != want:
                parts.append("%s has %d row(s), the migration left %s" % (t, total, want))
            outside = one(con, "select count(*) from %s where %s" % (t, " or ".join(   # a row without a path names no home
                "(%s is not null and substr(%s,1,?)<>?)" % (c, c) for c in cols)), *(new_prefix * len(cols)))
            if outside:
                parts.append("%d not under the new home" % outside)
            if parts and not parts[0].startswith(t):
                parts[0] = t + ": " + parts[0]
            if parts:
                why.append("; ".join(parts))
        item("workspace identity", why)
        # The exec-approvals socket (#8).
        outside = one(con, "select count(*) from exec_approvals_config where socket_path is null or substr(socket_path,1,?)<>?",
                      *new_prefix)
        rows = one(con, "select count(*) from exec_approvals_config")
        item("exec-approvals socket", (["%d row(s) not under the new home" % outside] if outside else [])
             + (["exec_approvals_config has %d row(s), the migration left %s" % (rows, rec.get("exec_approvals_rows"))]
                if rows != rec.get("exec_approvals_rows") else []))
        # Plugin-state keys under the old workspace hashes (D2-D4).
        n = sum(one(con, "select count(*) from plugin_state_entries where substr(entry_key,1,24)=?", k[:24])
                for k in rec.get("old_workspace_keys", []))
        item("plugin state keys", ["%d key(s) derived from an old workspace path" % n] if n else [])
        # Workshop proposals: the migrated ones keep their status (the drill staled 11 of them, #11).
        was, now = rec.get("proposal_statuses"), proposal_statuses(con)
        if was is None or now is None:
            item("Workshop proposals", ["statuses could not be read (neither a status column nor $.status)"])
        else:
            missing = sum(1 for p in was if p not in now)
            changed = sum(1 for p, st in was.items() if p in now and now[p] != st)
            item("Workshop proposals", (["%d of %d missing" % (missing, len(was))] if missing else [])
                 + (["%d of %d changed status since the migration" % (changed, len(was))] if changed else []))
        # The same allow-list as the migration's post-check, the installed-plugin index now rebuilt (U4).
        item("history allow-list", state_leftovers(con, h, rec.get("old_workspace_keys", []),
                                                  rec.get("old_codex_home_ids", []), post_start=True))
    finally:
        con.close()
    if failures:
        print("state-paths check: FAILED (%d item(s): %s)" % (len(failures), ", ".join(failures)), flush=True)
        return 1
    print("state-paths check: OK", flush=True)
    return 0


# --- preflight ------------------------------------------------------------------------------------------------------
def live_copy(src, dst, label):
    """A consistent copy of a database a running gateway may be writing: opened read-only (mode=ro), copied with the
    backup API in one step. Nothing is written next to the source. A WAL database without a -wal file has no connection
    open (the last one checkpoints and removes it), so every page is in the main file; a read-only open would want to
    create the -wal and -shm (a SQLite build either refuses or makes them next to the source): immutable=1 reads the
    file as it is instead, without locks. A writer that starts meanwhile writes to a new -wal, not to this file."""
    if not os.path.isfile(src):
        raise Refuse(label + ": database missing")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    for attempt in (1, 2):
        before = os.stat(src)
        with open(src, "rb") as fh:
            wal = fh.read(20)[18:20] == b"\x02\x02"   # the header's file format versions: 2 = WAL
        immutable = wal and not os.path.lexists(src + "-wal")
        q = "?mode=ro&immutable=1" if immutable else "?mode=ro"
        s = sqlite3.connect("file:" + pathname2url(src) + q, uri=True, timeout=10)
        try:
            d = sqlite3.connect(dst)
            try:
                s.backup(d)
            finally:
                d.close()
        finally:
            s.close()
        if not immutable:
            return
        # immutable=1 takes no locks: a writer that opened and checkpointed meanwhile tears the copy, and integrity_check
        # of the torn copy can still say ok. The source must be as it was: same size and mtime, still no -wal.
        after = os.stat(src)
        if (after.st_size, after.st_mtime_ns) == (before.st_size, before.st_mtime_ns) \
                and not os.path.lexists(src + "-wal"):
            return
        os.remove(dst)
    raise Refuse(label + ": the database changed during the copy; run prepare again")


def canonical_below(home, p):
    """No symlink below home on the way to p (the restore lays out what is below the home; the home itself may be
    reached through one)."""
    return os.path.realpath(p) == os.path.join(os.path.realpath(home), os.path.relpath(p, home))


def run_preflight(home, package):
    """What would make migrate refuse mid-downtime, found on home's live state while it runs: the runtime, the pin, and
    migrate itself on copies of the live databases, under a scratch new home whose workspaces and Codex homes are real
    (canonical) directories, mirrored from the live ones. Read-only on home; the scratch dir is removed on every way
    out (a SIGTERM or SIGHUP becomes an exit so the cleanup runs)."""
    if sys.version_info[:2] < MIN_PYTHON:
        raise Refuse("python %d.%d is older than %d.%d" % (sys.version_info[:2] + tuple(MIN_PYTHON)))
    if sqlite3 is None:
        raise Refuse("this python3 has no sqlite3 module")
    pin_version(package)
    st = home + "/.openclaw"
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="state-paths-preflight-"))
    try:
        try:
            h = Homes(home, tmp + "/home")
        except Usage:
            raise Refuse("the scratch dir (TMPDIR) is inside the home")
        live_copy(os.path.join(st, STATE_DB), os.path.join(h.nst, STATE_DB), STATE_DB)
        con = sqlite3.connect(os.path.join(h.nst, STATE_DB))
        try:
            # The running gateway holds these leases (classification: transient, empty in a backup); the switch migrates
            # a backup, so the dry run drops them from its copy the way a backup does. migrate itself stays strict.
            for t in TRANSIENT_LEASE_TABLES:
                if con.execute("select 1 from sqlite_master where type='table' and name=?", (t,)).fetchone():
                    con.execute('delete from "%s"' % t)
            con.commit()
            ws = [p for (p,) in con.execute("select workspace_path from workspace_setup_state where workspace_path is not null")]
        except sqlite3.Error:
            ws = []   # the dry run says why (a schema it is not pinned to)
        finally:
            con.close()
        for p in sorted(set(ws)):
            if h.under_old(p):
                if not (os.path.isdir(p) and canonical_below(home, p)):
                    raise Refuse("%s: a workspace of the live state is missing or not canonical (a symlink): the "
                                 "migration would refuse it" % os.path.relpath(p, home))
                os.makedirs(h.map(p), exist_ok=True)
        agents = os.path.join(st, "agents")
        for a in sorted(os.listdir(agents)) if os.path.isdir(agents) else []:
            p = os.path.join(agents, a, "agent", "codex-home")
            if not os.path.lexists(p):
                continue
            if not (os.path.isdir(p) and canonical_below(home, p)):
                raise Refuse("%s: a Codex home of the live state is not canonical (a symlink): the migration would "
                             "refuse it" % os.path.relpath(p, home))
            n = h.map(p)
            os.makedirs(n, exist_ok=True)
            if os.path.isfile(os.path.join(p, "state_5.sqlite")):
                live_copy(os.path.join(p, "state_5.sqlite"), os.path.join(n, "state_5.sqlite"),
                          os.path.relpath(n, h.nst) + "/state_5.sqlite")
        mig = Migration(h, h.nst, package)
        try:
            with contextlib.redirect_stdout(io.StringIO()):   # its progress lines describe the scratch copies
                mig.run()
        except BaseException:
            mig.rollback()
            raise
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def exit_on_signal(signum, frame):
    raise SystemExit(1)


def preflight(home, package):
    saved = [(sig, signal.signal(sig, exit_on_signal)) for sig in (signal.SIGTERM, signal.SIGHUP)]
    try:
        run_preflight(home, package)
    except Refuse as e:
        print("state-paths preflight: refused: %s; the switch would refuse it mid-downtime: fix it while production runs"
              % e, file=sys.stderr, flush=True)
        return 1
    except Exception as e:
        print("state-paths preflight: failed: %s: %s" % (type(e).__name__, e), file=sys.stderr, flush=True)
        return 1
    finally:
        for sig, handler in saved:
            signal.signal(sig, handler)
    print("state-paths preflight: OK (python %d.%d with sqlite3, OpenClaw %s, a dry run of the migration on copies of the "
          "live databases passed)" % (sys.version_info[:2] + (PIN_OPENCLAW,)), flush=True)
    return 0


# --- command line ---------------------------------------------------------------------------------------------------
def main(argv=None):
    p = argparse.ArgumentParser(prog="state-paths.py", description="OpenClaw 2026.9.7 state-path migration and its check.")
    sub = p.add_subparsers(dest="cmd")
    m = sub.add_parser("migrate", help="rewrite OLD to NEW in the path-keyed state (cross-home import only)")
    m.add_argument("--old", required=True)
    m.add_argument("--new", required=True)
    m.add_argument("--state", help="where the databases are (default NEW/.openclaw)")
    m.add_argument("--openclaw-package", default=OPENCLAW_PACKAGE, help=argparse.SUPPRESS)   # tests only
    c = sub.add_parser("check", help="read-only post-start checks")
    c.add_argument("--home", required=True)
    c.add_argument("--cron-total", required=True, help="the automation count admin's gateway listed")
    c.add_argument("--state", help="where the databases are (default HOME/.openclaw)")
    f = sub.add_parser("preflight", help="read-only, before anything is stopped: runtime, pin, dry run on copies")
    f.add_argument("--home", required=True, help="the old home, whose live state migrate will move")
    f.add_argument("--openclaw-package", default=OPENCLAW_PACKAGE, help=argparse.SUPPRESS)   # tests only
    args = p.parse_args(argv)
    if not args.cmd:
        p.print_usage(sys.stderr)
        return 2
    try:
        if args.cmd == "preflight":
            if not valid_home(args.home):
                raise Usage("--home must be an absolute home")
            return preflight(args.home, args.openclaw_package)
        if sqlite3 is None:
            print("state-paths: this python3 has no sqlite3 module", file=sys.stderr, flush=True)
            return 1
        if args.cmd == "check":
            if not valid_home(args.home):
                raise Usage("--home must be an absolute home")
            if not re.match(r"^[0-9]+$", args.cron_total):
                raise Usage("--cron-total must be a count")
            try:
                return run_check(args.home, int(args.cron_total), args.state or args.home + "/.openclaw")
            except (Refuse, Usage, sqlite3.Error, ValueError, KeyError, TypeError) as e:   # Usage: a record naming bad homes
                print("state-paths check: FAIL: %s%s" % ("" if isinstance(e, Refuse) else type(e).__name__ + ": ", e),
                      file=sys.stderr, flush=True)
                return 1
        mig = Migration(Homes(args.old, args.new), args.state or args.new + "/.openclaw", args.openclaw_package)
    except Usage as e:
        print("state-paths: usage: %s (%s)" % (e, "migrate --old OLD --new NEW [--state DIR] | "
                                                 "check --home HOME --cron-total N [--state DIR] | preflight --home OLD"),
              file=sys.stderr)
        return 2
    try:
        mig.run()
        return 0
    except Refuse as e:
        mig.rollback()
        print("state-paths: refused: %s; nothing was committed" % e, file=sys.stderr, flush=True)
    except Partial as e:   # its own status: import.sh tells the owner to roll back, not that nothing was committed
        mig.rollback()
        print("state-paths: failed: %s" % e, file=sys.stderr, flush=True)
        return 3
    except Exception as e:   # any other failure: still nothing committed
        mig.rollback()
        print("state-paths: failed: %s: %s; nothing was committed" % (type(e).__name__, e), file=sys.stderr, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
