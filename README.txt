Cluster-agnostic paired A/B bootstrap bench
===========================================
Measures a feature ON vs OFF (e.g. RCCL sock-bidir bootstrap) with statistically
stable methodology, portable across SLURM and Flux.


=== 1. RUN ON SLURM ===========================================================
  CLUSTER=slurm PLUGIN=<plugin> N=<nodes> TARGET=100 BIND=core SPARE=5 \
    OUTROOT=$PWD/results bash core.sh
  # N=nodes, TARGET=paired iters, BIND=core => mpirun --bind-to core.
  # SPARE=5 over-allocates a few nodes so acquire can skip dirty ones (recommended
  # on shared clusters; SPARE=0 grabs exactly N and fails if any node is unclean).
  # Results are written under $OUTROOT/<plugin>/<N>n/{on,off}.log; core.sh's stdout
  # is just progress. Run it backgrounded if you like: append '&' (or use tmux/screen).
  # <plugin> = a plugins/<plugin>.sh bench definition (see LAYOUT), e.g.
  #   rccl_bootstrap_ib (IB fabric) or rccl_bootstrap_tcp (plain-TCP fabric).
  # Resume: rerun the identical command (done-iter count is read from the logs).
  # Use an existing allocation instead of letting core.sh allocate: add JOBID=<jid>.
  # JOB_ID and SLURM_JOB_ID are accepted aliases; if a provided job is not RUNNING,
  # core.sh aborts instead of falling back to a fresh allocation.
  #
  # The command above is portable; per-site settings are all env knobs. By default,
  # scheduler routing flags are omitted and OpenMPI chooses its default launcher/fabric.
  # Set the ones your cluster needs:
  #   PARTITION ACCOUNT QOS   scheduler routing (empty => omit the flag).
  #   IFNAME                  TCP iface for MPI oob/btl (default eth0; set per site).
  #   MPI_BIN                 dir holding mpirun (default: take from PATH).
  #   MPI_MCA_ARGS            mpirun MCA/launcher flags (default empty). Override per
  #                           fabric; a plain-TCP cluster sets e.g.
  #                           MPI_MCA_ARGS="-mca plm rsh -mca btl tcp,self -mca pml ob1 \
  #                                         -mca btl_tcp_if_include $IFNAME".
  #   SSH_KH                  ssh UserKnownHostsFile (default: omit the flag).
  #   SPARE                   extra nodes to allocate before health filtering (default 0);
  #                           set >0 on noisy pools to skip dirty nodes without re-alloc.
  #   FAILMAX                 abort after this many consecutive failed arms (default 5).
  #   SLURM_NODE_FORMAT       sinfo node token for allocation names: %n default, %N for
  #                           clusters whose salloc --nodelist requires FQDNs.
  #   NODE_FEATURE            SLURM feature(s) keeping all ranks under one leaf switch,
  #                           e.g. NODE_FEATURE='switchA|switchB' (default: no constraint).
  #   EXCLUDE_NODES           csv of nodes to skip, e.g. 'node-001,node-002'.
  # Example, fully specified for an IB cluster (set your own partition/account/nodes):
  #   CLUSTER=slurm PLUGIN=rccl_bootstrap_ib N=<nodes> TARGET=100 BIND=core SPARE=5 \
  #     PARTITION=<partition> ACCOUNT=<account> QOS=<qos> \
  #     MPI_MCA_ARGS="-mca plm rsh -mca btl_tcp_if_include <nic> -mca btl ^vader,openib,ofi" \
  #     NODE_FEATURE='<feature>' EXCLUDE_NODES='<csv>' \
  #     OUTROOT=$PWD/results bash core.sh
  # Plain-TCP fabric: use PLUGIN=rccl_bootstrap_tcp and the plain-TCP MPI_MCA_ARGS
  #   form (see MPI_MCA_ARGS above), with IFNAME=<nic> ACCOUNT= QOS= as your site needs.
  # Local single-box / small SLURM validation (IB disabled, paths live in the plugin):
  #   CLUSTER=slurm PLUGIN=rccl_bootstrap_local N=<nodes> TARGET=30 BIND=core SPARE=5 \
  #     PARTITION=<partition> ACCOUNT= QOS= IFNAME=<nic> SSH_KH= SLURM_NODE_FORMAT=%N \
  #     MPI_MCA_ARGS="-mca plm rsh -mca plm_rsh_agent ssh -mca oob_tcp_if_include <nic> \
  #                   -mca btl tcp,self -mca pml ob1 -mca btl_tcp_if_include <nic>" \
  #     OUTROOT=$PWD/results bash core.sh
  #
  # Multi-scale sweep = just loop N (core.sh allocates/resumes per scale):
  #   for N in 1 2 4 8 16; do
  #     CLUSTER=slurm PLUGIN=<plugin> N=$N TARGET=100 BIND=core SPARE=5 \
  #       OUTROOT=$PWD/results bash core.sh
  #   done


