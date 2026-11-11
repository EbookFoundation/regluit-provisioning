#!/usr/bin/env bash
# aws_setup.sh - the AWS pieces the playbooks don't build (docs/AWS_SETUP.md).
# Issue #109. Run from a laptop with the AWS CLI and jq.
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
# Planned in #109, not here yet: `create` (one environment's machine, role
# and address; test only by default) and `cutover` (move the address/DNS,
# with confirmation). Shared security groups will stay check-only.

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

usage() { echo "usage: $0 check [prod|test|all]" >&2; exit 2; }

guard() {
    command -v jq >/dev/null || { echo "REFUSED: jq is required" >&2; exit 2; }
    local acct
    acct=$(AWS_TRY sts get-caller-identity --query Account --output text) \
        || { echo "REFUSED: no AWS credentials for profile $PROFILE" >&2; exit 2; }
    if [ "$(printf %s "$acct" | sha256)" != "$EXPECTED_ACCOUNT_SHA256" ]; then
        echo "REFUSED: profile $PROFILE is not the unglue.it AWS account" >&2; exit 2
    fi
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
    #   find   route53:ListHostedZones / route53:GetChange on "*" (certbot DNS-01)
    #   acme   route53:ChangeResourceRecordSets on the unglue.it zone, limited by
    #          condition to the TXT record _acme-challenge.<its own name>
    local zone_arn="arn:aws:route53:::hostedzone/$(zone_id | sed 's#^/hostedzone/##')"
    local shapes; shapes=$(jq -c --arg r "arn:aws:s3:::$LOGS_BUCKET/unglue.it/$env/*" --arg z "$zone_arn" --arg n "_acme-challenge.$dns" '
        def acts: [.Action]|flatten; def res: [.Resource]|flatten;
        [ .[] | select(.Effect=="Allow") |
          if has("NotAction") or has("NotResource") then "other"
          elif (acts - ["s3:PutObject","s3:AbortMultipartUpload"] | length)==0 and res==[$r] and (has("Condition")|not) then "log"
          elif (acts - ["route53:ListHostedZones","route53:GetChange"] | length)==0 and res==["*"] and (has("Condition")|not) then "find"
          elif acts==["route53:ChangeResourceRecordSets"] and res==[$z]
               and .Condition=={"ForAllValues:StringEquals":{"route53:ChangeResourceRecordSetsNormalizedRecordNames":[$n],"route53:ChangeResourceRecordSetsRecordTypes":["TXT"]}} then "acme"
          else "other" end ]' <<<"$pol")
    if jq -e 'index("other")' <<<"$shapes" >/dev/null; then
        diff_ "$env role $role: inline policy allows more than the log copy and its own ACME challenge record"
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
    fi
}

# --- main ----------------------------------------------------------------------------
[ "${1:-}" = check ] || usage
SCOPE="${2:-all}"
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
