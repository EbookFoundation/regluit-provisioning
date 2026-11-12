#!/usr/bin/env bash
# aws_setup.sh - the AWS pieces the playbooks don't build (docs/AWS_SETUP.md).
# Issue #109. Run from a laptop with the AWS CLI, jq and curl.
#
#   scripts/aws_setup.sh check [prod|test|all]      (default: all)
#
# check is READ-ONLY: it reads AWS and compares it with the expected values
# below, which mirror docs/AWS_SETUP.md. One line per item:
#   OK    matches
#   DIFF  doesn't match: fix AWS, or this file and the doc if AWS is right
#   NOTE  worth knowing, not a failure (e.g. test's database is stopped)
# then a one-line JSON summary. Exit 0 = no DIFF, 1 = at least one DIFF,
# 2 = refused to run (wrong account, region or arguments).
#
# Servers are found through DNS (name -> Elastic IP -> instance), not by
# instance name, so the check keeps working after a rebuild.
#
#   scripts/aws_setup.sh create test [--ami <id> --yes]
#   scripts/aws_setup.sh cutover test [--expect-current <ip> --yes]
#
# create: a replacement machine and Elastic IP for one environment, tagged
#   unglueit:candidate=<env>, next to the live one. Without --yes it prints
#   the plan and asks AWS (--dry-run) whether it would be allowed; nothing is
#   made. Reuses an existing candidate. Never touches the live machine, its
#   address, DNS, databases or security groups; won't create IAM roles.
# cutover: points the environment's DNS name at the candidate, only with
#   --yes AND --expect-current <the address it points at now>, and only if
#   the candidate answers HTTPS for that name. Leaves both machines running.
# Both refuse prod (#109: only after a test rebuild has worked end to end).
# Shared security groups are only ever checked.

set -u
set -o pipefail

PROFILE="${AWS_PROFILE:-gluejar_member}"
REGION=us-east-1
# SHA-256 of the AWS account ID that hosts unglue.it. The ID itself is kept
# out of this public repo; the hash lets the script refuse the wrong account.
EXPECTED_ACCOUNT_SHA256=272de3e81afd5c6224e48abddc57339953e13dfb1c8ad4e52038226574f07aa7
UBUNTU_OWNER=099720109477   # Canonical's public AWS account (official Ubuntu images)

# --- expected values (keep in step with docs/AWS_SETUP.md) -----------------
expect() {   # expect <env> <key>
    case "$1:$2" in
        prod:dns)       echo unglue.it ;;
        prod:type)      echo m5a.xlarge ;;
        prod:profile)   echo unglueit-log-shipper-prod ;;
        prod:rds)       echo production-2024 ;;
        prod:rds_class) echo db.m5.large ;;
        prod:multi_az)  echo true ;;
        prod:cert_dns)  echo later ;;   # DNS-01 permission: not added to prod yet
        test:dns)       echo test.unglue.it ;;
        test:type)      echo t3.large ;;
        test:profile)   echo unglueit-log-shipper-test ;;
        test:rds)       echo test-2026-08-23 ;;
        test:rds_class) echo db.t3.medium ;;
        test:multi_az)  echo false ;;
        test:cert_dns)  echo yes ;;     # certbot_challenge: dns-route53 (docs section 7)
        *) echo "BUG: no expected value for $1:$2" >&2; exit 2 ;;
    esac
}
ZONE_NAME=unglue.it
APP_SG=vpc-prod            # machines
DB_SG=vpc-rds              # databases; must admit MySQL from APP_SG
APP_PORTS="22 80 443"
MIN_DISK_GB=30
MIN_BACKUP_DAYS=7
FILES_BUCKET=tieulgnu
LOGS_BUCKET=unglueit-logs
FILES_HOST=files.unglue.it
# planned: the bucket is still publicly readable; report its lock progress as NOTEs.
# locked: only CloudFront may read it; anything else is a DIFF. Set after step 2 of
# "Locking the bucket" in docs/AWS_SETUP.md section 5.
FILES_LOCK=locked   # since 2026-11-12 (#115)

# --- plumbing ----------------------------------------------------------------
# AWS: a failed call is a failure of the check (access denied, throttling, network),
# recorded in a flag file because most calls run inside $( ) subshells.
# AWS_TRY: for lookups where "doesn't exist" is a valid answer; the caller reports it.
FAILFLAG=$(mktemp "${TMPDIR:-/tmp}/aws_setup.XXXXXX"); rm -f "$FAILFLAG"
trap 'rm -f "$FAILFLAG"' EXIT
AWS() {
    aws --profile "$PROFILE" --region "$REGION" "$@" && return 0
    echo "ERROR: aws $1 $2 failed" >&2; echo "aws $1 $2" >> "$FAILFLAG"; return 1
}
AWS_TRY() { aws --profile "$PROFILE" --region "$REGION" "$@" 2>/dev/null; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-64; }
N_OK=0; N_DIFF=0; N_NOTE=0; DIFFS=()
ok()   { N_OK=$((N_OK+1));     printf 'OK    %s\n' "$1"; }
diff_() { N_DIFF=$((N_DIFF+1)); DIFFS+=("$1"); printf 'DIFF  %s\n' "$1"; }
note() { N_NOTE=$((N_NOTE+1)); printf 'NOTE  %s\n' "$1"; }
same() {   # same <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1: $3"; else diff_ "$1: expected $2, got ${3:-nothing}"; fi
}


guard() {
    command -v jq >/dev/null || { echo "REFUSED: jq is required" >&2; exit 2; }
    local acct
    acct=$(AWS_TRY sts get-caller-identity --query Account --output text) \
        || { echo "REFUSED: no AWS credentials for profile $PROFILE" >&2; exit 2; }
    if [ "$(printf %s "$acct" | sha256)" != "$EXPECTED_ACCOUNT_SHA256" ]; then
        echo "REFUSED: profile $PROFILE is not the unglue.it AWS account" >&2; exit 2
    fi
    ACCOUNT_ID=$acct   # used only at run time (e.g. the CloudFront ARN); never printed
    echo "account: the unglue.it account (profile $PROFILE), region $REGION"
}