=== 2. RUN ON FLUX ============================================================
  CLUSTER=flux PLUGIN=<plugin> N=<nodes> TARGET=100 BIND=core SPARE=5 \
    ALLOC_TIME=2h GPUS_PER_TASK=1 \
    OUTROOT=$PWD/results bash core.sh
  # Results are written under $OUTROOT/<plugin>/<N>n/{on,off}.log; core.sh's stdout
  # is just progress. Append '&' (or use tmux/screen) to background it.
  # Same env knobs as SLURM (PARTITION/IFNAME/MPI_*/NODE_FEATURE/EXCLUDE_NODES/SPARE;
  # all optional), plus:
  #   ALLOC_TIME      flux alloc wall time (e.g. 2h).
  #   GPUS_PER_TASK   --gpus-per-task (default 1; set 0 for CPU-only).
  #   FLUX_FEATURE_MAP  required ONLY if NODE_FEATURE is set: flux has no `sinfo %f`,
  #                     so give a "hostname<TAB>feature" file (one line per node):
  #                         node001	switchA
  #                         node050	switchB
  #                     NODE_FEATURE is regex-matched against column 2. No map (or no
  #                     NODE_FEATURE) => no topology filter, all free nodes eligible.
  # Verify the flux adapter with no real cluster:
  #   mamba create -y -n fluxtest -c conda-forge flux-core   # one-time
  #   bash tests/run_flux_test.sh                            # expect "FLUX E2E: PASS"


=== 3. FEATURES FOR A STABLE BOOTSTRAP MEASUREMENT ============================
  These are the knobs/mechanisms that make ON-vs-OFF separable from cluster noise:

  CPU binding (BIND=core)   Pins ranks to cores (mpirun --bind-to core / flux
                            -o cpu-affinity=per-task). Removes scheduler-migration
                            jitter; in our runs it cut max-rank CV ~4x (47.9%->10.6%).
                            Single biggest stability lever. ON by default.

  Paired A/B + coin-flip    Both arms run back-to-back each iteration, order coin-
                            flipped. Per-pair delta cancels common-mode cluster drift
                            (thermals, neighbor noise) that would swamp the effect.

  Single-leaf topology      NODE_FEATURE keeps every rank under one leaf/L1 switch.
                            Mixing switches routes via the top-level switch and can
                            hang or destabilize large-N bootstrap. (SLURM: node feature;
                            Flux: FLUX_FEATURE_MAP, see section 2.)

  Health gate + settle      Before each iter, nodes must be clean: 0 D-state
                            gather/python procs, load<LOADMAX, kfd<=1. If dirty, SLEEP
                            (SETTLE=20s; load decays 30-60s post-teardown) instead of
                            busy-retrying. Keeps a contaminated node from poisoning data.

  Failed-arm detection      An arm that exits non-zero is logged as "=== failed iter" and
                            does not count toward TARGET, even if it printed sample-looking
                            lines before failing. FAILMAX aborts repeated failures early so
                            a missing library or broken mpirun does not produce fake data.

  Toxic-timeout handling    A timed-out RCCL iter can leave D-state GPU procs (dma_fence)
                            that SIGKILL can't reap. The gate then excludes that node and
                            re-acquire picks a fresh one. (Such nodes need admin reboot.)

  Exclusive nodes           Allocate whole nodes (no co-tenants) so neighbor jobs don't
                            inject tail latency into the slowest rank.

  Enough paired iters       Effect resolves on min-rank by ~30-80 pairs; max-rank tail
                            noise needs far more (see "metric" below). TARGET=100 default.

  Metric choice             min-rank (fastest rank) is a clean algorithmic-cost view;
                            max-rank (slowest rank) is bootstrap completion but is often
                            dominated by straggler tail. Report both when post-processing.


LAYOUT
  core.sh                 agnostic engine: paired A/B, coin-flip, health-gate,
                          toxic-timeout handling, rotate-don't-delete, resume.
  adapters/slurm.sh       SLURM adapter. Launches via mpirun --host (not --hostfile):
                          on a SLURM-aware OpenMPI build --hostfile triggers the SLURM
                          RAS module and aborts (ras_base_allocate). Interconnect via
                          IFNAME (default eth0; export IFNAME=<dev> per site).
  adapters/flux.sh        Flux adapter (verified on flux-core 0.85.0 via
                          `flux start --test-size`; see tests/run_flux_test.sh).
  plugins/rccl_bootstrap_<profile>.sh  RCCL sock-bidir ON/OFF arms, binary, metric.
                          One plugin per fabric/site (paths, NIC, GPU arch differ);
                          copy one and edit its env-overridable paths:
                            rccl_bootstrap_ib     InfiniBand fabric example
                            rccl_bootstrap_tcp    plain-TCP fabric example
                            rccl_bootstrap_local  single box / small SLURM (IB disabled)
  tests/run_flux_test.sh  E2E test: core.sh over the real flux.sh adapter inside a
                          local flux instance (no GPUs/RCCL). Uses tests/flux_local.sh
                          (single-host overrides) + tests/echo_plugin.sh.
  tests/run_failure_test.sh  E2E regression for failed arms that print sample-looking
                             lines before exiting non-zero.

CONTRACTS (to port to a new cluster or feature)
  cluster adapter must define: cluster_idle_nodes, cluster_alloc_nodelist,
    cluster_alloc_state, cluster_alloc_nodes, cluster_time_left_sec, cluster_cancel,
    cluster_launch, cluster_node_health, cluster_node_clean.
  bench plugin must define: bench_arms, bench_arm_cmd, bench_ldpath, bench_ppn,
    bench_expect, bench_sample_grep.
