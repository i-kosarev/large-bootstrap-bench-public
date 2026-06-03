#!/bin/bash
# Test-only plugin: emits a sample-looking line, then exits non-zero.
# core.sh must not count this as a complete benchmark iteration.
bench_arms() { echo "on off"; }
bench_arm_cmd() {
  echo "bash -c 'echo Bootstrap timings total 0.001; exit 42'"
}
bench_ldpath() { echo "/nonexistent/lib"; }
bench_ppn() { echo "1"; }
bench_expect() { echo "$1"; }
bench_sample_grep() { echo "Bootstrap timings total"; }
