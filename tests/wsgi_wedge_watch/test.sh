#!/bin/bash
# Host-side wrapper: renders wsgi_wedge_watch.sh.j2 with default values and runs
# the assertion harness (run_tests.sh) inside ubuntu:24.04 (GNU userland,
# matching prod). Usage: ./test.sh   (requires docker)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="$HERE/../../roles/regluit_prod/templates/wsgi_wedge_watch.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
sed -e "s/{{ mem_alert_email | default('notices@gluejar.com') }}/notices@gluejar.com/" \
    -e "s/{{ default_from_email | default('notices@gluejar.com') }}/notices@gluejar.com/" \
    -e "s/{{ wsgi_process_group | default('regluit') }}/regluit/" \
    "$TPL" > "$WORK/watch.sh"
bash -n "$WORK/watch.sh"
cp "$HERE/run_tests.sh" "$WORK/run_tests.sh"
docker run --rm -v "$WORK":/work ubuntu:24.04 bash /work/run_tests.sh
