# PLAN — a sustainable course for unglue.it ops (indexes, provisioning, cleanup)

**Author**: unglueit-plan-0914 (Claude Opus, planner — read-only) · **Written**: 2026-09-14, rev 3 ~11:25 PT
**For**: RY + the CoS to execute later · **Status**: Codex LGTM (round 3, 2026-09-14 11:19 PT; two small post-LGTM fixes noted in the log) — not yet executed
**Public-repo note**: written to be committable to a public repo. Credential specifics (which keys,
their state, fingerprints) are deliberately left out; they live in the private security tracker
and the vault.

---

## 0. Plain-English summary

Roughly: the plan on 9/14 was "deploy the new `/free/` indexes, then run the big provisioning
playbook to apply the database change." The big playbook broke on its first line, and a closer look
shows that was not a one-off. **The production server was built in June from a provisioning branch
that was never merged**, so the main branch's full playbook describes an older machine: Python 3.8
paths, Python-2-era package names, a pip step that upgrades anything unpinned, and a TLS section
that differs from what the box was built with (and has at least one latent bug). Fixing `python3.8`
alone would just move the failure a few steps further.

So the plan separates two things that were tangled together:

1. **Applying database migrations** gets its own small playbook (`migrate.yml`) with three explicit
   modes — *inspect* (read-only), *forward*, *rollback* — each gated on the exact plan Django says it
   will execute. `deploy.yml` learns to refuse, before touching the box, a deploy that brings
   migrations nobody acknowledged.
