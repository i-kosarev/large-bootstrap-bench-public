#!/bin/bash
# Single-host adapter used by tests/run_failure_test.sh.
cluster_idle_nodes() { echo local0; }
cluster_alloc_nodelist() { echo local-job; }
cluster_alloc_state() { echo RUNNING; }
cluster_alloc_nodes() { echo local0; }
cluster_time_left_sec() { echo 600; }
cluster_cancel() { :; }
cluster_node_health() { echo "0 0.0 0"; }
cluster_node_clean() { :; }
cluster_launch() {
  shift 7
  [ "${1:-}" = "--" ] && shift
  bash -lc "$*"
}
