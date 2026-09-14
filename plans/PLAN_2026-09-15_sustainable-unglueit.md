# PLAN — a sustainable course for unglue.it ops (indexes, provisioning, cleanup)

**Author**: unglueit-plan-0914 (Claude Opus, planner — read-only) · **Written**: 2026-09-14, rev 5.3 ~12:30 PT (cattle-not-pets revision + RY additions + CoS editorial, via the CoS)
**For**: RY + the CoS to execute later · **Status**: Codex LGTM (rev 5.1) + CoS LGTM (rev 5.2); rev 5.3 editorial, not re-reviewed; RY decides D1/D2/D10 next — not yet executed
**Public-repo note**: written to be committable to a public repo. Credential specifics (which keys,
their state, fingerprints) are deliberately left out; they live in the private security tracker
and the vault.

---

## 0. Plain-English summary

> **Sequence by week**
> - **This week (9/14–9/18):** PC-1…PC-5 pre-checks (PC-3/PC-4 **tonight, Mon 9/14**, read-only) →
>   **W1** indexes on Tue 9/15 → **L0** interim log archive (outside W1's observation hour) →
>   restore test **Wed 9/16** → credential track by the **9/18** W128 deadline → **old1 go/no-go**
>   (default Fri 9/18 09:00 PT; needs RY's OK on the shorter window, else Mon 9/21).
> - **This month:** PR-A (`migrate.yml` + deploy gate) and PR-B (Python pins) with their test proofs
>   → Window 2 (first `migrate.yml` inspect on prod, W77) → **S0 / PR-C** state inventory → **PR-D** logs
>   → **C1p** logs live on current prod.
> - **Next:** C4 (#67 certbot) – C5 (rebuild safety switches) – C6 (launch script) → **T1** first
>   from-scratch test rebuild → monthly **T+** → **P1** prod rebuilt Blue/Green-style.

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
2. **Keeping the playbook working** stops depending on anyone remembering to check it. RY's framing
   ([#74](https://github.com/EbookFoundation/regluit-provisioning/issues/74)): treat the servers as
   *cattle, not pets*. **Test is rebuilt from scratch by the playbook every month**, and that rebuild
   is the standing proof the playbook works. **Prod is replaced, not patched**: build a fresh box from
   the playbook, smoke it, switch, keep the old box 24 hours, delete it — the same shape as the MySQL
   upgrade on 9/12. That redefines #56.
3. **Before any box is treated as replaceable, we list what on it isn't** (a state inventory), and
   the logs get a proper home: which logs we keep, for how long, shipped off the box to S3, and a
   README section Eric can read. One finding makes this urgent: the playbook's cleanup cron deletes
   rotated app logs (including download logs) after 30 days, so an interim archive copy comes first.

For the two indexes, I recommend applying them **by hand over SSH, one migration at a time, under a
written one-time exception**, after re-rehearsing on test (now on MySQL 8.4 — the 9/10 rehearsal was
on 8.0). The hand commands are what the playbook would run, so the playbook adds repeatability, not
safety, for this change; and a live-table index build is the wrong place for new automation's first
production run. The indexes live in the database, so later playbook runs or server rebuilds won't lose
them (§3b, "Durability"). Deleting the old MySQL 8.0 instance becomes a **scheduled step** (default
Fri 9/18, 09:00) with explicit go criteria: indexes settled, no regression, a real restore test of
current production's backups, and Eric told at the 9/17 call.

The caveat: this plan is built from notes, repo reads, and session records. Several server facts
(exact venv layout, Django version actually installed, which package names resolve on 24.04, test's
current migration state) are marked **verify** and have read-only pre-checks attached. The planner
did not re-check any of them live. The log-deletion finding comes from master's templates; what the
live prod box actually runs is also a **verify** item.

---

## North star

RY, 2026-09-14 (as quoted in [#74](https://github.com/EbookFoundation/regluit-provisioning/issues/74)):

> *"we easily let our migration playbooks get stale and we need a more robust way to keep them
> working well. In many ways what we want is a regular build of our servers, treating them more like
> 'cattle than pets'. Important part though is making sure that we preserve important cumulated
> state on the servers -- logs, etc."*

Eric's only requirement (relayed via the CoS, 2026-09-14): **the right logs are saved, in a place he
understands, documented in the playbook.**

**This is a pattern, not a one-off.** "Production built or run from something that never made it back
to the main branch" has multiple documented manifestations in 2026 — largely from the same unreconciled
June cutover, which is exactly why it keeps resurfacing:
- **App repo, June**: prod was deploying the ad-hoc `prod-green` app branch; on 6/18
  [Gluejar/regluit#1171](https://github.com/Gluejar/regluit/pull/1171) aligned **master** to the deployed
  SHA (the production-branch release and deploy repoint were separate steps) — dev-journal 2026-06-18.
- **Provisioning, June → today**: the 6/17 cutover built prod from `feature/prod-green`, the lineage of
  [PR #25](https://github.com/EbookFoundation/regluit-provisioning/pull/25) (python_version
  parametrization that grew into the cutover), **closed unmerged 9/10**. Consequences since: the
  6/26 silent Beat-schedule revert (fixed by
  [#55](https://github.com/EbookFoundation/regluit-provisioning/pull/55)) and 9/14's `python3.8` failure.
- **OOM hardening**: [#45](https://github.com/EbookFoundation/regluit-provisioning/issues/45) records
  that "production was running config that never made it back to `master`," so applying the saved
  recipe "could have broken TLS"; the 8/18 box-local certbot fix
  ([#67](https://github.com/EbookFoundation/regluit-provisioning/issues/67)) is the same shape.
(I checked the provisioning repo's closed-unmerged PRs and found nothing earlier than 2026 that fits;
older history outside GitHub wasn't searched.) Regular rebuilds from master are the structural answer:
**monthly rebuilds expose the drift that their acceptance checks exercise** — anything a rebuilt box
needs but master lacks shows up as a failed or hand-assisted build. Precisely: test's rebuild shares
the existing test database, so it doesn't prove every piece of production state is reproducible; S0
and §6b cover that side.

What that means for this plan:
- A playbook is proven by **building from it on a schedule**, not by dry-running it (§6c).
- Production changes of the risky kind happen by **replacement**, Blue/Green-style (§6d).
- **Accumulated state is named, owned, and off the box** before any box is disposable (§6a, §6b).
- **Guardrail**: same tools — Ansible, Ubuntu, AWS CLI, cron, S3. No platform rewrite (§6e).
- Near-term work (indexes, `migrate.yml`, W77) still happens, because the next rebuild is weeks away.

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
| Logs live only on the box. Master's `prod.py.j2`: `downloads.log` 20 MB × 9 backups, `unglue.it.log` 5 MB × 5. Master's `cron.yml`: deletes `/var/log/regluit/*.log.*` older than 30 days; Apache daily logs deleted after 14 days; Celery worker log truncated weekly. Live prod values: **verify** (S0) | provisioning master `roles/regluit_prod/templates/prod.py.j2`, `tasks/cron.yml` |
| No off-box copy of logs exists; pre-6/18 logs only in snapshot `snap-0b9d1d7dec2c6b95f`, destination undecided since 7/2 | [#60](https://github.com/EbookFoundation/regluit-provisioning/issues/60) |
| TLS renewal fix of 8/18 is box-local (certbot webroot + deploy hook); master's `certs.yml` uses a different mechanism; a rebuild would regress it | [#67](https://github.com/EbookFoundation/regluit-provisioning/issues/67) |
| No EC2 launch automation exists in provisioning (roles configure an existing box) | repo read |
| Umbrella issue with definition of done: state inventory, logs, monthly test rebuild, prod Blue/Green, no rewrite | [#74](https://github.com/EbookFoundation/regluit-provisioning/issues/74) |
| Pending: delete `production-2024-old1` + B/G object `bgd-jdgebq3wemv2dony` (stops ~$555/mo Extended Support); W77 apt `.15→.16`; W128 staging IAM user (deadline 9/18); a credential remediation (private tracker); provisioning#68 stale since 8/28 | `PREFLIGHT_2026-09-14.md`, W128 note |

---

## 2. Principles

- **Don't lean on a playbook we can't run.** No real untagged `setup-prod.yml` run over the current
  prod box at all; prod gets **replaced** from the playbook (§6d) only after test has been rebuilt
  from scratch by the same playbook (§6c). Dry runs find drift; they never authorize a run.
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

**Durability of the hand-applied indexes** (RY asked whether a later or revised playbook run could lose
them). Roughly: no — the indexes live in the database, not on the web box, and Django will have
recorded them as applied. More precisely:
- The indexes are part of the `core_work` table in RDS (`production-2024`). No playbook task drops
  them; the replacement-build procedure (§6c, §6d, with `run_migrations=false`) doesn't touch the
  schema at all, and rebuilding the web box doesn't touch RDS.
- A hand-run `manage.py migrate core 0033/0034` writes the same `django_migrations` rows a playbook
  run would. So `migrate.yml`, a future full role run, or a rebuilt box all see 0033/0034 as
  **already applied** and do nothing with them.
- The ways they could go away are all deliberate or visible: (1) a rollback (`migrate core 0033` /
  `0032`, or a hand `DROP INDEX`); (2) a future code change that removes them from `Work.Meta.indexes`
  plus a generated `RemoveIndex` migration — which `migrate.yml`'s exact-plan gate would show before it
  ran; (3) running the site on a database that never had them — a brand-new database (not planned), or
  a restore from a snapshot/point-in-time **before** they were applied (e.g.
  `production-2024-pre-mysql84-20260912`, or refreshing test's DB from an older prod snapshot). In case
  (3) the `django_migrations` rows would normally be missing too, so `migrate.yml` inspect **reports
  0033/0034 as pending** (inspect never applies anything). The response is: reconcile physical state
  under §3c — a restore point that fell between a DDL finishing and Django recording it, or during an
  interrupted rollback, can leave index and record disagreeing — then apply through the normal
  `migrate.yml` gate as a separately approved step. Visible, not silent.
- **Verification** (added to W2.1, the first `migrate.yml` run on prod, and to every monthly test
  rebuild, §6c step 4): `DJ showmigrations core` shows both `[X]` **and** the §3c physical query shows
  both index names with their expected columns.

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

Not in PR-B: certs (#67), template parity, `group_vars/test` vault — #66 / W128, all on the cattle track (§5, §6).

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
5. pip is **not** exercised by tagged runs; it is proven only by the first from-scratch test rebuild (§6c, T1).
6. Prod: `setup-prod.yml --tags bootstrap,python --check`, then real in Window 2. Expect no change.

### 4d. What W77 becomes
W77 (`python3.12` apt `3.12.3-1ubuntu0.15 → .16`) is an **OS package revision**: `python_version`
stays `"3.12"`, the venv still points at `/usr/bin/python3.12`, PR-B is unaffected. W77 stays a
one-off apt bump (RY 9/12: no EBS snapshot) — but its rollback must be made real first (W2.3). It
needs `apache2` (mod_wsgi loads libpython), `celeryd`, `celerybeat` restarts. After PR-B, a future
*minor* change (e.g. an OS release with `python3.13`) shows up as the venv assertion failing — that
change is a var + venv rebuild, a separate project.

### 4e. From "fix the playbook" to "rebuild from the playbook"
Rev 4 replaces the old "road to a full `setup-prod.yml` run" with §6: the playbook is proven by
**building fresh boxes from it** (test monthly, prod Blue/Green-style), not by running it over a
long-lived box. We never run a full untagged `setup-prod.yml` over the current prod box; it gets
replaced instead. PR-B is still needed — it's the first thing a from-scratch build hits.

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
*PC-3 and PC-4 run **tonight, Mon 9/14**, read-only, so W1.2's gate facts (`PROCESS` grant,
`mysql.rds_kill_query` access, `performance_schema` on/off, storage headroom) are known before Tuesday.
Status 12:25 PT: **not yet run** — the planner's attempt was blocked by the Claude Code auto-mode
classifier ("Production Reads") and was not retried. Needs RY to run them or approve a session to.
Results get recorded with timestamps in §1. If they aren't in hand by Tue 09:00, W1 waits.*
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

### Window 1b — scheduled: old MySQL 8.0 deletion (default **Fri 9/18, 09:00 PT**; RY hands-on)

RY: *"do that after we're sure things are ok --> might mean scheduling."* So this is a **calendar-held
step with explicit go criteria**, not "a day later." (The CoS relay said "Fri 9/19"; 9/19 is a Saturday,
so the default is Friday **9/18**. RY picks the date — D2.) The CoS files the hold; nothing is created
on RY's calendar by the planner.

**Go criteria — all must be true at the go/no-go, recorded in `SESSION_SUMMARY.md`:**
1. **Indexes applied ≥ 24 h** (by 9/18 it would be ~72 h if W1 runs Tue 9/15) and the W2.1-style
   durability check passes (both `[X]`, both index names present).
2. **No regression since the indexes**: CloudWatch `CPUUtilization` (hourly max/avg),
   `DatabaseConnections`, `ReadLatency`/`WriteLatency` for the period since W1 are no worse than the
   9/12–9/14 baseline in `PREFLIGHT_2026-09-14.md`; app error log shows no new DB error class; `/`,
   `/free/`, `/accounts/login/` 200.
3. **Current prod is verified restorable** — old1 is not the recovery path for current data, prod's own
   backups are: `BackupRetentionPeriod` ≥ 7, `LatestRestorableTime` within the last 10 min, **and a
   real restore test** on **Wed 9/16** (moved off Thu 9/17, RY's heaviest day; owner: RY runs, sibling prepares and verifies; **cleanup deadline:
   same day 17:00 PT**, whether validation passed or failed). The restore command is written out and
   reviewed before the day, with every choice explicit rather than defaulted: `--profile gluejar_member
   --region us-east-1`; `--source-db-instance-identifier production-2024`;
   `--target-db-instance-identifier regluit-restoretest-20260916`; `--restore-time` = a recorded UTC
   time **after W1.6 completed** (both migrations applied); `--db-instance-class` = a smaller class
   checked for compatibility with the source's storage type/IOPS; `--no-multi-az`;
   `--no-publicly-accessible`; `--db-subnet-group-name` and `--vpc-security-group-ids` = prod's DB
   subnet group and DB security group IDs (read from `describe-db-instances`); `--db-parameter-group-name
   regluit-prod-mysql84` and prod's option group; `--no-deletion-protection`; backup retention: if the
   installed CLI's restore command accepts a retention option, set the minimum; otherwise record the
   inherited value (**verify** with `aws rds restore-db-instance-to-point-in-time help`), and the delete
   removes automated backups (`--delete-automated-backups`, the CLI default, stated explicitly). **Cost**: a smaller class
   still restores prod's full **allocated storage** (200 GB on 9/12) — estimate compute, storage, any separately
   billed IOPS/throughput, and backup charges for the hours kept, before running (expected: a few
   dollars). Before connecting to `regluit-restoretest-20260916`: `describe-db-instances` for
   that literal identifier shows `available`, Single-AZ, not publicly accessible, the expected subnet
   group/security groups/parameter group, and its **endpoint address** (recorded).
   **Probe without any chance of querying prod**: from the prod web box, a one-off script run with
   `DJ shell` that builds a **separate connection** from a deep copy of `settings.DATABASES['default']`
   with `HOST` set to the recorded temporary endpoint, rejects any `OPTIONS` that set host or socket,
   keeps TLS options, opens it under its own alias (never mutating or using the default connection or
   the ORM), and on that cursor: asserts the connection's effective host equals the recorded
   temporary endpoint (records `@@hostname` for diagnostics only — it isn't an RDS endpoint) and
   `SELECT DATABASE()` equals the expected schema, then prints only non-secret
   identity and counts, closing the connection in `finally`. Checks, with tolerances fixed beforehand:
   `core_work` row count within ±1% of the same count taken on prod at the restore time;
   `django_migrations` has both 0033 and 0034; the §3c physical query shows both indexes with their full
   definitions. Then, immediately after re-verifying the identifier:
   `aws rds delete-db-instance --db-instance-identifier regluit-restoretest-20260916
   --skip-final-snapshot --delete-automated-backups`, and poll until `DBInstanceNotFound` — a describe
   that fails for credentials/network reasons is **not** deletion evidence. The temporary instance never
   appears in any app settings. What this proves: the backups restore, and the sampled checks hold at the
   recorded point — not full application recovery or production recovery time. (Alternative if RY
   prefers: metadata-only check — D2 — in which case restorability is asserted, not proven.)
4. **Old1 unused**: `DatabaseConnections` for old1 is 0 at **every** datapoint since the 9/12 16:04 UTC
   switchover (a missing datapoint is not a zero — gaps are a no-go), and PC-5 found no consumer. The
   switchover was 09:04 PT 9/12, so Fri 9/18 09:00 PT is just under 6 days (5 d 23 h 56 m), **not the
   7 days rev 3 asked for** — the Friday default revises that criterion and needs RY's explicit yes
   (D2). Seven full days completes Sat 9/19 09:04 PT; the weekday fallback is Mon 9/21 09:00 PT (~9 days).
5. **Eric informed** (9/17 call) of the actual approved deletion date and that the final snapshot is
   kept; updated if the date moves.
Any criterion false → no-go; pick a new date.

| # | Step | Verify | Rollback | Stop if |
|---|---|---|---|---|
| W1b.1 | `aws sts get-caller-identity`; describe B/G `bgd-jdgebq3wemv2dony` | status `SWITCHOVER_COMPLETED`, source `…old1`, target `production-2024` | — | anything else |
| W1b.2 | `aws rds delete-blue-green-deployment --blue-green-deployment-identifier bgd-jdgebq3wemv2dony` (**no `--delete-target`**) | describe → not found; both instances `available` | none needed | error |
| W1b.3 | Check old1 `PendingModifiedValues` is empty; then `modify-db-instance --db-instance-identifier production-2024-old1 --no-deletion-protection --apply-immediately` | `DeletionProtection=false`, no other attribute changed | re-enable protection | pending modifications present (would apply too) |
| W1b.4 | Read the identifier back aloud; `delete-db-instance --db-instance-identifier production-2024-old1 --final-db-snapshot-identifier production-2024-old1-final-<YYYYMMDD of the go date>` | snapshot `creating`→`available`; old1 `deleting`→`DBInstanceNotFound`; `production-2024` untouched, deletion protection still ON; site 200 | restore old1 from final snapshot (hours; it's 8.0 data frozen at 9/12) | delete call errors → **re-enable deletion protection** on old1 unless deliberately retrying |
| W1b.5 | Next day: Cost Explorer shows the MySQL 8.0 Extended Support line stopped. Snapshots bill storage only. Keep `production-2024-pre-mysql84-20260912` ~2 weeks, then decide | recorded | — | line continues → look for any remaining 8.0 *instance* |

### Credential track — independent, by the 9/18 W128 deadline (RY + Eric decisions)
Not blocked by provisioning work: the rotation path uses `--tags config`, which PR-B guarantees is
unchanged. Order per the W128 note and the private runbook: mint staging IAM user → give test its own
credentials (W128 / #68) → rotate the production credential. IAM create/deactivate/delete steps are
RY's hands. If W128 slips, use the documented test stopgap rather than delaying the rotation.

### Between windows (no prod mutation)
PR-A and PR-B written by a sibling, Codex to LGTM, RY merges; §3a and §4c test proofs. **L0 and S0
start now in parallel** (see the cattle track below) — they are read-only on prod and don't wait for
the windows.

### Window 2 — after PR-A/PR-B merge and test proofs (RY hands-on)

| # | Step | Verify | Rollback | Stop if |
|---|---|---|---|---|
| W2.1 | `migrate.yml` **inspect** on prod (`--check`, then real — both read-only) | reports nothing pending; identity printed; `changed=0`; **index durability check**: `showmigrations core` 0033/0034 `[X]` and `expected_indexes` (§3a step 7) finds both index names with expected columns. Exception 2026-09-15-A now expires | none | anything pending not explained; either index missing → stop, §3c |
| W2.2 | `setup-prod.yml --tags bootstrap,python --check`, then real | `.pth` unchanged; assertion ok | restore saved `.pth` copies (PC-3) | any change/failure |
| W2.3 | **W77 on test, rollback made real first**: list the installed set `dpkg -l 'python3.12*' 'libpython3.12*'` at `.15`; `apt-get download` each at `3.12.3-1ubuntu0.15` into `/var/cache/regluit-rollback/` (APT authenticates via signed repository metadata + package hashes; download fails if they don't match) and record package/version/arch/SHA-256 of each file, re-verified with `sha256sum -c` before any rollback; `apt-get -s install <each>=<.16 version>` (exact target version, simulated) — confirm nothing unrelated is pulled; then real install with exact versions; restart apache2/celeryd/celerybeat | all at `.16`; services active; `/`, `/free/`, `/accounts/login/` 200; `venv/bin/python -c 'import ssl, sqlite3'` | **rehearse on test now**: `dpkg -i /var/cache/regluit-rollback/*.deb` (simulate with `apt-get -s install ./…deb` first), restart, smoke; then re-apply `.16` | simulation pulls unrelated packages; staged `.deb`s incomplete; interrupted apt → `dpkg --configure -a` then reassess before anything else |
| W2.4 | W77 on prod — same procedure, staged `.deb`s first, ≥ 1 h after test is clean | same + CloudWatch/app errors 30 min | staged `.deb`s | same |
| W2.5 | W77 on Linode boxes — per W77 note | — | — | — |

W77 note under the rebuild model: a rebuilt test box comes up with current packages anyway, so W77
on test is mainly the **rollback rehearsal**. Prod still needs W77 because a prod rebuild (§6d) is
weeks away. A scheduled prod rebuild can at most defer W2.4 to a dated fallback window, never cancel
it (decision D6).

### Cattle track — L0 and S0 start now; the rest follows the near-term windows (content in §6)

**What the inventory view changed in the near-term sequence** (rev 4): (1) **L0, an interim log
archive, moves to the front** — it's read-only on prod and addresses possible ongoing loss; (2) the
old "Window 3: dry-run the full playbook" is **dropped** — T1 (a real from-scratch test build)
replaces it; (3) Windows 1, 1b and 2 are otherwise unchanged: the index work, old-DB delete and W77
don't touch any accumulated state on the web box. (One interaction to keep: W1.7 and W2.4 read the
app and Celery logs for errors — L0's copy doesn't change those files.)

Order is fixed by dependencies. Each item is its own PR or issue with a Codex round, and RY merges it.
Owners are listed. Only three steps here touch prod: L0 (read-only copy), C1p (PR-D rollout, its own
go/no-go) and P1 (the rebuild and switch).

| # | Step | Owner | Depends on | Done when |
|---|---|---|---|---|
| L0 | **Interim log archive (this week; not during W1/W1b/W2 observation periods)**: from prod, read-only, archive `/var/log/regluit/` (all files incl. rotated `*.log.N`), `/var/log/celery/`, and `/var/log/apache2/` (all dated files still present; record the date range, since older days are already gone — a known historical gap). Method: on the box, `sha256sum` + size manifest printed to stdout; then `tar` to stdout over SSH → controller file → verify `tar -t` readability and re-hash every member against the manifest (any file whose size/hash changed mid-copy — e.g. a rotation race — is re-copied, or listed as changed); then upload with `aws s3 cp` to a private dated prefix (§6b) and verify the uploaded archive's checksum by download from a reader identity. Nothing written on the box. #60's pre-6/18 log: already copied into prod as `downloads.log.6` (7/2) and **will be deleted by rotation** once it passes `.9`; archive it from the snapshot (method in #60: snapshot → temp volume mounted read-only on another box, never booting old prod) and label it so later analysis doesn't double-count it against the on-box copy | sibling prepares, RY runs the upload | nothing | manifest + archive checksums recorded on #60/#74; **why urgent**: master's cron deletes rotated regluit logs after 30 days, Apache logs after 14, and rotation itself drops the oldest `downloads.log.9` — **verify** on prod what the live crontab and handlers actually do |
| S0 | **State inventory** (§6a, PR-C) — read-only discovery on prod + test, table committed as `STATE.md` | sibling (discovery), RY (review), Eric (confirms the logs rows) | nothing; runs alongside L0 | every row has a class, an owner, and a **verified preservation or reconstruction method, or an explicit discard decision** |
| C1 | **Logs deliverable** (§6b, **PR-D**): shipping + retention + README "Where the logs are" for Eric | sibling writes, Codex, Eric reads the README, RY merges | S0, L0, D9–D11 | merged **and** proven on test per §6b acceptance |
| C1p | **PR-D rolled out to current prod** (narrow tagged run, own go/no-go; includes attaching or updating the instance profile per D9 and the handler/cron changes) | RY hands-on | C1 | a real prod upload retrieved by the reader identity; retention rules verified; independent freshness check green; Eric has accepted the README |
| C2 | PR-A, PR-B **implemented, reviewed, merged, narrow proofs passed** (§3a, §4c steps 1–4). Integrated acceptance (pip, full role) happens at T1 | sibling, RY | — | as stated |
| C3 | [#66](https://github.com/EbookFoundation/regluit-provisioning/issues/66)/W128: `group_vars/test` complete + vault | RY + Eric decisions, sibling | credential track | `setup-test.yml --tags config --check` renders on test |
| C4 | [#67](https://github.com/EbookFoundation/regluit-provisioning/issues/67): certbot managed by provisioning — implemented and reviewed, with the **Blue/Green certificate sequence chosen** (§6c step 4). Its "fresh provision" and "applied to production" acceptance items are demonstrated at T1 and P1 | sibling, RY | S0 | implementation merged; sequence documented |
| C5 | **Replacement-build safety switches** in the role, plus hand-edits found by S0 folded in or retired: `run_migrations` (default **false** for replacement builds; the `Migrate database` task honours it), `schedulers_enabled` (default **false** on a replacement build: celerybeat, celeryd auto-start, the regluit crons, and the handlers that restart them all honour it), the production-DB assertion from `feature/prod-green`, and outbound-email squelch for test | sibling | S0 | merged; each switch shown off on a throwaway box before T1 |
| C6 | Box-launch script (AWS CLI, in `scripts/`) + switch/keep/delete runbook for **test**, including the Celery handoff (§6c step 4) | sibling, RY | C2–C5 | reviewed; AWS `--dry-run` where supported |
| T1 | **First from-scratch rebuild of test** (§6c) — also the integrated acceptance for PR-B (pip, full role), #67's fresh-provision item, and PR-D on a fresh box | RY + sibling | C1–C6 | §6c "done" checklist passes; old test box terminated after 24 h |
| T+ | Monthly test rebuild (§6c cadence), each at the then-current master SHA (recorded) | sibling with RY's go | T1 | each month: pass, or a filed finding |
| P1 | **Prod rebuilt Blue/Green-style** (§6d; #56 redefined) | RY hands-on | T1 + one more clean rebuild; **the P1 provisioning SHA must itself have passed a full test rebuild** — if master has moved since the last monthly one, run an extra test rebuild at the P1 SHA | §6d checklist; old prod box terminated after 24 h with logs verified shipped |

---

## 6. Cattle, not pets — rebuilds, state, logs ([provisioning#74](https://github.com/EbookFoundation/regluit-provisioning/issues/74))

### 6a. State inventory (step S0, deliverable **PR-C** → `STATE.md` in the provisioning repo)

**Owner**: a sibling session does the read-only discovery; RY reviews; Eric confirms the logs rows.
**Why first**: you can only treat a box as replaceable once you know what on it is *not* replaceable.

**Discovery method (read-only, prod and test)**, names and metadata only, never file contents under
`/etc` or `settings/`:
- files and symlinks changed since the box was built: `sudo find /etc /opt/regluit /home /root
  /usr/local /var/www /var/lib /var/spool -xdev \( -type f -o -type l \) -newer <a file laid down at
  build, e.g. the cloud-init marker> -printf '%TY-%Tm-%Td %y %p -> %l\n'` (paths, dates and link targets
  only; excludes `venv/` and `.git/`). Because `-newer` misses files copied with old timestamps,
  **also list known state locations regardless of timestamp**: `/var/log/*`, `/var/lib/redis`,
  `/var/lib/letsencrypt` + `/etc/letsencrypt`, `/var/spool/postfix` (queued mail), `/var/spool/cron`,
  celery beat schedule file, `/var/log/celery/metrics-*.html`, `/run` units' state dirs, mounts (`findmnt`)
- effective Django settings for storage and sessions (`DEFAULT_FILE_STORAGE`/`STORAGES`,
  `SESSION_ENGINE`, `CACHES`, `CELERY_*` URLs) printed by name → backend class/host only, no secrets —
  to confirm media is really S3 and sessions aren't in files or local Redis
- installed packages vs the playbook's lists (`apt-mark showmanual`); enabled systemd units and timers
  (`systemctl list-unit-files --state=enabled`, `list-timers`); `crontab -l` for root/ubuntu/celery and
  `/etc/cron.d/`; `ufw status`; users and `~/.ssh/authorized_keys` *line counts*; swap; mounts
- log directories: sizes, oldest/newest file dates, and what writes/rotates/deletes them
- the rendered-vs-template comparison already available: `setup-prod.yml --tags config --check`
  (known clean 9/14 for the config-tagged files)

**Initial table — known today (to be completed by S0; ✅ = off-box already, ❌ = only on the box)**

| Item | Class | Where it lives now | Off-box? | Owner / issue | Notes |
|---|---|---|---|---|---|
| Database (all app data) | accumulated state | RDS `production-2024` / `test-2026-08-23` | ✅ | — | Rebuilds point at the existing RDS; PITR is the backup |
| Uploaded media / ebook files | accumulated state | S3 | ✅ | — | per #74 |
| Secrets / settings values | build input | ansible-vault in this repo | ✅ | W128/#66 for test | test's `prod.py` is hand-managed today (#66) ❌ |
| App code, venv, static files | build product | GitHub + pip + `collectstatic` | ✅ (rebuildable) | PR-B | venv rebuild follows `requirements.txt` pins |
| **`/var/log/regluit/downloads.log*`** | **accumulated state — business record** | prod box | ❌ | #60, PR-D | download history; rotates at 20 MB with 9 backups per master's `prod.py.j2` (**verify** live), and master's cron deletes `*.log.*` older than 30 days |
| `/var/log/regluit/unglue.it.log*` | accumulated state (diagnostic) | prod box | ❌ | PR-D | 5 MB × 5 per template |
| `/var/log/regluit/doab-harvest.log` | accumulated state (diagnostic) | prod box | ❌ | PR-D | cron appends; not rotated (active file's mtime keeps it from the 30-day delete) → grows |
| Pre-6/18 logs from old prod | accumulated state | EBS snapshot `snap-0b9d1d7dec2c6b95f`; also copied onto prod 7/2 as `downloads.log.6` | ✅ (snapshot) | #60 | the on-box copy renumbers on each rotation and is deleted past `.9` → L0 archives it; don't double-count the two copies |
| Apache access/error logs | accumulated state (traffic evidence) | `/var/log/apache2/YYYYMMDD_*.log` via cronolog | ❌ | PR-D | gzip after 2 days, deleted after 14 days (cron); up to ~1 GB/day raw under bot load |
| Celery worker/beat logs | diagnostic | `/var/log/celery/` | ❌ | PR-D | worker log truncated weekly to 5,000 lines |
| systemd journal | diagnostic | box | ❌ | — | capped 500 MB; not shipped (proposed) |
| TLS certificate lineage + renewal config + deploy hook | **hand-edit since June** | `/etc/letsencrypt/` on prod | ❌ | #67 | the 8/18 renewal fix is box-local; rebuild would regress it |
| Box built from unmerged `feature/prod-green` | drift | whole role | — | #56, PR-B | template parity items |
| Redis db 0 — Celery broker (queued, reserved, scheduled/ETA tasks) | transient state, **per box** (`redis://127.0.0.1:6379/0`) | box | ❌ | §6c/§6d handoff | new workers can't see the old queue; handoff drains with workers running |
| Redis db 1 — Celery result backend | transient state, per box (`…/1`) | box | ❌ | S0 decision | `CeleryTask` rows in MySQL look results up here; results for tasks run on the old box become unavailable after a switch — S0 finds what reads them and records keep/discard |
| Postfix mail queue | transient state | `/var/spool/postfix` | ❌ | §6c/§6d handoff | flush (`postqueue -f`, confirm empty) before stopping the old box |
| Celery beat schedule file (last-run times) | transient state | box | ❌ | §6d | a new box may run or skip one periodic run; accept, but check which jobs send email |
| `~ubuntu/dump.sh` output (`unglue.it.sql.gz`) | ad-hoc artifact | prod home dir | ❌ | S0 | find out if anything relies on it; RDS snapshots are the real backup |
| SSH host keys, EIP, security groups, DNS | infrastructure identity | AWS / box | partial | C6 | host key changes on rebuild → `known_hosts` update step |
| Anything else hand-edited since 6/18 | unknown | — | — | S0 | the point of the discovery pass |

### 6b. Logs (step C1, deliverable **PR-D**) — Eric's requirement

**Eric's only requirement**: the right logs are saved, somewhere he understands, and the playbook
documents it. So the deliverable is judged by whether Eric can answer "which logs, how long, where"
from the README alone.

**Proposal (for Eric and RY to confirm, D9/D10):**

| Log | Why keep it | On-box retention | Off-box destination | Off-box retention |
|---|---|---|---|---|
| `downloads.log*` | business record (download counts) | as today | S3 `s3://<logs bucket>/unglue.it/<env>/regluit/downloads/YYYY/MM/` | **indefinitely** (small: ~20 MB per ~5 weeks) |
| `unglue.it.log*` | app errors | as today | `…/regluit/app/YYYY/MM/` | 1 year |
| `doab-harvest.log` | harvest history | add rotation (weekly) | `…/regluit/doab/YYYY/MM/` | 1 year |
| Apache access + error | traffic, bot and abuse evidence | 14 days (as today) | `…/apache/YYYY/MM/DD/` (gzipped) | 90 days |
| Celery worker + beat | task failures | as today | `…/celery/YYYY/MM/` | 90 days |
| journald | OS debugging | 500 MB cap | not shipped | — |

**Mechanics (same tooling — no new platform)**: an Ansible-installed shipper script + cron, S3 via
the AWS CLI, S3 lifecycle rules. Exact design is PR-D's; the plan fixes what PR-D must **prove**.

**PR-D acceptance requirements** (Codex rev-4 r1; all must be demonstrated on test before C1p):
1. **Every loss mechanism is covered**, not just the delete crons: Python `RotatingFileHandler`
   renumbering and dropping `.9`; the weekly Celery `tail -5000` truncation (which keeps no archive
   and can leave a writer on the unlinked file); Apache's cronolog + gzip + 14-day delete;
   `doab-harvest.log` growth. Each is either replaced by a mechanism that only discards what has been
   shipped, or explicitly accepted in the README.
2. **Coordinated writers**: several mod_wsgi processes write the same Django log files and
   `GroupWriteRotatingFileHandler` only changes permissions — so rotation must not be left to
   uncoordinated handlers. PR-D picks one of: `WatchedFileHandler` + `logrotate` (`copytruncate` is
   *not* acceptable for the downloads log) with a post-rotate reopen, or another design shown to
   produce immutable closed segments under concurrent writers.
3. **Bounded exposure**: a maximum unshipped age per log (proposal: 24 h for `downloads`, including a
   quiet log — rotate or snapshot-ship daily even if under size), and a written statement of what an
   unexpected instance loss can lose.
4. **Unique object keys** across rotations and instances (host id + segment start/end or content hash);
   no upload may overwrite an existing key (`--if-none-match`-style conditional put, or keys that
   can't collide, verified in a test).
5. **Content receipts**: the shipper records size + SHA-256 per segment; a **reader identity** (not the
   uploader) verifies them. Deletion on the box only after a verified receipt.
6. **Failure paths exercised on test**: shipping failure (no credentials / no network) → files
   accumulate, nothing deleted, alert raised; retry succeeds; retrieval of a given day's download log
   by following the README.
7. **Independent freshness check** that doesn't run on the box it's watching (a cron that never
   starts can't report itself): a daily check from outside — e.g. the controller-side cadence sweep, or
   an S3/CloudWatch alarm — alerts if the newest `downloads` object is older than 36 h or box disk use
   passes a threshold. Choice in PR-D.
8. **Final flush with manifest** in every switch runbook (§6c, §6d): stop the services that write, run
   the shipper on all remaining files including live ones, and verify a full manifest (sizes +
   checksums) with the reader identity **while the instance is still running** — a stopped instance
   can't upload.

**Credentials (D9)**: default an **EC2 instance role**, which requires S0 first: an instance has at most
one role, so check whether prod/test already have one and what uses it, and extend it (or replace it
with a superset) rather than bolting on a second. Verify the **effective identity of the shipper under
its real cron user and environment** (`aws sts get-caller-identity` in that context) — a shared
credentials file or environment variables would silently take precedence over the instance role.
Uploader: `s3:PutObject` on its own env prefix only (`unglue.it/prod/…` vs `unglue.it/test/…`), plus
multipart and KMS permissions if the bucket requires them. `PutObject` can overwrite, so it isn't
append-only protection — requirement 4 carries that. Reader: a separate identity (RY/Eric, and the
freshness check) with list/get only. (Controller-side commands keep using the `gluejar_member`
profile; that's a different identity from the instance role.)

**Bucket and retention (D11)**: before changing anything, **read and save the bucket's existing
lifecycle configuration** (a lifecycle PUT replaces the whole set) and merge. Rules are per prefix, with
`downloads/`, the L0 archive prefix, and the existing 2024 DB export **explicitly outside any expiration
rule**. If versioning is on, define noncurrent-version expiry for the expiring prefixes only.
Retention counts from **upload time** (S3's clock), which the README says in words. Public access
blocked; Eric's read access verified by Eric opening a file.
- README section **"Where the logs are"**, written for Eric: a table like the one above, how to find
  a given day's download log in the S3 console, how long each is kept, what happens at a rebuild,
  and who to ask. No Ansible knowledge needed to read it.

### 6c. Monthly from-scratch rebuild of test — the standing proof (replaces the rot check)

A failing rebuild is a **finding, not an outage**: the old test box keeps serving until the new one
passes.

**Proposed `Queue/_CADENCE` entry — "Rebuild test.unglue.it from the playbook"** (monthly, sibling
with RY's go for the AWS steps, ~half a day of wall time, mostly waiting):
1. From a verified detached worktree of provisioning master: record the **provisioning SHA** and the
   **app SHA** (the app branch tip resolved once; the build checks out that SHA, not the moving
   branch). Launch a fresh Ubuntu 24.04 instance with the C6 launch script (same instance type,
   security group, instance role; tags `role=test`, `build=<date>`).
2. Before provisioning, prove the new code needs no schema change: (a) controller-side, the PR-A
   comparison between the old box's app SHA and the recorded app SHA lists **no new migration files**,
   and (b) `migrate.yml` **inspect** on the old box shows nothing pending. Either fails → stop;
   migrations go through their own release procedure first (deploy + `migrate.yml` on the serving
   box), never inside a rebuild. After provisioning, `migrate.yml` inspect on the new box must also be
   empty before any smoke.
3. Run `setup-test.yml` **untagged, for real**, against the new box (temporary inventory entry), with
   `run_migrations=false` and `schedulers_enabled=false` (C5). Because both boxes share the test RDS,
   the build must not change the database: no migrate, no beat, no crons, no outbound mail (squelch
   verified — test's DB is a prod copy with real addresses). `set_site_domain` can create or update
   the Site row (domain *or* display name), so on replacement builds C5 **skips it and asserts the
   existing Site values read-only** instead. Identity assertion: DB host is test's, never prod's.
4. Smoke the new box without the public IP: HTTP by host header for `/`, `/free/`, a work page, login;
   `migrate.yml` inspect = nothing pending, **with the index durability check** (0033/0034 `[X]` and
   both index names present on test's DB — §3b); a log-shipping test upload to the test prefix. A **Celery round-trip** is deferred to step 5f because the new box's
   workers are deliberately disabled until then. **Certificate issuance** is a separate constraint:
   HTTP-01 validation reaches whichever box holds the IP, so the sequence chosen in C4 decides: either (a) securely transfer the
   current valid certbot lineage to the new box before TLS smoke (then smoke HTTPS with correct SNI via
   `curl --resolve test.unglue.it:443:<new ip>` with verification on), or (b) a bounded post-switch
   bootstrap with a stated maximum TLS gap and a rollback if issuance fails.
5. **Switch — the handoff** (same procedure in both directions, including rollback):
   a. maintenance page on the old box (blocks new producers);
   b. stop beat and the regluit crons on the old box; wait for running cron jobs and requests to finish;
   c. **keep old workers running** until the broker queue (db 0), reserved and ETA/scheduled tasks are
      empty (`celery inspect active/reserved/scheduled` + Redis `LLEN`); anything that won't drain →
      postpone, or a task-by-task keep/discard decision by RY; then stop workers;
   d. flush the old box's mail queue (`postqueue -f`, confirm empty);
   e. move the Elastic IP; certificates per C4's sequence;
   f. enable schedulers on the new box (`schedulers_enabled=true`, tagged run) only now that the old
      side is confirmed quiet; Celery round-trip; maintenance off on the new box; HTTPS smoke.
6. **Keep the old box 24 h with services stopped but the instance running**; then §6b final flush with
   manifest verified by the reader identity; then stop, snapshot the root volume, terminate; record ids.
   Rollback within the 24 h = step 5 in reverse (quiesce the new box first).
7. Record: dated line in `[[Unglue.it Infrastructure]]` and #74; any failure → provisioning issue
   with the failing task, and the old box keeps serving.
**Done** = a box built only from master + vault serves test.unglue.it, and no hand step was needed. Any
hand step is a finding to fold into the playbook before next month.

### 6d. Prod rebuilt Blue/Green-style — [#56](https://github.com/EbookFoundation/regluit-provisioning/issues/56) redefined

#56 becomes: **build a new prod box from the playbook → smoke → switch → keep the old box 24 h →
delete** — the same shape as the MySQL Blue/Green on 9/12. Gate: T1 plus one more clean test
rebuild, **and the P1 provisioning SHA must itself have passed a full test rebuild** (extra rebuild at
that SHA if master moved); S0 rows for prod all closed; log shipping live on current prod (**C1p**);
#67 certbot procedure rehearsed on test.

Outline (full runbook written at the time, Codex-reviewed, RY hands-on):
1. Same as §6c steps 1–3 against `production-2024`: pinned provisioning + app SHAs, empty migration
   plan required, `run_migrations=false`, `schedulers_enabled=false`, outbound email off, identity
   assertion. **No schema change is allowed between building the new box and the end of the 24 h
   rollback period**, so old and new code stay compatible with the one shared database.
2. Smoke as §6c step 4, with the certificate sequence proven on test; RY and Eric spot-check.
3. Switch using §6c step 5's handoff in a short maintenance window. **Prod-only addition**: before
   step 5f enables any email-producing work on the new box, restore the intended production mail
   configuration and verify one real send to an admin address; the same check applies to the old box
   on rollback. (Test stays squelched.)
4. Old box: 24 h with services stopped and the instance running; final flush with verified manifest;
   stop; snapshot the root volume (cheap insurance, like #60); terminate.
5. Rollback within the 24 h: §6c step 5 in reverse (quiesce new box, drain, move EIP back, re-enable
   old schedulers). W77 on prod closes either when W2.4 has patched and verified the current box, or
   when a replacement box serves prod with verified package versions (D6).

### 6e. Guardrail — no platform rewrite
Same tools as today: **Ansible, Ubuntu LTS, the AWS CLI, cron, S3**. Not in scope: Terraform or other
IaC frameworks, containers/Kubernetes, image bakers, autoscaling groups, a CloudWatch agent stack, or
a new CI system. If a step seems to need one of those, it comes back to RY as a decision, not a PR.

Plus (unchanged): release PRs containing migrations carry a checklist line with the exact `migrate.yml`
JSON invocation — enforced by the PR-A `deploy.yml` gate.

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
| W1b | Current prod data loss later | — | Recovery is prod PITR, not old1 — demonstrated by the 9/16 restore test if run (D2), otherwise only asserted from metadata |
| W1b restore test | Probe queries prod instead of the restored copy, falsely "proving" the restore | endpoint + `@@hostname` + `DATABASE()` assertions on a separate connection | Separate alias from a deep copy; reject host/socket `OPTIONS`; never the default connection |
| W1b restore test | Temporary instance left running (storage cost is prod's full allocation), reachable, or confused with prod | literal-identifier describe; `DBInstanceNotFound` by 17:00 | Explicit restore flags (private, Single-AZ, prod SG/subnets); cleanup on pass **or** fail; credential/network errors aren't deletion evidence |
| W1b | Friday default deletes old1 before 7 full days of zero connections | datapoint count since switchover | Explicit RY yes for the revised criterion, or move to Mon 9/21 |
| Indexes (later) | Lost by a rollback, a `RemoveIndex` migration, or running on a DB restored from before W1 | durability check in W2.1 and every monthly test rebuild | Deliberate/visible paths only; missing `django_migrations` rows show as pending in `migrate.yml` inspect → reconcile under §3c → separately approved apply |
| PR-A deploy gate | Branch moves between inspect and checkout | `HEAD != deploy_sha` | Checkout the resolved SHA, verify after |
| PR-A deploy gate | Gate blocks an urgent hotfix | pre-checkout failure | `migrations_acknowledged=true` override, documented |
| PR-A migrate.yml | Rollback target unapplies dependents in other apps | exact `--plan` ≠ `expected_plan` | Play stops before applying |
| PR-A migrate.yml | `-e` values arrive as strings | type assertion fails | JSON `-e` only; explicit type assertions |
| PR-A migrate.yml | "no-op" run writes data via `post_migrate` | — | Empty plan → `migrate` never invoked |
| PR-A | Output-format parsing breaks on a Django upgrade | strict parser fails loudly | Pin parser to installed version (PC-3); proven on test |
| PR-B | Change alters `--tags config` behaviour (credential path) | task-list diff + body/template/handler review | Required in PR; revert |
| PR-B | Tagged proofs miss apt/pip regressions | — | Separate `--tags packages` proof on test; pip proven by T1 (§6c) |
| PR-B | Venv assertion blocks a fresh build | fresh-build failure | Assertion placed after venv creation |
| W2.2 | `.pth` render changes content | `changed=1` | Stop; restore saved copies; compare |
| W2.3/2.4 | `.15` not downloadable at rollback time; partial apt transaction; package triggers restart services unexpectedly | staging step; `dpkg --audit`; service status | Stage `.deb`s before upgrading; rehearse rollback on test; `dpkg --configure -a` path; watch services |
| L0 | Logs keep being deleted by the 30-day cron before they're archived | S0 finds rotated files older than 30 days missing | L0 runs this week, before other cattle steps; PR-D changes deletes to "only after shipped" |
| L0 | Log copies contain personal data (IPs, emails in tracebacks) and end up somewhere public or in an AI transcript | bucket policy check; transcript review | Private bucket with public access blocked; copy by pipe, never `cat`/grep log contents in a CC session |
| S0 | Discovery misses a hand-edit (it's only as good as the `-newer` marker and path list) | a rebuilt test box behaves differently | T1's "no hand step needed" criterion is the backstop; every miss becomes an S0 row |
| C1 | Shipping silently stops; delete cron then can't free disk | independent off-box freshness check (§6b req. 7); disk threshold | Deletes only after verified receipt → disk fills, not data loss |
| C1 | Handler rotation or Celery truncation still drops log data the delete crons no longer do | PR-D failure-path tests (§6b req. 1–2, 6) | Replace or explicitly accept each loss mechanism |
| C1 | Upload overwrites an earlier segment with the same key | receipt mismatch | Unique keys + no-overwrite check (§6b req. 4) |
| C1/D9 | Second instance role can't be attached; or shared-file/env credentials override the role | `sts get-caller-identity` under the cron user | Extend the existing role after S0; verify effective identity |
| D11 | Lifecycle PUT wipes existing rules or a broad rule expires downloads/L0/DB export | saved pre-change config; rule review | Read-merge-write; explicit exclusions |
| C1p | Logs keep dropping on current prod until P1 | — | C1p rolls PR-D out to current prod long before P1 |
| T1/T+ / P1 | Building the new box changes the shared DB (full role runs `migrate`) | build log shows migrate ran | `run_migrations=false`; empty-plan preconditions; no schema changes during the rollback period |
| T1/T+ / P1 | Queued Celery work is stranded in the old box's local Redis | `inspect`/`LLEN` before stopping workers | Drain with workers running; postpone or task-by-task decision |
| T1/T+ / P1 | Task results for `CeleryTask` rows become unavailable (result backend is per-box Redis db 1) | S0 identifies readers | Recorded keep/discard decision per S0 |
| T1/T+ / P1 | Mail stuck in the old box's postfix queue | `postqueue -p` | Flush before stopping |
| certs.yml | Decrypted key material left on controller (`state: file` no-op) | file still present after run | Fixed by #67 (C4) before T1 |
| T1/T+ | Rebuilt test box points at prod DB, or sends real email | pre-run identity assertion; outbound mail check | C5 folds in the prod-DB assertion; email squelch verified in smoke before the switch |
| T1/T+ / P1 | Two boxes run Celery beat/crons against one DB during the switch → duplicate jobs or emails | beat logs on both boxes; duplicate DOAB runs | Stop old box's schedulers **before** starting new box's |
| T1/T+ / P1 | New box can't get a TLS certificate before the IP moves (HTTP-01 reaches the old box) | `curl --resolve` HTTPS smoke with verification | C4 chooses lineage transfer or bounded post-switch bootstrap; rehearsed on test first |
| T1/T+ / P1 | Old box terminated before its last logs shipped, or stopped so it can't upload | manifest verification by reader identity | Flush while running; manifest verified before stop/terminate |
| P1 | Rollback after switch while schema changed | — | No schema change from build to end of rollback period; rollback = §6c handoff in reverse |
| Cattle track | Scope creeps into a platform rewrite | PR proposes new tooling | §6e guardrail: that's an RY decision, not a PR |
| All | This plan's unverified facts are wrong | PC-1…PC-5 | Stop and revise the step before running it |

---

## 8. Decisions for RY (each with a default)

- **D1 — indexes now by hand, or wait for `migrate.yml`?** *Default: by hand in Window 1, one
  migration at a time, under exception 2026-09-15-A, after the test 8.4 re-rehearsal.*
- **D2 — old1 deletion date and restore test.** *Default: scheduled Fri 9/18 09:00 PT, calendar-held,
  go criteria in Window 1b, with a real point-in-time restore test on Wed 9/16.* Friday means just under
  6 days of zero old1 connections rather than rev 3's 7 — **RY must say yes to that revision**, or
  choose Mon 9/21 09:00 PT (the weekday after 7 full days, ~9 days). Waiting costs roughly $18/day of MySQL 8.0 Extended Support
  (~$555/month) for "sure things are ok." Alternative to the restore test: metadata-only backup check
  (faster, weaker — restorability asserted, not demonstrated).
- **D3 — pip `latest` → `present` in PR-B?** *Default: yes*, with the requirements-vs-installed
  reconciliation before any full run.
- **D4 — dead-host playbooks: parametrize or delete?** *Default: parametrize now; delete under #56.*
- **D5 — `deploy.yml` gate: fail-before-checkout or warn-only?** *Default: fail, with override.*
- **D6 — W77 timing.** *Default: Window 2, after the rollback `.deb`s are staged and rehearsed on
  test.* A booked prod rebuild doesn't cancel W77: it can at most defer it to a **dated fallback
  window** (default: two weeks after the deferral). W77 closes when the current box is patched and
  verified, or when a replacement box actually serves prod with verified package versions.
- **D7 — where the plan PR lives.** *Default: provisioning repo* — PR-A/B/C/D, #56 and #74 land there.
  Both repos are public; this file omits credential specifics.
- **D8 — who owns the monthly test rebuild.** *Default: a regluit sibling with RY's go for the AWS
  launch/EIP/terminate steps*, filed in `Queue/_CADENCE` by the CoS after T1 succeeds.
- **D9 — credentials for log shipping.** *Default: an EC2 instance role (extending any role the box
  already has, after S0), put-only to its environment's log prefix, with a separate reader identity*;
  alternative is a dedicated IAM user key in the vault (adds to the credential track).
- **D10 — log retention.** *Default: the §6b table* (downloads forever; app/doab 1 year; Apache and
  Celery 90 days). **Eric confirms.**
- **D11 — log bucket.** *Default: the existing `unglueit-logs` bucket* (#60 notes it holds only a
  2024 DB export) with public access blocked and per-prefix lifecycle rules; alternative is a new
  bucket.

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

### Rev 4 (cattle-not-pets revision) — requested by RY via the CoS, 2026-09-14 11:53
Added: North star (RY's words, Eric's requirement); §6 (state inventory PR-C, logs PR-D, monthly
from-scratch test rebuild replacing the dry-run rot check, #56 redefined as prod Blue/Green rebuild,
no-rewrite guardrail); cattle track with owners; L0 interim log archive moved to the front; old
"Window 3" dry-run dropped. §3, Windows 1/1b/2 and the credential track unchanged.

### Rev 4, round 1 — 2026-09-14 12:00–12:04 PT — **VERDICT: CHANGES REQUESTED**
Codex confirmed by diff against committed rev 3 that §3, the Window 1/1b/2 tables and the credential
track are unchanged, and that "the new rebuild/logging blockers do not invalidate that near-term
approval." 3 blockers, 8 should-fix. What rev 4.1 did:
- **B1** a replacement build runs the role's unconditional `migrate` against the shared DB →
  `run_migrations=false` switch (C5), empty-migration-plan preconditions before and after, pinned app
  + provisioning SHAs, no schema change from build through the rollback period.
- **B2** "stop Celery, then drain Redis" is impossible — each box has its own local Redis (verified:
  `CELERY_BROKER_URL = redis://127.0.0.1:6379/0`) → explicit handoff: maintenance on, stop beat/crons,
  **drain with workers running**, flush mail, move IP, enable new schedulers last; same in reverse for
  rollback; `schedulers_enabled=false` on replacement builds incl. handlers.
- **B3** shipping design couldn't support the preservation promise (handler rotation drops `.9`,
  multi-process writers, Celery `tail` truncation, quiet logs never "closed", counts ≠ contents) →
  eight PR-D acceptance requirements (§6b).
- Should-fix adopted: C1p rollout to current prod + off-box freshness check; dependency cycle broken
  (implementation+narrow proofs vs integrated acceptance at T1; P1 SHA must pass a test rebuild);
  S0 broadened (`/root`, `/var/lib`, `/var/spool`, symlinks, known locations regardless of timestamp,
  effective storage/session settings) and new rows for the Redis **result backend** (db 1, verified)
  and postfix queue; certificate sequence must be chosen in C4, HTTPS smoke via `--resolve` with SNI,
  old box stays *running* for final flush; L0 includes Apache logs, manifest + checksums, rotation-race
  handling; **#60's recovered log is also on prod as `downloads.log.6`** (verified in #60's 7/2
  comment) and will rotate out; D9 effective-identity and one-role-per-instance; D11 lifecycle
  read-merge-write, exclusions, upload-time retention, overwrite risk; D6 dated fallback instead of
  dropping W77.

### Rev 4, round 2 — 2026-09-14 12:08–12:10 PT — **VERDICT: LGTM**
"I would sign rev 4.1 at plan level. No blockers remain." All 3 rev-4 blockers RESOLVED; 8 of 11
round-1 items RESOLVED, 3 PARTIAL (wording). §3 and Windows 1/1b/2 re-confirmed unchanged from rev 3.
Non-blocking corrections **applied after the LGTM (rev 4.2, not re-reviewed)**:
- C1p now named as a prod-touching step and as P1's shipping prerequisite; P1's "same commit"
  wording reconciled with the "extra rebuild at the P1 SHA" rule.
- W2.4 can be deferred to a dated fallback but not dropped; W77 may close after patching the current
  box, not only after replacement.
- Prod switch restores and verifies production mail before enabling email-producing work (and on
  rollback).
- `set_site_domain` can write (creates/updates domain or name) → skipped on replacement builds, with a
  read-only assertion instead (C5).
- Celery round-trip deferral (workers disabled) separated from the HTTP-01 certificate constraint.

### Rev 5 — RY additions relayed by the CoS (12:11)
Added: "Durability of the hand-applied indexes" (§3b) with a verification step in W2.1 and every monthly
test rebuild; old-DB deletion made a scheduled, calendar-held step with go criteria and a default date
(the relay said "Fri 9/19"; 9/19 is a Saturday, so default is **Fri 9/18**); "pattern, not a one-off"
in the North star with repo history. **Codex round run: yes** — the changes are substantive (a new
factual claim about migration durability and a new production-adjacent AWS step, the restore test).

### Rev 5, round 1 — 2026-09-14 12:14–12:17 PT — **VERDICT: CHANGES REQUESTED**
Reviewed only the rev-5 diff. What rev 5.1 did:
- **B1** restore test left RDS defaults implicit → every restore flag explicit (profile/region, source,
  literal target, restore time after W1.6, class compatibility, `--no-multi-az`,
  `--no-publicly-accessible`, prod's subnet group/SGs/parameter + option groups,
  `--no-deletion-protection`, backup retention), configuration verified before connecting.
- **B2** the Django probe could silently query prod → separate connection alias from a deep copy,
  host/socket `OPTIONS` rejected, endpoint/`@@hostname`/`DATABASE()` asserted, no default connection or
  ORM; restore point fixed after both migrations; tolerances set in advance.
- **S** cost ignores full allocated storage → noted, estimate required; literal-identifier delete
  with `--delete-automated-backups`, cleanup deadline 17:00 on pass or fail, network errors aren't
  deletion evidence.
- **S** durability overstated recovery ("would be re-applied") → inspect only *reports* pending;
  reconcile via §3c, then a separately approved apply; "no playbook task touches" qualified.
- **S** Friday 9/18 is < 7 days after the 9/12 switchover → criterion restated as zero at every
  datapoint since switchover (gaps = no-go), Friday needs RY's explicit yes, else Mon 9/21.
- **S** history wording → #1171 aligned *master* only; #55 cited for 6/26; "multiple documented
  manifestations" of one unreconciled cutover; monthly rebuilds "expose the drift their acceptance
  checks exercise."
- **N** metadata-only alternative vs "proven" → risk row made conditional.

### Rev 5, round 2 — 2026-09-14 12:19–12:21 PT — **VERDICT: LGTM**
Both rev-5 blockers RESOLVED; 3 should-fix + nit RESOLVED, 2 PARTIAL (wording). Non-blocking fixes
**applied after the LGTM (rev 5.2, not re-reviewed)**: cost estimate includes IOPS/throughput and backup
charges; durability risk row now says inspect → reconcile → approved apply; the probe asserts the
effective connection host against the recorded endpoint (`@@hostname` is diagnostic only); Eric is told
the *actual* approved date; **arithmetic corrected** — Fri 9/18 09:00 PT is just under 6 days after the
09:04 PT 9/12 switchover (I had written ~5.7), 7 full days is Sat 9/19 09:04 PT, Mon 9/21 is ~9 days.

<!-- cc:2026.09.14 -->