ZONE_ID=""
zone_id() {
    [ -n "$ZONE_ID" ] || ZONE_ID=$(AWS route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
        --query "HostedZones[?Name=='$ZONE_NAME.'].Id | [0]" --output text)
    echo "$ZONE_ID"
}
record() {   # record <name> <type> -> JSON of the record set, or empty
    AWS route53 list-resource-record-sets --hosted-zone-id "$(zone_id)" \
        --start-record-name "$1" --start-record-type "$2" --max-items 1 \
        --query "ResourceRecordSets[?Name=='$1.' && Type=='$2'] | [0]" --output json
}

# --- one environment -----------------------------------------------------------
check_env() {
    local env=$1 dns ip inst vol ami prof rds
    dns=$(expect "$env" dns)
    echo; echo "== $env ($dns)"

    ip=$(record "$dns" A | jq -r '.ResourceRecords[0].Value // empty')
    [ -n "$ip" ] || { diff_ "$env DNS: no A record for $dns"; return; }
    ok "$env DNS: $dns -> $ip"

    inst=$(AWS_TRY ec2 describe-addresses --public-ips "$ip" --query 'Addresses[0].InstanceId' --output text)
    case "$inst" in
        i-*) ok "$env address: $ip is an Elastic IP on $inst" ;;
        *) diff_ "$env address: $ip is not an Elastic IP attached to a machine"; return ;;
    esac

    local j; j=$(AWS ec2 describe-instances --instance-ids "$inst" --query 'Reservations[0].Instances[0]' --output json)
    local state name; state=$(jq -r '.State.Name' <<<"$j"); name=$(jq -r '(.Tags // [])[] | select(.Key=="Name") | .Value' <<<"$j")
    if [ "$state" = running ]; then ok "$env machine: $name ($inst) running"; else diff_ "$env machine: $name ($inst) is $state"; fi
    same "$env machine type" "$(expect "$env" type)" "$(jq -r .InstanceType <<<"$j")"

    ami=$(jq -r .ImageId <<<"$j")
    local img; img=$(AWS ec2 describe-images --image-ids "$ami" --query 'Images[0].[OwnerId,Name]' --output text) || img=ERROR
    case "$img" in
        "$UBUNTU_OWNER"*ubuntu-noble-24.04-amd64-server*) ok "$env image: official Ubuntu 24.04 (${img##*$'\t'})" ;;
        "None"*|"") note "$env image: $ami no longer listed (deregistered); can't confirm it was Ubuntu 24.04" ;;
        ERROR) diff_ "$env image: couldn't read $ami" ;;
        *) diff_ "$env image: $ami is not an official Ubuntu 24.04 image ($img)" ;;
    esac

    vol=$(jq -r '.BlockDeviceMappings[] | select(.DeviceName=="'"$(jq -r .RootDeviceName <<<"$j")"'") | .Ebs.VolumeId' <<<"$j")
    local v; v=$(AWS ec2 describe-volumes --volume-ids "$vol" --query 'Volumes[0].[Size,VolumeType]' --output text)
    if [ "${v%%$'\t'*}" -ge "$MIN_DISK_GB" ] && [ "${v##*$'\t'}" = gp3 ]; then ok "$env disk: ${v%%$'\t'*} GB gp3"
    else diff_ "$env disk: expected >= $MIN_DISK_GB GB gp3, got $v"; fi

    if jq -e --arg g "$APP_SG" '[.SecurityGroups[].GroupName] | index($g)' <<<"$j" >/dev/null; then ok "$env security group: $APP_SG"
    else diff_ "$env security group: $APP_SG not attached (has $(jq -r '[.SecurityGroups[].GroupName]|join(",")' <<<"$j"))"; fi

    prof=$(jq -r '.IamInstanceProfile.Arn // "" | split("/") | last' <<<"$j")
    same "$env instance profile" "$(expect "$env" profile)" "$prof"
    check_role "$env" "$(expect "$env" profile)" "$dns"

    rds=$(expect "$env" rds)
    local d; d=$(AWS_TRY rds describe-db-instances --db-instance-identifier "$rds" --query 'DBInstances[0]' --output json)
    if [ -z "$d" ]; then diff_ "$env database: $rds not found"; return; fi
    local st; st=$(jq -r .DBInstanceStatus <<<"$d")
    case "$st" in
        available) ok "$env database: $rds available" ;;
        stopped|stopping|starting) if [ "$env" = test ]; then note "$env database: $rds is $st (test is turned off between uses)"; else diff_ "$env database: $rds is $st"; fi ;;
        *) diff_ "$env database: $rds is $st" ;;
    esac
    same "$env database class" "$(expect "$env" rds_class)" "$(jq -r .DBInstanceClass <<<"$d")"
    same "$env database multi-AZ" "$(expect "$env" multi_az)" "$(jq -r .MultiAZ <<<"$d")"
    case "$(jq -r .EngineVersion <<<"$d")" in 8.4.*) ok "$env database engine: MySQL $(jq -r .EngineVersion <<<"$d")" ;; *) diff_ "$env database engine: expected MySQL 8.4.x, got $(jq -r .EngineVersion <<<"$d")" ;; esac
    same "$env database public access" false "$(jq -r .PubliclyAccessible <<<"$d")"
    local b; b=$(jq -r .BackupRetentionPeriod <<<"$d")
    if [ "$b" -ge "$MIN_BACKUP_DAYS" ]; then ok "$env database backups: $b days"; else diff_ "$env database backups: expected >= $MIN_BACKUP_DAYS days, got $b"; fi
    local dbsg; dbsg=$(AWS ec2 describe-security-groups --filters Name=group-name,Values="$DB_SG" --query 'SecurityGroups[0].GroupId' --output text)
    if jq -e --arg g "$dbsg" '[.VpcSecurityGroups[].VpcSecurityGroupId] | index($g)' <<<"$d" >/dev/null; then ok "$env database security group: $DB_SG"
    else diff_ "$env database security group: $DB_SG not attached"; fi
}

