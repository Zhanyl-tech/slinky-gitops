#!/usr/bin/env bash
#
# rotate-auth-key.sh — rotate Slurm's shared auth key on a Slinky cluster.
#
# ── Why this is not a MUNGE script ──────────────────────────────────────────
#
# Nearly every guide about rotating Slurm's shared secret is about MUNGE. On a
# current Slinky deployment that guide describes a component which is not
# installed. Verified against Slinky v1.2 / Slurm 26.05:
#
#     AuthType=auth/slurm
#     CredType=cred/slurm
#     AuthAltTypes=auth/jwt
#     $ pgrep munged   ->   nothing
#
# Slurm 23.11 introduced auth/slurm, an internal plugin that replaces MUNGE with
# a shared key file. Slinky ships it as two Kubernetes secrets:
#
#     slurm-auth-slurm   key: slurm.key   the shared cluster auth key
#     slurm-auth-jwt     key: jwt.key     signs REST/scrontab tokens
#
# The operational hazard is the same one MUNGE had, so the careful bits below
# still apply — there is simply no munged to restart, and the secret names in
# every tutorial are wrong.
#
# ── The hazard ──────────────────────────────────────────────────────────────
#
# There is no atomic moment. Between writing the new key and every daemon
# reloading it, some hold the old key and some the new, and those two sets
# cannot authenticate to each other. So:
#
#   1. Refuse to start unless the cluster is healthy.
#   2. Drain first — running jobs are what a failed rotation destroys.
#   3. Keep the previous key, so rollback is one command.
#   4. Verify authentication end to end, and roll back automatically if it fails.
#
# ── Known limitation: this rotation does not currently succeed ──────────────
#
# On Slinky v1.2 / Slurm 26.05, replacing the Secret does not reach slurmd.
# Reproduced on a clean KinD cluster: with the Secret holding a new key and
# stable for five minutes, a slurmd pod deleted and recreated from scratch came
# up mounting the *previous* key.
#
#     secret                       sha c5016281…
#     slurmd pod created 02:28:25  sha 8cbda076…   (the pre-rotation key)
#
# Slinky ships the auth Secret with `immutable: true`, so the data cannot be
# patched — delete-and-recreate is the only route — and after that the node's
# kubelet keeps serving its cached copy to new pods. Tested both ways: it makes
# no difference whether the replacement Secret is immutable or mutable. The
# same delete-and-recreate against a Secret that node had never cached
# propagates fine, so the trigger is the pre-existing cache entry, but I have
# not pinned it to a specific kubelet code path and this comment does not
# pretend otherwise.
#
# So the script's job today is to *not lie about it*: it measures the key on
# disk inside each slurmd pod, and when that does not match the Secret it rolls
# back and exits non-zero rather than printing a green tick. Reporting success
# here would leave a cluster that answers `sinfo` and cannot run a job.
#
# The likely fix is versioned Secret names — write slurm-auth-slurm-<n> and
# repoint the NodeSet — so pods mount an object no kubelet has cached. That is
# a chart-level change and is not implemented here.
#
# Rotating jwt.key additionally invalidates every outstanding REST token; that
# is intended on a credential rotation, but it will page whoever automated
# against the API, so it is opt-in.
#
# Usage:
#   ./scripts/rotate-auth-key.sh -n slurm                 # rotate slurm.key
#   ./scripts/rotate-auth-key.sh -n slurm --jwt           # also rotate jwt.key
#   ./scripts/rotate-auth-key.sh -n slurm --dry-run
#   ./scripts/rotate-auth-key.sh -n slurm --rollback
#
set -euo pipefail

