# slinky-gitops

A working Slurm-on-Kubernetes cluster from nothing, and the credential rotation
nobody wants to be the first to try in production.

```
make up
```

Brings up a three-node KinD cluster, cert-manager, the Slinky operator, and a
Slurm cluster that registers a compute node and runs jobs. Verified on Apple
Silicon — **the Slinky images are multi-arch**, which is not obvious and is the
first thing that stops most people.

---

## What you get

```
$ make job
slinky-0

$ make status
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
all*         up   infinite      1   idle slinky-0

NodeName=slinky-0 Arch=aarch64 CoresPerSocket=11
   State=IDLE+DYNAMIC_NORM
```

Versions this was built and tested against:

| | |
| --- | --- |
| Slinky operator | v1.2.0 |
| Slurm | **26.05** |
| Kubernetes | v1.32.2 (KinD) |
| Architecture | arm64 and amd64 |

Slinky v1.2 ships Slurm 26.05, which is worth knowing if you are still planning
a 25.11 upgrade — the Kubernetes path is already a release ahead.

## The thing this repo is actually for

### Every MUNGE rotation guide is describing a component that isn't installed

Search for "rotate Slurm shared secret" and you get MUNGE. On a current Slinky
cluster, MUNGE is not there. Verified on the running deployment:

```
$ scontrol show config | grep -i auth
AuthType            = auth/slurm
CredType            = cred/slurm
AuthAltTypes        = auth/jwt
AuthInfo            = use_client_ids

$ pgrep munged
(nothing)
```

Slurm 23.11 introduced `auth/slurm`, an internal plugin that replaces MUNGE with
a shared key file. Slinky ships it as two secrets:

| Secret | Key | Purpose |
| --- | --- | --- |
| `slurm-auth-slurm` | `slurm.key` | Shared cluster auth |
| `slurm-auth-jwt` | `jwt.key` | Signs REST and scrontab tokens |

So the operational hazard is unchanged, but the mechanism, the secret names, and
the restart procedure in every tutorial are wrong.

### Rotation, done carefully

```bash
make rotate-dry   # show the plan
make rotate       # do it
make rollback     # undo it
```

There is no atomic moment in a shared-key rotation. Between writing the new key
and every daemon reloading it, some daemons hold the old key and some the new,
and those two sets cannot authenticate to each other. `auth/slurm` has no key
versioning and no grace period.

What the script does about that:

1. **Refuses to start unless the cluster is healthy.** Verifies `AuthType` is
   actually `auth/slurm` — if a site is still on MUNGE it says so and stops,
   rather than rotating a secret nothing reads.
2. **Drains first.** Running jobs are what a failed rotation destroys, so they
   are gone before the window opens.
3. **Backs up the current key** to `slurm-auth-slurm-previous`. Rollback is one
   command, not archaeology.
4. **Restarts every daemon that holds the key** — including slurmd, which
   `kubectl rollout restart` does not reach (see below).
5. **Verifies by measurement, not inference.** It reads `slurm.key` off disk
   inside each slurmd pod and compares the hash to the Secret, then requires a
   node to reach a genuinely schedulable state. Earlier versions checked
   proxies for this and passed while the cluster was dead.
6. **Rolls back automatically** if either check fails.
7. **Resumes nodes on any failure path.** A crash mid-rotation must not leave
   the cluster drained and unschedulable — and pod replacement always downs the
   node, so the resume is mandatory rather than cosmetic.

