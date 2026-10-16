#!/usr/bin/env python3
"""Tests for migrate/state-paths.py on fixture databases: the schema subset that
.superpowers/sdd/2026-10-02-bot-user-sebastian/state-path-classification.md §1 classifies, with made-up rows. The
derived values are computed here from the research's formulas (§2), independently of the script.
Run: python3 migrate/state-paths.test.py (Python 3.9+, stdlib only). Nothing outside a temp dir is touched."""
import contextlib
import hashlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "state-paths.py")
OLD = "/Users/admin"
MARK = "made-up-row-value"   # planted in rows, functional and historical: never printed


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def js(o):   # what JSON.stringify writes
    return json.dumps(o, separators=(",", ":"), ensure_ascii=False)


def home_id(p):   # D5: codexCatalogHomeIdFromCanonicalPath
    return hashlib.sha256(b"openclaw:codex-session-catalog-home:v1\0" + p.encode()).hexdigest()


def mt_key(hid, tid):   # D5: managedThreadStoreKey
    return "sha256:" + hashlib.sha256(b"openclaw:codex-managed-thread:v1\0" + hid.encode() + b"\0" + tid.encode()).hexdigest()


STATE_SCHEMA = """
create table schema_meta (meta_key text primary key, schema_version integer not null);
create table cron_jobs (store_key text not null, job_id text not null, job_json text not null, state_json text,
  declaration_key text, grant_definition_revision text, grant_definition_generation integer,
  grant_definition_updated_at integer, primary key (store_key, job_id));
create table cron_run_receipts (receipt_id text primary key, store_key text not null, job_id text not null, status text not null);
create unique index cron_run_receipts_running on cron_run_receipts (store_key, job_id) where status = 'running';
create table cron_job_scratch (store_key text not null, job_id text not null, source_sha256 text, primary key (store_key, job_id));
create table task_runs (task_id text primary key, runtime text not null, detail_json text, terminal_summary text);
create table workspace_setup_state (workspace_key text primary key, workspace_path text, version integer,
  bootstrap_seeded_at integer, setup_completed_at integer, updated_at integer, attested_at_ms integer,
  attestation_updated_at_ms integer);
create table workspace_generated_bootstrap_hashes (workspace_key text not null
  references workspace_setup_state (workspace_key) on delete cascade, file_name text not null, sha256 text not null,
  primary key (workspace_key, file_name));
create table workspace_path_aliases (alias_key text primary key, alias_path text not null, workspace_key text not null,
  workspace_path text not null, updated_at_ms integer);
create table exec_approvals_config (config_key text primary key, raw_json text not null, socket_path text);
create table session_watch_cursors (session_key text primary key, watcher_store_path text, cursor integer);
create table skill_usage (skill_file text primary key, skill_key text, uses integer);
create table skill_workshop_proposals (proposal_id text primary key, status text not null, record_json text not null,
  draft_hash text);
create table skill_workshop_proposal_rollbacks (proposal_id text primary key, target_skill_file text,
  previous_content text, previous_content_hash text);
create table skill_workshop_proposal_events (event_id integer primary key, proposal_id text, payload_json text);
create table plugin_state_entries (plugin_id text not null, namespace text not null, entry_key text not null,
  value_json text, primary key (plugin_id, namespace, entry_key));
create table plugin_blob_entries (plugin_id text, namespace text, entry_key text, metadata_json text,
  primary key (plugin_id, namespace, entry_key));
create table config_machine_state (state_key text primary key, value_json text);
create table config_health_entries (config_path text primary key, value_json text);
create table backup_runs (run_id text primary key, archive_path text);
create table diagnostic_events (event_id integer primary key, payload_json text);
create table migration_runs (run_id text primary key, report_json text);
create table migration_sources (source_key text primary key, source_path text, report_json text);
create table subagent_runs (run_id text primary key, payload_json text);
"""
CODEX_SCHEMA = """
create table _sqlx_migrations (version integer primary key, description text);
create table threads (id text primary key, rollout_path text not null, cwd text not null, title text,
  first_user_message text, preview text);
"""


