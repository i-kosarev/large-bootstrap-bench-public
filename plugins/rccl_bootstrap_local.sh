#!/bin/bash
# Local validation plugin: single-workstation / small SLURM box, IB disabled (TCP only).
# Site-specific defaults are intentionally isolated here; override ROCM, RCCL_LIB,
# BIN, PPN and IFNAME from the environment when porting to another workstation.
ROCM=${ROCM:-/opt/rocm}
RCCL_LIB=${RCCL_LIB:-/path/to/rccl/build}
BIN=${BIN:-/path/to/rccl-tests/all_gather_perf}
PLUGIN_LDPATH="$RCCL_LIB:$ROCM/lib:/usr/lib/x86_64-linux-gnu/openmpi/lib"
PPN=${PPN:-8}
IFNAME=${IFNAME:-eth0}

bench_arms() { echo "on off"; }
bench_arm_cmd() {
  local arm=$1 common="-x NCCL_SOCKET_IFNAME=$IFNAME -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=BOOTSTRAP -x NCCL_IB_DISABLE=1"
  case "$arm" in
    on)  echo "$common -x NCCL_BOOTSTRAP_BIDIR_ALLGATHER=1 $BIN -b 1K -e 1K -f 4 -g 1";;
    off) echo "$common -x NCCL_BOOTSTRAP_BIDIR_ALLGATHER=0 $BIN -b 1K -e 1K -f 4 -g 1";;
  esac
}
bench_ldpath() { echo "$PLUGIN_LDPATH"; }
bench_ppn() { echo "$PPN"; }
bench_expect() { echo $(( $1 * PPN )); }
bench_sample_grep() { echo "Bootstrap timings total"; }