> **Status: the rotation does not currently succeed on Slinky v1.2.** Replacing
> the Secret does not reach slurmd, for reasons documented in full under
> [What CI caught](#what-ci-caught). The script detects that and rolls back
> instead of reporting success. Read that section before using this on anything
> you care about.

Rotating `jwt.key` (`--jwt`) additionally invalidates every outstanding REST
token. That is the point of a credential rotation, but it will page whoever
automated against the API, so it is opt-in.

## Three things that only show up when you run it

**The auth secrets are immutable.** Slinky sets `immutable: true`, so
`kubectl patch` is rejected outright:

```
The Secret "slurm-auth-slurm" is invalid:
  data: Forbidden: field is immutable when `immutable` is set
```

The only way to change one is delete-and-recreate, carrying the labels over so
the operator and Helm still recognise it. The first version of this script
patched, failed here, and left the cluster drained — which is why step 6 exists.

**Recreating an immutable secret silently drops the flag.** Deleting and
recreating gets you a working, *mutable* secret. Everything keeps running, so
nothing tells you the cluster's posture just weakened. `set_key` captures the
flag before deleting and restores it after — verified by rotating twice and
checking `immutable` is still `true`.

**PIDs, secrets and node registration are all asynchronous.** A node takes
noticeably longer to appear in `sinfo` than its pod takes to reach `Running`.
`make slurm` waits for actual registration rather than pod readiness, because
pod-ready is not cluster-ready.

**A verification that does not cross the broken boundary always passes.** This
one cost two CI runs and is the most useful thing in the repo — see below.

## What CI caught

Two runs failed here, both on my code rather than on Slinky, and both worth
writing down because they are the same mistake wearing different clothes.

**Run 1 — thirty minutes of silence.** `make slurm` waited for node
registration with an unbounded `until` loop. When the node did not come up
there was no timeout and no diagnostics, so the job sat until GitHub killed it.
Bounded now (`REGISTER_TIMEOUT`, default 600s), dumping pod state, nodeset
status and `describe` output on failure. CI also uses a two-node topology
(`kind/cluster-ci.yaml`), because a GitHub runner is 2 vCPU / 7 GB and three
KinD nodes plus cert-manager plus the operator leaves the slurmd pod nothing to
schedule into.

**Run 2 — the rotation reported success on a cluster that could not run a
job.** Every step printed a green tick, `Rotation complete` scrolled past, and
the next line was:

```
srun: Required node not available (down, drained or reserved)
```

Chasing that down turned up four defects in my own script and one in Slinky
that I still cannot fully explain.

### The checks that could not fail

Rotation can only break one thing: the controller↔slurmd trust relationship,
since that is what the rotated key authenticates. Two verification attempts
both missed it, the same way:

| Check | Why it passed anyway |
| --- | --- |
| `sinfo` exits 0 | Never leaves the controller pod. `slurmctld` answers a local client whether or not a single node came back — it passes against zero compute. |
| No `*` on any node state | Crosses the boundary, but raced the restart. It passed **130 ms** after the rollout, reading the node as it was *before* the new key applied. |

A third was subtler: `grep -E '^(idle|mix|alloc)'` also matches **`idle*`**, and
that trailing `*` means *slurmctld cannot reach the node* — the precise failure
the check existed to catch. It is anchored at both ends now.

A fourth: the wait for replacement pods had no success flag, so on timeout it
fell out of the loop straight into the line that prints a green tick. Every one
of these is the same bug — **a check that cannot fail.**

### `rollout restart` never restarted slurmd

```
$ kubectl -n slurm get statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm
statefulset.apps/slurm-controller
deployment.apps/slurm-restapi
$ kubectl -n slurm get pod slurm-worker-slinky-0 -o jsonpath='{.metadata.ownerReferences[*].kind}'
NodeSet
```

`NodeSet` is a CRD, so `kubectl rollout restart` — which only knows built-in
kinds — silently skipped the one daemon on the far side of the boundary being
rotated. The controller adopted the new key in seconds and slurmd kept the old
one. Deleting the pods is the supported way to cycle them.

And replacing a slurmd pod leaves the node **down**, not drained:

```
$ sinfo -R
slurm-operator: Pod   root   2026-07-27T01:41:40   slinky-0
```

The operator sets that and never clears it — ninety seconds of watching showed
no self-heal. So an explicit `RESUME` is mandatory after any pod replacement,
and it must be re-issued rather than fired once.

### The part I could not fix: the key does not propagate

With all of that corrected, rotation still fails — and now says so. On a clean
KinD cluster, with the Secret holding a new key and stable for five minutes, a
slurmd pod deleted and recreated from scratch came up mounting the **previous**
key:

```
secret                        sha c5016281…
slurmd pod created 02:28:25   sha 8cbda076…    ← the pre-rotation key
slurmctld                     sha c5016281…    ← correct
```

with `_fetch_child: failed to fetch remote configs: Protocol authentication
error` in the slurmd log until the node went down.

Slinky ships the auth Secret `immutable: true`, so its data cannot be patched
and delete-and-recreate is the only route. After that, the node's kubelet keeps
serving its cached copy to newly created pods. Things I checked, so the record
is honest about what is and is not established:

- **Not the operator rewriting the Secret** — it held one value, `rv` unchanged, for 90s.
- **Not immutability itself** — recreating the replacement as *mutable* behaves identically.
- **Not universal** — the same delete-and-recreate against a Secret that node had never cached propagates immediately, which is why a naive control test made me dismiss this too early.

The trigger appears to be a pre-existing cache entry on that node, but I have
not pinned it to a specific kubelet code path, so the repo does not claim one.

**What the script does about it:** it reads the key off disk inside every
slurmd pod and compares it to the Secret. On mismatch it rolls back and exits
non-zero. That is the whole point — a rotation that cannot work must not print
a green tick, because "answers `sinfo`, cannot run a job" is the worst state to
hand someone.

The likely real fix is versioned Secret names (`slurm-auth-slurm-<n>`, repoint
the NodeSet) so pods mount an object no kubelet has cached. That is a
chart-level change and is **not implemented here**.

CI asserts the safety property rather than a success it cannot have: `make
rotate` must fail, and the cluster must still run a job afterwards.

The general form is worth more than any single bug: **a check that does not
cross the boundary you might have broken will pass no matter what you broke.**
Green ticks on a dead cluster are worse than a red one, because they stop you
looking.

## Layout

```
kind/cluster.yaml          3-node KinD topology
values/slurm.yaml          cluster shape, in git rather than --set flags
scripts/rotate-auth-key.sh the rotation
Makefile                   make up / job / rotate / rollback / down
```

Values live in a file on purpose. A cluster defined by a string of `--set`
arguments in someone's shell history is not reviewable and not reproducible.

## Requirements

`docker`, `kind`, `kubectl`, `helm`. Roughly 6 GB free for Docker. No GPU and no
real Slurm cluster needed.

## Honest scope

- **KinD only, so far.** The Helm values and rotation apply to any Kubernetes,
  but the bring-up path is local. Cloud is the obvious next step.
- **One nodeset, one replica.** Enough to prove registration and job execution;
  multi-nodeset scheduling and autoscaling profiles are not built yet.
- **No ArgoCD yet.** The "GitOps" in the name is currently aspirational — this
  is declarative and reproducible, but applied by Make rather than reconciled by
  a controller. Wiring ArgoCD to `values/` is the next commit, not a claim I
  should make before it exists.
- **No login node.** Jobs are submitted from the controller pod. A `LoginSet` CR
  exists in the CRDs and is not deployed here.

## The set

Part of a set of tools covering the lifecycle of a GPU allocation, each built on
the same rule — never act on absent evidence:

- **slinky-gitops** — this repo. Running Slurm on Kubernetes.
- **[gpu-reaper](https://github.com/Zhanyl-tech/gpu-reaper)** — wasted GPUs during a job.
- **[ib-slurm-exporter](https://github.com/Zhanyl-tech/ib-slurm-exporter)** — fabric problems attributed to the job.
- **[epilog-gpu-validator](https://github.com/Zhanyl-tech/epilog-gpu-validator)** — GPU hardware faults between jobs.
- **[slurm-scheduler-lab](https://github.com/Zhanyl-tech/slurm-scheduler-lab)** — the scheduling policy behind it all.

## License

MIT