class Fixture:
    """A new home with OpenClaw state restored from OLD: two workspaces, two Codex homes, every classified column.
    live: admin's own state as it runs instead, under a made-up old home inside the temp dir (what preflight reads)."""

    def __init__(self, live=False):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="state-paths-test-"))
        self.old = os.path.join(self.root, "Users", "admin") if live else OLD
        self.new = self.old if live else os.path.join(self.root, "home", "sebastian")
        self.ost, self.nst = self.old + "/.openclaw", self.new + "/.openclaw"
        self.ws = {self.ost + "/workspace": self.nst + "/workspace",
                   self.ost + "/workspace-vera": self.nst + "/workspace-vera"}
        self.wm, self.wv = self.ost + "/workspace", self.ost + "/workspace-vera"
        self.cx = {a: (self.ost + "/agents/%s/agent/codex-home" % a, self.nst + "/agents/%s/agent/codex-home" % a)
                   for a in ("main", "vera")}
        self.ok, self.nk = self.ost + "/cron/jobs.json", self.nst + "/cron/jobs.json"
        self.pkg = os.path.join(self.root, "package.json")
        self.state_db = os.path.join(self.nst, "state", "openclaw.sqlite")
        self.skill_file = self.ost + "/agents/main/agent/workshop-skills/charts/SKILL.md"
        self.build()

    def codex_db(self, agent):
        return os.path.join(self.cx[agent][1], "state_5.sqlite")

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def migrate_args(self):
        return ["migrate", "--old", self.old, "--new", self.new, "--state", self.nst, "--openclaw-package", self.pkg]

    def set_version(self, v):
        with open(self.pkg, "w") as fh:
            json.dump({"name": "openclaw", "version": v}, fh)

    def q(self, sql, *args, db=None):
        con = sqlite3.connect(db or self.state_db)
        try:
            return con.execute(sql, args).fetchall()
        finally:
            con.close()

    def one(self, sql, *args, db=None):
        return self.q(sql, *args, db=db)[0][0]

    def exec(self, sql, *args, db=None, fk=True):
        con = sqlite3.connect(db or self.state_db)
        try:
            con.execute("PRAGMA foreign_keys=%s" % ("ON" if fk else "OFF"))
            con.execute(sql, args)
            con.commit()
        finally:
            con.close()

    def snapshot(self):
        """Every file under the state dir with its content hash: a refused run must leave it identical."""
        out = {}
        for d, _, files in os.walk(self.nst):
            for f in files:
                p = os.path.join(d, f)
                with open(p, "rb") as fh:
                    out[os.path.relpath(p, self.nst)] = hashlib.sha256(fh.read()).hexdigest()
        return out

    def build(self):
        for n in list(self.ws.values()) + [c[1] for c in self.cx.values()] + [os.path.dirname(self.state_db)]:
            os.makedirs(n)
        self.set_version("2026.9.7")
        con = sqlite3.connect(self.state_db)
        con.executescript(STATE_SCHEMA)
        self.fill_state(con)
        con.commit()
        con.close()
        for a, rows in (("main", [("thread-1", self.cx["main"][0] + "/sessions/2026/09/rollout-1.jsonl", self.wm,
                                   "fix %s/brain" % self.old, "look at %s/brain (%s)" % (self.old, MARK), "a preview"),
                                  ("thread-2", self.cx["main"][0] + "/sessions/2026/09/rollout-2.jsonl", "/srv/elsewhere",
                                   "other", "other", "other")]),
                        ("vera", [("thread-v", self.cx["vera"][0] + "/sessions/2026/09/rollout-v.jsonl", self.wv,
                                   "t", "m", "p")])):
            con = sqlite3.connect(self.codex_db(a))
            con.executescript(CODEX_SCHEMA)
            con.executemany("insert into _sqlx_migrations values (?,?)", [(56, "x"), (57, "y")])
            con.executemany("insert into threads values (?,?,?,?,?,?)", rows)
            con.commit()
            con.close()

    def fill_state(self, con):
        ins = lambda t, *rows: con.executemany("insert into %s values (%s)" % (t, ",".join("?" * len(rows[0]))), rows)
        ok, wm, wv = self.ok, self.wm, self.wv
        ins("schema_meta", ("primary", 19))
        ins("cron_jobs",
            (ok, "job-cmd", js({"id": "job-cmd", "name": "harvest", "payload": {"kind": "command", "argv": [
                "/usr/bin/node", self.old + "/brain/harvester/harvest.mjs", "--out", self.old + "/brain/out"]}}),
             js({"lastDiagnostics": {"entries": [{"message": "wrote %s/brain/out (%s)" % (self.old, MARK)}]}}),
             None, "rev-1", 3, 1000),
            (ok, "job-hb", js({"id": "job-hb", "payload": {"kind": "heartbeat"}}), None, "heartbeat:main", None, None, None),
            (ok, "job-rev", js({"id": "job-rev", "payload": {"kind": "agentTurn", "message": "review"}}), None,
             "skill-collection-review:main", None, None, None))
        ins("cron_run_receipts", ("r1", ok, "job-cmd", "ok"), ("r2", ok, "job-cmd", "running"), ("r3", ok, "job-hb", "ok"))
        ins("cron_job_scratch", (ok, "job-hb", sha("heartbeat content")))
        ins("task_runs",
            ("t1", "cron", js({"storeKey": ok, "jobId": "job-cmd", "summary": "ran %s/brain/harvester" % self.old}),
             "finished in %s/brain" % self.old),
            ("t2", "cron", js({"storeKey": ok, "jobId": "job-hb"}), None),
            ("t3", "cli", js({"cwd": self.old + "/brain", "note": MARK}), None))
        ins("workspace_setup_state", *[(sha(o), o, 3, 1000, 2000, 3000, 4000, 5000) for o in (wm, wv)])
        ins("workspace_generated_bootstrap_hashes", (sha(wm), "AGENTS.md", sha("agents")))
        ins("workspace_path_aliases", *[(sha(o), o, sha(o), o, 1234) for o in (wm, wv)])
        ins("exec_approvals_config", ("default", js({"version": 1, "socket": {
            "path": self.ost + "/exec-approvals.sock", "token": MARK}, "defaults": {"security": "allowlist"}}),
            self.ost + "/exec-approvals.sock"))
        ins("session_watch_cursors", ("agent:main:main", self.ost + "/agents/main/sessions/sessions.json", 7),
            ("agent:vera:main", self.ost + "/agents/vera/sessions/sessions.json", 3))
        ins("skill_usage", (wm + "/skills/weather/SKILL.md", "weather", 4),
            ("/opt/homebrew/lib/node_modules/openclaw/skills/github/SKILL.md", "github", 2))
        sd = os.path.dirname(self.skill_file)
        ins("skill_workshop_proposals",
            ("p-create", "applied", js({"id": "p-create", "status": "applied", "kind": "create",
                                        "target": {"skillDir": sd, "skillFile": self.skill_file},
                                        "evidence": "user asked about %s/brain (%s)" % (self.old, MARK)}), sha("d1")),
            ("p-update", "applied", js({"id": "p-update", "status": "applied", "kind": "update",
                                        "target": {"skillDir": wm + "/skills/weather",
                                                   "skillFile": wm + "/skills/weather/SKILL.md"}}), sha("d2")),
            ("p-stale", "stale", js({"id": "p-stale", "status": "stale", "kind": "create",
                                     "target": {"skillDir": wv + "/skills/x", "skillFile": wv + "/skills/x/SKILL.md"}}), sha("d3")),
            ("p-pending", "pending", js({"id": "p-pending", "status": "pending", "kind": "create",
                                         "target": {"skillDir": "/srv/skills/y", "skillFile": "/srv/skills/y/SKILL.md"}}), sha("d4")))
        prev = "old content naming %s/brain (%s)" % (self.old, MARK)
        ins("skill_workshop_proposal_rollbacks", ("p-create", self.skill_file, prev, sha(prev)),
            ("p-update", wm + "/skills/weather/SKILL.md", "prev", sha("prev")))
        ins("skill_workshop_proposal_events", (1, "p-create", js([{"targetSkillFile": self.skill_file}])))
        rows = []
        for o in (wm, wv):
            for ns, k, val in (("dreaming-daily-ingestion", "2026-09-01", {"n": 1}),
                               ("short-term-recall", "recall:1", {"snippet": "see %s/brain/notes (%s)" % (self.old, MARK),
                                                                  "projectKey": "path:" + o, "score": 1}),
                               ("dreaming-memory-backups", "backup:1", {"content": "backup of %s/x (%s)" % (self.old, MARK)}),
                               ("short-term-meta", "meta", {"n": 2})):
                rows.append(("memory-core", ns, sha(o) + ":" + sha(k),
                             js({"version": 1, "workspaceKey": sha(o), "workspaceDir": o, "key": k, "value": val})))
            rows.append(("memory-core", "memory-host.events", sha(o)[:24] + ":event:1:" + "0" * 16,
                         js({"type": "report", "path": o + "/memory/report.md", "note": MARK})))
            rows.append(("memory-core", "memory-host.event-cursors", sha(o)[:24] + ":cursor", js({"seq": 1})))
            rows.append(("core:memory-artifact-provenance", "workspace-files", sha(o) + ":" + sha("memory/a.md"),
                         js({"workspaceKey": sha(o), "relativePath": "memory/a.md", "trust": "own"})))
        hid = home_id(self.cx["main"][0])
        rows += [
            ("codex", "app-server-managed-threads", mt_key(hid, "thread-1"),
             js({"sourceHomeId": hid, "threadId": "thread-1",
                 "rolloutPath": self.cx["main"][0] + "/sessions/2026/09/rollout-1.jsonl"})),
            ("codex", "app-server-thread-bindings", "conversation:legacy-1",
             js({"binding": {"cwd": wm, "threadId": "thread-1", "appServerRuntimeFingerprint": js(
                 {"codexHome": self.cx["main"][0], "codex": "0.139.0"})}})),
            ("codex", "session-catalog-resident." + hid, "entry-1", js({"path": self.cx["main"][0] + "/sessions/x.jsonl"})),
            ("imessage", "imessage.recovery-cursor", self.old + "/Library/Messages/chat.db:cursor", js({"rowid": 5})),
        ]
        ins("plugin_state_entries", *rows)
        ins("plugin_blob_entries", ("memory-wiki", "compiled-cache", "c1", js({"vaultPath": self.old + "/brain/vault"})))
        ins("config_machine_state",
            ("plugins.installedIndex", js({"plugins": {
                "imessage": {"installPath": self.ost + "/npm/projects/openclaw-imessage/node_modules/@openclaw/imessage"},
                "memory-wiki": {"installPath": self.ost + "/npm/projects/memory-wiki/node_modules/@openclaw/memory-wiki"}}})),
            ("skills.curatorState", js({"lastResult": {"collectionReviews": {sha(wm): 1}}})),
            ("daemon-runtime-pin:" + sha("pin"), js({"runtimePath": "/usr/bin/node"})))
        ins("config_health_entries", (self.ost + "/openclaw.json", js({"lastPromotedGood": {"hash": sha(MARK)}})))
        ins("backup_runs", ("b1", self.old + "/backups/claw-nightly-1"))
        ins("diagnostic_events", (1, js({"msg": "config at %s/openclaw.json" % self.ost})))
        ins("migration_runs", ("m1", js({"pending": self.ost + "/extensions/imessage"})))
        ins("migration_sources", (sha("src"), wm + "/AGENTS.md", js({"workspaceKey": sha(wm)})))
        ins("subagent_runs", ("s1", js({"text": "done in %s/brain (%s)" % (self.old, MARK)})))


def run(*args, env=None):
    return subprocess.run([sys.executable, SCRIPT] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, timeout=120, env=env)


