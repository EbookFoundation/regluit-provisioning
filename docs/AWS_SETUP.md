# AWS setup for unglue.it: what the playbooks don't build

The Ansible playbooks in this repo set up **a running Ubuntu machine**: packages, the app, Apache, Celery, certificates, cron jobs, log copying. They don't create anything in AWS. Everything below was made by hand, in the AWS console or the CLI. A new server needs at least its machine, address and DNS record, database access and log-copy role before the setup playbook can finish.

This is a checklist: what exists today, how to recreate it, and how to check it. A script that does the same is planned (see the issue linked at the end).

**Read as of 2026-11-10** (section 5's bucket access, 2026-11-11) from the AWS account that hosts unglue.it (the Gluejar member account of the Free Ebook Foundation's AWS organization), region `us-east-1`. Account numbers, passwords and keys are deliberately not in this file; they are in 1Password and the Ansible vault.

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
- **Who can read the bucket.** Until the lock below is done, a bucket policy lets anyone read any file (`Principal: "*"`, `s3:GetObject`), and CloudFront reads it that way too. The site itself links only to files.unglue.it. `scripts/aws_setup.sh check all` reports the bucket's state as a NOTE until the lock is done, then expects it.

### Locking the bucket so only CloudFront can read it anonymously

Two steps, each checked before the next, each reversible. Run them from a laptop with the account's AWS profile, in a scratch folder, because the files saved there are the rollback. The app's own reads and uploads use its IAM credentials and aren't affected.

**Before:** record today's state; stop if any value comes back empty. Type `bash` first and run all the blocks in that one shell: `set -e` then ends just that shell at the first failure, not your terminal, and the variables carry from block to block.

```bash
set -euo pipefail
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DIST=$(aws cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, 'files.unglue.it')].Id | [0]" --output text)
: "${ACCOUNT:?}" "${DIST:?}"; [ "$DIST" != None ] || { echo "no distribution"; exit 1; }
aws s3api get-bucket-policy --bucket tieulgnu --query Policy --output text > tieulgnu-policy-before.json
aws s3api get-public-access-block --bucket tieulgnu > tieulgnu-pab-before.json
aws s3api get-bucket-ownership-controls --bucket tieulgnu > tieulgnu-ownership-before.json
# The steps below assume the policy is exactly today's single public-read statement.
# If it holds anything else, stop and work out by hand what the other statements need.
jq -e '(.Statement | length) == 1 and .Statement[0].Effect == "Allow" and .Statement[0].Principal == "*"
  and .Statement[0].Action == "s3:GetObject" and .Statement[0].Resource == "arn:aws:s3:::tieulgnu/*"
  and (.Statement[0] | has("Condition") | not)' tieulgnu-policy-before.json
OBJ=$(aws s3api list-objects-v2 --bucket tieulgnu --prefix ebf/ --max-keys 1 --query 'Contents[0].Key' --output text)
[ -n "$OBJ" ] && [ "$OBJ" != None ] || { echo "no test file found"; exit 1; }   # a real file to test with
scripts/aws_setup.sh check all      # NOTE: "files bucket tieulgnu: anyone can read it directly"
```

**Step 1: give CloudFront its own signed access. Nothing changes for anyone yet.**

```bash
# Signed access needs object ownership "bucket owner preferred". Per-file ACLs stay
# enabled, so uploads that ask for public-read keep working ("enforced" would reject them).
aws s3api put-bucket-ownership-controls --bucket tieulgnu \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerPreferred}]'

# a bucket statement that lets this distribution, and only it, read files
jq --arg arn "arn:aws:cloudfront::$ACCOUNT:distribution/$DIST" '.Statement += [{
    "Sid": "CloudFrontOnly", "Effect": "Allow",
    "Principal": {"Service": "cloudfront.amazonaws.com"},
    "Action": "s3:GetObject", "Resource": "arn:aws:s3:::tieulgnu/*",
    "Condition": {"StringEquals": {"AWS:SourceArn": $arn}}}]' \
  tieulgnu-policy-before.json > tieulgnu-policy-step1.json
aws s3api put-bucket-policy --bucket tieulgnu --policy file://tieulgnu-policy-step1.json

# an Origin Access Control: CloudFront signs every request to the bucket
OAC=$(aws cloudfront create-origin-access-control --origin-access-control-config \
  Name=tieulgnu-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3 \
  --query OriginAccessControl.Id --output text)
: "${OAC:?}"

# attach it to the distribution's one origin (the ETag makes this fail if the config changed meanwhile)
aws cloudfront get-distribution-config --id "$DIST" > dist-before.json
jq --arg oac "$OAC" '.DistributionConfig | .Origins.Items[0].OriginAccessControlId = $oac
  | .Origins.Items[0].S3OriginConfig.OriginAccessIdentity = ""' dist-before.json > dist-step1.json
aws cloudfront update-distribution --id "$DIST" --if-match "$(jq -r .ETag dist-before.json)" \
  --distribution-config file://dist-step1.json > /dev/null
aws cloudfront wait distribution-deployed --id "$DIST"
```

