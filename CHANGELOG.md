# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Changes made in response to an audit of the repository
(September 2026). **None of this has been run on a Kubernetes cluster yet**:
it is covered by new offline tests, shellcheck and manifest validation (see
"How this was checked" below), and the KinD job in CI has to run before it
counts as proven on a real cluster.

### Fixed

- **Drain and resume no longer target `NodeName=ALL`.** The script drained and
  resumed every node, so a node a GPU health check had drained went back into
  service with its reason erased. It now drains only nodes that were in
  service, with a reason unique to the run, resumes only those, refuses to run
  on a degraded cluster without `--allow-degraded`, and re-applies an earlier
  drain reason that replacing a slurmd pod overwrote (the slurmd preStop hook
  sets every replaced node DOWN with its own reason).
- **The drain wait can fail.** On timeout it used to print "no running jobs"
  and go on to delete slurmd pods under live jobs. It now stops with nothing
  changed. A failed `squeue` counts as "unknown", not zero. Completing and
  suspended jobs are waited for too.
- **`--rollback` (`make rollback`) runs the same routine as the automatic
  rollback**: drain, restore, cycle slurmd, measure the key in every pod,
  resume, and only then retire the backup. It used to restart the built-in
  workloads only (never slurmd), never resume a node, and exit 0 unchecked.
- **The live auth Secret is never deleted before its replacement exists.** The
  replacement is created as `<name>-next` and read back first, the backup is
  verified, the live Secret is deleted with `--cascade=orphan` (so the
  operator's token Secrets, owned by the JWT key Secret, are not
  garbage-collected), recreated from a full manifest with retries, and an
  exit trap recreates it if the run is interrupted in between. Labels,
  annotations (previously dropped), type and `immutable` are carried over.
- **Key material no longer appears on a command line.** Manifests are built by
  `scripts/lib/authkey.py` and passed to `kubectl create -f -` on stdin;
  previously the base64 key was in `kubectl patch -p` argv three times a run.
- **Every slurmd pod is measured.** A pod that could not be exec'd was
  silently skipped, and one schedulable node passed the whole check. Now the
  pod count must match, every pod must hold the key, slurmctld's key is hashed
  too (and its `jwt.key` with `--jwt`), and every drained node must come back.
- **Preflight fails closed.** A failed NodeSet query used to pass as
  "converged"; an unreadable or unexpected `AuthType` was a warning. Both now
  stop the run, and NodeSets must have desired = replicas = updated = ready.
- **`--rollback` restores only what the last rotation changed.** It used to
  restore any `jwt.key` backup it found, reverting to a key from an older
  rotation. Backups are now immutable, labelled, and record the run and the
  keys it changed.
- **`make slurm` no longer counts `idle*` as registered.** The bring-up gate
  and the rotation script share one anchored definition of "schedulable"
  (`scripts/lib/nodes.sh`, `scripts/wait-node-registered.sh`).
- **CI's rotation step can fail in the direction that matters.** It passed on
  any non-zero exit, including a preflight refusal or a syntax error. It now
  requires exit 3, the documented failure message, and each Secret's key
  hash, `immutable` flag, labels and annotations to match what they were
  before (`scripts/ci/assert-rotation.sh`).
- `--help` prints usage (it printed part of a comment); `-n` or `--timeout`
  without a value is a usage error instead of "unbound variable".
- `make CLUSTER=name up` creates a cluster with that name.

Found by a second review of the changes above, and fixed before
release:

- **A node someone else drains during the run is never resumed.** Three
  paths could still put it back into service with its reason erased: the exit
  trap, on any stop before the pod replacement (drain-wait timeout, Ctrl-C,
  a failed backup), resumed every node it had drained without reading its
  reason; the resume loop judged a node by its *current* reason, which the
  slurmd preStop hook rewrites on every pod replacement; and it accepted any
  `slurm-operator: ` reason, including the operator's own drain of a cordoned
  Kubernetes node. Now the trap resumes only nodes still carrying the run's
  drain tag; node reasons are re-read just before every pod replacement; a
  node with anyone else's reason is handed over (never resumed by the run
  again, its drain put back right after each replacement, not only at the
  end); only the exact preStop reason counts as the replacement's; and a run
  that handed a node over exits 4 naming it instead of 0 or 3, since that
  node was not verified.
- **Busy nodes count as in service.** The state checks matched only bare
  `idle`/`mix`/`alloc`, so a node in `alloc+` (jobs completing), `mix-` or
  `plnd` (planned by the backfill scheduler) was treated as out of service:
  left undrained while its slurmd pod was replaced anyway, and after a resume
  never counted as schedulable. With `--allow-degraded`, a node left alone
  must now be one Slurm starts no job on (drained, down, failed, or not
  responding); anything else (reserved, maintenance, powered down, ...) is
  refused. A left-alone node with no drain reason, which the pod replacement
  sets DOWN, is resumed once instead of being left DOWN after exit 0.
