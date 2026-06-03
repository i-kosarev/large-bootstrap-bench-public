#!/bin/bash
# Bench plugin: RCCL bootstrap sock-bidir (ON) vs unidir (OFF) — plain-TCP fabric example.
# Pair with the generic SLURM adapter: CLUSTER=slurm PLUGIN=rccl_bootstrap_tcp, and
# set the site knobs (PARTITION, MPI_BIN, MPI_MCA_ARGS, IFNAME) via env.
# Uses a custom RCCL build + OpenMPI + rccl-tests; all paths env-overridable.
RCCL_LIB=${RCCL_LIB:-/path/to/rccl/build}
MPI_LIB=${MPI_LIB:-/path/to/openmpi/lib}
BIN=${BIN:-/path/to/rccl-tests/all_gather_perf}
IFNAME=${IFNAME:-eth0}
PLUGIN_LDPATH="$MPI_LIB:$RCCL_LIB"
PPN=${PPN:-8}

bench_arms() { echo "on off"; }
bench_arm_cmd() {
  # NCCL_SOCKET_IFNAME pins bootstrap to the chosen NIC ($IFNAME) — without it RCCL
  # may auto-pick a different interface and the bootstrap can stall at scale. Transport
  # env belongs in the plugin, not the generic adapter.
  local arm=$1 common="-x NCCL_SOCKET_IFNAME=$IFNAME -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=BOOTSTRAP"
  case "$arm" in
    on)  echo "$common -x NCCL_BOOTSTRAP_BIDIR_ALLGATHER=1 $BIN -b 1K -e 1K -f 4 -g 1";;
    off) echo "$common -x NCCL_BOOTSTRAP_BIDIR_ALLGATHER=0 $BIN -b 1K -e 1K -f 4 -g 1";;
  esac
}
bench_ldpath() { echo "$PLUGIN_LDPATH"; }
bench_ppn() { echo "$PPN"; }
bench_expect() { echo $(( $1 * PPN )); }
bench_sample_grep() { echo "Bootstrap timings total"; }
