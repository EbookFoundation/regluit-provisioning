# AWS setup for unglue.it: what the playbooks don't build

The Ansible playbooks in this repo set up **a running Ubuntu machine**: packages, the app, Apache, Celery, certificates, cron jobs, log copying. They don't create anything in AWS. Everything below was made by hand, in the AWS console or the CLI. A new server needs at least its machine, address and DNS record, database access and log-copy role before the setup playbook can finish.

This is a checklist: what exists today, how to recreate it, and how to check it. A script that does the same is planned (see the issue linked at the end).

**Read as of 2026-11-10** from the AWS account that hosts unglue.it (the Gluejar member account of the Free Ebook Foundation's AWS organization), region `us-east-1`. Account numbers, passwords and keys are deliberately not in this file; they are in 1Password and the Ansible vault.

## 1. Machines (EC2)

| | Production | Test |
|---|---|---|
| Name tag | `prod-green` | `test-2026-06-18` |
| Type | m5a.xlarge | t3.large |
| Image | Ubuntu 24.04 (`ubuntu-noble-24.04-amd64-server-20260610`) | same |
| Disk | 30 GB gp3 | 30 GB gp3 |
| Zone, subnet | us-east-1c; one shared subnet in the unglue.it VPC (not AWS's default VPC) | same |
| Security group | `vpc-prod` | `vpc-prod` |
| SSH key pair | `production` | `production` |
| IAM instance profile | `unglueit-log-shipper-prod` | `unglueit-log-shipper-test` |
| Fixed address (Elastic IP) | `52.4.17.140` | `3.209.72.10` |

**`vpc-prod` allows in:** SSH (22), HTTP (80) and HTTPS (443). Recreate its rules from the existing group, not from memory.

**To recreate:** launch an instance with the row above, attach the instance profile (section 6), and either move the Elastic IP to it or allocate a new one and update DNS (section 3). Then run the setup playbook (README).

**Check:** `ssh ubuntu@<address>` works, and `aws ec2 describe-instances` shows the instance profile attached.

## 2. Databases (RDS, MySQL 8.4.11)

| | Production | Test |
|---|---|---|
| Identifier | `production-2024` | `test-2026-08-23` |
| Class | db.m5.large, Multi-AZ | db.t3.medium, single-AZ |
| Storage | 200 GB gp2 | 200 GB gp2 |
| Parameter group | `regluit-prod-mysql84` (event scheduler off, for blue/green) | `regluit-test-mysql84-slowlog` |
| Security groups | `vpc-rds` + `default` | same |
| Backups | 7 days, window 07:27–07:57 UTC | same |
| Public access | no | no |

**`vpc-rds` allows in:** MySQL (3306) from the `vpc-prod` security group only.

**The app finds the database** through `vault_mysql_db_host` in the environment's Ansible vault. A new database means updating that value and re-running the setup playbook.

**To recreate:** normally from a snapshot (the 9/16 restore test is the procedure), not from empty.

**Check:** the settings template's host equals the instance's endpoint. `scripts/drift_check.sh` then reports nothing to change.

## 3. DNS (Route 53, zone `unglue.it`, same account)

Records the servers depend on:

| Name | Type | Points to |
|---|---|---|
| `unglue.it`, `*.unglue.it` | A | production's Elastic IP |
| `test.unglue.it` | A | test's Elastic IP |
| `files.unglue.it` | A/AAAA alias | the CloudFront distribution (section 5) |
| `_amazonses.unglue.it`, three `…._domainkey.unglue.it` | TXT / CNAME | Amazon SES verification and DKIM for unglue.it |
| `unglue.it`, `mail.unglue.it` | MX | DreamHost mail |
| ACM validation CNAME for files.unglue.it | CNAME | keep: it renews that certificate |

**Outside this account:** the `ebookfoundation.org` zone, which holds the DMARC record and SES identity for the address unglue.it sends from, is in the Foundation's own AWS account.

## 4. Storage (S3)

| Bucket | What it's for | Settings that matter |
|---|---|---|
| `tieulgnu` | Cover images and ebook files; origin for files.unglue.it | Versioning on; old versions expire after 90 days |
| `unglueit-logs` | Nightly copy of server logs (`unglue.it/prod/`, `unglue.it/test/`) and S3 access logs | Public access blocked; S3 access logs expire after 30 days |
| `unglueit-originals-backup` | Backup copy of original files | Versioning on; public access blocked |
| `unglueit`, `unglueit-files` | Probably legacy: Raymond recalls `tieulgnu` ("unglueit" backwards) replacing `unglueit` as the files bucket, partly to get around bots hitting it. Confirm with Eric before changing anything | |

## 5. files.unglue.it (CloudFront)

- One distribution: alias `files.unglue.it`, origin the `tieulgnu` bucket, HTTP redirected to HTTPS, all price classes.
- Certificate: an Amazon (ACM) certificate for `files.unglue.it` in us-east-1. Amazon renews it as long as its validation CNAME (section 3) stays in DNS.
- The app uses it through `AWS_S3_CUSTOM_DOMAIN` (set by the playbooks).

## 6. Permissions for the nightly log copy (IAM)

Two roles, each with an instance profile of the same name, created by hand on 2026-11-03/04 for provisioning #108:

- `unglueit-log-shipper-prod`: may only `s3:PutObject` and `s3:AbortMultipartUpload` under `unglueit-logs/unglue.it/prod/`.
- `unglueit-log-shipper-test`: the same, under `unglueit-logs/unglue.it/test/`.

Both trust EC2. The log copy uses the machine's role, so no stored access key is needed.

**Check:** `scripts/check_log_ship.sh`.

## 7. Certificates for the sites

Both sites use Let's Encrypt certificates renewed by certbot on the machine, but they got there differently:

- **Test:** the playbook manages certbot (`certbot_manage: true`; HTTP-01 through the port-80 virtual host, webroot `/var/lib/letsencrypt`; proven 2026-08-18, #67). A fresh test machine gets its certificate from the setup playbook, **once DNS points at it**.
- **Production:** certbot was set up **by hand** on the machine (webroot `/var/www/static`, renewal timer active). The playbook only points Apache at `/etc/letsencrypt/live/unglue.it/` (`manage_certs: false`, `certbot_manage` unset) and does nothing else about the certificate. **A new production machine built from the playbooks gets no certificate.**

**Plan (decided 2026-11-10, not built yet):** move both servers to certbot's DNS-01 method with its Route 53 plugin, which works before DNS points at a new machine. That means: the playbook installs the plugin and requests certificates with it; each machine's role gets permission to change only `_acme-challenge` records in the `unglue.it` zone (#109); try it on test first; then turn on `certbot_manage` for production.

**Until that's built, for a new production machine:** copy `/etc/letsencrypt/` from the old machine before switching DNS (never into git: it holds the private key), or switch DNS and run certbot at once, accepting a few minutes without HTTPS.

## 8. Mail (Amazon SES)

The app sends as `unglueit@ebookfoundation.org`. Production sends through SES in the **Foundation's** AWS account, not this one; test has used SES in this account (as of April 2026; not re-checked for this file). SMTP settings come from the Ansible vault. See provisioning #94 for the email-authentication records.

## Keeping this file true

Run `AWS_PROFILE=<unglue.it profile> scripts/aws_setup.sh check` (read-only; `check prod` or `check test` for one server). It compares AWS with the values above and prints OK, DIFF or NOTE per item. A DIFF means AWS and this file disagree: fix whichever is wrong, and keep the expected values at the top of the script in step with this file. Update the date at the top when you do.