- **The automatic rollback cannot be aborted by a diagnostic.** It runs under
  `set -e`, and one failed `kubectl get pods -o wide` ended the script with
  exit 1 ("the key in use is the one you started with") while the new key was
  live and slurmd held the old one. The listing is guarded, and the exit trap
  now measures the live key before letting exit 1 stand; if it changed, the
  exit is 4.
- **NodeSet convergence uses `status.desired`.** It compared against
  `spec.replicas`, which a DaemonSet-mode NodeSet ignores (the CRD defaults it
  to 1), so every healthy DaemonSet-mode cluster with more than one node was
  refused. It also treats a spec change the operator has not observed yet
  (`observedGeneration` behind `generation`) as not converged.
- **The documented Role grants `list` and `watch` on Secrets**, which
  `kubectl delete --wait` needs; the script's delete wait is now bounded by
  `--timeout` (kubectl's own default is a week).

### Added

- Distinct exit codes: 0 verified, 1 refused/aborted with the original key in
  place, 2 usage, 3 did not take and rolled back (verified), 4 needs a human.
- `--cleanup` deletes the backup and staging Secrets, refusing while a live
  auth Secret is missing.
- `--rollback` doubles as the repair path after an interrupted run: it
  rebuilds a missing live Secret from the backup's recorded metadata and takes
  back nodes a rotation left down (its own drain, the preStop reason, not
  responding), leaving other drains alone.
- `docs/rbac-rotate-auth-key.yaml`: the namespaced Role the script needs,
  derived from its kubectl calls (validated by kubeconform, not tested against
  a restricted account).
- `tests/run.sh` (`make test`): the real script against a fake kubectl that
  models immutable Secrets, owner-reference garbage collection, the slurmd
  preStop hook, the stale-key failure and Slurm's drain/resume rules; covers
  every failure path above, plus an interrupt between delete and recreate, and
  checks that the CI assertion fails on the wrong failure.
- Pinned versions in `make up` and CI: Slinky charts 1.2.0, node image
  `kindest/node:v1.32.2@sha256:f2263459…` (kind v0.27.0), cert-manager
  v1.20.4, helm v3.19.0, kubectl v1.32.2. Empty values install the latest.
- CI: offline-test, lint (shellcheck, `bash -n`, YAML parse) and manifest
  validation jobs (`helm template` of the pinned chart with
  `values/slurm.yaml`, checked by kubeconform against the Kubernetes schemas
  and the pinned Slinky CRDs); a manual-rollback step and a `--jwt` step in the
  KinD job; `helm list -A` and pod placement recorded every run; a diagnostics
  artifact on failure; a weekly drift job against the latest releases; actions
  pinned by commit SHA; `permissions: contents: read`.
- `docs/upstream-issue-draft.md`: a ready-to-file issue for
  SlinkyProject/slurm-operator (not filed).

### Changed (documentation corrected)

- The README said `auth/slurm` "has no key versioning and no grace period" and
  that "every tutorial" was wrong. Slurm has supported multi-key rotation with
  `slurm.jwks` since 24.05; the actual gap is that Slinky v1.2 can only ship
  `slurm.key`. Reworded in the README and the script header; the diagram now
  calls the kubelet cache the likely, not proven, cause.
- "What CI caught — Run 1" blamed an unbounded registration wait and a
  2 vCPU / 7 GB runner. The Actions record shows registration finished in
  71 s and the hang was the unbounded `srun` after the rotation; public-repo
  runners have 4 vCPU / 16 GB. The README now lists every run with links and
  step times, and `kind/cluster-ci.yaml` states why its single worker is kept.
- The stale-key analysis said "Not immutability itself". The kubelet source
  points at the immutable *cached original*; the README now gives that as a
  hypothesis with the experiments that would test it.
- The proposed fix (versioned Secret names, "a chart-level change") is blocked
  by the operator's webhook; the README now says what is possible today and
  what needs upstream work.
- The GitOps wording no longer promises Argo CD "in the next commit", and
  explains why the chart's random key generation would keep Argo CD
  permanently out of sync.
- Removed a reference to a `docs/autoscaling.md` that does not exist; the
  Layout and Requirements sections list everything the scripts need
  (Requirements now also names what `make lint` and the manifest validation
  need: shellcheck, kubeconform, PyYAML).
- Corrected in the second review:
  - `docs/upstream-issue-draft.md` said, under "measured", that the July
    rotation carried the Secret's annotations over. The script of the time
    created a mutable Secret, patched in the key, labels and `immutable`, and
    never copied annotations; the draft now says so. Its "minimal
    reproduction (about 10 minutes)" had never been run (it pins a
    cert-manager release published in September 2026); it is now labelled
    untested, without a duration, and the draft says to run it, not re-run it.
  - "The three runs since the propagation check was added" were four (369,
    404, 410 and 419 s), in `kind/cluster-ci.yaml` and the draft. The README's
    CI table stated "refused and rolled back" for them as observed; the API
    gives only step results and times, and at those commits the step passed on
    any non-zero exit, so the table now says that and nothing more.
  - "Leaves a working cluster on every exit path" is now "tries to ..., and
    says when it could not" (exit 4 exists for exactly that).
  - The README said CI keeps the rollback's pod placement "in the diagnostics
    artifact"; that artifact is only uploaded when a step fails. It is in the
    step log on every run.
  - "Honest scope" said pinning and the new CI steps are covered by the
    offline tests; only the pinned chart is (rendered and validated by
    `validate-manifests.sh`).
  - The `make status` sample showed `scontrol show node` output the target
    never produces; `make versions` claimed to record the node image, which it
    does not.
  - The Role's advice to check it with `make rotate-dry` could not work (a dry
    run deletes, creates and execs nothing); it now says to run a real rotate
    and rollback on a disposable cluster.

