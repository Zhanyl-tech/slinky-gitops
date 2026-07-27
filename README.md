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
4. **Verifies end to end.** `sinfo` round-trips through the auth plugin, so a
   clean response proves the controller and the nodes agree on the new key.
5. **Rolls back automatically** if that check fails.
6. **Resumes nodes on any failure path.** A crash mid-rotation must not leave
   the cluster drained and unschedulable.

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

## A note on CI

The first CI run hung and was killed at the job timeout. The cause was mine, not
Slinky's: `make slurm` waited for node registration with an unbounded `until`
loop, so when the node did not come up there was no timeout and no diagnostics —
just thirty minutes of silence.

It is bounded now (`REGISTER_TIMEOUT`, default 600s) and dumps pod state,
nodeset status and `describe` output on failure. CI also uses a two-node
topology (`kind/cluster-ci.yaml`), because a GitHub runner is 2 vCPU / 7 GB and
three KinD nodes plus cert-manager plus the operator leaves the slurmd pod
nothing to schedule into.

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

## License

MIT
