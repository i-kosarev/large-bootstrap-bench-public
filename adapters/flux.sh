#!/bin/bash
# Flux cluster adapter. Same contract as slurm.sh.
# Verified against flux-core 0.85.0 (conda-forge) via `flux start --test-size`.
# Required env: NODE_FEATURE, EXCLUDE_NODES, ALLOC_TIME (e.g. 2h).
#
# Model notes (differ from SLURM):
#  - `flux alloc --bg` returns a JOBID that is a CHILD broker instance. You reach
#    it with `flux proxy <JOBID> flux run ...`, NOT ssh+srun. cluster_launch uses
#    the global $JOBID (set by core.sh) to proxy in.
#  - `flux run` forbids mixing per-resource (-N/-n) with per-task (--tasks-per-node)
#    options. Use `-N <nodes> -n <nranks>` only; ranks distribute round-robin.
#  - `flux run` inherits the caller's environment by default, so mpirun-style
#    `-x VAR=val` flags from the bench plugin are translated to an `env VAR=val`
#    prefix on the command (explicit > implicit).
#  - CPU bind analog of mpirun --bind-to core is `-o cpu-affinity=per-task`.
#  - GPUs: set GPUS_PER_TASK=1 (default 1) -> `--gpus-per-task=1`. Set 0 to disable
#    (e.g. the CPU-only test instance, which exposes no GPUs).
#  - Health/clean still use ssh per-host (works on any cluster); flux exec -r could
#    replace it on a pure-flux system but ssh keeps parity with the slurm adapter.
: "${NODE_FEATURE:=}"; : "${EXCLUDE_NODES:=}"; : "${ALLOC_TIME:=2h}"; : "${GPUS_PER_TASK:=1}"
: "${SSH_KH=}"                    # empty default => no UserKnownHostsFile override
SSHO="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
[ -n "$SSH_KH" ] && SSHO="$SSHO -o UserKnownHostsFile=$SSH_KH"