### How this was checked

Run on macOS on 2026-09-26 (bash 3.2.57, BSD awk, Python 3.12.13):

- `tests/run.sh`: 28 of 28 scenarios pass (62-65 s wall clock over two full
  runs). Each audited defect was also re-introduced into a copy of the
  script, one at a time, to confirm a test fails; the final set of 14 such
  mutations was caught 14/14.
- shellcheck 0.11.0 (`uvx --from shellcheck-py`) on all 7 shell scripts: no
  findings at the default severity. `bash -n` on each: clean.
- Every YAML file (5) parsed with PyYAML 6.0.3.
- `scripts/ci/validate-manifests.sh` against the published chart 1.2.0 with
  helm v3.19.0 and kubeconform v0.8.0: 6 of 6 objects valid (the chart's 5
  plus the RBAC Role); a deliberately unknown NodeSet field was rejected.
- ruff 0.16.9 (`--select F,B,W,E9`) and `py_compile` on the Python helpers:
  clean.
- actionlint 1.7.7 (with shellcheck on the `run:` blocks) on the workflow:
  clean.

After the second review's fixes, re-checked on the same machine on
2026-09-26 (bash 3.2.57, BSD awk 20200816, Python 3.12.13):

- `tests/run.sh`: 39 of 39 scenarios pass (92 s and 98 s wall clock over two
  full runs). Each of 15 mutations re-introducing a reviewed defect into a
  scratch copy (for example, the trap resuming without reading the reason,
  no re-read before the pod replacement, the exact-name state regexes,
  `spec.replicas` as the NodeSet target, the Role without list/watch) was
  run against the tests written for it: 15/15 caught.
- shellcheck 0.11.0 on the same 7 shell scripts: no findings. `bash -n` on
  each: clean.
- The same 5 YAML files parsed with PyYAML 6.0.3.
- `scripts/ci/validate-manifests.sh` against the v1.2.0 chart *source*
  (`CHART_SOURCE` pointing at slurm-operator's `helm/` at that tag, not the
  published OCI chart), helm v3.19.0 and a local kubeconform build (it
  reports its version as "development"): 6 of 6 objects valid, including the
  changed Role.
- ruff 0.16.9 (`--select F,B,W,E9`) and `py_compile` on the Python helpers:
  clean.

Not run: the KinD job, or anything else needing a cluster (none was
available). bash 5 and mawk, which CI's Ubuntu runner uses, were not
available locally either; CI will be the first run on them.

## [0.1.0] - 2026-07-31

First public release.

*Corrected on 2026-09-26.* The original text of this entry said the tool was
"covered by tests", that `make demo` ran "against a synthetic backend", that
"CI runs the test suite on every push", and mentioned metric names. None of
that existed: there were no tests, no `demo` target and no metrics. What
actually shipped:

- `make up`: a KinD cluster, cert-manager, the Slinky operator and a Slurm
  cluster that registers a node; `make job` runs a job.
- `scripts/rotate-auth-key.sh`: rotate, dry-run and rollback of the
  `auth/slurm` key, with a sha256 check of `slurm.key` inside slurmd pods and
  an automatic rollback on mismatch.
- CI on KinD asserting that the rotation fails and the cluster still runs a
  job afterwards; shellcheck.
- Known limitation, stated in the README: the rotation does not succeed on
  Slinky v1.2.

[Unreleased]: https://github.com/Zhanyl-tech/slinky-gitops/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Zhanyl-tech/slinky-gitops/releases/tag/v0.1.0
