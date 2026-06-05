#!/bin/bash
# SLURM cluster adapter. Implements the cluster-agnostic contract used by core.sh.
# Every cluster-specific operation lives here; core.sh calls only these functions.
#
# Site config via env. Empty scheduler-routing knobs are omitted so the cluster's
# Slurm defaults apply.
#   PARTITION      partition name; empty => omit -p             (default empty)
#   ACCOUNT        --account value; empty => omit               (default empty)
#   QOS            --qos value; empty => omit                   (default empty)
#   NODE_FEATURE   topology constraint regex (e.g. 'switchA|switchB')
#   EXCLUDE_NODES  csv of nodes to skip
#   ALLOC_TIME     salloc walltime                             (default 02:00:00)
#   SSH_KH         UserKnownHostsFile; set SSH_KH= to OMIT it  (default unset->omit)
#   IFNAME         TCP interface for MPI oob/btl               (default eth0)
#   MPI_BIN        dir holding mpirun; empty => take from PATH (default empty)
#   MPI_MCA_ARGS   mpirun MCA/launcher flags; empty => OpenMPI defaults
#   SLURM_NODE_FORMAT  sinfo node-name token: %n (NodeName) or %N (NodeHostName/FQDN)
: "${PARTITION:=}"
ACCOUNT="${ACCOUNT-}"             # `-` not `:=` so an explicit empty value survives
QOS="${QOS-}"
: "${NODE_FEATURE:=}"; : "${EXCLUDE_NODES:=}"; : "${ALLOC_TIME:=02:00:00}"
: "${SSH_KH=}"                    # empty default => no UserKnownHostsFile override
: "${IFNAME:=eth0}"
: "${MPI_BIN:=}"
: "${SLURM_NODE_FORMAT:=%n}"
# OpenMPI defaults are used unless MPI_MCA_ARGS is set. Plain-TCP clusters often need:
#   MPI_MCA_ARGS="-mca plm rsh -mca plm_rsh_agent ssh -mca oob_tcp_if_include $IFNAME \
#                 -mca btl tcp,self -mca pml ob1 -mca btl_tcp_if_include $IFNAME"
: "${MPI_MCA_ARGS:=}"
SSHO="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
[ -n "$SSH_KH" ] && SSHO="$SSHO -o UserKnownHostsFile=$SSH_KH"