check_role() {   # the machine's role: trusts EC2; log copy + (optionally) its own ACME record
    local env=$1 role=$2 dns=$3 trust pol
    trust=$(AWS_TRY iam get-role --role-name "$role" --query 'Role.AssumeRolePolicyDocument.Statement' --output json)
    [ -n "$trust" ] || { diff_ "$env role $role: not found"; return; }
    # Exactly one statement: EC2, and only EC2, may assume the role.
    if jq -e 'length==1 and (.[0] | .Effect=="Allow" and ([.Action]|flatten)==["sts:AssumeRole"]
              and (.Principal|keys)==["Service"] and ([.Principal.Service]|flatten)==["ec2.amazonaws.com"]
              and (has("Condition")|not))' <<<"$trust" >/dev/null; then
        ok "$env role $role: only EC2 may assume it"
    else diff_ "$env role $role: trust policy isn't the single EC2-only allow"; fi
    local attached; attached=$(AWS iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyName' --output text) || attached=ERROR
    case "$attached" in
        "") ok "$env role $role: no attached (managed) policies" ;;
        *) diff_ "$env role $role: has attached policies ($attached); expected only its narrow inline policy" ;;
    esac
    pol=$(for p in $(AWS iam list-role-policies --role-name "$role" --query PolicyNames --output text); do
              AWS iam get-role-policy --role-name "$role" --policy-name "$p" --query PolicyDocument --output json; done | jq -s '[.[].Statement[]]')
    if jq -e --arg r "arn:aws:s3:::$LOGS_BUCKET/unglue.it/$env/*" \
         'any(.[]; .Effect=="Allow" and ([.Action]|flatten|index("s3:PutObject")) and ([.Resource]|flatten|index($r)))' <<<"$pol" >/dev/null; then
        ok "$env role $role: may write s3://$LOGS_BUCKET/unglue.it/$env/"
    else diff_ "$env role $role: no s3:PutObject on $LOGS_BUCKET/unglue.it/$env/*"; fi
    # Narrow means every Allow statement is one of exactly three shapes:
    #   log    s3:PutObject / s3:AbortMultipartUpload on its own log prefix
    #   find   exactly route53:ListHostedZones + route53:GetChange on "*" (certbot needs both)
    #   acme   route53:ChangeResourceRecordSets on the unglue.it zone, limited by
    #          condition to UPSERT/DELETE of the TXT record _acme-challenge.<its own name>
    #          (the only calls certbot-dns-route53 2.9 makes)
    local zone_arn="arn:aws:route53:::hostedzone/$(zone_id | sed 's#^/hostedzone/##')"
    local shapes; shapes=$(jq -c --arg r "arn:aws:s3:::$LOGS_BUCKET/unglue.it/$env/*" --arg z "$zone_arn" --arg n "_acme-challenge.$dns" '
        def acts: [.Action]|flatten; def res: [.Resource]|flatten;
        [ .[] | select(.Effect=="Allow") |
          if has("NotAction") or has("NotResource") then "other"
          elif (acts - ["s3:PutObject","s3:AbortMultipartUpload"] | length)==0 and res==[$r] and (has("Condition")|not) then "log"
          elif (acts|sort)==["route53:GetChange","route53:ListHostedZones"] and res==["*"] and (has("Condition")|not) then "find"
          elif acts==["route53:ChangeResourceRecordSets"] and res==[$z]
               and (.Condition|keys)==["ForAllValues:StringEquals"]
               and (.Condition["ForAllValues:StringEquals"] | (keys|sort)==["route53:ChangeResourceRecordSetsActions","route53:ChangeResourceRecordSetsNormalizedRecordNames","route53:ChangeResourceRecordSetsRecordTypes"]
                    and .["route53:ChangeResourceRecordSetsNormalizedRecordNames"]==[$n]
                    and .["route53:ChangeResourceRecordSetsRecordTypes"]==["TXT"]
                    and (.["route53:ChangeResourceRecordSetsActions"]|sort)==["DELETE","UPSERT"]) then "acme"
          else "other" end ]' <<<"$pol")
    if jq -e 'index("other")' <<<"$shapes" >/dev/null; then
        diff_ "$env role $role: inline policy has a statement that is not exactly the log copy or its own ACME-challenge permission"
    else ok "$env role $role: inline policy allows nothing else"; fi
    local want; want=$(expect "$env" cert_dns)
    if jq -e 'index("acme") and index("find")' <<<"$shapes" >/dev/null; then
        ok "$env role $role: may set only the TXT record _acme-challenge.$dns (certbot DNS-01)"
    elif [ "$want" = yes ]; then
        diff_ "$env role $role: missing the certbot DNS-01 permission for _acme-challenge.$dns"
    else
        note "$env role $role: no certbot DNS-01 permission yet (planned; docs/AWS_SETUP.md section 7)"
    fi
}