def load_script():
    """The script as a fresh module, for the in-process tests that make one step fail."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("state_paths", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Base(unittest.TestCase):
    def setUp(self):
        self.fresh()

    def fresh(self, live=False):
        """A new fixture: each subtest of a guard gets its own, so a run that wrongly commits cannot decide the next."""
        self.f = Fixture(live)
        self.addCleanup(self.f.cleanup)
        return self.f

    def run_quiet(self, *args, env=None):
        """Run the script; whatever it prints names no row value, neither home, nor a planted value."""
        p = run(*args, env=env)
        out = p.stdout + p.stderr
        for s in (MARK, OLD, self.f.old, self.f.new):
            self.assertNotIn(s, out, "printed a value (%s): %s" % (s, out))
        return p

    def migrate(self):
        p = self.run_quiet(*self.f.migrate_args())
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p

    def refuses(self, pattern, *args):
        """migrate (or the given args) exits 1 naming the reason, and leaves the state dir byte-identical."""
        before = self.f.snapshot()
        p = self.run_quiet(*(args or self.f.migrate_args()))
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertRegex(p.stderr, pattern)
        self.assertEqual(self.f.snapshot(), before, "a refused run changed the state dir")
        return p


class Migrate(Base):
    def test_cron_store_key_moves_in_all_three_tables_and_task_runs(self):   # #1-#4
        self.migrate()
        f = self.f
        for t, n in (("cron_jobs", 3), ("cron_run_receipts", 3), ("cron_job_scratch", 1)):
            self.assertEqual(f.one("select count(*) from %s where store_key=?" % t, f.nk), n, t)
            self.assertEqual(f.one("select count(*) from %s where store_key=?" % t, f.ok), 0, t)
        sk = f.q("select json_extract(detail_json,'$.storeKey') from task_runs where runtime='cron' order by task_id")
        self.assertEqual(sk, [(f.nk,), (f.nk,)])
        t1 = json.loads(f.one("select detail_json from task_runs where task_id='t1'"))
        self.assertEqual(t1["summary"], "ran %s/brain/harvester" % OLD, "run text is history")

    def test_command_argv_moves_and_its_grant_is_invalidated(self):   # #5, #25 / D6
        self.migrate()
        jj, rev, gen, upd = self.f.q("select job_json, grant_definition_revision, grant_definition_generation, "
                                     "grant_definition_updated_at from cron_jobs where job_id='job-cmd'")[0]
        self.assertEqual(json.loads(jj)["payload"]["argv"],
                         ["/usr/bin/node", self.f.new + "/brain/harvester/harvest.mjs", "--out", self.f.new + "/brain/out"])
        self.assertEqual((rev, gen, upd), (None, 4, None))
        self.assertEqual(self.f.one("select grant_definition_generation from cron_jobs where job_id='job-hb'"), None)
        state = json.loads(self.f.one("select state_json from cron_jobs where job_id='job-cmd'"))
        self.assertIn(OLD + "/brain/out", state["lastDiagnostics"]["entries"][0]["message"], "diagnostics are history (#18)")

    def test_workspace_identity_moves_with_recomputed_keys(self):   # #6, #7, #20, #21, #26 / D1
        self.migrate()
        f = self.f
        rows = f.q("select workspace_key, workspace_path, version, bootstrap_seeded_at, setup_completed_at, updated_at, "
                   "attested_at_ms, attestation_updated_at_ms from workspace_setup_state order by workspace_path")
        self.assertEqual(rows, [(sha(n), n, 3, 1000, 2000, 3000, 4000, 5000) for n in sorted(f.ws.values())])
        self.assertEqual(f.q("select workspace_key, file_name from workspace_generated_bootstrap_hashes"),
                         [(sha(f.nst + "/workspace"), "AGENTS.md")])
        aliases = f.q("select alias_key, alias_path, workspace_key, workspace_path from workspace_path_aliases "
                      "order by alias_path")
        self.assertEqual(aliases, [(sha(n), n, sha(n), n) for n in sorted(f.ws.values())])

    def test_exec_approvals_socket_moves_in_the_column_and_raw_json(self):   # #8
        self.migrate()
        raw, sp = self.f.q("select raw_json, socket_path from exec_approvals_config")[0]
        self.assertEqual(sp, self.f.nst + "/exec-approvals.sock")
        j = json.loads(raw)
        self.assertEqual(j["socket"], {"path": self.f.nst + "/exec-approvals.sock", "token": MARK})
        self.assertEqual(j["defaults"], {"security": "allowlist"})

    def test_plain_path_columns_move_and_other_rows_stay(self):   # #9, #10, #12
        self.migrate()
        f = self.f
        self.assertEqual(f.q("select watcher_store_path from session_watch_cursors order by session_key"),
                         [(f.nst + "/agents/main/sessions/sessions.json",), (f.nst + "/agents/vera/sessions/sessions.json",)])
        self.assertEqual(sorted(f.q("select skill_file from skill_usage")),
                         sorted([(f.nst + "/workspace/skills/weather/SKILL.md",),
                                 ("/opt/homebrew/lib/node_modules/openclaw/skills/github/SKILL.md",)]))
        self.assertEqual(f.q("select target_skill_file from skill_workshop_proposal_rollbacks order by proposal_id"),
                         [(f.new + f.skill_file[len(OLD):],), (f.nst + "/workspace/skills/weather/SKILL.md",)])

    def test_workshop_targets_move_and_nothing_else_in_the_record(self):   # #11, #27-#29
        before = {p: json.loads(r) for p, r in self.f.q("select proposal_id, record_json from skill_workshop_proposals")}
        self.migrate()
        f = self.f
        after = {p: json.loads(r) for p, r in f.q("select proposal_id, record_json from skill_workshop_proposals")}
        for pid, rec in before.items():
            want = json.loads(json.dumps(rec))
            for k in ("skillDir", "skillFile"):
                if want["target"][k].startswith(OLD + "/"):
                    want["target"][k] = f.new + want["target"][k][len(OLD):]
            self.assertEqual(after[pid], want, pid)
        self.assertIn(OLD + "/brain", after["p-create"]["evidence"], "evidence text is history (#29)")
        prev, h = f.q("select previous_content, previous_content_hash from skill_workshop_proposal_rollbacks "
                      "where proposal_id='p-create'")[0]
        self.assertEqual(sha(prev), h, "previous_content is never rewritten (#27)")
        self.assertIn(f.skill_file, f.one("select payload_json from skill_workshop_proposal_events"), "events are history (#28)")
        self.assertEqual(f.q("select proposal_id, status from skill_workshop_proposals order by proposal_id"),
                         [("p-create", "applied"), ("p-pending", "pending"), ("p-stale", "stale"), ("p-update", "applied")])

    def test_memory_core_keys_are_recomputed_for_the_new_workspace(self):   # #13, #22 / D2
        self.migrate()
        f = self.f
        for o, n in f.ws.items():
            rows = f.q("select namespace, entry_key, value_json from plugin_state_entries where plugin_id='memory-core' "
                       "and namespace not like 'memory-host.%' and substr(entry_key,1,64)=?", sha(n))
            self.assertEqual(len(rows), 4, n)
            for ns, k, v in rows:
                j = json.loads(v)
                self.assertEqual(k, sha(n) + ":" + sha(j["key"]), ns)
                self.assertEqual((j["workspaceKey"], j["workspaceDir"]), (sha(n), n), ns)
                if ns == "short-term-recall":
                    self.assertEqual(j["value"]["projectKey"], "path:" + n)
                    self.assertIn(OLD + "/brain/notes", j["value"]["snippet"], "recall snippets are history (#30)")
                if ns == "dreaming-memory-backups":
                    self.assertIn(OLD + "/x", j["value"]["content"], "backup content is history (#30)")
            self.assertEqual(f.one("select count(*) from plugin_state_entries where substr(entry_key,1,24)=?", sha(o)[:24]), 0)

    def test_memory_host_and_provenance_keys_are_recomputed(self):   # #23 / D3, D4
        self.migrate()
        f = self.f
        for o, n in f.ws.items():
            ev = f.q("select entry_key, value_json from plugin_state_entries where namespace='memory-host.events' "
                     "and substr(entry_key,1,24)=?", sha(n)[:24])
            self.assertEqual([k for k, _ in ev], [sha(n)[:24] + ":event:1:" + "0" * 16])
            self.assertEqual(json.loads(ev[0][1])["path"], o + "/memory/report.md", "event payloads are history (#30)")
            self.assertEqual(f.q("select entry_key from plugin_state_entries where namespace='memory-host.event-cursors' "
                                 "and substr(entry_key,1,24)=?", sha(n)[:24]), [(sha(n)[:24] + ":cursor",)])
            pv = f.q("select entry_key, value_json from plugin_state_entries where plugin_id='core:memory-artifact-provenance' "
                     "and substr(entry_key,1,64)=?", sha(n))
            self.assertEqual([k for k, _ in pv], [sha(n) + ":" + sha("memory/a.md")])
            self.assertEqual(json.loads(pv[0][1]), {"workspaceKey": sha(n), "relativePath": "memory/a.md", "trust": "own"})

    def test_codex_plugin_state_moves_with_the_new_home_id(self):   # #14, #15, #24 / D5
        self.migrate()
        f = self.f
        o, n = f.cx["main"]
        nid = home_id(n)
        k, v = f.q("select entry_key, value_json from plugin_state_entries where namespace='app-server-managed-threads'")[0]
        self.assertEqual(k, mt_key(nid, "thread-1"))
        self.assertEqual(json.loads(v), {"sourceHomeId": nid, "threadId": "thread-1",
                                         "rolloutPath": n + "/sessions/2026/09/rollout-1.jsonl"})
        b = json.loads(f.one("select value_json from plugin_state_entries where namespace='app-server-thread-bindings'"))
        self.assertEqual(b["binding"]["cwd"], f.nst + "/workspace")
        self.assertEqual(json.loads(b["binding"]["appServerRuntimeFingerprint"]), {"codexHome": n, "codex": "0.139.0"})
        self.assertEqual(f.one("select count(*) from plugin_state_entries where namespace=?",
                               "session-catalog-resident." + home_id(o)), 1, "the old catalog cache stays (#31)")
        self.assertEqual(f.one("select count(*) from plugin_state_entries where plugin_id='imessage' and entry_key=?",
                               OLD + "/Library/Messages/chat.db:cursor"), 1, "the iMessage cursor stays (#32)")

    def test_codex_threads_move_in_each_codex_home(self):   # #16, #17, #51
        self.migrate()
        f = self.f
        main = f.q("select id, rollout_path, cwd, title from threads order by id", db=f.codex_db("main"))
        self.assertEqual(main, [("thread-1", f.cx["main"][1] + "/sessions/2026/09/rollout-1.jsonl", f.nst + "/workspace",
                                 "fix %s/brain" % OLD),
                                ("thread-2", f.cx["main"][1] + "/sessions/2026/09/rollout-2.jsonl", "/srv/elsewhere", "other")])
        self.assertEqual(f.q("select rollout_path, cwd from threads", db=f.codex_db("vera")),
                         [(f.cx["vera"][1] + "/sessions/2026/09/rollout-v.jsonl", f.nst + "/workspace-vera")])

    def test_history_and_config_health_stay(self):   # #18, #19, #33-#42 (and N3: config_health_entries untouched)
        f = self.f
        tables = ("config_health_entries", "plugin_blob_entries", "config_machine_state", "backup_runs",
                  "diagnostic_events", "migration_runs", "migration_sources", "subagent_runs", "skill_workshop_proposal_events")
        before = {t: f.q("select * from %s order by 1" % t) for t in tables}
        self.migrate()
        for t in tables:
            self.assertEqual(f.q("select * from %s order by 1" % t), before[t], t)
        self.assertEqual(f.one("select config_path from config_health_entries"), f.ost + "/openclaw.json")

    def test_row_counts_and_integrity_hold(self):
        f = self.f
        dbs = [f.state_db, f.codex_db("main"), f.codex_db("vera")]
        names = lambda db: [r[0] for r in f.q("select name from sqlite_master where type='table'", db=db)]
        before = {db: {t: f.one('select count(*) from "%s"' % t, db=db) for t in names(db)} for db in dbs}
        self.migrate()
        for db in dbs:
            self.assertEqual({t: f.one('select count(*) from "%s"' % t, db=db) for t in names(db)}, before[db], db)
            self.assertEqual(f.q("pragma integrity_check", db=db), [("ok",)])

    def test_the_record_for_the_check_is_written(self):
        p = self.migrate()
        self.assertRegex(p.stdout, r"state-paths: OK")
        path = os.path.join(self.f.nst, "rehome-state-paths.json")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        with open(path) as fh:
            rec = json.load(fh)
        self.assertEqual(rec["old_home"], OLD)
        self.assertEqual(rec["new_home"], self.f.new)
        self.assertEqual(sorted(rec["old_workspace_keys"]), sorted(sha(o) for o in self.f.ws))
        self.assertEqual(sorted(rec["old_codex_home_ids"]), sorted(home_id(o) for o, _ in self.f.cx.values()))
        self.assertEqual(rec["proposal_statuses"], {"p-create": "applied", "p-update": "applied", "p-stale": "stale",
                                                    "p-pending": "pending"})
        self.assertEqual((rec["workspace_setup_rows"], rec["workspace_alias_rows"], rec["exec_approvals_rows"]), (2, 2, 1))
        self.assertEqual((rec["cron_jobs"], rec["cron_jobs_total"]), (3, 3))

    def test_statuses_come_from_record_json_when_the_table_has_no_status_column(self):
        self.f.exec("alter table skill_workshop_proposals drop column status")
        self.migrate()
        with open(os.path.join(self.f.nst, "rehome-state-paths.json")) as fh:
            self.assertEqual(json.load(fh)["proposal_statuses"]["p-stale"], "stale")

    def test_a_setup_row_without_a_path_is_left_alone_and_passes_the_check(self):
        self.f.exec("insert into workspace_setup_state (workspace_key, version) values ('no-path', 1)")
        self.migrate()
        self.assertEqual(self.f.q("select workspace_path from workspace_setup_state where workspace_key='no-path'"), [(None,)])
        Check.rebuild_installed_index(self.f)
        p = self.run_quiet("check", "--home", self.f.new, "--cron-total", "3")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_a_failure_after_the_commit_says_so(self):
        # In-process, with the record's rename made to fail once every database has committed.
        mod = load_script()
        real_replace = mod.os.replace

        def boom(src, dst):
            raise OSError("simulated")
        mod.os.replace = boom
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                rc = mod.main(self.f.migrate_args())
        finally:
            mod.os.replace = real_replace
        self.assertEqual(rc, 3, "a partial commit has its own exit status")
        self.assertRegex(err.getvalue(), r"every database committed, but then OSError: simulated")
        self.assertNotIn("nothing was committed", err.getvalue())
        self.assertEqual(self.f.one("select count(*) from cron_jobs where store_key=?", self.f.nk), 3)

    def test_a_wal_database_migrates_and_checkpoints(self):
        for db in (self.f.state_db, self.f.codex_db("main")):
            con = sqlite3.connect(db)
            self.assertEqual(con.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            con.close()
        self.migrate()
        self.assertEqual(self.f.one("select count(*) from cron_jobs where store_key=?", self.f.nk), 3)
        self.assertEqual(os.path.getsize(self.f.state_db + "-wal") if os.path.exists(self.f.state_db + "-wal") else 0, 0)


class Refusals(Base):
    def test_only_openclaw_2026_9_7(self):
        self.f.set_version("2026.9.8")
        self.refuses(r"pinned to OpenClaw 2026\.9\.7, found 2026\.9\.8")
        os.remove(self.f.pkg)
        self.refuses(r"cannot read the OpenClaw version")

    def test_only_state_schema_19(self):
        self.f.exec("update schema_meta set schema_version=20")
        self.refuses(r"state schema is 20, not 19")

    def test_only_codex_migration_57(self):
        self.f.exec("insert into _sqlx_migrations values (58, 'z')", db=self.f.codex_db("vera"))
        self.refuses(r"codex-home/state_5\.sqlite: migration level is 58, not 57")

    def test_state_a_gateway_doctor_or_cli_touched_is_refused(self):
        f = self.f
        nh = sha(f.nst + "/workspace")
        cases = [
            ("insert into cron_jobs (store_key, job_id, job_json, declaration_key) values (?, 'seeded', '{}', 'heartbeat:main')",
             (f.nk,), r"cron_jobs\.store_key already has rows under the new cron key"),
            ("insert into workspace_path_aliases values (?,?,?,?,1)", (nh, f.nst + "/workspace", nh, f.nst + "/workspace"),
             r"workspace_path_aliases already has rows for a workspace under the new home"),
            ("insert into plugin_state_entries values ('memory-core','short-term-meta',?,'{}')", (nh + ":x",),
             r"plugin_state_entries already has keys derived from a workspace under the new home"),
            ("insert into skill_usage values (?, 'a', 1)", (f.nst + "/workspace/skills/a/SKILL.md",),
             r"skill_usage\.skill_file already names the new home"),
            ("update session_watch_cursors set watcher_store_path=? where session_key='agent:vera:main'",
             (f.nst + "/agents/vera/sessions/sessions.json",), r"session_watch_cursors\.watcher_store_path already names the new home"),
            ("insert into config_health_entries values (?, '{}')", (f.nst + "/openclaw.json",),
             r"config_health_entries\.config_path already names the new home"),
            ("insert into exec_approvals_config values ('other', '{}', ?)", (f.nst + "/exec-approvals.sock",),
             r"exec_approvals_config\.socket_path already names the new home"),
            ("insert into plugin_state_entries values ('codex', ?, 'e', '{}')", ("session-catalog-resident." + home_id(f.cx["vera"][1]),),
             r"plugin_state_entries already has Codex rows for a Codex home under the new home"),
        ]
        orig = os.path.join(f.root, "orig.sqlite")
        shutil.copy(f.state_db, orig)
        for sql, args, pattern in cases:
            with self.subTest(pattern=pattern):
                shutil.copy(orig, f.state_db)   # each case starts from the pristine state
                f.exec(sql, *args)
                self.refuses(pattern)

    def test_codex_threads_already_under_the_new_home_are_refused(self):
        self.f.exec("update threads set cwd=? where id='thread-v'", self.f.nst + "/workspace-vera", db=self.f.codex_db("vera"))
        self.refuses(r"codex-home/state_5\.sqlite: threads already name the new home")

    def test_a_second_run_is_refused(self):
        self.migrate()
        self.refuses(r"rehome-state-paths\.json exists: state-paths already ran on this state")
        os.remove(os.path.join(self.f.nst, "rehome-state-paths.json"))
        self.refuses(r"already has rows under the new cron key")

    def test_a_collision_with_a_fresh_workspace_row_is_refused_before_any_write(self):   # §3: the drill's state
        f = self.f
        n = f.nst + "/workspace"
        f.exec("insert into workspace_setup_state (workspace_key, workspace_path, version) values (?,?,1)", sha(n), n)
        self.refuses(r"workspace_setup_state already has rows for a workspace under the new home")

    def test_a_constraint_failure_mid_rewrite_rolls_everything_back(self):
        # No state-DB triggers exist upstream; one stands in here for any write that fails half-way.
        self.f.exec("create trigger boom before update on skill_usage begin select raise(abort, 'simulated'); end")
        self.refuses(r"failed: IntegrityError: simulated.*nothing was committed")

    def test_a_write_that_changes_row_counts_fails_the_post_check(self):
        # A trigger stands in for any side effect that adds or removes rows during the rewrite.
        self.f.exec("create trigger grow after update on skill_usage begin "
                    "insert into diagnostic_events (payload_json) values ('{}'); end")
        self.refuses(r"row counts changed")
        self.f.exec("drop trigger grow")
        self.f.exec("create table zz_log (x)", db=self.f.codex_db("vera"))
        self.f.exec("create trigger grow after update on threads begin insert into zz_log values (1); end",
                    db=self.f.codex_db("vera"))
        self.refuses(r"agents/vera/agent/codex-home/state_5\.sqlite: row counts changed")

    def test_a_missing_or_symlinked_workspace_is_refused(self):
        shutil.rmtree(self.f.nst + "/workspace-vera")
        self.refuses(r"\.openclaw/workspace-vera: a workspace of the old state is missing under the new home, or is not canonical")
        os.symlink(self.f.nst + "/workspace", self.f.nst + "/workspace-vera")
        self.refuses(r"\.openclaw/workspace-vera: a workspace of the old state is missing")

    def test_a_symlinked_codex_home_is_refused(self):
        real = os.path.join(self.f.root, "elsewhere")
        os.rename(self.f.cx["vera"][1], real)
        os.symlink(real, self.f.cx["vera"][1])
        self.refuses(r"\.openclaw/agents/vera/agent/codex-home: a Codex home is not canonical")

    def test_a_database_another_process_holds_is_refused(self):
        # Snapshot first: reading the file here would drop this process's POSIX locks on it.
        before = self.f.snapshot()
        con = sqlite3.connect(self.f.codex_db("main"), isolation_level=None)
        con.execute("begin immediate")
        try:
            p = self.run_quiet(*self.f.migrate_args())
        finally:
            con.execute("rollback")
            con.close()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertRegex(p.stderr, r"agents/main/agent/codex-home/state_5\.sqlite: cannot take the write lock "
                                   r"\(database is locked\): is a gateway, doctor or CLI running")
        self.assertEqual(self.f.snapshot(), before)

    def test_a_non_prefix_old_home_value_in_a_rewrite_column_fails_the_post_check(self):   # §8.4
        self.f.exec("insert into skill_usage values (?, 'b', 1)", "/x" + OLD + "/skills/b/SKILL.md")
        self.refuses(r"skill_usage\.skill_file: changed 1 row\(s\), expected 2")

    def test_an_old_home_left_in_a_functional_json_field_fails_the_post_check(self):
        f = self.f
        f.exec("insert into task_runs values ('t9', 'cron', ?, null)", js({"storeKey": OLD + "/elsewhere/jobs.json"}))
        self.refuses(r"the old home is left in task_runs storeKey")

    def test_an_old_home_in_a_functional_memory_field_fails_the_post_check(self):   # §8.4
        f = self.f
        o = f.wm
        f.exec("insert into plugin_state_entries values ('memory-core','short-term-recall',?,?)", sha(o) + ":" + sha("r2"),
               js({"version": 1, "workspaceKey": sha(o), "workspaceDir": o, "key": "r2",
                   "value": {"snippet": "s", "source": OLD + "/brain/x.md"}}))
        self.refuses(r"plugin_state_entries memory-core/short-term-recall: the old home in a functional field")

    def test_an_unclassified_table_or_column_naming_the_old_home_fails_the_post_check(self):   # §8.4
        f = self.f
        f.exec("create table zz_new_feature (p text)")
        f.exec("insert into zz_new_feature values (?)", OLD + "/x")
        self.refuses(r"zz_new_feature\.p names the old home in 1 row\(s\): unclassified, or not rewritten")
        f.exec("drop table zz_new_feature")
        f.exec("alter table cron_jobs add column note text")
        f.exec("update cron_jobs set note=? where job_id='job-hb'", OLD + "/x")
        self.refuses(r"cron_jobs\.note names the old home in 1 row\(s\)")

    def test_a_lease_left_in_the_restored_state_still_refuses(self):
        # Only the preflight drops the running gateway's leases from its copy: a backup has none, so one in the state
        # being migrated means something unexpected, and the migration stays strict.
        self.f.exec("create table agent_database_leases (path text primary key, owner_pid integer)")
        self.f.exec("insert into agent_database_leases values (?, 1)", OLD + "/.openclaw/agents/main/agent/openclaw-agent.sqlite")
        self.refuses(r"agent_database_leases\.path names the old home in 1 row\(s\)")

    def test_an_unclassified_codex_column_naming_the_old_home_fails_the_post_check(self):
        db = self.f.codex_db("main")
        self.f.exec("create table thread_spawn_edges (id text, cwd text)", db=db)
        self.f.exec("insert into thread_spawn_edges values ('e', ?)", OLD + "/brain", db=db)
        self.refuses(r"codex-home/state_5\.sqlite: thread_spawn_edges\.cwd names the old home", )

    def test_a_non_prefix_codex_thread_path_fails_the_post_check(self):
        self.f.exec("update threads set cwd=? where id='thread-2'", "/srv" + OLD, db=self.f.codex_db("main"))
        self.refuses(r"codex-home/state_5\.sqlite: threads\.cwd: changed 1 row\(s\), expected 2")

    def test_a_foreign_key_violation_fails_the_post_check(self):
        self.f.exec("insert into workspace_generated_bootstrap_hashes values (?, 'X.md', 'h')", sha("/nowhere"), fk=False)
        self.refuses(r"state/openclaw\.sqlite: foreign_key_check found violations")

    def test_a_workspace_alias_that_is_not_a_plain_self_alias_is_refused(self):
        o = self.f.wv
        self.f.exec("insert into workspace_path_aliases values (?,?,?,?,1)", sha(o + "-link"), o + "-link", sha(o), o)
        self.refuses(r"workspace_path_aliases: a workspace has aliases other than its plain self-alias")

    # Fix round 1, I2: one refusal per rewrite guard. Each input is one the rewrite without that guard would get wrong,
    # with nothing later to stop it (or a later check with another reason): each test fails when its guard is removed.
    def test_a_task_run_whose_storeKey_member_is_not_the_one_compact_member_is_refused(self):   # #4
        f = self.f
        for dj in (js({"storeKey": f.ok, "previous": {"storeKey": f.ok}}),   # twice: the nested history would move too
                   '{"storeKey": %s}' % js(f.ok)):                            # not compact: nothing would move
            with self.subTest(members=dj.count('"storeKey"')):
                self.fresh().exec("insert into task_runs values ('t8', 'cron', ?, null)", dj)
                self.refuses(r"task_runs\.detail_json: the storeKey member is not the one compact member the rewrite expects")

    def test_a_command_automation_whose_argv_element_appears_elsewhere_is_refused(self):   # #5
        a = OLD + "/brain/run.sh"
        self.f.exec("insert into cron_jobs (store_key, job_id, job_json) values (?, 'job-x', ?)", self.f.ok,
                    js({"id": "job-x", "name": a, "payload": {"kind": "command", "argv": [a]}}))
        self.refuses(r"cron_jobs\.job_json: the old home outside payload\.argv elements")

    def test_an_exec_approvals_row_that_is_not_the_one_default_socket_is_refused(self):   # #8
        f = self.f
        osock = f.ost + "/exec-approvals.sock"
        raw = {"version": 1, "socket": {"path": osock, "token": MARK}}
        for what, sql, args in (
                ("socket token twice", "update exec_approvals_config set raw_json=?",
                 (js(dict(raw, previousSocket={"path": osock})),)),
                ("another socket in the column", "update exec_approvals_config set raw_json=?, socket_path=?",
                 (js(raw), f.ost + "/custom.sock"))):
            with self.subTest(what=what):
                self.fresh().exec(sql, *args)
                self.refuses(r"exec_approvals_config: socket_path and \$\.socket\.path are not the one default socket "
                             r"of the old state dir")

    def test_a_proposal_whose_evidence_equals_its_skill_dir_is_refused(self):   # #11, #29: the review's probe
        sd = os.path.dirname(self.f.skill_file)
        self.f.exec("update skill_workshop_proposals set record_json=? where proposal_id='p-create'",
                    js({"id": "p-create", "status": "applied", "kind": "create",
                        "target": {"skillDir": sd, "skillFile": self.f.skill_file}, "evidence": sd}))
        self.refuses(r"skill_workshop_proposals\.record_json: the target rewrite would touch other fields")

    def test_a_memory_core_key_whose_suffix_is_not_sha256_of_its_key_is_refused(self):   # #22 / D2
        o = self.f.wm
        self.f.exec("insert into plugin_state_entries values ('memory-core','short-term-meta',?,?)", sha(o) + ":" + sha("other"),
                    js({"version": 1, "workspaceKey": sha(o), "workspaceDir": o, "key": "k9", "value": {"n": 1}}))
        self.refuses(r"plugin_state_entries memory-core/short-term-meta: a row is not sha256\(workspace\):sha256\(key\) "
                     r"for an old workspace \(D2\)")

    def test_a_memory_core_row_naming_its_workspace_in_another_field_is_refused(self):   # #13
        o = self.f.wm
        self.f.exec("insert into plugin_state_entries values ('memory-core','short-term-meta',?,?)", sha(o) + ":" + sha("k9"),
                    js({"version": 1, "workspaceKey": sha(o), "workspaceDir": o, "key": "k9", "value": {"root": o}}))
        self.refuses(r"plugin_state_entries memory-core/short-term-meta: the rewrite would touch other fields")

    def test_a_managed_thread_whose_key_is_not_derived_from_its_home_and_thread_is_refused(self):   # #24 / D5
        hid = home_id(self.f.cx["main"][0])
        self.f.exec("insert into plugin_state_entries values ('codex','app-server-managed-threads',?,?)",
                    mt_key(hid, "thread-other"), js({"sourceHomeId": hid, "threadId": "thread-9"}))
        self.refuses(r"plugin_state_entries codex managed thread: a key is not derived from an old Codex home \(D5\)")

    def test_a_codex_binding_naming_its_cwd_in_another_field_is_refused(self):   # #14
        wm = self.f.wm
        self.f.exec("insert into plugin_state_entries values ('codex','app-server-thread-bindings','conversation:legacy-2',?)",
                    js({"binding": {"cwd": wm, "threadId": "thread-2"}, "lastCwd": wm}))
        self.refuses(r"plugin_state_entries codex binding: the old home outside binding\.cwd and "
                     r"binding\.appServerRuntimeFingerprint")

    def test_a_plugin_key_still_derived_from_an_old_path_fails_the_post_check(self):   # §8.2 step 8
        # A plugin the rewrite does not handle, keyed by an old workspace's hash or the old cron key's: nothing moves it.
        for what, prefix in (("workspace", sha(OLD + "/.openclaw/workspace")[:24]), ("cron key", sha(OLD + "/.openclaw/cron/jobs.json")[:24])):
            with self.subTest(what=what):
                self.fresh().exec("insert into plugin_state_entries values ('zz-plugin','zz',?,'{}')", prefix + ":x")
                self.refuses(r"plugin_state_entries: 1 key\(s\) still derived from an old path")

    def test_a_commit_that_fails_after_an_earlier_database_committed_says_so(self):   # §8.1 item 4
        # In-process: the last database's COMMIT fails once the state and the first Codex database have committed.
        mod = load_script()
        real_open = mod.open_rw

        class FailingCommit:
            def __init__(self, con):
                self.con = con

            def __getattr__(self, name):
                return getattr(self.con, name)

            def execute(self, sql, *args):
                if sql == "COMMIT":
                    raise sqlite3.OperationalError("simulated")
                return self.con.execute(sql, *args)

        def open_failing(path, label):
            con = real_open(path, label)
            return FailingCommit(con) if "/vera/" in path else con
        mod.open_rw = open_failing
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            rc = mod.main(self.f.migrate_args())
        self.assertEqual(rc, 3, "a partial commit has its own exit status (import.sh points at rehome.sh rollback)")
        self.assertRegex(err.getvalue(), r"COMMIT failed \(OperationalError\) after 2 of 3 database\(s\) committed: "
                                         r"the state is inconsistent")
        self.assertNotIn("nothing was committed", err.getvalue())
        for s in (MARK, OLD, self.f.new):
            self.assertNotIn(s, err.getvalue())
        self.assertEqual([n for n in os.listdir(self.f.nst) if n.startswith("rehome-state-paths")], [], "a record was left")
        self.assertEqual(self.f.one("select count(*) from cron_jobs where store_key=?", self.f.nk), 3, "the state committed")
        self.assertEqual(self.f.one("select count(*) from threads where substr(cwd,1,?)=?", len(OLD) + 1, OLD + "/",
                                    db=self.f.codex_db("vera")), 1, "the last Codex database did not")
        self.refuses(r"cron_jobs\.store_key already has rows under the new cron key: a gateway, doctor or CLI already "
                     r"ran on this state, or an earlier state-paths migrate committed part of its work")


class Check(Base):
    def setUp(self):
        super().setUp()
        self.migrate()
        self.rebuild_installed_index(self.f)

    @staticmethod
    def rebuild_installed_index(f):
        """The first start rebuilds the installed-plugin index under the new home, all but the iMessage record (§9 U4)."""
        f.exec("update config_machine_state set value_json=? where state_key='plugins.installedIndex'", js({"plugins": {
            "imessage": {"installPath": f.ost + "/npm/projects/openclaw-imessage/node_modules/@openclaw/imessage"},
            "memory-wiki": {"installPath": f.nst + "/npm/projects/memory-wiki/node_modules/@openclaw/memory-wiki"}}}))

    def check(self, total="3", *extra):
        return self.run_quiet("check", "--home", self.f.new, "--cron-total", total, *extra)

    def fails(self, pattern, total="3"):
        p = self.check(total)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertRegex(p.stdout + p.stderr, pattern)

    def test_passes_after_the_migration_and_changes_nothing(self):
        before = self.f.snapshot()
        p = self.check()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertRegex(p.stdout, r"state-paths check: OK")
        self.assertEqual(self.f.snapshot(), before)

    def test_the_automation_count_must_equal_the_recorded_one(self):
        self.fails(r"FAIL automations: the cron store holds 3, admin's gateway listed 21", total="21")

    def test_cron_rows_under_another_store_key_fail(self):   # review I1: what the gateway sees, not what was written
        other = self.f.root + "/elsewhere/cron/jobs.json"
        orig = os.path.join(self.f.root, "orig.sqlite")
        shutil.copy(self.f.state_db, orig)
        # The same row count, one row under another key: the count under the migrated key alone would pass.
        self.f.exec("update cron_jobs set store_key=? where job_id='job-rev'", other)
        self.fails(r"FAIL automations: 1 cron_jobs row\(s\) outside the migrated cron store key\n", total="2")
        # A gateway under another store key seeds its declarations there; the migrated rows stay where they were.
        shutil.copy(orig, self.f.state_db)
        self.f.exec("insert into cron_jobs (store_key, job_id, job_json, declaration_key) values (?, 'seeded', '{}', "
                    "'heartbeat:main')", other)
        self.fails(r"FAIL automations: 1 cron_jobs row\(s\) outside the migrated cron store key; "
                   r"cron_jobs has 4 row\(s\), the migration left 3\n")

    def test_the_cron_row_total_must_equal_the_migrated_one(self):
        self.f.exec("delete from cron_jobs where job_id='job-rev'")
        self.fails(r"FAIL automations: cron_jobs has 2 row\(s\), the migration left 3\n", total="2")

    def test_no_duplicate_cron_declarations(self):
        self.f.exec("insert into cron_jobs (store_key, job_id, job_json, declaration_key) values (?, 'seeded', '{}', "
                    "'heartbeat:main')", self.f.nk)
        self.fails(r"FAIL cron declarations: 1 declaration_key\(s\) duplicated in the active cron store", total="4")

    def test_no_fresh_workspace_rows(self):
        n = self.f.nst + "/workspace-x"
        self.f.exec("insert into workspace_setup_state (workspace_key, workspace_path, version) values (?,?,1)", sha(n), n)
        self.fails(r"FAIL workspace identity: workspace_setup_state has 3 row\(s\), the migration left 2")

    def test_workspace_rows_and_aliases_under_the_new_home_only(self):
        o = self.f.wm
        self.f.exec("insert into workspace_path_aliases values (?,?,?,?,1)", sha(o), o, sha(o), o)
        self.fails(r"FAIL workspace identity: workspace_path_aliases has 3 row\(s\), the migration left 2; 1 not under the new home")

    def test_the_exec_approvals_socket_under_the_new_home(self):
        self.f.exec("update exec_approvals_config set socket_path='/tmp/x.sock'")
        self.fails(r"FAIL exec-approvals socket: 1 row\(s\) not under the new home")

    def test_no_plugin_state_keys_under_an_old_workspace_hash(self):
        self.f.exec("insert into plugin_state_entries values ('memory-core','short-term-meta',?,'{}')", sha(self.f.wv) + ":x")
        self.fails(r"FAIL plugin state keys: 1 key\(s\) derived from an old workspace path")

    def test_workshop_proposal_statuses_unchanged(self):
        self.f.exec("update skill_workshop_proposals set status='stale' where proposal_id='p-create'")
        self.fails(r"FAIL Workshop proposals: 1 of 4 changed status since the migration")
        self.f.exec("delete from skill_workshop_proposals where proposal_id='p-create'")
        self.fails(r"FAIL Workshop proposals: 1 of 4 missing")

    def test_a_new_proposal_after_the_migration_is_fine(self):
        self.f.exec("insert into skill_workshop_proposals values ('p-new','pending','{}',null)")
        self.assertEqual(self.check().returncode, 0)

    def test_the_installed_plugin_index_names_the_old_home_only_for_imessage(self):   # §9 U4
        f = self.f
        rebuilt = {"plugins": {
            "imessage": {"installPath": f.ost + "/npm/projects/openclaw-imessage/node_modules/@openclaw/imessage"},
            "memory-wiki": {"installPath": f.nst + "/npm/projects/memory-wiki"}},
            "sourceAdmissions": {f.ost + "/npm/projects/openclaw-imessage/x": {"signature": "s"}}}
        f.exec("update config_machine_state set value_json=? where state_key='plugins.installedIndex'", js(rebuilt))
        self.assertEqual(self.check().returncode, 0)
        rebuilt["plugins"]["memory-wiki"]["installPath"] = f.ost + "/npm/projects/memory-wiki"
        f.exec("update config_machine_state set value_json=? where state_key='plugins.installedIndex'", js(rebuilt))
        self.fails(r"FAIL history allow-list: config_machine_state plugins\.installedIndex names the old home outside "
                   r"the iMessage install record")

    def test_the_history_allow_list_still_holds(self):
        self.f.exec("create table audit_events (id integer primary key, payload text)")
        self.f.exec("insert into audit_events (payload) values (?)", "doctor saw " + OLD + "/x")
        self.fails(r"FAIL history allow-list: audit_events\.payload names the old home in 1 row\(s\)")

    def test_a_state_never_migrated_fails(self):
        os.remove(os.path.join(self.f.nst, "rehome-state-paths.json"))
        self.fails(r"FAIL record: no rehome-state-paths\.json: state-paths migrate never completed on this state")

    def test_a_bad_count_is_a_usage_error(self):
        for bad in ("", "x", "-1", "2.5"):
            p = run("check", "--home", self.f.new, "--cron-total", bad)
            self.assertEqual(p.returncode, 2, bad)


class Preflight(Base):
    """preflight --home: admin's live state, read-only, while production runs (fix round 1, I3): the runtime, the version
    pin, and a dry run of the migration on backup-API copies under a scratch new home, removed afterwards."""

    def setUp(self):
        self.fresh(live=True)
        self.tmp = os.path.join(self.f.root, "tmp")   # TMPDIR: the scratch new home goes here
        os.makedirs(self.tmp)

    def preflight(self, *extra):
        return self.run_quiet("preflight", "--home", self.f.old, "--openclaw-package", self.f.pkg, *extra,
                              env=dict(os.environ, TMPDIR=self.tmp))

    def passes(self):
        before = self.f.snapshot()
        p = self.preflight()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertRegex(p.stdout, r"state-paths preflight: OK")
        self.assertEqual(self.f.snapshot(), before, "preflight changed the live state")
        self.assertEqual(os.listdir(self.tmp), [], "the scratch copy was left behind")
        return p

    def refuses(self, pattern, *args):
        before = self.f.snapshot()
        p = self.preflight()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertRegex(p.stderr, r"state-paths preflight: refused: .*" + pattern)
        self.assertRegex(p.stderr, r"fix it while production runs")
        self.assertEqual(self.f.snapshot(), before, "preflight changed the live state")
        self.assertEqual(os.listdir(self.tmp), [], "the scratch copy was left behind")
        return p

    def test_passes_on_the_live_state_and_changes_nothing(self):
        p = self.passes()
        self.assertRegex(p.stdout, r"python 3\.\d+ with sqlite3, OpenClaw 2026\.9\.7, a dry run of the migration on "
                                   r"copies of the live databases passed")

    def test_the_running_gateways_leases_do_not_stop_it(self):
        # Production showed it: the live gateway holds agent-database leases naming its own home. They are transient and
        # empty in a backup (classification, row notes), so the switch's import never sees them; the dry run drops them
        # from its copy the way a backup does, and the live rows stay.
        self.f.exec("create table agent_database_leases (path text primary key, owner_pid integer)")
        self.f.exec("create table state_leases (lease_key text primary key, owner_pid integer)")
        self.f.exec("insert into agent_database_leases values (?, 1)", self.f.ost + "/agents/main/agent/openclaw-agent.sqlite")
        self.f.exec("insert into state_leases values ('gateway', 1)")
        self.passes()
        self.assertEqual(self.f.q("select count(*) from agent_database_leases"), [(1,)])

    def test_reads_live_databases_in_use(self):
        # The gateway runs while prepare does: WAL databases, a writer holding its transaction open on the state; a Codex
        # database in WAL mode that nothing has open (no -wal: a read-only open could neither create one nor do without).
        for db in (self.f.state_db, self.f.codex_db("main")):
            con = sqlite3.connect(db)
            con.execute("pragma journal_mode=wal")
            con.close()

        def files():
            names = sorted(os.path.relpath(os.path.join(d, n), self.f.nst) for d, _, ns in os.walk(self.f.nst) for n in ns)
            mains = {}
            for db in (self.f.state_db, self.f.codex_db("main")):
                with open(db, "rb") as fh:
                    mains[db] = hashlib.sha256(fh.read()).hexdigest()
            return names, mains
        before = files()   # before the writer locks: reading a file here would drop this process's locks on it
        con = sqlite3.connect(self.f.state_db, isolation_level=None)
        con.execute("begin immediate")
        con.execute("insert into diagnostic_events (payload_json) values ('{}')")
        try:
            p = self.preflight()
        finally:
            con.execute("rollback")
            con.close()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(os.listdir(self.tmp), [])
        names, mains = files()
        self.assertEqual(mains, before[1], "a live database file changed")
        self.assertEqual([n for n in names if n not in before[0] and "openclaw.sqlite-" not in n], [],
                         "preflight created files next to a live database")

    def test_a_committed_change_still_in_the_wal_is_seen(self):
        # A gateway's committed write that no checkpoint has copied into the main file yet: only a locking, WAL-aware read
        # (mode=ro) sees it; the dry run must, and refuses here on what it wrote.
        con = sqlite3.connect(self.f.state_db, isolation_level=None)
        try:
            con.execute("pragma journal_mode=wal")
            con.execute("pragma wal_autocheckpoint=0")
            con.execute("create table zz_new_feature (p text)")
            con.execute("insert into zz_new_feature values (?)", (self.f.old + "/x",))
            p = self.preflight()
        finally:
            con.close()
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertRegex(p.stderr, r"zz_new_feature\.p names the old home in 1 row\(s\)")
        self.assertEqual(os.listdir(self.tmp), [])

    def _wal_db_without_wal(self):
        con = sqlite3.connect(self.f.state_db)
        con.execute("pragma journal_mode=wal")
        con.close()
        self.assertFalse(os.path.lexists(self.f.state_db + "-wal"))
        return self.f.state_db

    def _live_copy_with(self, src, hook, journal_wal=True):
        """live_copy of src with hook() run right after each backup() (a writer that changes the source mid-copy);
        returns (calls, exception or None)."""
        import unittest.mock as um
        mod = load_script()
        real = sqlite3
        calls = []

        class Conn(object):
            def __init__(self, c):
                self.c = c

            def backup(self, d):
                self.c.backup(d)
                calls.append(1)
                hook(len(calls))

            def close(self):
                self.c.close()

        class Shim(object):
            def connect(self, *a, **k):
                c = real.connect(*a, **k)
                return Conn(c) if k.get("uri") else c

        dst = os.path.join(self.tmp, "copy", "x.sqlite")
        with um.patch.object(mod, "sqlite3", Shim()):
            try:
                mod.live_copy(src, dst, "state db")
                return calls, None
            except mod.Refuse as e:
                return calls, e

    def test_an_immutable_copy_is_restated_and_retried_once(self):
        # fix round 2, item 2: the source's size or mtime changed (or a -wal appeared) while the immutable=1 copy ran:
        # the copy may be torn and integrity_check would still say ok.
        src = self._wal_db_without_wal()
        st = os.stat(src)
        # quiet: copied once
        calls, err = self._live_copy_with(src, lambda n: None)
        self.assertIsNone(err)
        self.assertEqual(len(calls), 1)
        # changed during the first copy only: a second copy is made and accepted
        calls, err = self._live_copy_with(
            src, lambda n: os.utime(src, ns=(st.st_atime_ns, st.st_mtime_ns + 10 ** 9)) if n == 1 else None)
        self.assertIsNone(err)
        self.assertEqual(len(calls), 2)
        # changed during both: refused, with the way out
        st = os.stat(src)
        calls, err = self._live_copy_with(
            src, lambda n: os.utime(src, ns=(st.st_atime_ns, st.st_mtime_ns + n * 10 ** 9)))
        self.assertIsNotNone(err)
        self.assertEqual(len(calls), 2)
        self.assertRegex(str(err), r"state db: the database changed during the copy; run prepare again")
        # a size change counts too
        st = os.stat(src)
        def grow(n):   # size only: the mtime is put back
            os.truncate(src, st.st_size + n * 4096)
            os.utime(src, ns=(st.st_atime_ns, st.st_mtime_ns))
        calls, err = self._live_copy_with(src, grow)
        self.assertIsNotNone(err)
        self.assertEqual(len(calls), 2)
        self.assertEqual(os.path.exists(os.path.join(self.tmp, "copy", "x.sqlite")), False,
                         "a refused copy was left behind")

    def test_a_wal_appearing_during_an_immutable_copy_is_retried_with_locks(self):
        # a writer opened the database meanwhile: the first copy is discarded, the second is a locking (mode=ro) read
        src = self._wal_db_without_wal()
        calls, err = self._live_copy_with(src, lambda n: open(src + "-wal", "wb").close() if n == 1 else None)
        self.assertIsNone(err)
        self.assertEqual(len(calls), 2)

    def test_a_database_read_with_mode_ro_is_not_restated(self):
        # a WAL database with a -wal, read with locks: its copy is consistent by the backup API; no retry
        con = sqlite3.connect(self.f.state_db, isolation_level=None)
        try:
            con.execute("pragma journal_mode=wal")
            con.execute("pragma wal_autocheckpoint=0")
            con.execute("create table zz_t (p text)")
            st = os.stat(self.f.state_db)
            calls, err = self._live_copy_with(
                self.f.state_db, lambda n: os.utime(self.f.state_db, ns=(st.st_atime_ns, st.st_mtime_ns + 10 ** 9)))
        finally:
            con.close()
        self.assertIsNone(err)
        self.assertEqual(len(calls), 1)

    def test_only_openclaw_2026_9_7(self):   # read as migrate reads it
        self.f.set_version("2026.9.8")
        self.refuses(r"pinned to OpenClaw 2026\.9\.7, found 2026\.9\.8")
        os.remove(self.f.state_db)   # the pin comes first: before any live database is read or copied
        self.refuses(r"pinned to OpenClaw 2026\.9\.7, found 2026\.9\.8")

    def test_python_3_9_with_sqlite3(self):
        for attr, value, pattern in (("MIN_PYTHON", (99, 0), r"python 3\.\d+ is older than 99\.0"),
                                     ("sqlite3", None, r"this python3 has no sqlite3 module")):
            with self.subTest(attr=attr):
                mod = load_script()
                setattr(mod, attr, value)
                err = io.StringIO()
                with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                    rc = mod.main(["preflight", "--home", self.f.old, "--openclaw-package", self.f.pkg])
                self.assertEqual(rc, 1)
                self.assertRegex(err.getvalue(), r"state-paths preflight: refused: " + pattern)

    def test_a_shape_the_migration_would_refuse_is_refused_now(self):   # the review's probe, on the live state
        sd = os.path.dirname(self.f.skill_file)
        self.f.exec("update skill_workshop_proposals set record_json=? where proposal_id='p-create'",
                    js({"id": "p-create", "status": "applied", "kind": "create",
                        "target": {"skillDir": sd, "skillFile": self.f.skill_file}, "evidence": sd}))
        self.refuses(r"skill_workshop_proposals\.record_json: the target rewrite would touch other fields")

    def test_the_post_check_runs_too(self):
        self.f.exec("create table zz_new_feature (p text)")
        self.f.exec("insert into zz_new_feature values (?)", self.f.old + "/x")
        self.refuses(r"zz_new_feature\.p names the old home in 1 row\(s\): unclassified, or not rewritten")

    def test_a_codex_database_the_migration_would_refuse_is_refused_now(self):
        self.f.exec("update threads set cwd=? where id='thread-2'", "/srv" + self.f.old, db=self.f.codex_db("main"))
        self.refuses(r"codex-home/state_5\.sqlite: threads\.cwd: changed 1 row\(s\), expected 2")

    def test_only_state_schema_19(self):
        self.f.exec("update schema_meta set schema_version=20")
        self.refuses(r"the state schema is 20, not 19")

    def test_a_symlinked_workspace_or_codex_home_is_refused(self):
        real = os.path.join(self.f.root, "elsewhere")
        os.rename(self.f.ost + "/workspace-vera", real)
        os.symlink(real, self.f.ost + "/workspace-vera")
        self.refuses(r"\.openclaw/workspace-vera: a workspace of the live state is missing or not canonical")
        os.remove(self.f.ost + "/workspace-vera")
        os.rename(real, self.f.ost + "/workspace-vera")
        self.passes()
        os.rename(self.f.cx["vera"][1], real)
        os.symlink(real, self.f.cx["vera"][1])
        self.refuses(r"\.openclaw/agents/vera/agent/codex-home: a Codex home of the live state is not canonical")

    def test_a_scratch_dir_inside_the_home_is_refused(self):
        self.tmp = os.path.join(self.f.old, "tmp")
        os.makedirs(self.tmp)
        self.refuses(r"the scratch dir \(TMPDIR\) is inside the home")

    def test_usage(self):
        for args in (["preflight"], ["preflight", "--home", "Users/admin"], ["preflight", "--home", self.f.old + "/"]):
            with self.subTest(args=args):
                self.assertEqual(run(*args).returncode, 2)


class Usage(Base):
    def test_homes_must_be_two_different_absolute_homes_neither_inside_the_other(self):
        f = self.f
        for old, new in ((OLD, OLD), ("Users/admin", f.new), (OLD, f.new + "/"), (OLD, OLD + "/sub"), (f.new + "/x", f.new),
                         (OLD, "/home/../x")):
            with self.subTest(old=old, new=new):
                p = run("migrate", "--old", old, "--new", new, "--openclaw-package", f.pkg)
                self.assertEqual(p.returncode, 2, p.stdout + p.stderr)

    def test_no_subcommand_is_a_usage_error(self):
        self.assertEqual(run().returncode, 2)
        self.assertEqual(run("bogus").returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
