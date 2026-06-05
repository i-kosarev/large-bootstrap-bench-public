#!/bin/bash
# Regression test for DRY_RUN: core.sh must print REAL, copy-pasteable commands and
# perform NO side effects -- no allocation, launch, cancel, node-clean, or ssh.
# Read-only discovery (cluster_idle_nodes / cluster_alloc_nodes / cluster_alloc_state)
# IS allowed, so the printed commands carry real node names.
set -uo pipefail
HERE=$(cd "$(dirname "$0")"&&pwd); ROOT=$(cd "$HERE/.."&&pwd)

# Probe adapter: read-only ops append to RO_MARK; side-effecting ops append to SE_MARK.
# DRY_RUN must leave SE_MARK absent.
RO_MARK=/tmp/coredry_ro_marker
SE_MARK=/tmp/coredry_se_marker
cat > "$ROOT/adapters/dry_probe.sh" <<EOF
#!/bin/bash
cluster_idle_nodes()     { echo idle  >> "$RO_MARK"; printf 'pn1\npn2\npn3\n'; }
cluster_alloc_state()    { echo state >> "$RO_MARK"; echo RUNNING; }
cluster_alloc_nodes()    { echo nodes >> "$RO_MARK"; printf 'pn1\npn2\n'; }
cluster_time_left_sec()  { echo 600; }
cluster_node_health()    { echo health >> "$RO_MARK"; echo "0 0.0 0"; }
cluster_alloc_nodelist() { echo alloc  >> "$SE_MARK"; echo probe-job; }
cluster_cancel()         { echo cancel >> "$SE_MARK"; }
cluster_node_clean()     { echo clean  >> "$SE_MARK"; }
cluster_launch()         { echo launch >> "$SE_MARK"; }
EOF
cp "$HERE/single_sample_plugin.sh" "$ROOT/plugins/" 2>/dev/null || \
  cp "$HERE/echo_plugin.sh" "$ROOT/plugins/single_sample_plugin.sh"
trap 'rm -f "$ROOT/adapters/dry_probe.sh" "$ROOT/plugins/single_sample_plugin.sh"' EXIT

run_dry(){ # $1=label, rest=env assignments
  local label=$1; shift
  rm -f "$RO_MARK" "$SE_MARK"; local out=/tmp/coredry_${label}.log
  local outroot=/tmp/coredry_${label}_out; rm -rf "$outroot"
  set +e
  env "$@" DRY_RUN=1 CLUSTER=dry_probe PLUGIN=single_sample_plugin N=2 TARGET=100 \
    OUTROOT="$outroot" bash "$ROOT/core.sh" > "$out" 2>&1
  local rc=$?
  set -e
  echo "--- $label (rc=$rc) ---"; sed -n '1,40p' "$out"
  [ "$rc" -eq 0 ] || { echo "FAIL: DRY_RUN should exit 0 ($label)"; exit 1; }
  [ ! -f "$SE_MARK" ] || { echo "FAIL: DRY_RUN executed side effects ($label): $(tr '\n' ',' <"$SE_MARK")"; exit 1; }
  grep -q '>>> ' "$out" || { echo "FAIL: DRY_RUN printed no commands ($label)"; exit 1; }
  grep -q 'iter 1 on' "$out" || { echo "FAIL: DRY_RUN did not print the per-arm launch ($label)"; exit 1; }
  # no result logs should be written
  [ ! -e "$outroot/single_sample_plugin/2n/on.log" ] || { echo "FAIL: DRY_RUN wrote result logs ($label)"; exit 1; }
}

run_dry self                       # self-allocate path: real node names from discovery
grep -q 'pn1' /tmp/coredry_self.log || { echo "FAIL: self path did not use discovered node names"; exit 1; }
run_dry ext JOBID=external-abc     # external-JOBID path
grep -q 'external JOBID=external-abc' /tmp/coredry_ext.log || { echo "FAIL: external path not shown"; exit 1; }

echo "DRYRUN E2E: PASS"