# --- shared pieces --------------------------------------------------------------
check_shared() {
    echo; echo "== shared"
    local g; g=$(AWS ec2 describe-security-groups --filters Name=group-name,Values="$APP_SG" --query 'SecurityGroups[0]' --output json)
    if [ "$g" = null ] || [ -z "$g" ]; then diff_ "security group $APP_SG: not found"; else
        local p missing=""
        for p in $APP_PORTS; do
            jq -e --argjson p "$p" 'any(.IpPermissions[]; .IpProtocol=="-1" or (.IpProtocol=="tcp" and .FromPort<=$p and .ToPort>=$p))' <<<"$g" >/dev/null || missing="$missing $p"
        done
        if [ -z "$missing" ]; then ok "security group $APP_SG: admits TCP $APP_PORTS"; else diff_ "security group $APP_SG: doesn't admit TCP$missing"; fi
    fi
    local app_id db; app_id=$(jq -r '.GroupId // empty' <<<"$g")
    db=$(AWS ec2 describe-security-groups --filters Name=group-name,Values="$DB_SG" --query 'SecurityGroups[0]' --output json)
    if [ -n "$app_id" ] && jq -e --arg a "$app_id" 'any(.IpPermissions[]; (.IpProtocol=="-1" or (.IpProtocol=="tcp" and .FromPort<=3306 and .ToPort>=3306)) and any(.UserIdGroupPairs[]; .GroupId==$a))' <<<"$db" >/dev/null; then
        ok "security group $DB_SG: admits MySQL from $APP_SG"
    else diff_ "security group $DB_SG: doesn't admit MySQL (3306) from $APP_SG"; fi

    same "bucket $FILES_BUCKET versioning" Enabled "$(AWS_TRY s3api get-bucket-versioning --bucket "$FILES_BUCKET" --query Status --output text)"
    local pab; pab=$(AWS_TRY s3api get-public-access-block --bucket "$LOGS_BUCKET" --query 'PublicAccessBlockConfiguration' --output json)
    if [ -n "$pab" ] && jq -e 'all(.[]; .==true)' <<<"$pab" >/dev/null 2>&1; then ok "bucket $LOGS_BUCKET: all public access blocked"
    else diff_ "bucket $LOGS_BUCKET: public access not fully blocked"; fi

    local cf; cf=$(AWS cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '$FILES_HOST')] | [0]" --output json)
    if [ "$cf" = null ] || [ -z "$cf" ]; then diff_ "CloudFront: no distribution for $FILES_HOST"; else
        local origin dom; dom=$(jq -r .DomainName <<<"$cf")
        origin=$(jq -r '.DefaultCacheBehavior.TargetOriginId as $t | .Origins.Items[] | select(.Id==$t) | .DomainName' <<<"$cf")
        case "$origin" in "$FILES_BUCKET".s3*) ok "CloudFront $FILES_HOST: origin $origin" ;; *) diff_ "CloudFront $FILES_HOST: origin is $origin, expected the $FILES_BUCKET bucket" ;; esac
        same "CloudFront $FILES_HOST: viewer protocol" redirect-to-https "$(jq -r .DefaultCacheBehavior.ViewerProtocolPolicy <<<"$cf")"
        local alias; alias=$(record "$FILES_HOST" A | jq -r '.AliasTarget.DNSName // empty')
        same "DNS $FILES_HOST -> CloudFront" "$dom." "$alias"
        check_files_lock "$cf"
    fi
}

# Who can read the files bucket (docs/AWS_SETUP.md section 5, "Locking the bucket").
# Locked means: CloudFront signs every request to the bucket (an Origin Access Control,
# sigv4, always); the bucket policy lets exactly this distribution read; S3 itself says
# the policy is not public; the public-access block ignores per-file public grants and
# refuses public policies, but still accepts uploads that ask for public-read (one app
# command does); and object ownership is BucketOwnerPreferred, which signed access
# needs while per-file ACLs stay enabled. The app's own reads use IAM and still work.
# AWS_ABSENT <error code> <value if absent> <aws args...>: like AWS, but when the call
# fails only because the thing doesn't exist (that exact error code), print the given
# value instead. Any other failure (access denied, throttling) fails the check.
AWS_ABSENT() {
    local code=$1 absent=$2 err out; shift 2
    err=$(mktemp "${TMPDIR:-/tmp}/aws_setup_err.XXXXXX")
    if out=$(aws --profile "$PROFILE" --region "$REGION" "$@" 2>"$err"); then rm -f "$err"; printf '%s\n' "$out"; return 0; fi
    # the AWS CLI reports "An error occurred (<Code>) when calling the <Op> operation: ..."
    if grep -qF "An error occurred ($code) when calling" "$err"; then rm -f "$err"; printf '%s\n' "$absent"; return 0; fi
    cat "$err" >&2; rm -f "$err"
    echo "ERROR: aws $1 $2 failed" >&2; echo "aws $1 $2" >> "$FAILFLAG"; return 1
}

