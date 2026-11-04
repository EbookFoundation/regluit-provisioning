# Deploying Regluit to Production

The current provisioning setup uses [Ansible](https://www.ansible.com/resources/get-started) to deploy code to production servers.

## Pre-requisites 
Before attempting to deploy, ensure you have done the following:
1. git checkout https://github.com/EbookFoundation/regluit-provisioning
1. create `certs` and `decrypted` directories in `private`
1. Install `ansible` on your local machine
1. Obtain the `ansible-vault` password and save it to a file
1. Set the path to the `ansible-vault` file via environment variable e.g. `export ANSIBLE_VAULT_PASSWORD_FILE=[path]`
1. Create/obtain the secret key needed to SSH into the server
1. (optional) Add the secret key to your ssh agent 
    ```
    $ ssh-agent bash
    $ ssh-add /path/to/secret.pem
    ``` 


## Deploy
Deploying is as simple as running the `setup-prod` ansible playbook.  
Navigate to the `regluit-provisioning/` directory and run the following:  
```
$ ansible-playbook -i hosts setup-prod.yml
```   
If you successfully completed all the pre-requisite steps, the playbook should begin running through deploy tasks and finally restart apache.


## Additional Configuration

### Variables and Secrets
The necessary variables are pulled from `regluit-provisioning/group_vars/production/vars.yml` which in turn pulls certain secret values from `vault.yml`.  
The variables are split into two files to still allow for searching references in playbook tasks.
To add or view secret values, you must decrypt the file first: `$ ansible-vault decrypt vault.yml` however **always remember to encrypt secret files before pushing to git**.   This is done in a similar manner: `$ ansible-vault encrypt vault.yml`.   

Ansible also allows for overriding variables from the command line when running playbooks.  
This is useful for ad-hoc playbook runs without editing var files.   
For example, deploying code from another branch can be done as so:  
`$ ansible-playbook -i hosts setup-prod.yml -e git_branch=mybranch`  

### Inventory and Groups
Currently we are using a static inventory file `hosts` to define target server hosts and groups.  
This means that the `hosts` file must be manually updated to reflect things such as DNS changes or additional hosts being added.  
In the future, the static inventory file may be replaced with a dynamic inventory solution, such as ansible's [ec2 inventory script](http://docs.ansible.com/ansible/latest/user_guide/intro_dynamic_inventory.html#example-aws-ec2-external-inventory-script)  

One important aspect of the `hosts` file is that it defines the groups which a host or hosts are a part of.   
Currently there are two hosts: `regluit-prod` (unglue.it) in the `production` group and `regluit-test` (test.unglue.it) in the `test` group. The dead `dev`, `ondeck` and `batterup` targets were removed in 2026-09 (#56).
These designations are important, as the `setup-prod` playbook specifically targets the `regluit-prod` host, and only that host will inherit the variables in `group_vars/production/`.   

## Scripts

Read-only helpers, run from the control machine by piping them over ssh; each file's header has the details and usage.

- `scripts/describe_prod.sh`: describes what is installed and running on a server, for comparing against what the playbooks would build.

### Log analysis scripts

Stdlib-only Python 3 that read the Apache access logs (`/var/log/apache2/YYYYMMDD_access.log`) and print counts only, never IPs, user agents or URLs. Example: `ssh ubuntu@test.unglue.it 'python3 - 20260929' < scripts/url_family_report.py`.

- `scripts/url_family_report.py`: requests, distinct URLs, server seconds and status codes per URL family (feedback, sign-in, keyword, deep `/free/` pages, OPDS, other), with time windows and a before/after `--compare` mode.
- `scripts/page_depth.py`: how deep `/free/` requests page (`?work_list=N`), split into likely-human, browser-only and other traffic.
- `scripts/cache_hit_estimate.py`: replays a log through a simulated shared cache and estimates hits and server seconds saved per URL family.

## Login gate on test.unglue.it

test.unglue.it asks for a login (HTTP Basic auth, at the Apache level) before anything reaches the app, so crawlers get a cheap 401 instead of Django pages. Production has no gate: it needs both `test_gate: true` and `deploy_type: 'test'` (`login_gate_on` in `roles/regluit_prod/defaults/main.yml`), so even `-e test_gate=true` on a prod run does nothing. The login is in 1Password (EbookFoundation vault, "test.unglue.it gate"); the vault holds only its bcrypt line (`vault_test_gate_userline`).

To let real traffic in for a while, then lock it again:

```
ansible-playbook -i hosts setup-test.yml --tags apache-config -e test_gate=false
ansible-playbook -i hosts setup-test.yml --tags apache-config -e test_gate=true
```

## Where the logs are

Every night at 01:30 UTC, `/usr/local/sbin/ship_logs.py` copies the server's logs to `s3://unglueit-logs/unglue.it/prod/`. **It only copies.** It deletes nothing on the server and changes no rotation or cleanup job, so the server's own keeping times still apply there. Nothing in this S3 folder expires yet.

| S3 folder | What | Named by |
| --- | --- | --- |
| `apache/` | Apache access and error logs, one file per finished day | day and content hash |
| `rotated/` | `downloads.log.N`, `unglue.it.log.N` | content hash |
| `metrics/` | daily metrics pages | date and content hash |
| `sampler/` | status sampler, one file per finished day | day and content hash |
| `live/YYYY-MM-DD/` | `downloads.log`, `unglue.it.log`, `doab-harvest.log`, `w1.log`, Apache's `error.log`, `update_downloads.log`, each only if it changed since the last run | file name and content hash |

The hash is the SHA-256 of the uncompressed contents, so you can check a copy: `gunzip -c file.gz | shasum -a 256` should match the name. A file renumbered by rotation, or gzipped by the cleanup job, isn't sent twice. A rotated file that was still being written shows up as more than one object, each a complete copy at that moment, so **overlapping lines are expected**: de-duplicate if you count from them.

**Is it working?** `scripts/check_log_ship.sh` (run it from a laptop; it only reads) shows the newest object and its age, and exits 1 past 36 hours. Nothing checks this automatically, and a job that never starts can't report itself. A job that runs and fails mails `log_ship_mail_to` once, then again only after a good run. On the server: `/var/log/regluit/ship_logs.log`; `ship_logs.py --help` lists `--dry-run` and `--whoami`.

**Getting a file back:** `aws s3 ls s3://unglueit-logs/unglue.it/prod/apache/ | grep 20261030`, then `aws s3 cp` and `gunzip`.

**What it can't do:** a server lost during the day loses up to about a day of logs. `unglue.it.log` rotates fast enough that a busy day could push lines out of its six files between copies. Today's status sampler and dated Apache files wait for the next night.

**The credential** is an instance role, so no key is stored on the server. It may only upload under one folder; it can't read, list or delete. The script turns off the other standard credential sources (environment, `~/.aws`, `~/.boto`), so it won't pick up the app's keys. The role does let anyone on the server upload there, and uploading can overwrite, because the bucket has no versioning.

**Setting a host up** (AWS writes; `HOST` is `prod` or `test`, and the instance ID comes from the console):

```bash
HOST=prod; INSTANCE=i-...; ROLE=unglueit-log-shipper-$HOST
aws iam create-role --role-name $ROLE --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name $ROLE --policy-name upload-logs --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:PutObject","s3:AbortMultipartUpload"],"Resource":"arn:aws:s3:::unglueit-logs/unglue.it/'$HOST'/*"}]}'
aws iam create-instance-profile --instance-profile-name $ROLE
aws iam add-role-to-instance-profile --instance-profile-name $ROLE --role-name $ROLE
aws ec2 associate-iam-instance-profile --instance-id $INSTANCE --iam-instance-profile Name=$ROLE
```

Attaching a role needs no restart. Then install with a narrow run, and try it once by hand:

```bash
ansible-playbook -i hosts setup-prod.yml --tags log-shipping      # never --diff
ssh ubuntu@unglue.it '/usr/local/sbin/ship_logs.py --whoami'      # should name the role
```

**Tests:** `tests/log_shipper/test.sh` runs the script end to end in throwaway containers (needs docker).

## Python and security updates

The servers use Ubuntu 24.04's own Python (`python3.12`); we don't build or install upstream Python. Decided 2026-10-26 (#102).

Ubuntu backports security fixes into its own builds and keeps the version number, so the servers report 3.12.3 even when they carry the fix an advisory attributes to a later 3.12.x. When an advisory says to upgrade Python, don't compare version numbers: look up the advisory's CVE in Ubuntu's CVE tracker (<https://ubuntu.com/security/cves>) and read its status for `python3.12` on 24.04 (noble). It may be fixed, pending, or not applicable to Ubuntu's build.

What happens without anyone acting:

- `unattended-upgrades` installs Ubuntu security updates every day (early morning UTC).
- `needrestart` then restarts the services that use a changed library, including `apache2`, `celeryd` and `celerybeat`. Seen on prod 2026-10-23: a zlib update at 06:23:01 UTC, all three restarted at 06:23:03.

What does not: anything inside the app's virtualenv, including pip and certifi. Ubuntu's updates don't touch those. Our way to update them is the app's `requirements.txt` plus a deploy with `-e run_pip=true`, which first upgrades the venv's pip from a hash-pinned wheel (see `deploy.yml`). The emSign certificate incident in October 2026 was fixed this way (#101).

Next decision point: upstream Python 3.12 security support ends October 2028; Ubuntu 24.04 standard support runs to 2029.

## Notes

`sudo apt-get install mysql-client-8.0=8.0.19-0ubuntu5`
`sudo apt-get install mysql-client-core-8.0=8.0.19-0ubuntu5'
