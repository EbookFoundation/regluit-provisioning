# What was on `feature/prod-green`, and where it went

Production was built on 2026-06-17 from `feature/prod-green`, which never
merged back. By 2026-09-29 it was 39 commits ahead of `master` and 104
behind. This file compares the two branches **as they are now**, file by
file, and records what happened to each difference. Part of #56.

**Short version:** `master` had already taken almost all of the June recipe
(the late-June reconciliation, #55 and Gluejar/regluit#1078) and has moved
past it since. Two things were genuinely missing. Both are ported in this PR.

## Ported in this PR

| Topic | June commit | Why |
|---|---|---|
| Maintenance page + `/var/www/maintenance/` | 671d7d4 | `apache.conf.j2` and `apache_liveness_watch.sh` on master both use this directory, but nothing on master created it or installed the page. A fresh build would serve a bare 503. |
| Ansible-level production-settings guard | 44573ba (+1 condition) | master had only the Django-level check in `prod.py.j2`, which fires after code checkout, package installs and restarts. The assert stops the run first. It catches two mistakes: a non-production host whose DB host name contains "production", and `deploy_type: prod` on a host outside the `production` group (e.g. `setup-test.yml -e deploy_type=prod`). Name-based, not a proof. |

## Already on master (usually in a newer form)

| Topic | Notes |
|---|---|
| Python 3.12 venv | master: `python_version: "3.12"` + venv assertion (#77) |
| Celery 5 settings | master hard-codes the `CELERY_`-prefixed names (provisioning #37); June's Celery-4 branches not needed |
| mod_wsgi daemon mode, `processes=4`, `maximum-requests=8000` | master (#45, from the 6/22 OOM work); June had `processes=2` |
| `WSGIApplicationGroup %{GLOBAL}` (regluit#1163) | on master |
| `manage_certs: false`, certbot certificate paths | master; cert handling there is a superset (legacy ACME + certbot, #67) |
| `git_branch: production` | on master |
| pip `--exists-action=w` | on master |
| `.my.cnf` mode 0600 | on master |
| `set_site_domain` with `changed_when` + guard off production (regluit#1164) | on master |
| Per-environment `ADMINS` / `disable_admin_emails` | on master |
| Beat schedule: 4 jobs run, 7 parked (2026-06-11 decision) | on master |
| Production vault | same 36 variable names on both; master holds the newer email and Stripe values |

## Dropped

| Topic | Why |
|---|---|
| `prod-green` host group, `setup-prod-green.yml`, `group_vars/prod-green/` | Scaffolding to build the new box that is now production. Its settings are covered by `group_vars/production`. |
| dj42 host, group_vars, vault | Staging box for the 4.2 cutover; retired. |
| `setup.yml` (unified playbook) | `hosts: all` runs against every host if `-l` is forgotten. The per-environment playbooks stay. |
| `requirements.yml` (community.aws, amazon.aws) | Only for the wildcard-certificate flow abandoned in April 2026. Nothing uses it. |
| June's `group_vars/test` and test CSR/key | master's test config is newer (rebuilt 2026-08, certbot, email safety net #84). |
| Cron `apache-restart-workaround` (every 20 min) | master removes it on purpose: after the 2026-06-22 OOM it was shown to leave orphaned mod_wsgi workers. |
| `DEFAULT_FILE_STORAGE` in `prod.py.j2` | Conflicts with `STORAGES` on Django 4.2 and is silently ignored on 5.x, which drops S3 (regluit#1202/#1203). |

## Also removed in this PR

The dead `dev` (m.unglue.it), `ondeck` and `batterup` targets: playbooks,
group_vars, inventory entries. `batterup`'s playbook targeted
`regluit-ondeck`, not production. Kept: `setup-regluit.yml` and the
`regluit_common` / `regluit_dev` roles (a local-development recipe). That
recipe already fails `--syntax-check` on master (`pip3` module); unchanged here.

## Before building a new production server

- **The TLS certificate must be on the box before the first full run.**
  Production has `manage_certs: false` and no `certbot_manage`, so this role
  neither issues the certificate nor checks for it, and `prod.conf` names
  `/etc/letsencrypt/live/unglue.it/`. Without it, `apache2ctl configtest`
  fails (seen on a from-scratch build, 2026-09-29). June's build issued it by
  hand first with certbot's Route 53 DNS-01 plugin; the steps are in
  `group_vars/prod-green/vars.yml` on `feature/prod-green`.
- **The role assumes `ufw` and `unattended-upgrades` are already installed.**
  Ubuntu's EC2 images ship both; a minimal image does not.
- **test.unglue.it is behind master.** A `--check --diff --tags apache-config`
  run on 2026-09-29 showed test's live `prod.conf` lacks master's July
  crawler blocks and the certbot webroot alias (#67). A full run on test
  would update it.

## How to check a server against this

`scripts/describe_prod.sh` prints a read-only description of a server: for
the main files and directories the role renders or installs, existence,
owner, mode and a truncated hash, never contents. Run it on production and on
a freshly built box and diff the two. Hashes of credential-bearing files
will differ wherever the credentials differ; compare those by eye, not as a
failure.