check_files_lock() {
    local cf=$1 oac_id oac_cfg oac_good arn pol status pab acct_bpa own cf_ok has_deny is_public open pab_ok
    oac_id=$(jq -r '.DefaultCacheBehavior.TargetOriginId as $t | .Origins.Items[] | select(.Id==$t) | .OriginAccessControlId // ""' <<<"$cf")
    oac_good=false
    if [ -n "$oac_id" ]; then
        oac_cfg=$(AWS cloudfront get-origin-access-control --id "$oac_id" --query OriginAccessControl.OriginAccessControlConfig --output json)
        oac_good=$(jq '.SigningBehavior=="always" and .SigningProtocol=="sigv4" and .OriginAccessControlOriginType=="s3"' <<<"$oac_cfg")
    fi
    arn="arn:aws:cloudfront::$ACCOUNT_ID:distribution/$(jq -r .Id <<<"$cf")"
    # Anything that can't be read (other than "doesn't exist") makes the whole check
    # fail through FAILFLAG, so a failed lookup can never turn into an OK here.
    pol=$(AWS_ABSENT NoSuchBucketPolicy '{"Statement":[]}' s3api get-bucket-policy --bucket "$FILES_BUCKET" --query Policy --output text) || return 0
    # S3's own verdict on whether the policy is public (no policy: not public)
    status=$(AWS_ABSENT NoSuchBucketPolicy False s3api get-bucket-policy-status --bucket "$FILES_BUCKET" --query PolicyStatus.IsPublic --output text) || return 0
    pab=$(AWS_ABSENT NoSuchPublicAccessBlockConfiguration '{}' s3api get-public-access-block --bucket "$FILES_BUCKET" --query PublicAccessBlockConfiguration --output json) || return 0
    # S3 applies the strictest of the bucket and account settings
    acct_bpa=$(AWS_ABSENT NoSuchPublicAccessBlockConfiguration False s3control get-public-access-block --account-id "$ACCOUNT_ID" --query PublicAccessBlockConfiguration.BlockPublicAcls --output text) || return 0
    own=$(AWS_ABSENT OwnershipControlsNotFoundError ObjectWriter s3api get-bucket-ownership-controls --bucket "$FILES_BUCKET" --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text) || return 0
    # exactly the runbook's statement: no extra actions or conditions that could narrow it
    cf_ok=$(jq --arg b "arn:aws:s3:::$FILES_BUCKET/*" --arg a "$arn" '
        [.Statement[] | select(.Effect=="Allow"
            and .Principal == {"Service":"cloudfront.amazonaws.com"}
            and ([.Action] | flatten) == ["s3:GetObject"]
            and ([.Resource] | flatten) == [$b]
            and .Condition == {"StringEquals":{"AWS:SourceArn":$a}})] | length > 0' <<<"$pol")
    # a Deny could block CloudFront despite the Allow; this check can't judge one, so it never says OK past it
    has_deny=$(jq '[.Statement[] | select(.Effect=="Deny")] | length > 0' <<<"$pol")
    is_public=false; [ "$status" = True ] && is_public=true
    # anonymous reads get through only if the policy is public and S3 isn't told to restrict it
    open=false; if [ "$is_public" = true ] && [ "$(jq '.RestrictPublicBuckets==true' <<<"$pab")" != true ]; then open=true; fi
    pab_ok=$(jq '.IgnorePublicAcls==true and .BlockPublicPolicy==true and .RestrictPublicBuckets==true and .BlockPublicAcls!=true' <<<"$pab")

    if [ -n "$oac_id" ] && [ "$oac_good" != true ]; then
        diff_ "files bucket: CloudFront's Origin Access Control $oac_id doesn't always sign (expected sigv4, always, type s3)"
    elif [ "$(jq '.BlockPublicAcls==true' <<<"$pab")" = true ] || [ "$acct_bpa" = True ]; then
        diff_ "files bucket $FILES_BUCKET: BlockPublicAcls is on (bucket or account), so uploads that ask for public-read fail (translate_doab_ids does); keep it off until the app stops asking"
    elif [ -n "$oac_id" ] && [ "$own" != BucketOwnerPreferred ]; then
        diff_ "files bucket $FILES_BUCKET: object ownership is $own; with an Origin Access Control it must be BucketOwnerPreferred (Enforced would reject public-read uploads)"
    elif [ "$open" != true ] && [ -z "$oac_id" ]; then
        diff_ "files bucket: not anonymously readable, but CloudFront has no Origin Access Control; files.unglue.it can't fetch from the bucket"
    elif [ "$open" != true ] && [ "$cf_ok" != true ]; then
        diff_ "files bucket: CloudFront signs its requests, but the bucket policy doesn't let this distribution read; files.unglue.it can't fetch from the bucket"
    elif [ "$open" != true ] && [ "$is_public" != true ] && [ "$pab_ok" = true ] && [ "$has_deny" = true ]; then
        note "files bucket $FILES_BUCKET: locked, but the policy has a Deny statement; check by hand that it doesn't block CloudFront"
    elif [ "$open" != true ] && [ "$is_public" != true ] && [ "$pab_ok" = true ]; then
        ok "files bucket $FILES_BUCKET: not anonymously readable except through CloudFront"
    else
        local where
        if [ "$open" != true ]; then where="anonymous reads are blocked, but the policy still counts as public or the public-access block isn't fully set"
        elif [ -z "$oac_id" ]; then where="anyone can read it directly; lock not started"
        elif [ "$cf_ok" != true ]; then where="step 1 half done: CloudFront signs its requests, but the bucket policy has no statement for this distribution yet; add it before removing public read"
        else where="step 1 done (CloudFront signs its requests); public read still on"; fi
        if [ "$FILES_LOCK" = locked ]; then diff_ "files bucket $FILES_BUCKET: $where"
        else note "files bucket $FILES_BUCKET: $where (planned; docs/AWS_SETUP.md section 5)"; fi
    fi
}

# --- create / cutover (one environment's machine; test only for now) ----------
# Tag on a machine and its Elastic IP while it is the not-yet-live replacement.
CANDIDATE_TAG=unglueit:candidate
UBUNTU_SSM=/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id
KEY_PAIR=production

die() { echo "STOP: $*" >&2; exit 1; }
refuse_prod() {
    [ "$1" = test ] && return 0
    echo "REFUSED: '$2 $1' is not enabled. #109: production comes only after a test rebuild has worked end to end." >&2
    exit 2
}

# The live machine for an environment, via DNS -> Elastic IP -> instance.
# Prints: ip instance subnet vpc
live_machine() {
    local env=$1 dns ip inst
    dns=$(expect "$env" dns)
    ip=$(record "$dns" A | jq -r '.ResourceRecords[0].Value // empty')
    [ -n "$ip" ] || die "no A record for $dns"
    inst=$(AWS_TRY ec2 describe-addresses --public-ips "$ip" --query 'Addresses[0].InstanceId' --output text)
    case "$inst" in i-*) ;; *) die "$dns -> $ip is not an Elastic IP on a machine" ;; esac
    local rest; rest=$(AWS ec2 describe-instances --instance-ids "$inst" \
        --query 'Reservations[0].Instances[0].[InstanceId,SubnetId,VpcId]' --output text) || die "can't read $inst"
    echo "$ip $rest"
}

