#!/bin/bash
# Cluster-agnostic paired A/B bootstrap bench core.
# Ties a cluster adapter (adapters/<cluster>.sh) + a bench plugin (plugins/<plugin>.sh).
# Paired = both arms run back-to-back each iter, coin-flip order, per-pair delta cancels drift.
#
# Findings baked in:
#  - health-gate with SETTLE-SLEEP (load decays ~30-60s after teardown; sleep beats busy-retry)
#  - toxic timeout: a timed-out iter leaves D-state GPU procs -> exclude+flag node, don't reuse
#  - rotate-don't-delete logs; target-based resume; --bind-to core (configurable)
#
# Usage:
#   CLUSTER=slurm PLUGIN=rccl_bootstrap_ib N=8 TARGET=100 BIND=core \
#     OUTROOT=/path NODELIST="n1,n2,..." JOBID=<jid> bash core.sh
#   (if JOBID/NODELIST omitted, core allocates via adapter from idle topology pool)
#   Pick a plugin per fabric/site: rccl_bootstrap_ib (IB), rccl_bootstrap_tcp
#   (plain-TCP), rccl_bootstrap_local (single box). Copy one and edit its paths.
set -uo pipefail
HERE=$(cd "$(dirname "$0")"&&pwd)
: "${CLUSTER:=slurm}"; : "${PLUGIN:=rccl_bootstrap_ib}"
: "${N:?set N}"; : "${TARGET:=100}"; : "${BIND:=core}"; : "${TIMEOUT:=$((150+N*10))}"
: "${SETTLE:=20}"; : "${SPARE:=0}"; : "${OUTROOT:=$HERE/results}"; : "${FAILMAX:=5}"
: "${EXCLUDE_NODES:=}"; : "${DRY_RUN:=0}"
# Existing-allocation aliases. JOBID is the canonical harness knob; JOB_ID is
# accepted as an explicit spelling variant. Ambient scheduler variables such as
# SLURM_JOB_ID are intentionally not auto-detected, to avoid surprising reuse.
if [ -z "${JOBID:-}" ]; then
  JOBID="${JOB_ID:-}"
fi
EXTERNAL_JOB=0; [ -n "${JOBID:-}" ] && EXTERNAL_JOB=1
source "$HERE/adapters/$CLUSTER.sh"
source "$HERE/plugins/$PLUGIN.sh"
# Command printers are optional in the adapter contract: an adapter SHOULD provide
# cluster_{alloc,launch,cancel}_cmd that print the real, copy-pasteable command, but
# if it doesn't (e.g. minimal test adapters), fall back to a readable description so
# tracing/DRY_RUN still works.
type cluster_alloc_cmd  >/dev/null 2>&1 || cluster_alloc_cmd()  { echo "cluster_alloc_nodelist $1"; }
type cluster_launch_cmd >/dev/null 2>&1 || cluster_launch_cmd() { echo "cluster_launch $*"; }
type cluster_cancel_cmd >/dev/null 2>&1 || cluster_cancel_cmd() { echo "cluster_cancel $1"; }
PPN=$(bench_ppn); EXP=$(bench_expect "$N"); NRANKS=$((N*PPN)); LDP=$(bench_ldpath)
OUT="$OUTROOT/${PLUGIN}/${N}n"; mkdir -p "$OUT"
HF="$OUT/hostfile.txt"
log(){ echo "[$(date +%H:%M:%S)] $*"; }
# Side-effecting cluster operations echo the exact command they are about to run on
# a "    >>> ..." line (always, not just under DRY_RUN), so a real run is fully
# traceable. DRY_RUN=1 prints the whole plan and executes nothing (see below).