Check: an ebook download from a work page on unglue.it works, `curl -sI "https://files.unglue.it/$OBJ"` gives `200`, and `check all` says step 1 is done.

**Step 2: remove public read.**

```bash
# stop if anyone changed the policy since step 1 (diff prints the difference and set -e stops)
diff <(aws s3api get-bucket-policy --bucket tieulgnu --query Policy --output text | jq -S .) \
     <(jq -S . tieulgnu-policy-step1.json)
# remove exactly the public-read statement saved in "Before", nothing else
jq --argjson pub "$(jq -c '.Statement[0]' tieulgnu-policy-before.json)" \
  '.Statement |= map(select(. != $pub))' tieulgnu-policy-step1.json > tieulgnu-policy-step2.json
jq -e '.Statement | length == 1 and .[0].Sid == "CloudFrontOnly"' tieulgnu-policy-step2.json
aws s3api put-bucket-policy --bucket tieulgnu --policy file://tieulgnu-policy-step2.json
aws s3api put-public-access-block --bucket tieulgnu --public-access-block-configuration \
  BlockPublicAcls=false,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# make CloudFront fetch the test file fresh, so a cached copy can't hide a failure
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/$OBJ" --query Invalidation.Id --output text
```

Why those four settings: `IgnorePublicAcls` shuts off files that carry their own public-read grant (`translate_doab_ids` uploads with `ACL='public-read'`). `BlockPublicPolicy` stops a public policy coming back by accident, and `RestrictPublicBuckets` blocks anonymous access even if one did. `BlockPublicAcls` stays off so an upload that asks for public-read still succeeds instead of failing; the grant is simply ignored.

Check, once the invalidation has completed: `curl -sI "https://files.unglue.it/$OBJ"` gives `200`, `curl -sI "https://tieulgnu.s3.amazonaws.com/$OBJ"` gives `403`, an ebook download from a work page works, and `check all` says "not anonymously readable except through CloudFront". Then set `FILES_LOCK=locked` in `scripts/aws_setup.sh` (one line, via a PR), so `check` reports any drift back as a DIFF.

**Rollback** (either step). It restores what "Before" saved, so first make sure nobody has since made a change you'd be undoing:

```bash
aws s3api put-public-access-block --bucket tieulgnu --public-access-block-configuration \
  "$(jq -c .PublicAccessBlockConfiguration tieulgnu-pab-before.json)"
aws s3api put-bucket-policy --bucket tieulgnu --policy file://tieulgnu-policy-before.json
aws s3api put-bucket-ownership-controls --bucket tieulgnu \
  --ownership-controls "$(jq -c .OwnershipControls tieulgnu-ownership-before.json)"
```

The Origin Access Control can stay attached; it works with either policy.

## 6. Permissions for the nightly log copy (IAM)

Two roles, each with an instance profile of the same name, created by hand on 2026-11-03/04 for provisioning #108. Despite the names, each is the machine's only role, so it also carries the certificate permission below:

- `unglueit-log-shipper-prod`: may only `s3:PutObject` and `s3:AbortMultipartUpload` under `unglueit-logs/unglue.it/prod/`.
- `unglueit-log-shipper-test`: the same, under `unglueit-logs/unglue.it/test/`.

Both trust EC2. The log copy uses the machine's role, so no stored access key is needed.