# The candidate machine for an environment, if any (not terminated).
candidate_instance() {
    AWS ec2 describe-instances --filters "Name=tag:$CANDIDATE_TAG,Values=$1" \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId' --output text || die "can't list candidate machines"
}
candidate_address() {   # prints: allocation-id public-ip associated-instance
    AWS ec2 describe-addresses --filters "Name=tag:$CANDIDATE_TAG,Values=$1" \
        --query 'Addresses[].[AllocationId,PublicIp,InstanceId]' --output text || die "can't list candidate addresses"
}

# A reusable candidate must be exactly one machine that is NOT the live one,
# in the live machine's VPC and subnet, of the right type and profile, with no
# Elastic IP other than the candidate address. Prints its id, or stops.
validate_candidate() {   # validate_candidate <env> <candidates> <live-inst> <vpc> <subnet> <candidate-alloc-or-empty>
    local env=$1 cands=$2 live=$3 vpc=$4 subnet=$5 calloc=$6 c j
    [ "$(wc -w <<<"$cands")" -eq 1 ] || die "more than one machine tagged $CANDIDATE_TAG=$env: $cands; sort that out by hand"
    c=$cands
    [ "$c" != "$live" ] || die "the LIVE machine $live carries the $CANDIDATE_TAG tag; remove the tag before going on"
    j=$(AWS ec2 describe-instances --instance-ids "$c" --query 'Reservations[0].Instances[0]' --output json) || die "can't read candidate $c"
    [ "$(jq -r .VpcId <<<"$j")" = "$vpc" ] || die "candidate $c is in another VPC"
    [ "$(jq -r .SubnetId <<<"$j")" = "$subnet" ] || die "candidate $c is in another subnet"
    [ "$(jq -r .InstanceType <<<"$j")" = "$(expect "$env" type)" ] || die "candidate $c is $(jq -r .InstanceType <<<"$j"), not $(expect "$env" type)"
    [ "$(jq -r '.IamInstanceProfile.Arn // "" | split("/") | last' <<<"$j")" = "$(expect "$env" profile)" ] || die "candidate $c doesn't have profile $(expect "$env" profile)"
    case "$(jq -r .State.Name <<<"$j")" in pending|running) ;; *) die "candidate $c is $(jq -r .State.Name <<<"$j"); start or terminate it by hand" ;; esac
    [ "$(jq -c '[.SecurityGroups[].GroupName]' <<<"$j")" = "[\"$APP_SG\"]" ] || die "candidate $c's security groups aren't exactly $APP_SG"
    local img; img=$(AWS ec2 describe-images --image-ids "$(jq -r .ImageId <<<"$j")" --query 'Images[0].[OwnerId,Name]' --output text) || die "can't read candidate image"
    case "$img" in "$UBUNTU_OWNER"*ubuntu-noble-24.04-amd64-server*) ;; *) die "candidate $c isn't on an official Ubuntu 24.04 image ($img)" ;; esac
    local vol; vol=$(jq -r --arg r "$(jq -r .RootDeviceName <<<"$j")" '.BlockDeviceMappings[] | select(.DeviceName==$r) | .Ebs.VolumeId' <<<"$j")
    local v; v=$(AWS ec2 describe-volumes --volume-ids "$vol" --query 'Volumes[0].[Size,VolumeType,Encrypted]' --output text) || die "can't read candidate disk"
    local vsize vtype venc; read -r vsize vtype venc <<<"$v"
    { [ "$vsize" -ge "$MIN_DISK_GB" ] && [ "$vtype" = gp3 ] && [ "$venc" = True ]; } || die "candidate $c's root disk is $v, not >= $MIN_DISK_GB GB gp3 encrypted"
    local others; others=$(AWS ec2 describe-addresses --filters Name=instance-id,Values="$c" --query 'Addresses[].AllocationId' --output text) || die "can't read candidate addresses"
    for a in $others; do [ "$a" = "$calloc" ] || die "candidate $c already has another Elastic IP ($a)"; done
    echo "$c"
}

