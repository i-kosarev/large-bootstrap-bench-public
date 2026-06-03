#!/bin/bash
# Test adapter used by tests/run_jobid_test.sh.
: "${ALLOC_MARK:?set ALLOC_MARK}"
cluster_idle_nodes() { echo alloc-node; }
cluster_alloc_nodelist() {
  echo "allocated $1" >> "$ALLOC_MARK"
  echo allocated-job
}
cluster_alloc_state() {
  case "$1" in
    external-job|allocated-job) echo RUNNING;;
    *) echo DEAD;;
  esac
}
cluster_alloc_nodes() {
  case "$1" in
    external-job) echo external-node;;
    allocated-job) echo alloc-node;;
  esac
}
cluster_time_left_sec() { echo 600; }
cluster_cancel() { :; }
cluster_node_health() { echo "0 0.0 0"; }
cluster_node_clean() { :; }
cluster_launch() {
  shift 7
  [ "${1:-}" = "--" ] && shift
  bash -lc "$*"
}
