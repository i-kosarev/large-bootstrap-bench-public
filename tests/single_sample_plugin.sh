#!/bin/bash
# Test-only plugin: one rank, one sample per successful arm.
bench_arms() { echo "on off"; }
bench_arm_cmd() {
  echo "bash -c 'echo Bootstrap timings total 0.001'"
}
bench_ldpath() { echo "/nonexistent/lib"; }
bench_ppn() { echo "1"; }
bench_expect() { echo "$1"; }
bench_sample_grep() { echo "Bootstrap timings total"; }
