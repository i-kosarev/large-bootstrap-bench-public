#!/bin/bash
# Regression test for DRY_RUN: core.sh must print the command plan and execute nothing
# (no scheduler calls, no result logs), for both the self-allocate and external-JOBID paths.
set -uo pipefail
HERE=$(cd "$(dirname "$0")"&&pwd); ROOT=$(cd "$HERE/.."&&pwd)

# A test adapter whose every cluster_* call appends to a marker file. If DRY_RUN truly
# executes nothing, the marker must stay absent.
MARK=/tmp/coredry_marker
cat > "$ROOT/adapters/dry_probe.sh" <<EOF
#!/bin/bash
cluster_idle_nodes()     { echo "idle"     >> "$MARK"; echo probe-node; }
cluster_alloc_nodelist() { echo "alloc"    >> "$MARK"; echo probe-job; }
cluster_alloc_state()    { echo "state"    >> "$MARK"; echo RUNNING; }
cluster_alloc_nodes()    { echo "nodes"    >> "$MARK"; echo probe-node; }
cluster_time_left_sec()  { echo 600; }
cluster_cancel()         { echo "cancel"   >> "$MARK"; }
cluster_node_health()    { echo "health"   >> "$MARK"; echo "0 0.0 0"; }
cluster_node_clean()     { echo "clean"    >> "$MARK"; }
cluster_launch()         { echo "launch"   >> "$MARK"; }
EOF
cp "$HERE/single_sample_plugin.sh" "$ROOT/plugins/" 2>/dev/null || \
  cp "$HERE/echo_plugin.sh" "$ROOT/plugins/single_sample_plugin.sh"
trap 'rm -f "$ROOT/adapters/dry_probe.sh" "$ROOT/plugins/single_sample_plugin.sh"' EXIT

run_dry(){ # $1=label, rest=env assignments
  local label=$1; shift
  rm -f "$MARK"; local out=/tmp/coredry_${label}.log
  local outroot=/tmp/coredry_${label}_out; rm -rf "$outroot"
  set +e
  env "$@" DRY_RUN=1 CLUSTER=dry_probe PLUGIN=single_sample_plugin N=2 TARGET=100 \
    OUTROOT="$outroot" bash "$ROOT/core.sh" > "$out" 2>&1
  local rc=$?
  set -e
  echo "--- $label (rc=$rc) ---"; sed -n '1,40p' "$out"
  [ "$rc" -eq 0 ] || { echo "FAIL: DRY_RUN should exit 0 ($label)"; exit 1; }
  [ ! -f "$MARK" ] || { echo "FAIL: DRY_RUN executed adapter calls ($label): $(tr '\n' ',' <"$MARK")"; exit 1; }
  grep -q '>>> ' "$out" || { echo "FAIL: DRY_RUN printed no command plan ($label)"; exit 1; }
  grep -q 'iter 1 on' "$out" || { echo "FAIL: DRY_RUN did not print the per-arm launch ($label)"; exit 1; }
}

run_dry self                       # self-allocate path
run_dry ext JOBID=external-abc     # external-JOBID path
grep -q 'external JOBID=external-abc' /tmp/coredry_ext.log || { echo "FAIL: external path not shown"; exit 1; }

echo "DRYRUN E2E: PASS"