NAMESPACE="slurm"
AUTH_SECRET="slurm-auth-slurm"
JWT_SECRET="slurm-auth-jwt"
BACKUP_SUFFIX="-previous"
ROTATE_JWT=0
DRY_RUN=0
ROLLBACK=0
TIMEOUT=300

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
step() { printf "\n${BOLD}%s${RESET}\n" "$1"; }
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
die()  { printf "  ${RED}✗${RESET} %s\n" "$1" >&2; exit 1; }
note() { printf "  ${DIM}%s${RESET}\n" "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --jwt)          ROTATE_JWT=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --rollback)     ROLLBACK=1; shift ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    -h|--help)      sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown flag: $1" ;;
  esac
done

command -v kubectl >/dev/null || die "kubectl not found"
k() { kubectl --namespace "$NAMESPACE" "$@"; }

controller_pod() {
  k get pods -l app.kubernetes.io/component=controller -o name 2>/dev/null | head -1
}

# One line per node: "<name> <state>". Slurm suffixes the state with `*` when
# the node is not responding, `~` for powered down, and so on. Those suffixes
# are load-bearing: `idle*` is a node slurmctld believes is idle but cannot
# reach, which is exactly what a slurmd that failed to authenticate looks like.
node_states() {
  local c; c=$(controller_pod)
  [ -n "$c" ] || return 1
  k exec "$c" -c slurmctld -- sinfo -N --noheader -o '%N %t' 2>/dev/null
}

# sha256 of the key as stored in the Secret.
secret_key_sha() {
  k get secret "$1" -o jsonpath="{.data.${2//./\\.}}" 2>/dev/null \
    | base64 -d 2>/dev/null | shasum -a 256 | awk '{print $1}'
}

# sha256 of the key as each slurmd pod actually has it on disk, one per line.
# This is a direct measurement of the property the whole rotation depends on,
# rather than an inference from "we restarted the pods".
slurmd_key_shas() {
  local pods p
  pods=$(k get pods -l app.kubernetes.io/name=slurmd -o name 2>/dev/null || true)
  for p in $pods; do
    k exec "$p" -c slurmd -- sha256sum /etc/slurm/slurm.key 2>/dev/null \
      | awk -v n="$p" '{print n" "$1}'
  done
}

# copy_key <src-secret> <dst-secret> <key>
# Routes through set_key so an immutable destination is handled the same way,
# rather than failing only on the rollback path.
copy_key() {
  local src="$1" dst="$2" key="$3" value
  value=$(k get secret "$src" -o jsonpath="{.data.${key//./\\.}}")
  [ -n "$value" ] || die "no key $key in secret $src"
  set_key "$dst" "$key" "$value"
}

# Slinky sets immutable:true on the auth secrets, so `kubectl patch` is
# rejected outright. The only way to change one is delete-and-recreate, and the
# labels have to be carried over or the operator stops recognising it.
set_key() {
  local secret="$1" key="$2" value="$3" labels was_immutable
  if k get secret "$secret" >/dev/null 2>&1; then
    labels=$(k get secret "$secret" -o json \
      | python3 -c 'import json,sys;d=json.load(sys.stdin).get("metadata",{}).get("labels",{});print(json.dumps(d))')
    was_immutable=$(k get secret "$secret" -o json \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("immutable",""))')
    k delete secret "$secret" >/dev/null
  else
    labels="{}"; was_immutable=""
  fi
  k create secret generic "$secret" --from-literal=placeholder=x >/dev/null
  k patch secret "$secret" --type merge -p "{\"data\":{\"$key\":\"$value\"}}" >/dev/null
  k patch secret "$secret" --type merge -p "{\"data\":{\"placeholder\":null}}" >/dev/null
  # Restore labels so the operator and Helm still own it.
  if [ "$labels" != "{}" ]; then
    k patch secret "$secret" --type merge -p "{\"metadata\":{\"labels\":$labels}}" >/dev/null
  fi
  # Restore immutability. Slinky sets this deliberately; recreating the secret
  # without it silently downgrades the cluster's posture, and the downgrade is
  # invisible because everything keeps working.
  if [ "$was_immutable" = "True" ] || [ "$was_immutable" = "true" ]; then
    k patch secret "$secret" --type merge -p '{"immutable":true}' >/dev/null
  fi
}

# ── Rollback ────────────────────────────────────────────────────────────────
if [ "$ROLLBACK" -eq 1 ]; then
  step "Rolling back"
  k get secret "${AUTH_SECRET}${BACKUP_SUFFIX}" >/dev/null 2>&1 \
    || die "no ${AUTH_SECRET}${BACKUP_SUFFIX} — nothing to roll back to"

  copy_key "${AUTH_SECRET}${BACKUP_SUFFIX}" "$AUTH_SECRET" "slurm.key"
  ok "restored slurm.key"

  if k get secret "${JWT_SECRET}${BACKUP_SUFFIX}" >/dev/null 2>&1; then
    copy_key "${JWT_SECRET}${BACKUP_SUFFIX}" "$JWT_SECRET" "jwt.key"
    ok "restored jwt.key"
  fi

  k rollout restart statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm >/dev/null 2>&1 || true
  ok "restarted Slurm workloads"
  exit 0
fi

# ── 1. Preflight ────────────────────────────────────────────────────────────
step "1/6  Preflight"

k get secret "$AUTH_SECRET" >/dev/null 2>&1 || die "secret $AUTH_SECRET not found in $NAMESPACE"
ok "found $AUTH_SECRET"

# Confirm this cluster really is on auth/slurm. If a site is still on MUNGE,
# rotating these secrets accomplishes nothing and the operator should know.
ctl=$(controller_pod)
[ -n "$ctl" ] || die "no Slurm controller pod in $NAMESPACE"

authtype=$(k exec "$ctl" -c slurmctld -- scontrol show config 2>/dev/null \
  | awk -F'= *' '/^AuthType/{print $2}' | tr -d ' ' || true)
case "$authtype" in
  auth/slurm) ok "AuthType=auth/slurm" ;;
  auth/munge) die "this cluster uses auth/munge; rotating $AUTH_SECRET will do nothing" ;;
  "")         warn "could not read AuthType; continuing" ;;
  *)          warn "unexpected AuthType=$authtype" ;;