cmd_create() {
    local env=$1 yes=$2 want_ami=$3
    refuse_prod "$env" create
    local live ip inst subnet vpc
    live=$(live_machine "$env") || exit 1
    read -r ip inst subnet vpc <<<"$live"
    echo "live $env machine: $inst ($ip), subnet $subnet, VPC $vpc"

    local sg sgvpc
    read -r sg sgvpc <<<"$(AWS ec2 describe-security-groups --filters Name=group-name,Values="$APP_SG" \
        --query 'SecurityGroups[0].[GroupId,VpcId]' --output text)" || die "can't read $APP_SG"
    [ "$sgvpc" = "$vpc" ] || die "$APP_SG is in $sgvpc but the live machine is in $vpc"

    local profile; profile=$(expect "$env" profile)
    local proles; proles=$(AWS_TRY iam get-instance-profile --instance-profile-name "$profile" --query 'InstanceProfile.Roles[].RoleName' --output json) \
        || die "instance profile $profile doesn't exist. Creating IAM roles is a deliberate human step: see docs/AWS_SETUP.md section 6."
    [ "$(jq -c . <<<"$proles")" = "[\"$profile\"]" ] || die "instance profile $profile should hold exactly the role $profile; it holds $proles"

    local ami owner rootdev
    ami=$(AWS ssm get-parameter --name "$UBUNTU_SSM" --query Parameter.Value --output text) || die "can't read the current Ubuntu image ID"
    read -r owner rootdev <<<"$(AWS ec2 describe-images --image-ids "$ami" --query 'Images[0].[OwnerId,RootDeviceName]' --output text)" || die "can't read image $ami"
    [ "$owner" = "$UBUNTU_OWNER" ] || die "image $ami is owned by $owner, not Canonical"
    if [ "$yes" = yes ] && [ "$want_ami" != "$ami" ]; then
        die "--yes needs --ami $ami (the image this plan shows), so what launches is what you reviewed; got '${want_ami:-nothing}'"
    fi

    # The role must already be right: log copy and, for DNS-01, its own ACME record.
    local before=$N_DIFF
    check_role "$env" "$profile" "$(expect "$env" dns)" >/dev/null
    [ "$N_DIFF" -eq "$before" ] || die "role $profile isn't as docs/AWS_SETUP.md section 6 describes; run: $0 check $env"

    local name; name="$env-$(date +%Y-%m-%d)"
    local addr; addr=$(candidate_address "$env")
    [ "$(wc -l <<<"${addr:-x}" | tr -d ' ')" -le 1 ] || die "more than one Elastic IP tagged $CANDIDATE_TAG=$env"
    local calloc cip con; read -r calloc cip con <<<"$addr"
    [ "$cip" != "$ip" ] || die "the LIVE address $ip carries the $CANDIDATE_TAG tag; remove the tag before going on"
    local existing; existing=$(candidate_instance "$env")
    [ -z "$existing" ] || existing=$(validate_candidate "$env" "$existing" "$inst" "$vpc" "$subnet" "$calloc") || exit 1
    case "$con" in ""|None|"$existing") ;; *) die "candidate address $cip is attached to $con, which isn't the candidate machine" ;; esac
    local type; type=$(expect "$env" type)
    local tags="ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=$CANDIDATE_TAG,Value=$env}]"
    local bdm="DeviceName=$rootdev,Ebs={VolumeSize=$MIN_DISK_GB,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}"
    local run=(ec2 run-instances --image-id "$ami" --instance-type "$type" --subnet-id "$subnet"
               --security-group-ids "$sg" --key-name "$KEY_PAIR" --iam-instance-profile "Name=$profile"
               --block-device-mappings "$bdm" --metadata-options HttpTokens=required,HttpEndpoint=enabled
               --tag-specifications "$tags" "ResourceType=volume,Tags=[{Key=Name,Value=$name}]" --count 1)

    echo
    echo "== plan: create $env"
    if [ -n "$existing" ]; then echo "  machine: reuse existing candidate $existing"
    else echo "  machine: launch $name: $type, image $ami (Ubuntu 24.04, Canonical), $MIN_DISK_GB GB gp3 encrypted, $APP_SG, key $KEY_PAIR, profile $profile, IMDSv2 required"; fi
    if [ -n "$addr" ]; then echo "  address: reuse candidate Elastic IP $cip"
    else echo "  address: allocate a new Elastic IP tagged $CANDIDATE_TAG=$env"; fi
    echo "  not touched: the live machine $inst, its address $ip, DNS, databases, security groups"

    if [ "$yes" != yes ]; then
        echo
        if [ -z "$existing" ]; then
            local out; out=$(aws --profile "$PROFILE" --region "$REGION" "${run[@]}" --dry-run 2>&1)
            case "$out" in *DryRunOperation*) echo "permission check (AWS --dry-run): launch would be allowed" ;;
                *) echo "permission check (AWS --dry-run) FAILED: $out" >&2; exit 1 ;; esac
        fi
        if [ -z "$addr" ]; then
            local out2; out2=$(aws --profile "$PROFILE" --region "$REGION" ec2 allocate-address --domain vpc --dry-run 2>&1)
            case "$out2" in *DryRunOperation*) echo "permission check (AWS --dry-run): address allocation would be allowed" ;;
                *) echo "permission check (AWS --dry-run) FAILED: $out2" >&2; exit 1 ;; esac
        fi
        local live_alloc; live_alloc=$(AWS ec2 describe-addresses --public-ips "$ip" --query 'Addresses[0].AllocationId' --output text) || die "can't read $ip"
        local out3; out3=$(aws --profile "$PROFILE" --region "$REGION" ec2 associate-address --allocation-id "$live_alloc" \
            --instance-id "$inst" --no-allow-reassociation --dry-run 2>&1)
        case "$out3" in *DryRunOperation*) echo "permission check (AWS --dry-run): attaching an address would be allowed" ;;
            *) echo "permission check (AWS --dry-run) FAILED: $out3" >&2; exit 1 ;; esac
        echo "Plan only: nothing created. To do it: $0 create $env --ami $ami --yes"
        return 0
    fi

    partial() { die "$1. What exists now: machine ${existing:-none}, address ${cip:-none} (both tagged $CANDIDATE_TAG=$env). Re-running create reuses them; to undo: terminate the machine, release the address."; }
    if [ -z "$existing" ]; then
        existing=$(AWS "${run[@]}" --query 'Instances[0].InstanceId' --output text) || partial "launch failed"
        echo "launched $existing; waiting for it to run..."
        AWS ec2 wait instance-running --instance-ids "$existing" || partial "$existing didn't reach running"
    fi
    if [ -z "$addr" ]; then
        local alloc; alloc=$(AWS ec2 allocate-address --domain vpc \
            --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$name},{Key=$CANDIDATE_TAG,Value=$env}]" \
            --query AllocationId --output text) || partial "address allocation failed"
        addr=$(candidate_address "$env"); read -r calloc cip con <<<"$addr"
    fi
    local alloc_id=$calloc new_ip=$cip
    if [ "$con" != "$existing" ]; then
        AWS ec2 associate-address --allocation-id "$alloc_id" --instance-id "$existing" --no-allow-reassociation >/dev/null \
            || partial "couldn't attach $new_ip to $existing"
    fi
    echo
    echo "created: $existing with $new_ip (candidate; $(expect "$env" dns) still points at $ip)"
    echo "next:"
    echo "  1. build it:  ansible-playbook -i hosts setup-$env.yml -e ansible_host=$new_ip"
    echo "     (stop celery on one of the two machines while both point at the same database)"
    echo "  2. check it:  curl --resolve $(expect "$env" dns):443:$new_ip https://$(expect "$env" dns)/  (and click around the same way)"
    echo "  3. switch:    scripts/aws_setup.sh cutover $env --expect-current $ip"
}

