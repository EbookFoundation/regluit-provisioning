#!/bin/bash
# Runs ship_logs.py against a throwaway S3 server (SeaweedFS, with key checking
# on), inside ubuntu:24.04 with the apt python3-boto3, the same boto3 as the
# servers. Needs docker. Leaves nothing behind: both containers and the network
# are removed on exit.
#   tests/log_shipper/test.sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../roles/regluit_prod/files/ship_logs.py"
RUN="logship-test-$$"
# Pinned by digest. MinIO's public images could not be pulled on 2026-11-02.
S3_IMAGE=chrislusf/seaweedfs@sha256:c2658820e763294a9e9de7b36c81e59b879e3459148351aee4e31a126ca64860
# Everything sizable lives in memory (--tmpfs): a nearly full Docker disk makes
# SeaweedFS hang uploads rather than fail them, and other containers share that disk.
# Throwaway credentials for a container that exists only for this run.
KEY=testkeytestkey
SECRET=testsecrettestsecret
WORK=$(mktemp -d)

cleanup() {
    docker rm -f "$RUN-s3" "$RUN-test" >/dev/null 2>&1 || true
    docker network rm "$RUN" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$SCRIPT"
FREE_MB=$(docker run --rm ubuntu:24.04 df -m / | awk 'NR==2 {print $4}')
if [ "$FREE_MB" -lt 200 ]; then
    echo "Docker's disk has only ${FREE_MB} MB free; not adding to it. Free some space first." >&2
    exit 2
fi
cat > "$WORK/s3.json" <<EOF
{"identities":[{"name":"test","credentials":[{"accessKey":"$KEY","secretKey":"$SECRET"}],
 "actions":["Admin","Read","List","Tagging","Write"]}]}
EOF
docker network create "$RUN" >/dev/null
docker run -d --rm --name "$RUN-s3" --network "$RUN" -v "$WORK/s3.json:/s3.json:ro" \
    --tmpfs /data:size=512m \
    "$S3_IMAGE" server -dir=/data -s3 -s3.port=9000 -s3.config=/s3.json >/dev/null

docker run --rm --name "$RUN-test" --network "$RUN" \
    --tmpfs /tmp:size=256m,exec \
    --tmpfs /var/cache/apt:size=256m \
    --tmpfs /var/lib/apt/lists:size=128m \
    --tmpfs /usr/lib/python3/dist-packages:size=300m \
    -v "$SCRIPT:/work/ship_logs.py:ro" \
    -v "$HERE/test_ship_logs.py:/work/test_ship_logs.py:ro" \
    -e TEST_ENDPOINT="http://$RUN-s3:9000" \
    -e AWS_ACCESS_KEY_ID="$KEY" -e AWS_SECRET_ACCESS_KEY="$SECRET" \
    -e AWS_DEFAULT_REGION=us-east-1 \
    -e PYTHONDONTWRITEBYTECODE=1 \
    ubuntu:24.04 bash -c '
        set -e
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-boto3 >/dev/null 2>&1
        python3 -c "import boto3; print(\"boto3\", boto3.__version__)"
        cd /work
        for i in $(seq 1 60); do
            python3 -c "
import boto3, botocore.config, os
c = boto3.client(\"s3\", endpoint_url=os.environ[\"TEST_ENDPOINT\"], region_name=\"us-east-1\",
                 config=botocore.config.Config(s3={\"addressing_style\": \"path\"}, retries={\"max_attempts\": 1}))
c.list_buckets()
" 2>/dev/null && break
            sleep 1
        done
        python3 test_ship_logs.py
    '