cluster_idle_nodes() {
  # List free nodes, optionally filtered to a topology group (NODE_FEATURE), minus EXCLUDE_NODES.
  #
  # NODE_FEATURE = the topology constraint (on SLURM it's a node feature like 'switchA|switchB'
  # that keeps every rank under one leaf switch; mixing switches hangs large-N bootstrap).
  # SLURM exposes features via `sinfo %f`; FLUX HAS NO EQUIVALENT. So on flux you supply the
  # node->group mapping yourself in a FLUX_FEATURE_MAP file: two columns "hostname<TAB>feature",
  # one line per node, e.g.
  #     node001<TAB>switchA
  #     node002<TAB>switchA
  #     node050<TAB>switchB
  # Then NODE_FEATURE is matched (regex) against column 2 to keep only those hosts.
  # If NODE_FEATURE is empty OR the map file is absent, NO topology filter is applied
  # (all free nodes are eligible) -- fine for clusters with no switch-locality constraint.
  local raw; raw=$(flux resource list -s free -no '{nodelist}' 2>/dev/null)
  [ -z "$raw" ] && return 0
  flux hostlist --expand "$raw" 2>/dev/null | tr ' ' '\n' \
    | { if [ -n "$NODE_FEATURE" ] && [ -f "${FLUX_FEATURE_MAP:-/nonexistent}" ]; then
          grep -Ff <(awk -v f="$NODE_FEATURE" '$2~f{print $1}' "$FLUX_FEATURE_MAP"); else cat; fi; } \
    | { if [ -n "$EXCLUDE_NODES" ]; then grep -vE "$(echo "$EXCLUDE_NODES"|tr ',' '|')"; else cat; fi; } \
    | sort -u
}
_alloc_argv() {
  local nl=$1 n; n=$(echo "$nl"|tr ',' '\n'|grep -c .)
  ALLOC_ARGV=(flux alloc -N "$n" --requires="host:$nl" -t "$ALLOC_TIME" --bg)
}
cluster_alloc_cmd() { _alloc_argv "$1"; echo "${ALLOC_ARGV[*]}"; }
cluster_alloc_nodelist() {
  # `flux alloc -N <n> --requires=host:<csv> -t <time> --bg` returns a JOBID (child instance).
  _alloc_argv "$1"
  "${ALLOC_ARGV[@]}" 2>/dev/null
}
cluster_alloc_state() { # map flux job status -> RUNNING|PENDING|DEAD
  # verified status strings: RUN / SCHED / DEPEND / CLEANUP / INACTIVE
  case "$(flux jobs -no '{status}' "$1" 2>/dev/null)" in
    RUN|run*) echo RUNNING;; SCHED|DEPEND|PENDING|CLEANUP|sched*) echo PENDING;; *) echo DEAD;;
  esac
}
# Print the exact, copy-pasteable job-state query (no execution).
cluster_alloc_state_cmd() { echo "flux jobs -no '{status}' $1"; }
cluster_alloc_nodes() { flux hostlist --expand "$1" 2>/dev/null | tr ' ' '\n'; }   # JOBID -> node list
cluster_time_left_sec() { flux job timeleft "$1" 2>/dev/null | awk '{printf "%d", $1+0}'; }  # seconds
cluster_cancel() { flux cancel "$1" 2>/dev/null; }
cluster_cancel_cmd() { echo "flux cancel $1"; }
# Build the flux launch argv into LAUNCH_ARGV. Single source of truth for run + print.
_launch_build() {
  local head=$1 hf=$2 nranks=$3 ppn=$4 bind=$5 tmo=$6 ldp=$7; shift 7
  [ "$1" = "--" ] && shift
  local aff=""; [ "$bind" = "core" ] && aff="-o cpu-affinity=per-task"
  local gpu=""; [ "${GPUS_PER_TASK:-1}" -gt 0 ] 2>/dev/null && gpu="--gpus-per-task=$GPUS_PER_TASK"
  local envpfx="" cmd=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "-x" ]; then envpfx="$envpfx ${2}"; shift 2
    else cmd+=("$1"); shift; fi
  done
  local nodes=$((nranks/ppn))
  # shellcheck disable=SC2206
  LAUNCH_ARGV=(timeout "$tmo" flux proxy "${JOBID:?flux: JOBID unset}"
    env LD_LIBRARY_PATH="$ldp" flux run -N "$nodes" -n "$nranks" $aff $gpu
    env $envpfx "${cmd[@]}")
}
cluster_launch() { _launch_build "$@"; "${LAUNCH_ARGV[@]}"; }
cluster_launch_cmd() { _launch_build "$@"; echo "${LAUNCH_ARGV[*]}"; }
cluster_node_health() {
  ssh $SSHO "$1" 'echo "$(ps -eo stat,comm|awk "\$1~/^D/ && \$2~/gather|python/"|wc -l) $(cut -d" " -f1 /proc/loadavg) $(ls /sys/class/kfd/kfd/proc 2>/dev/null|wc -l)"' 2>/dev/null || echo "ERR 999 999"
}
cluster_node_clean() {
  ssh $SSHO "$1" 'pkill -9 all_gather_perf 2>/dev/null; pkill -9 mpirun 2>/dev/null; pkill -9 flux 2>/dev/null' 2>/dev/null
}
# STATUS: verified on flux-core 0.85.0 via `flux start --test-size`. Confirmed:
#  - flux alloc --bg returns a usable JOBID; flux jobs -no {status} => RUN/SCHED/...
#  - flux job timeleft => integer seconds; flux hostlist <JOBID> expands node list
#  - launch path `flux proxy <JOBID> flux run -N -n` works; env inherits + explicit
#    `env VAR=val` prefix propagates; -o cpu-affinity=per-task accepted.
# Remaining site-specific: NODE_FEATURE needs a FLUX_FEATURE_MAP file (no sinfo %f on
# flux); GPU binding (--gpus-per-task) add per-site if the test instance exposes GPUs.
