#!/bin/bash
# Regression test for using an existing scheduler allocation instead of allocating.
set -uo pipefail
HERE=$(cd "$(dirname "$0")"&&pwd); ROOT=$(cd "$HERE/.."&&pwd)

cp "$HERE/local_jobid.sh" "$ROOT/adapters/"
cp "$HERE/single_sample_plugin.sh" "$ROOT/plugins/"
trap 'rm -f "$ROOT/adapters/local_jobid.sh" "$ROOT/plugins/single_sample_plugin.sh"' EXIT

OUT=/tmp/corejobid_out
MARK=/tmp/corejobid_alloc_marker
rm -rf "$OUT" "$MARK"
set +e
SLURM_JOB_ID=external-job CLUSTER=local_jobid PLUGIN=single_sample_plugin \
  N=1 TARGET=1 FAILMAX=1 OUTROOT="$OUT" ALLOC_MARK="$MARK" \
  bash "$ROOT/core.sh" > "$OUT.run.log" 2>&1
rc=$?
set -e

echo "--- slurm-job-id alias core output ---"
sed -n '1,120p' "$OUT.run.log"
echo "--- assertions ---"
echo "rc=$rc (expect 0)"
[ "$rc" -eq 0 ] || { echo "FAIL: SLURM_JOB_ID alias was not accepted"; exit 1; }
[ ! -s "$MARK" ] || { echo "FAIL: core allocated despite existing SLURM_JOB_ID"; exit 1; }
[ "$(cat "$OUT/single_sample_plugin/1n/.jobid")" = external-job ] || { echo "FAIL: wrong job id recorded"; exit 1; }
[ "$(cat "$OUT/single_sample_plugin/1n/.nodes")" = external-node ] || { echo "FAIL: wrong node selected"; exit 1; }

OUT=/tmp/corejobid_dead_out
MARK=/tmp/corejobid_dead_alloc_marker
rm -rf "$OUT" "$MARK"
set +e
JOBID=dead-job CLUSTER=local_jobid PLUGIN=single_sample_plugin \
  N=1 TARGET=1 FAILMAX=1 OUTROOT="$OUT" ALLOC_MARK="$MARK" \
  bash "$ROOT/core.sh" > "$OUT.run.log" 2>&1
rc=$?
set -e

echo "--- dead provided job core output ---"
sed -n '1,120p' "$OUT.run.log"
echo "rc=$rc (expect non-zero)"
[ "$rc" -ne 0 ] || { echo "FAIL: dead provided JOBID did not abort"; exit 1; }
[ ! -s "$MARK" ] || { echo "FAIL: core allocated after provided JOBID was dead"; exit 1; }

echo "JOBID E2E: PASS"