2. **Making the full playbook trustworthy again** is slower work (existing
   [provisioning#56](https://github.com/EbookFoundation/regluit-provisioning/issues/56)). We start
   with a narrow, tested slice (Python version pins, package names, pip behaviour). A dry run is
   used only to *find* drift; the full playbook is not run for real on production until it has run
   for real, successfully, on a representative test machine.

For the two indexes, I recommend applying them **by hand over SSH, one migration at a time, under a
written one-time exception**, after re-rehearsing on test (now on MySQL 8.4 — the 9/10 rehearsal was
on 8.0). The hand commands are what the playbook would run, so the playbook adds repeatability, not
safety, for this change; and a live-table index build is the wrong place for new automation's first
production run. Deleting the old MySQL 8.0 instance gets its own go/no-go the next day, after the
indexes have been observed and current production's backups are confirmed.

The caveat: this plan is built from notes, repo reads, and session records. Several server facts
(exact venv layout, Django version actually installed, which package names resolve on 24.04, test's
current migration state) are marked **verify** and have read-only pre-checks attached. The planner
did not re-check any of them live.

---

## 1. Where we are (sourced)

| Fact | Source |
|---|---|
| Prod DB is MySQL 8.4.11 (Multi-AZ) since 2026-09-12 09:04 PT | `.cc-briefs/RESUME-2026-09-12-mysql84-prod.md` |
| Prod code is `production` @ `8015b0af1` (#1255 merged, release #1260), deployed with `deploy.yml` 10:43 PT 9/14 | `SESSION_SUMMARY.md` 9/14 |
| `core` migrations: 0032 applied; **0033/0034 not applied**; `/free/` 200 in ~2.0 s | `SESSION_SUMMARY.md` 9/14 10:49, 10:53–10:57 |
| Full `setup-prod.yml` failed at task 1 (`apt: Unable to locate package python3.8`), `ok=0 changed=0 failed=1` | `NEEDS.md` |
| `python3.8` appears 17 times in provisioning master `cf81f229`, across 8 files | `grep -rn python3.8` |
| Prod + test: Ubuntu 24.04.4, system Python 3.12.3 (apt `3.12.3-1ubuntu0.15`), venv paths `venv/lib/python3.12/` | `.cc-briefs/Unglue.it Infrastructure.md`; 9/14 tracebacks per `NEEDS.md` |
| App `requirements.txt` on master pins **`django==5.2.15`** (since #1081, 7/3). Installed Django version on the boxes: **verify** (PC-3) | `git show master:requirements.txt` |
| Prod was cut over 6/17 from the **unmerged** `feature/prod-green` branch, never reconciled into master | dev-journal 2026-07-01; provisioning#56 (open) |
| That branch already has `python_version: "3.12"` for production/test, 24.04 apt names, pip `state: present` + `--exists-action=w` | `git diff master feature/prod-green -- roles/regluit_prod/tasks/main.yml` |
| PR #25 (python_version parametrization) was closed unmerged 2026-09-10 | `gh pr view 25` |
| `deploy.yml` never migrates; `Migrate database` in `roles/regluit_prod/tasks/apache.yml` has no tag and no task-level `become` | repo read |
| `core/apps.py` connects a `post_migrate` handler (`create_notice_types`) — **every real `migrate` invocation writes notice-type rows**, even with nothing pending | app repo read |
| `roles/regluit_prod/tasks/certs.yml` "delete decrypted files" uses `state: file`, which does not delete | repo read (Codex r1) |
| `group_vars/test/vars.yml` has no vault vars → any test run rendering settings templates fails until W128 | repo read; W128 note |
| The 9/10 rehearsal of 0033/0034 on test was on MySQL 8.0 and left both indexes applied there | #1255 comments |
| Test rehearsal timings (1.47M `core_work` rows): 0033 10.3 s, 0034 7.6 s; reverse ~0.3 s each | #1255 comment "Merge gate 2" |
| Installed Ansible 12.0.0: `raw` skips in check mode; `django_manage` declares no check-mode support (skipped); `pip` with `requirements` predicts `changed=True` regardless | local source read; Codex r1 |
| Pending: delete `production-2024-old1` + B/G object `bgd-jdgebq3wemv2dony` (stops ~$555/mo Extended Support); W77 apt `.15→.16`; W128 staging IAM user (deadline 9/18); a credential remediation (private tracker); provisioning#68 stale since 8/28 | `PREFLIGHT_2026-09-14.md`, W128 note |

---

## 2. Principles

- **Don't lean on a playbook we can't run.** No real untagged `setup-prod.yml` run on production
  until it has **run for real, successfully, on a representative test machine** from the same
  commit, with certs behaviour reconciled (§4e). Dry runs find drift; they never authorize a run.
  Known-good narrow paths stay in use: `deploy.yml` (code), `setup-prod.yml --tags config`
  (settings; verified 9/14), and `migrate.yml` once proven.
- **Hand-SSH on production is an exception, not a method.** Each use gets a written exception
  (what, why not the playbook, exact commands, approver, expiry) in the session summary and on the
  PR. The §3b exception expires when `migrate.yml` is merged **and** proven on test **and** its
  first production *inspect* run has succeeded.
- **New automation debuts on test, then on prod in a mode that cannot change anything.**
- **A shared-role change must not silently change a working narrow path** — checked by task-list
  comparison *and* a review of task bodies, templates, variables, notifications and handlers.
- **One class of change per go/no-go.** Schema change, infrastructure deletion, OS package change,
  and credential work each get their own decision, even when they share a morning.

**Command convention (every Django command in this plan, prod or test)** — SSH as `ubuntu`, then:
```
cd /opt/regluit && /opt/regluit/venv/bin/python manage.py <command> --settings=regluit.settings.prod --no-color
```
`manage.py` defaults to `regluit.settings.me`, so `--settings` is never omitted. Written below as
`DJ <command>`. Before any mutating step, positively identify the target: deployed SHA
(`git -C /opt/regluit rev-parse HEAD`), and the DB endpoint + database name Django will use
(`DJ shell -c "from django.db import connection as c; print(c.settings_dict['HOST'], c.settings_dict['NAME'])"`
— prints host and name only). Confirm no deploy or other migrate is running (check with RY/CoS and
`pgrep -af 'manage.py migrate|ansible'` on the box).

---

## 3. Migrations path

### 3a. `migrate.yml` (provisioning PR-A)

**Shape**: same targeting as `deploy.yml` (`deploy_target`, default `regluit-prod`), **no vault
variables** (only `project_path`, `django_settings_module`, venv) → runnable on test today. Runs as
`ansible_user` (`ubuntu`); the playbook sets `become: false` explicitly rather than relying on
inheritance. Variables are passed as JSON so types survive:
`-e '{"mode":"forward","app":"core","target":"0033_free_facet_lang_index","expected_plan":[["core.0033_free_facet_lang_index","forward"]]}'`.

**Modes**:
- `inspect` (default): read-only. Never calls `migrate` without `--plan`/`--check`.
- `forward` / `rollback`: requires `app`, `target`, `expected_plan`, and `expected_sha`.

**Steps (spec; exact YAML is the PR's job, Codex-reviewed):**

1. **Identity** — read deployed SHA; assert `== expected_sha` (mutating modes). Print DB host+name.
   All read-only commands use `check_mode: false`, `changed_when: false`, and **fail on non-zero rc**.
2. **Current state** — `DJ showmigrations --plan -v 1`; strict parse of `[X] app.name` / `[ ] app.name`
   lines (Django 5.2 format — **verify** against the installed version on test); any unparseable
   line fails the play.
3. **Exact plan** — `DJ migrate <app> <target> --plan -v 1` (mutating modes) — this is what Django
   will actually do, including direction and any dependent migrations (rollback can unapply
   dependents in other apps). Parse into `[migration, direction]` pairs; **assert equal to
   `expected_plan`**. Any difference stops the play before anything runs.
4. **SQL for the record** — `DJ sqlmigrate <app> <name>` for each planned migration, adding
   `--backwards` for rollback. (Display only; says nothing about locking or privileges.)
5. **Apply** — only in `forward`/`rollback`, only if the plan is **non-empty**:
   `DJ migrate <app> <target> --noinput`. If the plan is empty, skip — a real `migrate` would still
   fire `post_migrate` and write notice-type rows. Reports `changed` honestly when it runs.
   No restarts (opt-in `restart_after`).
6. **Verify the expected resulting state**, not "latest": re-run step 2 and assert that each
   migration in `expected_plan` is now `[X]` (forward) or `[ ]` (rollback) and nothing else changed.
   In `inspect` mode, also run `DJ migrate --check` and report (non-zero = something pending — a
   report, not a failure, in inspect mode; any *other* error still fails).
7. **Physical check hook** — optional `expected_indexes` var: runs a read-only query against
   `information_schema.statistics` for the named indexes and asserts column order, `COLLATION`
   (A/D), `NON_UNIQUE`, `SUB_PART`, `INDEX_TYPE`, `IS_VISIBLE`. `migrate --check` knows nothing
   about physical indexes.
8. **Header comment**: modes, JSON `-e` usage, "code first for additive changes; expand-then-contract
   for destructive ones", and §3c's recovery procedure.

**`deploy.yml` companion change (same PR-A)** — so "code deployed, migration forgotten" is loud and
the deployed commit is the inspected commit:

- **Resolve once, on the controller** (`delegate_to: localhost`, runs under `--check`): in a
  controller-side cache clone of `git_repo`, fetch and resolve the requested `git_branch` —
  branch, tag (peeled to its commit), or SHA, so the existing "rollback to a previous SHA" interface
  keeps working — to exactly one commit, `deploy_sha`; fail if it doesn't resolve uniquely.
  Diff the box's current SHA against `deploy_sha` **in that clone** (`git diff --name-only`, full
  tree comparison, no API file-count cap) and list `*/migrations/*.py`. Any comparison error fails
  closed. No change to the box's checkout. (Exact implementation and tests: PR-A.)
- **Gate before checkout**: if migration files arrive and `migrations_acknowledged` isn't true, fail
  with the file list and the `migrate.yml` command to run next. Also report **already-pending**
  migrations on the box (`showmigrations --plan`, read-only, rc checked). Failing *after* checkout is
  not enough: mod_wsgi daemons recycle on `maximum-requests` and would load new code without a restart.
- **Checkout `version: {{ deploy_sha }}`**, not the moving branch; verify `HEAD == deploy_sha` after.
- **After restart**: report pending migrations (parsed `showmigrations`; errors fail, "pending"
  warns).
- Header comment: migrations go through `migrate.yml`.

**Proof on test (sibling with RY's go; test only)**:
1. PC-2 identity + state on test (positively the test RDS endpoint and DB name, not merely "not prod").
2. `migrate.yml` inspect mode against test (`--check` and real — both read-only).
3. Rollback then forward **through the playbook, on 8.4**, one migration at a time:
   rollback target `0033` (plan `[[core.0034…, backward]]`), rollback target `0032`
   (plan `[[core.0033…, backward]]`), forward `0033`, forward `0034`. Record timings and watch
   test's `/free/` during each. This is also the **8.4 rehearsal** the indexes still lack (unless
   W1.1 already did it by hand).
4. Gate tests: wrong `expected_plan`, wrong `expected_sha`, empty plan in forward mode (must skip
   `migrate`), a string instead of a list in `expected_plan` (must fail).
5. `deploy.yml -e deploy_target=regluit-test --check` against a throwaway branch with a dummy
   migration file → pre-checkout gate fires; box checkout unchanged. Delete the branch after.

### 3b. For 0033/0034 now: hand-SSH, one migration at a time (recommended), under a written exception

**Recommendation (D1 default)**: Window 1, by hand, after an 8.4 re-rehearsal on test.
**Alternative**: wait for `migrate.yml` to be merged and test-proven (likely several days).

**Why hand-SSH is acceptable here**
- **Same operation.** The playbook runs the same `manage.py migrate` in the same venv against the
  same DB. The DDL risk lives in the migration: `ALGORITHM=INPLACE LOCK=NONE`, a 10 s
  `lock_wait_timeout`, one index per migration.
- **New automation shouldn't debut on a live-table DDL.**
- **Waiting costs something, but not much.** `/free/` is correct at ~2 s; hourly DB CPU maxes of
  90–99.9% recur (`PREFLIGHT` §1). The indexes target the two worst `/free/` cases (D 2.32 s, E
  0.90 s on prod 8.4). Whether they relieve the CPU spikes is **not established**.

**What the online DDL does and does not promise (MySQL 8.4)**
- Roughly: the index is built while reads and writes continue. More precisely: an in-place
  secondary-index build permits concurrent DML, but takes an **exclusive metadata lock (MDL) briefly
  at preparation and at commit**. While it waits for that lock, **new queries on `core_work` queue
  behind it**. `lock_wait_timeout = 10` bounds **each acquisition attempt**, not the total stall,
  not time holding a granted lock, and not the final phase where buffered concurrent changes are
  applied. So there is **no hard bound on user-visible stall**; the protection is the pre-gate (no
  long transactions) plus the live stop conditions below.
- Concurrent DML during the build goes to the online-alter log. If it exceeds
  `innodb_online_alter_log_max_size`, the DDL fails **and uncommitted concurrent DML is rolled
  back** — i.e. application writes can fail, not only the index. A larger log lengthens the final
  locked phase. PC-4 measures the write rate and records the limit.
- Descending key parts are supported (8.0+). Secondary indexes with descending parts don't use
  change buffering — a minor write-performance note, not a blocker.
- Build reads 1.47M rows; on Multi-AZ, writes replicate synchronously (latency, not locking relief).
  Test timings (~10 s on 8.0) are **not** a production upper bound.
- `CREATE INDEX` itself is atomic in 8.4, but the sequence `SET` → DDL → reset → Django's
  `django_migrations` insert is not one transaction. A failure can leave: index present but
  unrecorded, or (for reverse) index dropped but still recorded. See §3c.
- `post_migrate` writes notice-type rows on every `migrate` run (idempotent updates in normal
  operation — rehearsed on test 9/10, but **verify** no errors in its output).
- **Rollback**: `DJ migrate core 0033` drops 0034's index; `DJ migrate core 0032` drops 0033's.
  Reverse DDL is `DROP INDEX … ALGORITHM=INPLACE LOCK=NONE` (~0.3 s on test; also needs an MDL).
  The deployed code (`8015b0af1`) doesn't depend on the indexes at runtime — it has served without
  them since 9/14 10:43 — so rollback needs no code change.

**User**: run as `ubuntu`. `PREPARED_1255_direct_migrate.md` proposed `sudo -u www-data` "to match
Ansible"; the checked-in task has no `become` and neither does its play, so Ansible would run it as
`ubuntu` (absent a CLI/config override, which the 9/14 runs didn't use). PC-3 records log-file
ownership in `/var/log/regluit` to confirm `ubuntu` can write there.

**The exception, as it should be recorded** (paste into `SESSION_SUMMARY.md` and a #1255 comment):
> EXCEPTION 2026-09-15-A — hand-applied core.0033 and core.0034 on production over SSH, one at a time.
> Why not the playbook: full `setup-prod.yml` unrunnable (provisioning drift, #56); `migrate.yml`
> not yet merged/proven. Commands: plan §5 W1.4–W1.6. Approved by: RY (in pane, time).
> Expires: when `migrate.yml` is merged, proven on test, and has run once in inspect mode on prod.
> Any later prod migration uses `migrate.yml`.

### 3c. Failure recovery for index migrations (per migration, per direction)

Never retry, `--fake`, or roll back until **both** ledger rows and **both** physical indexes are
reconciled.

1. Confirm the DDL statement is gone, **by connection id, not by text search** (a text search matches
   the observer's own query). The migrate's connection id is captured when it starts (Window 1,
   terminal b: the processlist row whose `info` is the `CREATE INDEX`/`DROP INDEX`, excluding
   `ID = CONNECTION_ID()`). Then:
   `SELECT id, command, time, state, info FROM information_schema.processlist WHERE id = <ddl_id>`
   → either no row (connection closed) or `command = 'Sleep'` with `info IS NULL` (idle, statement
   finished). And `performance_schema.metadata_locks` has no row for `core_work` whose
   `OWNER_THREAD_ID` maps (via `performance_schema.threads.PROCESSLIST_ID`) to `<ddl_id>` — if
   performance_schema is enabled (**verify** in PC-4; if disabled, rely on the processlist check plus
   `SHOW ENGINE INNODB STATUS` showing no active DDL, and say so in the record). Same procedure for
   rollback's `DROP INDEX`.
2. Ledger: `DJ showmigrations core` → state of 0033 and 0034 separately.
3. Physical (in a session where `SELECT DATABASE()` has been asserted equal to Django's configured
   `NAME` — an unselected database makes `DATABASE()` NULL and would show existing indexes as absent):
   `SELECT index_name, seq_in_index, column_name, collation, non_unique, sub_part,
   index_type, is_visible FROM information_schema.statistics WHERE table_schema = DATABASE() AND
   table_name = 'core_work' AND index_name LIKE 'core_work_free%' ORDER BY index_name, seq_in_index`.
   Expected: `core_work_free_lang_new_idx` = (`is_free` A, `language` A, `featured` D, `created` D);
   `core_work_free_new_idx` = (`is_free` A, `featured` D, `created` D); both non-unique, BTREE, visible,
   no prefix.
4. Decide, per migration:
   - recorded + index matches → done.
   - not recorded + no index → safe to re-run *that* migration (after the cause is understood).
   - **not recorded + index exactly matches** → `DJ migrate core <that migration> --fake --plan` first;
     proceed with `--fake` **only** if the plan lists that single migration forward. Never fake 0034
     while 0033 is unreconciled (faking to 0034 would also fake 0033).
   - not recorded + index present but **differs** → stop; drop and recreate is a new decision for RY.
   - recorded + no index (reverse interrupted) → stop; decide with RY between re-creating via
     `--fake` backwards then forward, or accepting the rollback.
5. Failover/disconnect mid-DDL: reconnect to the verified writer endpoint (re-run the identity check),
   then steps 1–4.

---

## 4. Python pins, package names, pip (provisioning PR-B)

### 4a. Evidence and gaps
- In hand: Ubuntu 24.04.4; `python3.12` `3.12.3-1ubuntu0.15`; venv site-packages under
  `venv/lib/python3.12/`; `feature/prod-green` set `python_version: "3.12"`.
- **Not in hand (PC-3)**: a literal `python3 --version` / `venv/bin/python --version` from today;
  installed Django version; whether `regluit.pth`/`opt.pth` exist under `python3.12/site-packages`;
  which apt names resolve on 24.04; whether `python3-apt` is installed.

### 4b. The change
One variable, **`python_version: "3.12"`** (major.minor only), in `group_vars/production/vars.yml`,
`group_vars/test/vars.yml`, and `roles/regluit_prod/defaults/main.yml`. Then:

1. **Bootstrap** (top-level playbooks + `regluit_common`), tag `[bootstrap]`: ensure the *controller
   interpreter* and *apt bindings* exist, separately — install `python3` if `/usr/bin/python3` is
   missing; install `python3-apt` if `python3 -c 'import apt'` fails. Report changed only when
   something was installed.
2. **Facts**: tag the explicit `Gathering Facts` task `[always]` so tagged runs get facts too.
   (It only reads; **verify** in the PR that nothing downstream changes behaviour because facts are
   now present under `--tags config`.)
3. **apt package list** (`roles/regluit_prod/tasks/main.yml`), tag `[packages]`: adopt the
   `feature/prod-green` list (proven by the 6/11 dj42 rebuild) after PC-3's per-name check.
4. **pip**: `state: present` + `extra_args: --exists-action=w` (supersedes open
   [provisioning#39](https://github.com/EbookFoundation/regluit-provisioning/pull/39)). Precisely:
   this stops *upgrading unpinned* requirements on every full run; it does **not** freeze the venv —
   pip will still change installed versions to satisfy explicit pins. So before any real full run,
   reconcile `requirements.txt` with what's installed (`pip freeze` diff, PC-3).
5. **`.pth`**: `dest: …/venv/lib/python{{ python_version }}/site-packages/{{ item }}`, tag `[python]`.
6. **Venv assertion**, tag `[python]`, placed **after** the venv-creating pip task (so a fresh build
   creates the venv first): `venv/bin/python` reports `python_version` and its site-packages dir
   exists; plain failure message ("venv is Python X, playbook expects Y").
7. **Dead hosts** (`setup-dev.yml`, `setup-batterup.yml`/`setup-ondeck.yml`, `regluit_common`,
   `regluit_dev`): parametrize mechanically; PR states they are **untested — hosts are dead**
   (RY 8/30). Deleting them is #56 (D4).

Not in PR-B: certs (§4e), template parity, `group_vars/test` vault — #56 / W128.

### 4c. Proof — test first
1. **Config-path guard** (local): `setup-prod.yml --list-tasks --tags config` before/after →
   identical; **plus** reviewer reads the diff of every task/template/handler reachable under
   `--tags config` (expected: none besides the facts tag in 4b.2).
2. Test, check: `setup-test.yml --tags bootstrap,python --check` → bootstrap `skipping` (raw),
   `.pth` render reports ok/changed, assertion ok.
3. Test, real: same tags. Expect `.pth` unchanged; if changed, stop and compare content (a revert of
   the commit would **not** undo a rendered file — restore from the pre-run copy saved in PC-3).
4. Test, packages: `setup-test.yml --tags packages --check`, then real (installs any missing names on
   test only). Record exactly what apt installed.
5. pip is **not** exercised by tagged runs; it is proven only in the §4e full real run on test.
6. Prod: `setup-prod.yml --tags bootstrap,python --check`, then real in Window 2. Expect no change.

### 4d. What W77 becomes
W77 (`python3.12` apt `3.12.3-1ubuntu0.15 → .16`) is an **OS package revision**: `python_version`
stays `"3.12"`, the venv still points at `/usr/bin/python3.12`, PR-B is unaffected. W77 stays a
one-off apt bump (RY 9/12: no EBS snapshot) — but its rollback must be made real first (W2.3). It
needs `apache2` (mod_wsgi loads libpython), `celeryd`, `celerybeat` restarts. After PR-B, a future
*minor* change (e.g. an OS release with `python3.13`) shows up as the venv assertion failing — that
change is a var + venv rebuild, a separate project.

### 4e. Road to a real full `setup-prod.yml` run (#56; not scheduled in these windows)
Gate, all required:
1. `group_vars/test` has its own vault (W128).
2. A representative test machine (test.unglue.it, or a disposable box from the same AMI/snapshot
   with its own DB) completes a **real, untagged** `setup-test.yml` from the same provisioning
   commit, and the site passes smoke + login + a Celery task.
3. certs.yml reconciled with how prod's certs are actually managed (certbot per
   `group_vars/production` comments vs master's acme flow), and the `state: file` "delete" fixed.
4. `requirements.txt` vs installed venv reconciled (4b.4).
5. A `--check` against prod whose every changed task has a written reason in the allowlist (per task,
   with scope; no blanket "pip changed" or "certs changed" entries), reviewed by RY.

---

## 5. Runbook — next windows

**Roles.** *RY* runs every mutating prod or AWS command himself. *Sibling* prepares commands, runs
read-only checks and test runs with RY's go, watches CloudWatch and the site, records. *CoS* tracks
gates and files queue items. *Eric* is told at the 9/17 call that `deploy.yml` will begin refusing
unacknowledged migrations.

**Global stop rules**: unexpected output → stop and report, never retry blind; one mutating step at a
time, verify before the next; never `--diff` on provisioning runs; provisioning is run from a
**clean detached checkout of a verified commit** (HTTPS fetch → `git worktree add --detach <dir>
<sha>` → confirm `sha` equals `gh api repos/EbookFoundation/regluit-provisioning/commits/master`).
AWS commands always pass `--profile gluejar_member --region us-east-1` and are preceded once per
window by `aws sts get-caller-identity` (account ID read back).

**Recording**: `SESSION_SUMMARY.md` (timestamped), vault `[[Unglue.it Infrastructure]]` (living
note; bump `last-verified`), the relevant queue note, a comment on the PR the step belongs to,
dev-journal for durable lessons.

### Pre-checks (sibling, read-only, before Window 1)
- **PC-1 AWS/DB snapshot**: CloudWatch 1-min `CPUUtilization`, `DatabaseConnections`, `ReadLatency`,
  `WriteLatency`, `DiskQueueDepth`, `FreeableMemory`, `FreeStorageSpace`, `BurstBalance` (gp2) for 24 h;
  old1 connections 7 days (not just 24 h); prod `BackupRetentionPeriod` and `LatestRestorableTime`;
  `PendingModifiedValues` on prod and old1.
- **PC-2 test identity/state**: SHA; DB host+name positively the test endpoint; `DJ showmigrations core`;
  §3c physical query on test.
- **PC-3 host facts** (prod + test): `lsb_release -d`; `python3 --version`; `venv/bin/python --version`;
  `DJ version`; `readlink -f venv/bin/python`; `ls venv/lib/`; `*.pth` under `python3.12/site-packages`
  (save copies); `python3 -c 'import apt'`; `dpkg -l 'python3.12*' 'libpython3.12*'`; `apt-cache policy`
  for every apt name in top-level playbooks and roles; `venv/bin/pip freeze` vs `requirements.txt`;
  ownership in `/var/log/regluit`.
- **PC-4 DDL sizing** (prod, read-only SQL): `innodb_online_alter_log_max_size`,
  `performance_schema` on/off, `information_schema.tables` data/index length for `core_work`,
  `tmpdir` and `innodb_tmpdir` (on RDS MySQL these normally sit on the instance's storage volume, so
`FreeStorageSpace` is the capacity that matters — **verify** the instance class isn't an
Optimized-Reads class whose temp space is local NVMe, in which case use `FreeLocalStorage`);
the schema name and writer endpoint Django uses (identity baseline for W1.2);
**sizing basis**: on test (same row count, indexes present) read both indexes' size from
`mysql.innodb_index_stats` (`stat_name='size'` × page size). Headroom figure (an **operational
margin**, not a MySQL-documented bound): max(5 GB, 3 × the larger index + `innodb_online_alter_log_max_size`),
checked separately for temp and persistent storage when they differ; corroborate by noting
`FreeStorageSpace` on test before/after W1.1. Prod had ~199 GB free on 9/12, so this is expected to
pass by a wide margin and exists to catch surprises; a per-table write-rate estimate (`performance_schema.table_io_waits_summary_by_table`
  count deltas for `core_work` over 15 min if enabled; otherwise `max(id)` + `modified`-style
  timestamp deltas, noting they miss deletes); the DB user's ability to see all processlist rows and
  to call `mysql.rds_kill_query` (`SHOW GRANTS`, no secrets printed).
- **PC-5 scheduled consumers of old1**: grep provisioning, app settings templates, cron, and
  `.cc-briefs` scripts for `production-2024-old1` endpoint strings; list EventBridge/Lambda/Glue
  jobs referencing it (read-only describes).

### Window 1 — Tue 9/15 morning: indexes only (RY hands-on; sibling watching)

Before the go decision, open **three terminals**: (a) SSH to prod in `tmux` for the migrate; (b) a
second DB session opened with **`DJ dbshell`** (uses Django's own configured host, user, and
database — do not use `~ubuntu/.my.cnf`, which per Codex r2 carries only a `[mysqldump]` section),
in which, before go, RY/sibling assert: `SELECT @@hostname, CURRENT_USER(), DATABASE(),
@@innodb_read_only` → writer (read_only 0), app user, `DATABASE()` = the schema name recorded in PC-2/PC-4;
`SHOW GRANTS` includes `PROCESS` (without it MySQL shows only the app user's own threads), and
`SELECT id, user, host, db, command, state FROM information_schema.processlist` shows rows for
other users (e.g. `rdsadmin`) — if visibility can't be established, postpone;
`SHOW GRANTS` includes what `mysql.rds_kill_query` needs (**verify**; if not, name who can kill and
have them on call, or postpone); (c) sibling polling `/free/`, `/`, a work page and a write path (login page POST is not
needed — watch the app error log for DB write errors) every 10 s, plus CloudWatch 1-min.

| # | Step | Verify after | Rollback | Stop if |
|---|---|---|---|---|
| W1.1 | **8.4 re-rehearsal on test** by hand with the convention: `DJ migrate core 0033` (drops 0034), `DJ migrate core 0032`, `DJ migrate core 0033`, `DJ migrate core 0034`, each timestamped, each with `--plan` first | ledger + §3c physical match after each; timings recorded; test `/free/` latency during each | n/a (test) | identity isn't positively test; any error other than lock-wait; any step > 5 min |
| W1.2 | **Prod identity + gate** (read-only). *Identity*: SHA = `8015b0af1914a36af1093cecf245cb60d4213d00`; Django `HOST` and `NAME` equal the endpoint and schema recorded in PC-4 (the `production-2024` writer endpoint), matching terminal (b). *State*: `DJ showmigrations --plan` shows exactly 0033 and 0034 unapplied; `DJ migrate core 0033 --plan` = exactly `core.0033_free_facet_lang_index` forward; §3c physical query shows neither index. *Concurrency/resources* (below) | CPU 1-min < 60% for prior 10 min, no point > 90% in prior 5; `DatabaseConnections` < 30 (baseline max 12); `DiskQueueDepth`/`WriteLatency` at baseline; no `innodb_trx` older than 30 s; no processlist query touching `core_work` older than 30 s; persistent storage (`FreeStorageSpace`) **and**, if PC-4 found local temp storage, `FreeLocalStorage` each ≥ the PC-4 headroom figure, refreshed within the hour | — | any gate fails → wait 15 min, re-check twice, then postpone |
| W1.3 | Record exception 2026-09-15-A; RY says go in pane | — | — | no explicit go |
| W1.4 | **Apply 0033** (RY): `date; DJ migrate core 0033 --noinput; date` | ledger 0033 `[X]`, 0034 `[ ]`; §3c physical shows the lang index exactly; no DDL left in processlist; notice-type output without errors | `DJ migrate core 0032` (after re-gating) | see live stop conditions |
| W1.5 | Pause ≥ 10 min, then **gate for 0034**: W1.2's *identity* and *concurrency/resources* checks only (not its state check), plus the new state: `showmigrations` 0033 `[X]` with its exact physical index; 0034 `[ ]` with its index absent; `DJ migrate core 0034 --plan` = exactly `core.0034_free_facet_index` forward; RY says go | as stated | — | any check fails → stop here; 0033 alone is a safe resting state |
| W1.6 | **Apply 0034** (RY): `date; DJ migrate core 0034 --noinput; date` | ledger both `[X]`; physical both exact; `DJ migrate --check` exit 0 | `DJ migrate core 0033` | see live stop conditions |
| W1.7 | **Effect check**: `speed_check_prod.py` "after" column vs 9/12 baseline; `/free/` ×3; app/Celery logs no new DB errors; CloudWatch 60 min | recorded on #1255 | if CPU/latency for *other* pages gets worse after (optimizer picks the new index badly): `DJ migrate core 0033`, then `0032` | — |

**Live stop conditions during W1.4/W1.6** (independent of CPU):
- terminal (c) sees `/` or `/free/` > 10 s or any 5xx for **two consecutive polls**, or
- terminal (b) shows ≥ 5 sessions in `Waiting for table metadata lock` on `core_work`, or
- app log shows DB write errors, or
- the DDL runs > 10 min, or CPU > 95% for 5 consecutive 1-min points.
Action: in (b), use the **DDL's connection id captured at start** (processlist row whose `info` is
the `CREATE INDEX`, excluding `ID = CONNECTION_ID()`), `CALL mysql.rds_kill_query(<that id>);` — **never kill a blocker automatically**.
`KILL QUERY` returns before cleanup finishes: wait until the statement and its MDL are gone (§3c
step 1), then reconcile (§3c) before anything else. If a lock-wait timeout fires **twice** for the
same migration, stop for the day; find the blocker, don't loop.

### Window 1b — Wed 9/16 (or later): old MySQL 8.0 deletion, own go/no-go (RY)

Preconditions: indexes observed ≥ 24 h without regression; PC-1 shows old1 with 0 connections for
7 days; PC-5 found no consumer; prod `BackupRetentionPeriod` ≥ 7 and `LatestRestorableTime` within
the last 10 min — **this, not old1, is the recovery path for current data** (point-in-time restore
to a new instance; accepted data-loss window = up to `LatestRestorableTime` lag, ~5 min).

| # | Step | Verify | Rollback | Stop if |
|---|---|---|---|---|
| W1b.1 | `aws sts get-caller-identity`; describe B/G `bgd-jdgebq3wemv2dony` | status `SWITCHOVER_COMPLETED`, source `…old1`, target `production-2024` | — | anything else |
| W1b.2 | `aws rds delete-blue-green-deployment --blue-green-deployment-identifier bgd-jdgebq3wemv2dony` (**no `--delete-target`**) | describe → not found; both instances `available` | none needed | error |
| W1b.3 | Check old1 `PendingModifiedValues` is empty; then `modify-db-instance --db-instance-identifier production-2024-old1 --no-deletion-protection --apply-immediately` | `DeletionProtection=false`, no other attribute changed | re-enable protection | pending modifications present (would apply too) |
| W1b.4 | Read the identifier back aloud; `delete-db-instance --db-instance-identifier production-2024-old1 --final-db-snapshot-identifier production-2024-old1-final-20260916` | snapshot `creating`→`available`; old1 `deleting`→`DBInstanceNotFound`; `production-2024` untouched, deletion protection still ON; site 200 | restore old1 from final snapshot (hours; it's 8.0 data frozen at 9/12) | delete call errors → **re-enable deletion protection** on old1 unless deliberately retrying |
| W1b.5 | Next day: Cost Explorer shows the MySQL 8.0 Extended Support line stopped. Snapshots bill storage only. Keep `production-2024-pre-mysql84-20260912` ~2 weeks, then decide | recorded | — | line continues → look for any remaining 8.0 *instance* |

### Credential track — independent, by the 9/18 W128 deadline (RY + Eric decisions)
Not blocked by provisioning work: the rotation path uses `--tags config`, which PR-B guarantees is
unchanged. Order per the W128 note and the private runbook: mint staging IAM user → give test its own
credentials (W128 / #68) → rotate the production credential. IAM create/deactivate/delete steps are
RY's hands. If W128 slips, use the documented test stopgap rather than delaying the rotation.

### Between windows (no prod mutation)
PR-A and PR-B written by a sibling, Codex to LGTM, RY merges; §3a and §4c test proofs.

### Window 2 — after PR-A/PR-B merge and test proofs (RY hands-on)

| # | Step | Verify | Rollback | Stop if |
|---|---|---|---|---|
| W2.1 | `migrate.yml` **inspect** on prod (`--check`, then real — both read-only) | reports nothing pending; identity printed; `changed=0`. Exception 2026-09-15-A now expires | none | anything pending not explained |
| W2.2 | `setup-prod.yml --tags bootstrap,python --check`, then real | `.pth` unchanged; assertion ok | restore saved `.pth` copies (PC-3) | any change/failure |
| W2.3 | **W77 on test, rollback made real first**: list the installed set `dpkg -l 'python3.12*' 'libpython3.12*'` at `.15`; `apt-get download` each at `3.12.3-1ubuntu0.15` into `/var/cache/regluit-rollback/` (APT authenticates via signed repository metadata + package hashes; download fails if they don't match) and record package/version/arch/SHA-256 of each file, re-verified with `sha256sum -c` before any rollback; `apt-get -s install <each>=<.16 version>` (exact target version, simulated) — confirm nothing unrelated is pulled; then real install with exact versions; restart apache2/celeryd/celerybeat | all at `.16`; services active; `/`, `/free/`, `/accounts/login/` 200; `venv/bin/python -c 'import ssl, sqlite3'` | **rehearse on test now**: `dpkg -i /var/cache/regluit-rollback/*.deb` (simulate with `apt-get -s install ./…deb` first), restart, smoke; then re-apply `.16` | simulation pulls unrelated packages; staged `.deb`s incomplete; interrupted apt → `dpkg --configure -a` then reassess before anything else |
| W2.4 | W77 on prod — same procedure, staged `.deb`s first, ≥ 1 h after test is clean | same + CloudWatch/app errors 30 min | staged `.deb`s | same |
| W2.5 | W77 on Linode boxes — per W77 note | — | — | — |

### Window 3 — after W128 lands: find the full-playbook drift (sibling + RY)

| # | Step | Verify | Stop if |
|---|---|---|---|
| W3.1 | `setup-test.yml --check` (untagged, no `--diff`) on test | recap saved; every changed/failed task listed on #56 | output shows a task that should skip (migrate, collectstatic, `raw`) actually ran |
| W3.2 | Only after W3.1: `setup-prod.yml --check` on prod | same; draft allowlist with per-task reasons | same |
| W3.3 | Burn down #56 toward §4e's gate | — | — |

Check mode is a **diagnostic** here: `git` doesn't check out, `pip` always predicts changed, commands
and `django_manage` skip, templates are diffed against files that later tasks won't re-read.

---

## 6. Sustainability — catch rot in a sweep, not mid-deploy

**Proposed `Queue/_CADENCE` entry — "Provisioning rot check"** (monthly, first Monday, sibling,
read-only, ~30 min):

1. HTTPS-fetch provisioning; `git worktree add --detach` at master's SHA; confirm SHA against
   `gh api`. Run everything below **from that worktree**.
2. **Package probe** (catches "the OS dropped a package" — the thing check mode can't, because
   `raw` skips): a script in provisioning `scripts/` that extracts every apt package name from
   top-level playbooks **and** roles (including `raw:` bootstrap strings) and runs `apt-cache policy`
   on test and prod; also prints `/var/lib/apt/lists` age (cache freshness), `python3 --version`,
   `venv/bin/python --version`, `DJ version`. **Pass** = every name has a candidate and lists are
   < 7 days old.
3. `migrate.yml` **inspect** on prod: pending list. **Pass** = empty or matches a release in flight.
4. After W3.2 exists: `setup-prod.yml --check`; **pass** = `failed=0` and each changed task is in the
   reasoned allowlist. Report-only until then.
5. One dated line in `[[Unglue.it Infrastructure]]`; on fail, a provisioning issue + CoS queue item
   naming the failing names/tasks.

Plus: release PRs containing migrations carry a checklist line with the exact `migrate.yml` JSON
invocation — enforced by the PR-A `deploy.yml` gate.

---

## 7. Risk table

| Step | What could go wrong | How we'd know | What we'd do |
|---|---|---|---|
| Any Django command | Wrong settings module → wrong DB (`manage.py` defaults to `settings.me`) | identity print shows unexpected host/name | Convention in §2 always passes `--settings`; identity check before every mutation |
| W1.1 | Test settings point at prod DB | PC-2 identity | Stop; flag as drift/security issue |
| W1.4/1.6 | Long transaction holds MDL → DDL waits → `core_work` queries queue (stall **not** bounded by 10 s overall) | poll latency; ≥ 5 `Waiting for table metadata lock` | Gate prevents most; stop conditions; kill the DDL thread only via `mysql.rds_kill_query`; wait for cleanup; reconcile |
| W1.4/1.6 | Online-alter log overflow → DDL fails **and** concurrent uncommitted writes roll back | DDL error; app DB write errors | PC-4 sizes risk; quiet window; if hit, reconcile and reschedule; check for user-visible failed writes in logs |
| W1.4/1.6 | Build load saturates I/O/CPU during a crawler burst | 1-min CPU, `DiskQueueDepth`, `WriteLatency`, `BurstBalance` | Gate + stop conditions; one index per sitting with a pause between |
| W1.4/1.6 | Multi-AZ failover or connection loss mid-DDL | client error; RDS event | Reconnect to verified writer; §3c before any retry |
| W1.4/1.6 | SSH drop | terminal disconnect | `tmux`; reattach; if process died, §3c |
| W1.4/1.6 | Partial/ambiguous ledger vs physical state | §3c queries | §3c decision table; `--fake --plan` before any fake; never fake 0034 over unreconciled 0033 |
| W1.4/1.6 | `post_migrate` notice-type handler errors | migrate output | Migration DDL already recorded; investigate handler separately; not a reason to roll back the index |
| W1.7 | Optimizer picks new index badly elsewhere | CPU/latency on other pages after | `migrate core 0033` / `0032` |
| W1b | Wrong identifier / wrong account/region | read-back; `sts` identity | Pinned profile/region; read-back; prod has deletion protection ON |
| W1b | A rare consumer still used old1 | PC-5; 7-day connections | Stop before delete |
| W1b | `--apply-immediately` applies other pending modifications | `PendingModifiedValues` | Check empty first |
| W1b | Delete fails after protection removed | CLI error | Re-enable protection |
| W1b | Current prod data loss later | — | Recovery is prod PITR (verified retention/restorable time), not old1 |
| PR-A deploy gate | Branch moves between inspect and checkout | `HEAD != deploy_sha` | Checkout the resolved SHA, verify after |
| PR-A deploy gate | Gate blocks an urgent hotfix | pre-checkout failure | `migrations_acknowledged=true` override, documented |
| PR-A migrate.yml | Rollback target unapplies dependents in other apps | exact `--plan` ≠ `expected_plan` | Play stops before applying |
| PR-A migrate.yml | `-e` values arrive as strings | type assertion fails | JSON `-e` only; explicit type assertions |
| PR-A migrate.yml | "no-op" run writes data via `post_migrate` | — | Empty plan → `migrate` never invoked |
| PR-A | Output-format parsing breaks on a Django upgrade | strict parser fails loudly | Pin parser to installed version (PC-3); proven on test |
| PR-B | Change alters `--tags config` behaviour (credential path) | task-list diff + body/template/handler review | Required in PR; revert |
| PR-B | Tagged proofs miss apt/pip regressions | — | Separate `--tags packages` proof on test; pip only via §4e full test run |
| PR-B | Venv assertion blocks a fresh build | fresh-build failure | Assertion placed after venv creation |
| W2.2 | `.pth` render changes content | `changed=1` | Stop; restore saved copies; compare |
| W2.3/2.4 | `.15` not downloadable at rollback time; partial apt transaction; package triggers restart services unexpectedly | staging step; `dpkg --audit`; service status | Stage `.deb`s before upgrading; rehearse rollback on test; `dpkg --configure -a` path; watch services |
| W3 | Check mode trusted as proof | — | Diagnostic only; §4e gate requires a real full test run |
| certs.yml | Decrypted key material left on controller (`state: file` no-op) | file still present after run | Fix in #56 before any full run (§4e.3) |
| Monthly check | Runs stale code | worktree SHA ≠ `gh api` SHA | Detached verified worktree |
| All | This plan's unverified facts are wrong | PC-1…PC-5 | Stop and revise the step before running it |

---

## 8. Decisions for RY (each with a default)

- **D1 — indexes now by hand, or wait for `migrate.yml`?** *Default: by hand in Window 1, one
  migration at a time, under exception 2026-09-15-A, after the test 8.4 re-rehearsal.*
- **D2 — old1 deletion timing.** *Default: Window 1b (≥ 24 h after indexes, own go/no-go).* Costs ~a
  day of Extended Support (~$18) for a cleaner separation.
- **D3 — pip `latest` → `present` in PR-B?** *Default: yes*, with the requirements-vs-installed
  reconciliation before any full run.
- **D4 — dead-host playbooks: parametrize or delete?** *Default: parametrize now; delete under #56.*
- **D5 — `deploy.yml` gate: fail-before-checkout or warn-only?** *Default: fail, with override.*
- **D6 — W77 timing.** *Default: Window 2, after the rollback `.deb`s are staged and rehearsed on test.*
- **D7 — where the plan PR lives.** *Default: provisioning repo* — PR-A/PR-B, #56 and the monthly
  check land there. Both repos are public; this file omits credential specifics.
- **D8 — representative test machine for §4e.** *Default: test.unglue.it after W128*; alternative is a
  disposable box (its teardown must be documented and verified).

---

## Review log

*(Codex rounds appended below with timestamps. Codex ran `codex exec -s read-only` with read access
to both repos and the installed Ansible source; it ran no ansible/ssh/aws commands.)*

### Round 1 — 2026-09-14 11:00–11:06 PT — **VERDICT: CHANGES REQUESTED**
7 blockers, 9 should-fix, 1 nit. Summary and what rev 2 did:
- **B1** gate checked pending migrations, not the operation (rollback could pass an empty-pending
  gate) → modes `inspect/forward/rollback`; gate on exact `migrate <app> <target> --plan`; verify
  expected resulting state.
- **B2** real `migrate` with nothing pending isn't read-only (`post_migrate` → `create_notice_types`,
  verified in `core/apps.py`) → empty plan never invokes `migrate`; W2.1 is inspect-only.
- **B3** "≤10 s stall" was false (`lock_wait_timeout` bounds each acquisition, not the whole) and
  cancellation underspecified → bound removed; latency/lock-queue stop conditions; second DB session;
  `mysql.rds_kill_query` on the DDL thread only; wait for cleanup.
- **B4** recovery could fake after partial success → §3c per-migration/per-direction reconciliation
  with full index definitions; `--fake --plan` first; apply 0033 and 0034 as separate commands.
- **B5** dry run + allowlist can't authorize a full run (pip always predicts changed; certs.yml
  `state: file` "delete" no-op, verified) → §4e gate requires a real full run on a representative
  test machine and certs reconciliation.
- **B6** W77 rollback not executable → stage `.15` `.deb`s, simulate, rehearse rollback on test.
- **B7** old1 deletion lacked a current-prod recovery gate → Window 1b with PITR/retention check,
  7-day connections, consumer search, `PendingModifiedValues`, re-protect on failure.
- Should-fix adopted: command convention with `--settings` (manage.py defaults to `settings.me`);
  **Django is 5.2.15 per requirements, not 4.2** (my prompt to Codex was wrong; plan now says verify
  installed version); immutable-SHA deploy gate; `--list-tasks` plus body review; bootstrap split
  (interpreter vs apt bindings, venv assertion after creation, facts `always`); DDL resource checks
  (alter-log overflow rolls back concurrent DML); dependency order test→prod for full checks;
  credential track decoupled with its 9/18 deadline; monthly check from a verified worktree incl.
  top-level playbook packages; JSON `-e`; nits on change buffering and snapshot billing.

### Round 2 — 2026-09-14 11:11–11:15 PT — **VERDICT: CHANGES REQUESTED**
Round-1 items: 12 RESOLVED, 5 PARTIAL (rev 3 originally said 11/6 — Codex r3 caught the miscount). New in rev 2: 3 blockers, 1 should-fix, 1 nit; plus one
carried should-fix. What rev 3 did:
- **B1** the observer DB session used the MySQL option file in `~ubuntu`, which (per Codex, reading
  the template) holds only a `[mysqldump]` section, so `mysql` wouldn't get host/database and
  `DATABASE()` would be NULL → terminal (b) is now `DJ dbshell`, with writer/user/`DATABASE()`/
  visibility/kill-privilege assertions before go; the physical query asserts `DATABASE()` first.
  *(Planner could not independently read that template — the secret-guard hook blocked it,
  correctly; not retried.)*
- **B2** the "DDL gone" check matched its own query text → check by captured connection id, excluding
  `CONNECTION_ID()`, with `metadata_locks` joined via `threads.PROCESSLIST_ID`.
- **B3** W1.5 re-ran a gate that requires both migrations unapplied → explicit 0034 gate (0033 `[X]` +
  exact index, 0034 `[ ]` + absent, exact `--plan` for 0034) reusing only identity/resource checks.
- **S** `git ls-remote <branch>` can't resolve a rollback SHA; GitHub compare caps file lists at 300 →
  controller-side cache clone resolves branch/tag/SHA to one commit and diffs trees; fail closed.
- **S (carried)** `tmpdir` path ≠ capacity; 10× threshold unjustified → RDS temp space = storage
  volume (verify not Optimized-Reads), sized from test's measured index size, 3× / ≥5 GB rule.
- **N** `dpkg-deb -I` isn't signature verification → APT-authenticated download + recorded SHA-256.

### Round 3 — 2026-09-14 11:17–11:19 PT — **VERDICT: LGTM**
All round-2 blockers RESOLVED; deploy-gate and APT items RESOLVED; round-1 #3/#4/#8/#10 RESOLVED.
"No new BLOCKER identified." Two non-blocking should-fixes, **applied after the LGTM (not
re-reviewed)**:
- the processlist `COUNT(*)` didn't prove cross-user visibility → require `PROCESS` in `SHOW GRANTS`
  and inspect `user`/`host` columns; postpone if visibility can't be established.
- W1.2 checked only `FreeStorageSpace` although PC-4 may identify local temp storage; 3× was
  presented as MySQL-grounded → gate both storages; headroom restated as an operational margin
  that explicitly adds `innodb_online_alter_log_max_size`, corroborated by test measurements.

<!-- cc:2026.09.14 -->