# Count complete iters across the fresh log AND every rotated .log.bak-* (rotate-don't-delete:
# resume must be additive for any post-processing that reads the baks). An iter is complete
# only when its successful "=== iter" block carries exactly EXP samples. Failed arms are logged
# as "=== failed iter" and ignored even if the benchmark printed sample-looking lines before
# exiting non-zero.
complete(){
  local -a files=(); local f; shopt -s nullglob
  # Keep only files that actually exist: the fresh ".log" is a literal (nullglob
  # doesn't drop it when missing), and during a rotation it can be absent while a
  # .bak-* exists. Passing a missing path to awk is fatal and would abort the whole
  # count, so filter first.
  for f in "$OUT/$1.log" "$OUT/$1.log.bak-"*; do [ -f "$f" ] && files+=("$f"); done
  shopt -u nullglob
  [ ${#files[@]} -eq 0 ] && { echo 0; return; }
  awk -v E="$EXP" '
    /^===/ {
      if (s && n == E) k++;
      n = 0;
      s = ($0 ~ /^=== iter/);
      next;
    }
    s && /'"$(bench_sample_grep)"'/ { n++ }
    END { if (s && n == E) k++; print k+0 }
  ' "${files[@]}" 2>/dev/null||echo 0
}
node_clean(){ for n in "$@"; do cluster_node_clean "$n" & done; wait; }
# returns 0 if node is clean: 0 D-state (toxic GPU-fence zombies), kfd<=1 (no leaked
# GPU contexts), load<LOADMAX. LOADMAX is high on purpose: a clean post-teardown node
# carries benign background load (~1.5-2) from monitoring daemons; only a catastrophic
# hang (load >>10, e.g. the 2000+ python D-state case) should fail the gate. D-state and
# kfd are the reliable contamination signals; load is a coarse meltdown backstop only.
LOADMAX=${LOADMAX:-8.0}
is_clean(){ local h; h=$(cluster_node_health "$1"); awk -v h="$h" -v L="$LOADMAX" 'BEGIN{split(h,a," ");exit !(a[1]==0&&a[2]<L&&a[3]<=1)}'; }

# --- acquire nodes: use provided JOBID/NODELIST or allocate N (+spare) clean from pool ---
acquire(){
  local we_allocated=0
  if [ "$EXTERNAL_JOB" = 1 ]; then
    [ "$(cluster_alloc_state "$JOBID")" = RUNNING ] || { log "provided JOBID=$JOBID is not RUNNING"; return 1; }
    mapfile -t pool < <(cluster_alloc_nodes "$JOBID")
  else
    mapfile -t idle < <(cluster_idle_nodes)
    local need=$((N+SPARE))   # spare nodes let acquire skip dirty entries from the pool
    [ "${#idle[@]}" -lt "$N" ] && { log "only ${#idle[@]} idle < $N needed"; return 1; }
    local take; take=$(printf '%s\n' "${idle[@]}"|head -$((need<${#idle[@]}?need:${#idle[@]}))|paste -sd,)
    echo "    >>> $(cluster_alloc_cmd "$take")"
    JOBID=$(cluster_alloc_nodelist "$take") || { log "alloc failed"; return 1; }
    we_allocated=1
    log "allocated JOBID=$JOBID"; mapfile -t pool < <(cluster_alloc_nodes "$JOBID")
  fi
  # health-scan pool, keep N clean
  CLEAN=()
  for n in "${pool[@]}"; do is_clean "$n" && CLEAN+=("$n"); [ "${#CLEAN[@]}" -ge "$N" ] && break; done
  if [ "${#CLEAN[@]}" -lt "$N" ]; then
    log "only ${#CLEAN[@]}/$N clean nodes"
    [ "$we_allocated" = 1 ] && { log "freeing leaked alloc $JOBID"; echo "    >>> $(cluster_cancel_cmd "$JOBID")"; cluster_cancel "$JOBID"; unset JOBID; }
    return 1
  fi
  NODES=("${CLEAN[@]:0:N}")
  : > "$HF"; for n in "${NODES[@]}"; do echo "$n slots=$PPN" >> "$HF"; done
  HEAD="${NODES[0]}"; echo "$JOBID" > "$OUT/.jobid"; printf '%s\n' "${NODES[@]}" > "$OUT/.nodes"
  log "nodes: ${NODES[*]}"
}

run_arm(){ local arm=$1 it=$2 tmp rc cmd
  # Resolve the bench command ONCE so the printed command is exactly what runs (some
  # plugins are non-deterministic, e.g. randomized args). Print the REAL, copy-pasteable
  # launch command (ssh ... mpirun ... / flux ...), then execute it (skip if DRY_RUN).
  cmd=$(bench_arm_cmd "$arm")
  # shellcheck disable=SC2086
  echo "    >>> [iter $it $arm] $(cluster_launch_cmd "$HEAD" "$HF" "$NRANKS" "$PPN" "$BIND" "$TIMEOUT" "$LDP" -- $cmd)"
  [ "$DRY_RUN" = 1 ] && return 0
  if ! tmp=$(mktemp "$OUT/.${arm}.${it}.XXXXXX"); then
    echo "=== failed iter $it $arm rc=125 t=$(date +%s) mktemp failed ===" >> "$OUT/$arm.log" 2>/dev/null || true
    return 125
  fi
  trap 'rm -f "$tmp"' RETURN
  # $cmd is a shell-style argv fragment (mpirun -x flags + command); word-split intentionally.
  # shellcheck disable=SC2086
  cluster_launch "$HEAD" "$HF" "$NRANKS" "$PPN" "$BIND" "$TIMEOUT" "$LDP" -- $cmd > "$tmp" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "=== iter $it $arm t=$(date +%s) ===" >> "$OUT/$arm.log"
  else
    echo "=== failed iter $it $arm rc=$rc t=$(date +%s) ===" >> "$OUT/$arm.log"
  fi
  cat "$tmp" >> "$OUT/$arm.log"
  rm -f "$tmp"
  trap - RETURN
  return "$rc"
}

# DRY RUN: print REAL, copy-pasteable commands -- the actual salloc / ssh mpirun (or
# flux) lines you could run by hand -- then exit WITHOUT executing them. To produce
# real node names it performs only READ-ONLY discovery (sinfo/squeue via the adapter);
# it never allocates, launches, cancels, or sshes into a node.
if [ "$DRY_RUN" = 1 ]; then
  log "DRY_RUN=1: printing real commands (read-only discovery only), executing nothing."
  if [ "$EXTERNAL_JOB" = 1 ]; then
    echo "# reuse external JOBID=$JOBID (verify it is RUNNING):"
    echo "    >>> squeue -h -j $JOBID -o '%t'"
    mapfile -t NODES < <(cluster_alloc_nodes "$JOBID")
    [ "${#NODES[@]}" -eq 0 ] && NODES=("<node1>")
  else
    mapfile -t idle < <(cluster_idle_nodes)
    local_need=$((N+SPARE))
    if [ "${#idle[@]}" -ge "$N" ]; then
      local_take_n=$((local_need<${#idle[@]}?local_need:${#idle[@]}))
      take=$(printf '%s\n' "${idle[@]}"|head -"$local_take_n"|paste -sd,)
      mapfile -t NODES < <(printf '%s\n' "${idle[@]}"|head -"$N")
    else
      log "DRY_RUN: only ${#idle[@]} idle (need $N) right now; showing the command shape with placeholder nodes."
      local_take_n=$local_need
      take=$(printf 'node%d,' $(seq 1 "$local_need")|sed 's/,$//')
      mapfile -t NODES < <(printf 'node%d\n' $(seq 1 "$N"))
    fi
    echo "# allocate $local_take_n node(s) (want N=$N + SPARE=$SPARE = $local_need; capped to idle), keep first $N clean:"
    echo "    >>> $(cluster_alloc_cmd "$take")"
  fi
  # build the real hostfile + head so the launch line below is exactly what would run
  : > "$HF"; for n in "${NODES[@]}"; do echo "$n slots=$PPN" >> "$HF"; done
  HEAD="${NODES[0]}"
  echo "# per-node health gate (run for each allocated node): 0 D-state, load<$LOADMAX, kfd<=1"
  read -ra A <<< "$(bench_arms)"
  echo "# one paired iteration (both arms); the loop repeats this until TARGET=$TARGET:"
  for arm in "${A[@]}"; do run_arm "$arm" 1; done
  [ "$EXTERNAL_JOB" = 1 ] || echo "    >>> # when done (self-allocated): $(cluster_cancel_cmd "${JOBID:-<jobid>}")"
  exit 0
fi

acquire || { log "acquire failed; abort"; exit 1; }
i=0
declare -A fail_streak=()
while :; do
  c1=$(complete "$(bench_arms|awk '{print $1}')"); c2=$(complete "$(bench_arms|awk '{print $2}')")
  if [ "$c1" -ge "$TARGET" ] && [ "$c2" -ge "$TARGET" ]; then log "TARGET met ($c1/$c2)"; break; fi
  if [ "$(cluster_alloc_state "$JOBID")" != RUNNING ]; then
    if [ "$EXTERNAL_JOB" = 1 ]; then
      log "provided alloc $JOBID dead; abort"
      exit 1
    fi
    log "alloc $JOBID dead; re-acquire"; unset JOBID; acquire || break; continue
  fi
  # health gate with settle-sleep (not busy-retry)
  gate_ok=1; for n in "${NODES[@]}"; do is_clean "$n" || { gate_ok=0; break; }; done
  if [ "$gate_ok" -ne 1 ]; then log "health gate: settling ${SETTLE}s"; sleep "$SETTLE"; continue; fi
  i=$((i+1))
  read -ra A <<< "$(bench_arms)"
  if (( RANDOM%2 )); then ORDER=("${A[0]}" "${A[1]}"); else ORDER=("${A[1]}" "${A[0]}"); fi
  for arm in "${ORDER[@]}"; do
    if run_arm "$arm" "$i"; then
      fail_streak[$arm]=0
    else
      fail_streak[$arm]=$(( ${fail_streak[$arm]:-0} + 1 ))
      log "arm $arm failed (${fail_streak[$arm]}/$FAILMAX); see $OUT/$arm.log"
      [ "${fail_streak[$arm]}" -ge "$FAILMAX" ] && { log "too many consecutive failures for $arm; abort"; exit 2; }
    fi
    node_clean "${NODES[@]}"
  done
  (( i%10==0 )) && log "iter $i (${A[0]}=$(complete "${A[0]}") ${A[1]}=$(complete "${A[1]}"))"
done
log "DONE ${N}n ${A[0]}=$(complete "${A[0]}") ${A[1]}=$(complete "${A[1]}")"
