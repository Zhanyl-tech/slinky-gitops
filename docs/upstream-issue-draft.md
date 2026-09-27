# Draft: upstream issue for SlinkyProject/slurm-operator

**Status: draft, not filed.** The repository owner decides whether and when to
file it. It follows the upstream
[feature request template](https://github.com/SlinkyProject/slurm-operator/blob/main/.github/ISSUE_TEMPLATE/feature_request.md).
Everything below is labelled as either *measured* (seen on a running
cluster), *read in source* (with the file and tag), *hypothesis*, or
*untested* (written down but never executed). Before filing, run the minimal
reproduction below on the then-current release (it has never been run as
written) and update the versions and the text to what it shows, and run at
least experiment 1 or 2 so the issue can state the mechanism rather than
propose it.

Checked for duplicates on 2026-09-26 (searches for `slurm.key rotation`,
`slurm.jwks`, `slurm-key-hash`, `slurmKeyRef`, `rotate key`, `immutable
secret`): nothing open covers this. Related: #204 (closed unmerged), #248
(open, JWT token Secret ownership).

---

**Title:** `[FEA] Supported auth/slurm key rotation: a replaced slurm.key does not reach new NodeSet pods, and there is no slurm.jwks path`

**Is your feature request related to a problem? Please describe.**

There is no supported way to rotate the `auth/slurm` key on a running Slinky
cluster, and the obvious manual procedure leaves slurmd on the old key while
slurmctld moves to the new one.

Slurm supports graceful rotation: since 24.05 a `slurm.jwks` file with several
keys lets "an scontrol reconfigure" replace a restart
([authentication.html](https://slurm.schedmd.com/authentication.html)), and
Slinky's own `docs/concepts/architecture.md` says auth/slurm "uses a shared
cryptographic key (e.g. `slurm.key`, or `slurm.jwks` for key rotation)". But
in v1.2.0 (and on `main` at 160a6ae3f1, 2026-09-23), *read in source*:

1. **Only `slurm.key` can be delivered.** Every Slurm pod gets
   `Controller.spec.slurmKeyRef` projected as `/etc/slurm/slurm.key`
   (`internal/builder/{controllerbuilder,workerbuilder,restapibuilder,loginbuilder}/*_app.go`).
   The chart's `jwksKeys` is the `auth/jwt` JWKS (`jwks.json`, via
   `AuthAltParameters`), not `auth/slurm`'s `slurm.jwks`.
2. **A key change rolls the controller but not slurmd.** The controller pod
   template carries `slinky.slurm.net/slurm-key-hash` (`controller_app.go`,
   `getAuthHashes`), so replacing the Secret rolls slurmctld. NodeSet pods get
   only `sshd`/`sssd` config hashes (`worker_app.go`, `getWorkerHashes`),
   LoginSet pods only SSH and `sssd` hashes (`login_app.go`), and RestApi pods
   no hash annotation at all. The NodeSet controller does
   enqueue on a change to the key Secret (`eventhandler_secret.go`), but with
   no hash in the template that produces no new revision.
3. **The key reference cannot move.** `ValidateUpdate` rejects any change:
   `cannot change SlurmKeyRef after deployment` (`controller_webhook.go`).
   So the Secret name is fixed at install, and since the chart creates it with
   `immutable: true`, the only way to change the key is to delete and recreate
   a Secret of the same name.

**What happens when you do that (measured).** KinD cluster, Slinky v1.2.0
charts, Slurm 26.05 (July 2026; the repository records Kubernetes v1.32.2 as
its test environment, though nothing was pinned at the time, so treat the
Kubernetes version as approximate). The key
Secret was deleted and recreated with a new key by the repository's script as
it was then (`set_key` in `scripts/rotate-auth-key.sh` at commit `8d22ade`):
a new, mutable Opaque Secret was created with `kubectl create secret
generic`, then patched with the new key, the original labels and
`immutable: true`. The original annotations were *not* carried over; that
script never copied them. slurmctld picked up the new key. With the Secret
holding the new key and stable for five minutes, a slurmd pod deleted and
recreated from scratch came up with the *previous* key:

```
secret                        sha256 c5016281…
slurmctld                     sha256 c5016281…
slurmd pod created 02:28:25   sha256 8cbda076…   <- the pre-rotation key
```

and slurmd logged `_fetch_child: failed to fetch remote configs: Protocol
authentication error` until the node went down. Also observed:

- The Secret held one value (`resourceVersion` unchanged) for 90 s, so this
  is not something rewriting the Secret.
- Recreating the replacement as *mutable* behaved the same.
- The same delete-and-recreate against a Secret the node had never cached
  propagated immediately.

The same rotation, run by a script that measures the key in every slurmd pod
and rolls back on mismatch, was run in all four CI runs since that check was
added (`ubuntu-latest`, KinD with a single worker). In each, the rotation step
exited non-zero after 369-419 s, which fits the script's 300 s propagation
wait plus a rollback; the logs were not re-read for this draft, so which check
fired is not confirmed. Repository:
https://github.com/Zhanyl-tech/slinky-gitops (see "The part I could not fix").

**Likely mechanism (hypothesis, from reading kubelet source, not yet
isolated).** The kubelet's default `Watch` strategy caches Secrets per node,
keyed by namespace/name
([`pkg/kubelet/util/manager/watch_based_manager.go` at v1.32.2](https://github.com/kubernetes/kubernetes/blob/v1.32.2/pkg/kubelet/util/manager/watch_based_manager.go)).
In `Get()`, an immutable object marks the item immutable and stops its watch
(`Stopped watching for changes - object is immutable`);
`restartReflectorIfNeeded()` returns early for immutable items; and
`DeleteReference()` drops the item only when no pod on the node references
the name any more. So once a node has cached `slurm-auth-slurm` as immutable,
new pods there get the cached bytes for as long as any other pod on that node
(controller, restapi, a terminating slurmd) still mounts it. That explains all
three observations. The Kubernetes docs note that after deleting and
recreating an immutable Secret, "Existing Pods maintain a mount point to the
deleted Secret - it is recommended to recreate these pods"
([Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#secret-immutable)).
If this is right, the problem is not specific to Slinky, but Slinky's
combination (one fixed, immutable Secret name mounted by every Slurm pod,
including co-located ones) makes it unavoidable.

**Minimal reproduction** (KinD). *Untested: written on 2026-09-26 from the
July observations and not yet executed.* It is not the July procedure either:
it pins versions that did not exist or were not pinned in July (cert-manager
v1.20.4 was published in September 2026), and it recreates the Secret in one
`kubectl create -f` with its annotations, where the July script created a
mutable Secret and then patched it (see above). How long it takes is unknown
until it has been run.

```sh
kind create cluster --image kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f \
  --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes: [{role: control-plane}, {role: worker}]
EOF
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.20.4 \
  --namespace cert-manager --create-namespace --set crds.enabled=true --wait
helm install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds --version 1.2.0 --wait
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator --version 1.2.0 \
  --namespace slinky --create-namespace --wait
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm --version 1.2.0 \
  --set-json 'nodesets={"slinky":{"replicas":1}}' --set partitions.all.enabled=true \
  --namespace slurm --create-namespace
# wait until `kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sinfo` shows the node idle

NS=slurm
key_sha() { kubectl -n $NS exec "$1" -c "$2" -- sha256sum /etc/slurm/slurm.key; }
kubectl get pods -A -o wide                  # placement: one worker, so everything is co-located
key_sha slurm-controller-0 slurmctld
key_sha slurm-worker-slinky-0 slurmd

# Replace the key. The Secret is immutable, so delete and recreate it,
# keeping Helm's labels and annotations.
kubectl -n $NS get secret slurm-auth-slurm -o json > old.json
head -c 1024 /dev/urandom > new.key
python3 - <<'PY'
import base64, json
s = json.load(open("old.json"))
for k in ("uid", "resourceVersion", "creationTimestamp", "managedFields"):
    s["metadata"].pop(k, None)
s["data"]["slurm.key"] = base64.b64encode(open("new.key", "rb").read()).decode()
json.dump(s, open("new.json", "w"))
PY
kubectl -n $NS delete secret slurm-auth-slurm
kubectl -n $NS create -f new.json
sha256sum new.key

# The operator rolls the controller (slurm-key-hash). Replace slurmd by hand,
# since nothing else will.
kubectl -n $NS rollout status statefulset/slurm-controller --timeout=300s
kubectl -n $NS delete pod slurm-worker-slinky-0
kubectl -n $NS wait --for=condition=ready pod/slurm-worker-slinky-0 --timeout=300s

key_sha slurm-controller-0 slurmctld          # expected: the new key
key_sha slurm-worker-slinky-0 slurmd          # observed: the previous key
kubectl -n $NS logs slurm-worker-slinky-0 -c slurmd | grep -i 'authentication'
```

Experiments that would confirm or refute the mechanism (none run yet):

1. Same, with slurmd alone on a worker (no other pod there mounting
   `slurm-auth-slurm`). Prediction: slurmd gets the new key.
2. After recreating the Secret, restart the kubelet on slurmd's node
   (`docker exec <node> systemctl restart kubelet`), then replace the pod.
   Prediction: new key.
3. Run that kubelet at `-v=4` and look for
   `Stopped watching for changes - object is immutable`.
4. Install with `slurmKey.create=false` and a pre-created *mutable* Secret
   (`slurmKey.secretRef`). Prediction: new key, because the cache item never
   becomes immutable.

**Describe the solution you'd like**

In order of how much each would help:

1. **First-class `slurm.jwks`.** An optional `Controller.spec.slurmJwksRef`
   (Secret key selector), projected as `/etc/slurm/slurm.jwks` next to
   `slurm.key` in every pod that gets `slurm.key` today. Slurm needs no
   configuration for it: "the presence of the slurm.jwks file enables this
   functionality", and "If the slurm.jwks is not present or cannot be read,
   the cluster defaults to the slurm.key"
   ([authentication.html](https://slurm.schedmd.com/authentication.html)).
   Rotation then becomes: add the new key (not default), wait for the
   projected file to update in every pod, `scontrol reconfigure`; mark it
   default, reconfigure; remove the old key, reconfigure. That only works if
   the JWKS Secret is *mutable* (projected Secret volumes update in place;
   an immutable one cannot change), so the chart should create it mutable, or
   leave it to the user. The operator could also run the reconfigure when the
   JWKS Secret's content hash changes.
2. **A `slinky.slurm.net/slurm-key-hash` annotation on NodeSet, RestApi and
   LoginSet pod templates**, as the controller already has. A key change would
   then roll slurmd through the NodeSet's existing Slurm-aware update strategy
   (drain, `maxUnavailable`) instead of leaving it on the old key. Small and
   testable with envtest. On its own it does not fix the stale bytes if the
   hypothesis above holds, because the rolled pods mount the same immutable
   name; it removes the manual pod deletion and makes the controller and
   slurmd behave the same way.
3. **Document the current limitation**: the Secret name is fixed at install,
   the chart's Secret is immutable, and replacing it does not reliably reach
   new pods on a node that still mounts it.

**Describe alternatives you've considered**

- *Versioned Secret names* (write `slurm-auth-slurm-<n>` and point the cluster
  at it): blocked by the webhook in item 3 above. Allowing `slurmKeyRef`
  changes would make it possible, with every Slurm pod rolled onto a name no
  kubelet has cached, but it is still a hard cut-over with a split-trust
  window unless combined with `slurm.jwks`.
- *Rolling NodeSet pods on Secret content change* (#204, closed without merge;
  the maintainers suggested Reloader, stakater/Reloader#1192): addresses
  "nothing restarts slurmd", but under the hypothesis above the new pods would
  still be served the cached bytes on a node where another pod mounts the
  Secret.
- *Restarting the kubelet or evicting every Slurm pod from a node* before its
  new slurmd starts: works around the cache (if the hypothesis holds) but is
  disruptive and outside what an operator should do.

**Additional context**

- `jwt.key` has the same shape: fixed name (`JwtKeyRef` is also immutable
  after deployment), immutable Secret. In v1.2.0 the auth-token Secrets from
  `BuildTokenSecret` are owned by the JWT key Secret, so deleting it without
  `--cascade=orphan` garbage-collects them (#248 proposes owning them by the
  Token instead). The operator's own REST client signs a 15-minute token from
  the JWT key and refreshes it at 4/5 of its lifetime (`slurmclient_sync.go`),
  reconciling on RestApi objects rather than the Secret, so after a JWT key
  change its token can stay stale for up to about 12 minutes (read in source,
  not measured).
- The slurmd preStop hook (`scontrol update nodename=$(hostname) state=down
  reason='slurm-operator: Pod is terminating'`) overwrites any existing reason,
  including one set by a health check, whenever a slurmd pod is replaced. Any
  rotation procedure that replaces pods has to save and restore those reasons.

______________________________________________________________________

By submitting this issue, you agree to follow our
[code of conduct](https://github.com/SlinkyProject/slurm-operator/blob/main/CODE_OF_CONDUCT.md)
and our
[contributing guidelines](https://github.com/SlinkyProject/slurm-operator/blob/main/CONTRIBUTING.md).
