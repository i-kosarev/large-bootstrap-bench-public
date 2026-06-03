#!/bin/bash
# Minimal bench plugin to validate the flux adapter end-to-end without GPUs/RCCL.
# Two arms; each "sample" line mimics the grep contract. EXP = nranks.
bench_arms() { echo "on off"; }
bench_arm_cmd() {
  local arm=$1
  # emit one "Bootstrap timings total <sec>" per rank so core's complete() counts it
  echo "-x ARMTAG=$arm bash -c 'echo Bootstrap timings total 0.00$RANDOM'"
}
bench_ldpath() { echo "/nonexistent/lib"; }
bench_ppn() { echo "2"; }
bench_expect() { echo $(( $1 * 2 )); }
bench_sample_grep() { echo "Bootstrap timings total"; }
