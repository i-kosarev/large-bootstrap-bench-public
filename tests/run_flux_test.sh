#!/bin/bash
# Self-contained flux adapter E2E test. Requires flux-core (conda env 'fluxtest':
#   mamba create -y -n fluxtest -c conda-forge flux-core).
# Validates core.sh drives the REAL adapters/flux.sh end-to-end inside a local
# `flux start --test-size` instance (no GPUs/RCCL needed).
set -uo pipefail
HERE=$(cd "$(dirname "$0")"&&pwd); ROOT=$(cd "$HERE/.."&&pwd)
# conda is optional: if flux is already on PATH, skip activation. Override the conda
# profile via CONDA_SH and the env name via FLUX_CONDA_ENV.
: "${FLUX_CONDA_ENV:=fluxtest}"
if ! command -v flux >/dev/null 2>&1; then
  # Only resolve the conda profile path when we actually need it. ${HOME:-} avoids
  # an unbound-variable abort under `set -u` when HOME is unset and flux is on PATH.
  : "${CONDA_SH:=${HOME:-}/miniforge3/etc/profile.d/conda.sh}"
  [ -f "$CONDA_SH" ] && { source "$CONDA_SH"; conda activate "$FLUX_CONDA_ENV"; }
fi
command -v flux >/dev/null 2>&1 || { echo "flux not found (set CONDA_SH / FLUX_CONDA_ENV or put flux on PATH)"; exit 1; }
# stage test-only adapter+plugin into the dirs core.sh searches, then remove after
cp "$HERE/flux_local.sh" "$ROOT/adapters/"; cp "$HERE/echo_plugin.sh" "$ROOT/plugins/"
trap 'rm -f "$ROOT/adapters/flux_local.sh" "$ROOT/plugins/echo_plugin.sh"' EXIT
rm -rf /tmp/fluxbench_out
flux start --test-size=4 bash -c "
  cd '$ROOT'
  CLUSTER=flux_local PLUGIN=echo_plugin N=2 TARGET=5 BIND=core ALLOC_TIME=10m \
    GPUS_PER_TASK=0 OUTROOT=/tmp/fluxbench_out bash core.sh
"
echo '--- assertions ---'
iters=$(grep -c '=== iter' /tmp/fluxbench_out/echo_plugin/2n/on.log)
samples=$(grep -c 'Bootstrap timings total' /tmp/fluxbench_out/echo_plugin/2n/on.log)
echo "on iters=$iters (expect >=5), samples=$samples (expect >=20 = 5*4ranks)"
[ "$iters" -ge 5 ] && [ "$samples" -ge 20 ] && echo "FLUX E2E: PASS" || { echo "FLUX E2E: FAIL"; exit 1; }