cmd_cutover() {
    local env=$1 yes=$2 expect_current=$3
    refuse_prod "$env" cutover
    local dns; dns=$(expect "$env" dns)
    local live ip inst subnet vpc; live=$(live_machine "$env") || exit 1
    read -r ip inst subnet vpc <<<"$live"
    local cand; cand=$(candidate_instance "$env")
    [ -n "$cand" ] || die "no candidate machine tagged $CANDIDATE_TAG=$env; run create first"
    local alloc_id new_ip on; read -r alloc_id new_ip on <<<"$(candidate_address "$env")"
    cand=$(validate_candidate "$env" "$cand" "$inst" "$vpc" "$subnet" "$alloc_id") || exit 1
    [ -n "$new_ip" ] || die "the candidate has no candidate Elastic IP"
    [ "$on" = "$cand" ] || die "candidate address $new_ip is attached to '$on', not $cand"
    [ "$new_ip" != "$ip" ] || die "$dns already points at the candidate ($ip)"
    local st; st=$(AWS ec2 describe-instances --instance-ids "$cand" --query 'Reservations[0].Instances[0].State.Name' --output text)
    [ "$st" = running ] || die "candidate $cand is $st"
    local code; code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --resolve "$dns:443:$new_ip" "https://$dns/" || true)
    case "$code" in 200|301|302|401) ;; *) die "candidate doesn't answer https://$dns/ properly (HTTP $code); build and check it first" ;; esac

    echo "== plan: cutover $env"
    echo "  $dns A: $ip ($inst)  ->  $new_ip ($cand); TTL $(record "$dns" A | jq -r .TTL)s"
    echo "  candidate answers https://$dns/ with HTTP $code (certificate valid for $dns)"
    echo "  not touched: either machine's state, addresses, databases"
    [ "$yes" = yes ] || { echo "Plan only. To switch: scripts/aws_setup.sh cutover $env --expect-current $ip --yes"; return 0; }
    [ "$expect_current" = "$ip" ] || die "--expect-current must be the address $dns points at now ($ip); got '${expect_current:-nothing}'"

    # One batch: DELETE the exact record we expect, CREATE the new one. If the
    # record changed since we read it, Route 53 rejects the whole batch.
    local cur; cur=$(record "$dns" A)
    [ "$(jq -c '[.ResourceRecords[].Value]' <<<"$cur")" = "[\"$ip\"]" ] || die "$dns has more than one A value; switch it by hand"
    local batch; batch=$(jq -cn --argjson old "$cur" --arg v "$new_ip" \
        '{Comment:"aws_setup.sh cutover",Changes:[{Action:"DELETE",ResourceRecordSet:$old},
          {Action:"CREATE",ResourceRecordSet:($old|.ResourceRecords=[{Value:$v}])}]}')
    local back; back=$(jq -c --argjson new "$(jq -c '.Changes[1].ResourceRecordSet' <<<"$batch")" \
        '{Comment:"aws_setup.sh cutover rollback",Changes:[{Action:"DELETE",ResourceRecordSet:$new},{Action:"CREATE",ResourceRecordSet:.Changes[0].ResourceRecordSet}]}' <<<"$batch")
    local change; change=$(AWS route53 change-resource-record-sets --hosted-zone-id "$(zone_id)" --change-batch "$batch" \
        --query ChangeInfo.Id --output text) || die "DNS change failed"
    AWS route53 wait resource-record-sets-changed --id "$change" || die "DNS change $change didn't complete"
    echo
    echo "switched: $dns -> $new_ip ($cand). Old machine $inst ($ip) left running."
    echo "to switch back, restore the record:"
    echo "  aws route53 change-resource-record-sets --hosted-zone-id $(zone_id) --change-batch '$back'"
    echo "after checking the site: stop $inst, keep it 24 hours, then terminate it and release $ip;"
    echo "  remove the $CANDIDATE_TAG tag from $cand and its address."
}

# --- main ----------------------------------------------------------------------------
usage() {
    echo "usage: $0 check [prod|test|all]" >&2
    echo "       $0 create test [--ami <id> --yes]" >&2
    echo "       $0 cutover test [--expect-current <ip> --yes]" >&2
    exit 2
}
ACTION="${1:-}"; shift || true
case "$ACTION" in
    create|cutover)
        ENVNAME="${1:-}"; shift || true
        case "$ENVNAME" in prod|test) ;; *) usage ;; esac
        YES=no; EXPECT_CURRENT=""; WANT_AMI=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --yes) YES=yes ;;
                --expect-current) EXPECT_CURRENT="${2:-}"; shift ;;
                --ami) WANT_AMI="${2:-}"; shift ;;
                *) usage ;;
            esac; shift
        done
        guard
        if [ "$ACTION" = create ]; then cmd_create "$ENVNAME" "$YES" "$WANT_AMI"; else cmd_cutover "$ENVNAME" "$YES" "$EXPECT_CURRENT"; fi
        [ ! -s "$FAILFLAG" ] || { echo "STOP: an AWS call failed (see ERROR above)" >&2; exit 1; }
        exit 0 ;;
    check) ;;
    *) usage ;;
esac
SCOPE="${1:-all}"
case "$SCOPE" in prod|test|all) ;; *) usage ;; esac
guard
case "$SCOPE" in
    prod) check_env prod ;;
    test) check_env test ;;
    all)  check_env prod; check_env test; check_shared ;;
esac
if [ -s "$FAILFLAG" ]; then
    while read -r c; do diff_ "AWS read failed: $c (see ERROR above); that item wasn't checked"; done < "$FAILFLAG"
fi
echo
jq -cn --arg scope "$SCOPE" --argjson ok "$N_OK" --argjson diff "$N_DIFF" --argjson note "$N_NOTE" \
    --args '{check: $scope, ok: $ok, diff: $diff, note: $note, diffs: $ARGS.positional}' "${DIFFS[@]+"${DIFFS[@]}"}"
[ "$N_DIFF" -eq 0 ]
