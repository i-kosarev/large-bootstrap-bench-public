#!/bin/bash
# Test-only plugin: one arm always succeeds, the other always fails after a sample.
bench_arms() { echo "on off"; }
bench_arm_cmd() {
  case "$1" in
    on)  echo "bash -c 'echo Bootstrap timings total 0.001; exit 42'";;
    off) echo "bash -c 'echo Bootstrap timings total 0.002'";;
  esac
}
bench_ldpath() { echo "/nonexistent/lib"; }
bench_ppn() { echo "1"; }
bench_expect() { echo "$1"; }
bench_sample_grep() { echo "Bootstrap timings total"; }
