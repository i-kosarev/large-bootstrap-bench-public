#!/bin/bash
# Test adapter for a single-host `flux start --test-size=K` instance.
# Sources the REAL flux.sh; overrides only what a fake single-host instance can't model:
#  - idle nodes: test-size brokers share ONE hostname; real cluster_idle_nodes does
#    sort -u and collapses them. Emit K pseudo-IDs so core sees distinct "nodes".
#  - alloc: by COUNT (no --requires=host with duplicate hostnames).
#  - health/clean: no ssh.
# Source the REAL flux adapter from this repo. core.sh copies this file into adapters/
# before sourcing it, so the sibling flux.sh sits next to us at ${BASH_SOURCE} dir.
_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_HERE/flux.sh"
cluster_idle_nodes() {                 # K brokers -> node0..node(K-1)
  local k; k=$(flux resource list -s free -no '{nnodes}' 2>/dev/null)
  k=${k:-0}; for ((i=0;i<k;i++)); do echo "node$i"; done
}
cluster_alloc_nodelist() {
  local nl=$1 n; n=$(echo "$nl"|tr ',' '\n'|grep -c .)
  flux alloc -N "$n" -t "$ALLOC_TIME" --bg 2>/dev/null
}
cluster_alloc_nodes() {                # JOBID -> same pseudo-IDs sized to the alloc
  local k; k=$(flux job info "$1" R 2>/dev/null | grep -o '"rank": "[0-9-]*"' | head -1)
  k=$(flux jobs -no '{nnodes}' "$1" 2>/dev/null); k=${k:-0}
  for ((i=0;i<k;i++)); do echo "node$i"; done
}
cluster_node_health() { echo "0 0.10 0"; }
cluster_node_clean()  { :; }
