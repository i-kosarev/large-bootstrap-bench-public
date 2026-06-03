#!/bin/bash
# Regression test for failed arms that print sample-looking lines before exiting.
set -uo pipefail
HERE=$(cd "$(dirname "$0")"&&pwd); ROOT=$(cd "$HERE/.."&&pwd)

cp "$HERE/local_fail.sh" "$ROOT/adapters/"
cp "$HERE/fail_after_sample_plugin.sh" "$ROOT/plugins/"
cp "$HERE/one_arm_fail_plugin.sh" "$ROOT/plugins/"
trap 'rm -f "$ROOT/adapters/local_fail.sh" "$ROOT/plugins/fail_after_sample_plugin.sh" "$ROOT/plugins/one_arm_fail_plugin.sh"' EXIT

OUT=/tmp/corefail_out
rm -rf "$OUT"
set +e
CLUSTER=local_fail PLUGIN=fail_after_sample_plugin N=1 TARGET=1 FAILMAX=2 \
  OUTROOT="$OUT" bash "$ROOT/core.sh" > "$OUT.run.log" 2>&1
rc=$?
set -e

echo "--- core output ---"
sed -n '1,120p' "$OUT.run.log"
echo "--- assertions ---"
echo "rc=$rc (expect non-zero)"
[ "$rc" -ne 0 ] || { echo "FAIL: core accepted failed arms"; exit 1; }

on_complete=$(awk '
  /^===/ { if (s && n == 1) k++; n = 0; s = ($0 ~ /^=== iter/); next }
  s && /Bootstrap timings total/ { n++ }
  END { if (s && n == 1) k++; print k+0 }
' "$OUT/fail_after_sample_plugin/1n/on.log" 2>/dev/null || echo 0)
echo "complete_on=$on_complete (expect 0)"
[ "$on_complete" = 0 ] || { echo "FAIL: failed on-arm sample was counted"; exit 1; }

OUT=/tmp/corefail_one_arm_out
rm -rf "$OUT"
set +e
CLUSTER=local_fail PLUGIN=one_arm_fail_plugin N=1 TARGET=1 FAILMAX=2 \
  OUTROOT="$OUT" bash "$ROOT/core.sh" > "$OUT.run.log" 2>&1
rc=$?
set -e

echo "--- one-arm-failure core output ---"
sed -n '1,160p' "$OUT.run.log"
echo "rc=$rc (expect non-zero)"
[ "$rc" -ne 0 ] || { echo "FAIL: persistent one-arm failure did not abort"; exit 1; }
on_failed=$(awk '/^=== failed iter/ { n++ } END { print n+0 }' "$OUT/one_arm_fail_plugin/1n/on.log" 2>/dev/null)
off_complete=$(awk '
  /^===/ { if (s && n == 1) k++; n = 0; s = ($0 ~ /^=== iter/); next }
  s && /Bootstrap timings total/ { n++ }
  END { if (s && n == 1) k++; print k+0 }
' "$OUT/one_arm_fail_plugin/1n/off.log" 2>/dev/null || echo 0)
echo "one_arm_failed_on=$on_failed (expect >=2), off_complete=$off_complete (expect >=1)"
[ "$on_failed" -ge 2 ] || { echo "FAIL: on-arm failures were not tracked"; exit 1; }
[ "$off_complete" -ge 1 ] || { echo "FAIL: successful off-arm was not counted"; exit 1; }

echo "FAILURE E2E: PASS"