**Certificate permission (DNS-01, section 7):** a second inline policy, `certbot-dns-route53`, allowing `route53:ListHostedZones` and `route53:GetChange`, plus `route53:ChangeResourceRecordSets` on the `unglue.it` zone **only** to `UPSERT` or `DELETE` the TXT record `_acme-challenge.<the machine's own name>` (IAM conditions on record name, type and action; those are the only calls certbot's Route 53 plugin makes). Test: added 2026-11-10; its renewal switched to DNS-01 the same day. Production: not yet; if its certificate also covers `www.unglue.it`, include `_acme-challenge.www.unglue.it` in the name list.

**Check:** `scripts/check_log_ship.sh`.

## 7. Certificates for the sites

Both sites use Let's Encrypt certificates renewed by certbot on the machine, but they got there differently:

- **Test:** the playbook manages certbot (`certbot_manage: true`; HTTP-01 through the port-80 virtual host, webroot `/var/lib/letsencrypt`; proven 2026-08-18, #67). A fresh test machine gets its certificate from the setup playbook, **once DNS points at it**.
- **Production:** certbot was set up **by hand** on the machine (webroot `/var/www/static`, renewal timer active). The playbook only points Apache at `/etc/letsencrypt/live/unglue.it/` (`manage_certs: false`, `certbot_manage` unset) and does nothing else about the certificate. **A new production machine built from the playbooks gets no certificate.**

**DNS-01 (decided 2026-11-10):** the playbook now supports `certbot_challenge: dns-route53` (installs certbot's Route 53 plugin and requests the certificate through DNS, which works before DNS points at a new machine). Test is switched to it; production comes after test has renewed this way. To switch an existing machine: add the role permission (section 6), then on the box `sudo certbot reconfigure --cert-name <name> --dns-route53` (the playbook's precheck stops and prints this command if the stored renewal settings don't match).

**Until that's built, for a new production machine:** copy `/etc/letsencrypt/` from the old machine before switching DNS (never into git: it holds the private key), or switch DNS and run certbot at once, accepting a few minutes without HTTPS.

## 8. Mail (Amazon SES)

The app sends as `unglueit@ebookfoundation.org`. Production sends through SES in the **Foundation's** AWS account, not this one; test has used SES in this account (as of April 2026; not re-checked for this file). SMTP settings come from the Ansible vault. See provisioning #94 for the email-authentication records.

## Rebuilding test (scripts/aws_setup.sh create / cutover)

1. **Plan:** `scripts/aws_setup.sh create test`. It prints what it would make (a new machine and Elastic IP tagged `unglueit:candidate=test`, next to the live one), asks AWS with `--dry-run` whether that's allowed, and prints the exact command for step 2. Nothing is created.
2. **Create:** `scripts/aws_setup.sh create test --ami <the ID the plan showed> --yes`. The live machine, its address and DNS are not touched. The IAM role must already exist and pass `check` (creating roles stays a deliberate human step).
3. **Build:** `ansible-playbook -i hosts setup-test.yml -e ansible_host=<the candidate's address>`. The certificate comes by DNS-01 (section 7), so this works before DNS moves. Both machines now point at the same test database: stop celery on one of them until the switch.
4. **Check:** `curl --resolve test.unglue.it:443:<candidate address> https://test.unglue.it/` and click around the same way.
5. **Switch:** `scripts/aws_setup.sh cutover test` shows the plan; `... --expect-current <the address test.unglue.it points at now> --yes` moves the DNS record in one atomic change (refused if the record changed meanwhile) and prints the command to switch back.
6. **Afterwards:** stop the old machine, keep it 24 hours, then terminate it, release its address, and remove the candidate tag from the new machine and its address.

Production: `create prod` and `cutover prod` are refused until a test rebuild has worked end to end (#109).

## Keeping this file true

Run `AWS_PROFILE=<unglue.it profile> scripts/aws_setup.sh check` (read-only; `check prod` or `check test` for one server). It compares AWS with the values above and prints OK, DIFF or NOTE per item. A DIFF means AWS and this file disagree: fix whichever is wrong, and keep the expected values at the top of the script in step with this file. Update the date at the top when you do.
