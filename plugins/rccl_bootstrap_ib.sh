#!/bin/bash
# Bench plugin: RCCL bootstrap sock-bidir (ON) vs unidir (OFF) — IB-fabric example.
# Example site profile for an InfiniBand cluster (TCP bootstrap over a management NIC).
# All paths are env-overridable; set them to your build/install locations.
RCCL_LIB=${RCCL_LIB:-/path/to/rccl/build}
ROCM=${ROCM:-/opt/rocm}
BIN=${BIN:-/path/to/rccl-tests/all_gather_perf}
IFNAME=${IFNAME:-eth0}
PLUGIN_LDPATH="$RCCL_LIB:$ROCM/lib:/opt/rocm/lib"
PPN=${PPN:-8}

# two arms; coin-flipped per iter by core
bench_arms() { echo "on off"; }
# per-arm mpirun -x env + the test binary/args (printed as one string for cluster_launch)
bench_arm_cmd() {
  local arm=$1 common="-x NCCL_SOCKET_IFNAME=$IFNAME -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=BOOTSTRAP"
  case "$arm" in
    on)  echo "$common -x NCCL_BOOTSTRAP_BIDIR_ALLGATHER=1 $BIN -b 1K -e 1K -f 4 -g 1";;
    off) echo "$common -x NCCL_BOOTSTRAP_BIDIR_ALLGATHER=0 $BIN -b 1K -e 1K -f 4 -g 1";;
  esac
}
bench_ldpath() { echo "$PLUGIN_LDPATH"; }
bench_ppn() { echo "$PPN"; }
# how many timing samples a valid iteration must contain (= ranks)
bench_expect() { echo $(( $1 * PPN )); }   # $1 = node count
# grep pattern marking one timing sample
bench_sample_grep() { echo "Bootstrap timings total"; }