# List idle node names meeting topology feature + exclusions, one per line.
# Filter on the STATE column (not `sinfo -t idle`) so 'plnd' (planned for other
# users' queued jobs) nodes -- which --immediate cannot grab -- are excluded.
cluster_idle_nodes() {
  local partflag=()
  [ -n "$PARTITION" ] && partflag=(-p "$PARTITION")
  sinfo "${partflag[@]}" -h -N -o "%t ${SLURM_NODE_FORMAT} %f" \
    | awk '$1=="idle"{$1="";sub(/^ /,"");print}' \
    | { if [ -n "$NODE_FEATURE" ]; then grep -E "$NODE_FEATURE"; else cat; fi; } \
    | awk '{print $1}' \
    | { if [ -n "$EXCLUDE_NODES" ]; then grep -vE "$(echo "$EXCLUDE_NODES"|tr ',' '|')"; else cat; fi; } \
    | sort -u
}
# Build the salloc argv for a nodelist into ALLOC_ARGV (single source of truth so the
# executed command and the printed/dry-run command are byte-identical).
_alloc_argv() {
  local nl=$1 n; n=$(echo "$nl"|tr ',' '\n'|grep -c .)
  local flags=()
  [ -n "$PARTITION" ] && flags+=(-p "$PARTITION")
  [ -n "$ACCOUNT" ] && flags+=(--account="$ACCOUNT")
  [ -n "$QOS" ] && flags+=(--qos="$QOS")
  ALLOC_ARGV=(salloc --no-shell --exclusive -N "$n" --nodelist="$nl" "${flags[@]}" --time="$ALLOC_TIME" --immediate=60)
}
# Print the exact, copy-pasteable allocation command for a nodelist (no execution).
cluster_alloc_cmd() { _alloc_argv "$1"; echo "${ALLOC_ARGV[*]}"; }
# Allocate exactly the given comma-sep nodelist NOW (immediate) or fail. Prints JOBID.
cluster_alloc_nodelist() {
  _alloc_argv "$1"
  local log; log=$(mktemp)
  trap 'rm -f "$log"' RETURN          # don't leak the salloc capture file under /tmp
  "${ALLOC_ARGV[@]}" > "$log" 2>&1 &
  local i jid=""
  for i in $(seq 1 30); do
    jid=$(grep -oE 'Granted job allocation [0-9]+' "$log" 2>/dev/null|awk '{print $4}'|tail -1)
    [ -n "$jid" ] && break; sleep 2
  done
  [ -z "$jid" ] && { cat "$log" >&2; return 1; }
  echo "$jid"
}
cluster_alloc_state() { # RUNNING|PENDING|DEAD
  case "$(squeue -h -j "$1" -o '%t' 2>/dev/null)" in
    R) echo RUNNING;; PD|CF) echo PENDING;; *) echo DEAD;;
  esac
}
# Print the exact, copy-pasteable job-state query (no execution).
cluster_alloc_state_cmd() { echo "squeue -h -j $1 -o '%t'"; }
cluster_alloc_nodes() { scontrol show hostnames "$(squeue -h -j "$1" -o '%N' 2>/dev/null)" 2>/dev/null; }
cluster_time_left_sec() {
  local L; L=$(squeue -h -j "$1" -o '%L' 2>/dev/null); [ -z "$L" ] && { echo -1; return; }
  # %L is [DD-]HH:MM:SS or MM:SS
  awk -v t="$L" 'BEGIN{n=split(t,a,/[-:]/); s=0; if(n==4)s=a[1]*86400+a[2]*3600+a[3]*60+a[4]; else if(n==3)s=a[1]*3600+a[2]*60+a[3]; else if(n==2)s=a[1]*60+a[2]; print s}'
}
cluster_cancel() { scancel "$1" 2>/dev/null; }
cluster_cancel_cmd() { echo "scancel $1"; }
# Launch a command across the alloc via direct-SSH mpirun (rsh; pam_slurm_adopt gives GPU).
# args: HEAD HOSTFILE NRANKS PPN BIND(core|none) TIMEOUT LDPATH -- <env -x ...> <cmd...>
#
# Uses --host "n:ppn,..." (derived from the hostfile) rather than --hostfile. On a
# SLURM-aware OpenMPI build, --hostfile makes the rsh launcher fall through to the SLURM
# RAS module, which aborts with "An internal error has occurred in ORTE ...
# base/ras_base_allocate.c". --host pins the resource list explicitly and avoids that path
# (verified by isolating this single flag: --hostfile -> ras_base_allocate, --host -> clean
# 16/16 ranks; -mca ras ^slurm and stripping SLURM_* env did NOT rescue --hostfile).
# MCA/transport flags come from MPI_MCA_ARGS; mpirun is taken from MPI_BIN if set.
# Build the remote shell command (the string passed to ssh) into LAUNCH_REMOTE and the
# ssh head into LAUNCH_HEAD. Single source of truth for both execution and printing.
_launch_build() {
  local head=$1 hf=$2 nranks=$3 ppn=$4 bind=$5 tmo=$6 ldp=$7; shift 7
  [ "$1" = "--" ] && shift
  local bindflag=""; [ "$bind" = "core" ] && bindflag="--bind-to core"
  local hostlist; hostlist=$(awk -v p="$ppn" 'NF{printf "%s%s:%s",sep,$1,p; sep=","}' "$hf")
  local mpirun_bin="mpirun" envpfx="export LD_LIBRARY_PATH=$ldp"
  [ -n "$MPI_BIN" ] && { mpirun_bin="$MPI_BIN/mpirun"; envpfx="export PATH=$MPI_BIN:\$PATH; $envpfx"; }
  LAUNCH_HEAD=$head
  LAUNCH_REMOTE="$envpfx; timeout $tmo $mpirun_bin --host $hostlist -np $nranks --map-by ppr:${ppn}:node $bindflag $MPI_MCA_ARGS -x LD_LIBRARY_PATH $*"
}
cluster_launch() { _launch_build "$@"; ssh $SSHO "$LAUNCH_HEAD" "$LAUNCH_REMOTE"; }
# Print the exact, copy-pasteable launch command (no execution).
cluster_launch_cmd() { _launch_build "$@"; echo "ssh $SSHO $LAUNCH_HEAD \"$LAUNCH_REMOTE\""; }
# Health of one node: prints "DSTATE LOAD KFD". core.sh decides clean/dirty.
cluster_node_health() {
  ssh $SSHO "$1" 'echo "$(ps -eo stat,comm|awk "\$1~/^D/ && \$2~/gather|python/"|wc -l) $(cut -d" " -f1 /proc/loadavg) $(ls /sys/class/kfd/kfd/proc 2>/dev/null|wc -l)"' 2>/dev/null || echo "ERR 999 999"
}
# Kill leftover ranks on a node (best-effort; D-state survivors reported by health).
cluster_node_clean() {
  ssh $SSHO "$1" 'pkill -9 all_gather_perf 2>/dev/null; pkill -9 mpirun 2>/dev/null; pkill -9 orted 2>/dev/null' 2>/dev/null
}