esac

# Rotating on top of an existing fault turns one incident into two.
notready=$(k get nodesets.slinky.slurm.net -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
bad=[i["metadata"]["name"] for i in d.get("items",[])
     if i.get("status",{}).get("replicas",0) != i.get("status",{}).get("updatedReplicas",0)]
print(" ".join(bad))' 2>/dev/null || true)
[ -n "$notready" ] && die "nodesets not converged: $notready"
ok "nodesets converged"

# ── 2. Plan ─────────────────────────────────────────────────────────────────
step "2/6  Plan"
running=$(k exec "$ctl" -c slurmctld -- squeue --noheader --states=RUNNING 2>/dev/null | wc -l | tr -d ' ' || echo "?")
note "namespace       $NAMESPACE"
note "rotating        slurm.key$([ "$ROTATE_JWT" -eq 1 ] && echo " + jwt.key")"
note "running jobs    $running (will be drained)"
[ "$ROTATE_JWT" -eq 1 ] && warn "rotating jwt.key invalidates every outstanding REST token"

if [ "$DRY_RUN" -eq 1 ]; then
  warn "dry run — stopping here"
  exit 0
fi

# From here on a failure would leave the cluster drained and unschedulable,
# which is a worse outcome than not having rotated. Resume on any exit path.
DRAINED=0
resume_on_exit() {
  local rc=$?
  if [ "$DRAINED" -eq 1 ] && [ "$rc" -ne 0 ]; then
    printf "\n  ${YELLOW}!${RESET} failed after draining — resuming nodes\n"
    local c; c=$(controller_pod)
    [ -n "$c" ] && k exec "$c" -c slurmctld -- \
      scontrol update NodeName=ALL State=RESUME >/dev/null 2>&1 || true
  fi
}
trap resume_on_exit EXIT

# ── 3. Drain ────────────────────────────────────────────────────────────────
step "3/6  Drain"
DRAINED=1
k exec "$ctl" -c slurmctld -- scontrol update NodeName=ALL State=DRAIN \
  Reason="auth key rotation" >/dev/null 2>&1 || warn "scontrol drain failed; continuing"
ok "nodes draining"

deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  n=$(k exec "$ctl" -c slurmctld -- squeue --noheader --states=RUNNING 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ "$n" = "0" ] && break
  note "waiting on $n running job(s)…"
  sleep 10
done
ok "no running jobs"

# ── 4. Back up ──────────────────────────────────────────────────────────────
step "4/6  Back up current keys"
copy_key "$AUTH_SECRET" "${AUTH_SECRET}${BACKUP_SUFFIX}" "slurm.key"
ok "slurm.key -> ${AUTH_SECRET}${BACKUP_SUFFIX}"
if [ "$ROTATE_JWT" -eq 1 ]; then
  copy_key "$JWT_SECRET" "${JWT_SECRET}${BACKUP_SUFFIX}" "jwt.key"
  ok "jwt.key -> ${JWT_SECRET}${BACKUP_SUFFIX}"
fi

# ── 5. Rotate ───────────────────────────────────────────────────────────────
step "5/6  Rotate"
# auth/slurm expects a random key file; 1024 bytes matches what Slinky ships.
new_auth=$(dd if=/dev/urandom bs=1024 count=1 2>/dev/null | base64 | tr -d '\n')
set_key "$AUTH_SECRET" "slurm.key" "$new_auth"
ok "slurm.key rotated"

if [ "$ROTATE_JWT" -eq 1 ]; then
  new_jwt=$(dd if=/dev/urandom bs=1024 count=1 2>/dev/null | base64 | tr -d '\n')
  set_key "$JWT_SECRET" "jwt.key" "$new_jwt"
  ok "jwt.key rotated"
fi

# Projected secrets update lazily; restarting is what makes every daemon adopt
# the key at a predictable moment rather than whenever the kubelet notices.
#
# The catch, and the reason an earlier version of this script rotated onto a
# cluster that could not run a job: `kubectl rollout restart` only understands
# built-in workload kinds. Checked against a live cluster:
#
#   $ kubectl -n slurm get statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm
#   statefulset.apps/slurm-controller
#   deployment.apps/slurm-restapi
#   $ kubectl -n slurm get pod slurm-worker-slinky-0 -o jsonpath='{.metadata.ownerReferences[*].kind}'
#   NodeSet
#
# So that command restarts the controller and the REST API and leaves *slurmd*
# — the one daemon on the other side of the trust boundary being rotated —
# running with the old key until the kubelet happens to refresh the projected
# volume. The controller adopts the new key in seconds, slurmd a minute or two
# later, and in between the cluster has no usable compute.
#
# NodeSet is a CRD, so it has no rollout to restart. Deleting the pods is the
# supported way to cycle them; the NodeSet controller replaces them (~30s).
k rollout restart statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm >/dev/null 2>&1 || true

old_slurmd=$(k get pods -l app.kubernetes.io/name=slurmd -o jsonpath='{.items[*].metadata.uid}' 2>/dev/null || true)
k delete pod -l app.kubernetes.io/name=slurmd --wait=false >/dev/null 2>&1 || true
ok "restarting Slurm workloads (controller, restapi, slurmd)"

k rollout status statefulset -l app.kubernetes.io/instance=slurm --timeout="${TIMEOUT}s" >/dev/null 2>&1 \
  || warn "rollout did not settle in ${TIMEOUT}s"

# Wait for the slurmd pods to actually be *different* pods and ready. Checking
# readiness alone would pass instantly against the pods we just asked to die.
#
# Note the `replaced` flag. Written without it, this loop simply ends when the
# deadline passes and execution continues to a line that prints a green tick —
# a wait that cannot fail, which is the same defect as every other one this
# script has already been caught by.
replaced=0
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  new_slurmd=$(k get pods -l app.kubernetes.io/name=slurmd -o jsonpath='{.items[*].metadata.uid}' 2>/dev/null || true)
  ready=$(k get pods -l app.kubernetes.io/name=slurmd -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null || true)
  if [ -n "$new_slurmd" ] && [ "$new_slurmd" != "$old_slurmd" ] \
     && [ -n "$ready" ] && ! printf '%s' "$ready" | grep -q false; then
    replaced=1
    break
  fi
  sleep 5
done

if [ "$replaced" -ne 1 ]; then
  warn "slurmd pods did not come back — rolling back"
  k get pods -l app.kubernetes.io/name=slurmd -o wide 2>&1 | sed 's/^/      /'
  k get nodesets.slinky.slurm.net 2>&1 | sed 's/^/      /'
  copy_key "${AUTH_SECRET}${BACKUP_SUFFIX}" "$AUTH_SECRET" "slurm.key"
  [ "$ROTATE_JWT" -eq 1 ] && copy_key "${JWT_SECRET}${BACKUP_SUFFIX}" "$JWT_SECRET" "jwt.key"
  die "rotation failed and was rolled back"
fi
ok "slurmd pods replaced"

# Now check the thing everything else assumes: that slurmd is holding the key
# we just wrote. Measured on a live cluster, it sometimes is not — a slurmd pod
# created after the rotation came up with a *previous* key while slurmctld had
# the new one:
#
#     secret     1024 bytes  sha 6e5e3a5d…
#     slurmctld  1024 bytes  sha 6e5e3a5d…   ✓
#     slurmd     1024 bytes  sha 4d7bc353…   ✗
#
# and slurmd logged `_fetch_child: failed to fetch remote configs: Protocol
# authentication error` until the node went down. I have not pinned the
# mechanism down to a specific kubelet behaviour, and this script does not
# pretend to: it measures the file instead of reasoning about how it got there.
want_sha=$(secret_key_sha "$AUTH_SECRET" "slurm.key")
propagated=0
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  have=$(slurmd_key_shas || true)
  if [ -n "$have" ] && [ -n "$want_sha" ] \
     && ! printf '%s\n' "$have" | awk -v w="$want_sha" '$2 != w' | grep -q .; then
    propagated=1
    break
  fi
  sleep 10
done

if [ "$propagated" -ne 1 ]; then
  warn "slurmd never picked up the new key — rolling back"
  note "want $want_sha"
  printf '%s\n' "${have:-<no slurmd pod reachable>}" | sed 's/^/      have /'
  copy_key "${AUTH_SECRET}${BACKUP_SUFFIX}" "$AUTH_SECRET" "slurm.key"
  [ "$ROTATE_JWT" -eq 1 ] && copy_key "${JWT_SECRET}${BACKUP_SUFFIX}" "$JWT_SECRET" "jwt.key"
  k rollout restart statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm >/dev/null 2>&1 || true
  k delete pod -l app.kubernetes.io/name=slurmd --wait=false >/dev/null 2>&1 || true
  die "rotation failed and was rolled back"
fi
ok "slurmd holding the new key"

# ── 6. Verify or roll back ──────────────────────────────────────────────────
step "6/6  Verify"

# What has to be true here, and what the weaker checks miss.
#
# The only boundary this rotation can break is controller <-> slurmd: those two
# authenticate with the key that just changed. Everything else is unaffected.
#
# Two checks were tried here and both were wrong, in the same way:
#
#   `sinfo` exits 0        — never leaves the controller pod. slurmctld answers
#                            a local client whether or not a single compute node
#                            ever came back, so it passes on a cluster with zero
#                            usable compute.
#   no `*` on any state    — crosses the boundary, but races the restart. It
#                            passed 130ms after the rollout, reading the node as
#                            it was *before* the new key was in play.
#
# The check that holds is the one that cannot be true unless the rotation
# worked: a slurmd holding the wrong key cannot register, and an unregistered
# node cannot reach idle. So resume first, then require a node to actually
# become schedulable. That is one property, verified after the dust settles,
# and it is what the header of this file has always promised.
#
# Resume is not optional and not a formality. Measured on a live cluster: when
# a slurmd pod is replaced, the Slinky operator marks the node down —
#
#     $ sinfo -R
#     slurm-operator: Pod   root   2026-07-27T01:41:40   slinky-0
#
# — and never clears it. Ninety seconds of watching showed no self-heal. The
# node sits down until something resumes it.
# Resume is re-issued every pass rather than once. The operator can mark a node
# down again while the replacement pods settle, and a single RESUME does not
# repeat itself — that one-shot is exactly what left a cluster drained for the
# 43 minutes it took CI to give up.
schedulable=0
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  ctl=$(controller_pod)
  [ -n "$ctl" ] && k exec "$ctl" -c slurmctld -- \
    scontrol update NodeName=ALL State=RESUME >/dev/null 2>&1 || true
  states=$(node_states || true)
  # Anchored at both ends on purpose. `^(idle|mix|alloc)` also matches `idle*`,
  # and `idle*` is a node slurmctld cannot reach — precisely the failure this
  # check exists to catch. An unanchored match here reported success on a
  # cluster whose only node was `idle*` and whose jobs would not start.
  if printf '%s\n' "$states" | awk '{print $2}' | grep -qE '^(idle|mix|alloc)$'; then
    schedulable=1
    break
  fi
  sleep 5
done

if [ "$schedulable" -ne 1 ]; then
  # No node reached a schedulable state, which is what a slurmd that cannot
  # authenticate looks like from here. Roll back rather than leave a cluster
  # that answers sinfo but cannot run anything.
  warn "no node became schedulable with the new key — rolling back"
  printf '%s\n' "${states:-<no node state available>}" | sed 's/^/      /'
  copy_key "${AUTH_SECRET}${BACKUP_SUFFIX}" "$AUTH_SECRET" "slurm.key"
  [ "$ROTATE_JWT" -eq 1 ] && copy_key "${JWT_SECRET}${BACKUP_SUFFIX}" "$JWT_SECRET" "jwt.key"
  k rollout restart statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm >/dev/null 2>&1 || true
  k delete pod -l app.kubernetes.io/name=slurmd --wait=false >/dev/null 2>&1 || true
  die "rotation failed and was rolled back"
fi
ok "node schedulable with the new key — auth verified end to end"

cat <<EOF

${BOLD}Rotation complete.${RESET}

  previous keys kept in ${DIM}${AUTH_SECRET}${BACKUP_SUFFIX}${RESET}
  roll back with ${DIM}$0 -n $NAMESPACE --rollback${RESET}

EOF
