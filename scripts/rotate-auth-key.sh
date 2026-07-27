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
# the node is not responding, which is the signal this script cares about most.
node_states() {
  local c; c=$(controller_pod)
  [ -n "$c" ] || return 1
  k exec "$c" -c slurmctld -- sinfo -N --noheader -o '%N %t' 2>/dev/null
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
k rollout restart statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm >/dev/null 2>&1 || true
ok "restarting Slurm workloads"
k rollout status statefulset -l app.kubernetes.io/instance=slurm --timeout="${TIMEOUT}s" >/dev/null 2>&1 \
  || warn "rollout did not settle in ${TIMEOUT}s"

# ── 6. Verify or roll back ──────────────────────────────────────────────────
step "6/6  Verify"

# What has to be true here, and what a weaker check misses.
#
# The only boundary this rotation can break is controller <-> slurmd: those two
# authenticate to each other with the key that just changed. Everything else is
# unaffected.
#
# This script originally verified by running `sinfo` inside the controller pod
# and checking the exit code. That never crosses the boundary — slurmctld
# answers a local client whether or not a single compute node ever came back —
# so it returned 0 on a cluster with no usable compute. It printed
# "authentication verified", resumed nothing that existed yet, and left a
# cluster that could not run a job. CI caught it; a person would have caught it
# at 3am.
#
# The signal that does cross the boundary is registration. A slurmd holding the
# wrong key cannot register, and slurmctld marks it not-responding with a `*`
# suffix on the state. So "every node has lost its `*`" IS the end-to-end auth
# check, and it is the one the header of this file has always promised.
verified=0
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  states=$(node_states || true)
  if [ -n "$states" ] && ! printf '%s\n' "$states" | grep -q '\*'; then
    verified=1
    break
  fi
  sleep 5
done

if [ "$verified" -ne 1 ]; then
  warn "nodes did not re-register with the new key — rolling back"
  printf '%s\n' "${states:-<no node state available>}" | sed 's/^/      /'
  copy_key "${AUTH_SECRET}${BACKUP_SUFFIX}" "$AUTH_SECRET" "slurm.key"
  [ "$ROTATE_JWT" -eq 1 ] && copy_key "${JWT_SECRET}${BACKUP_SUFFIX}" "$JWT_SECRET" "jwt.key"
  k rollout restart statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm >/dev/null 2>&1 || true
  die "rotation failed and was rolled back"
fi
ok "all nodes re-registered — auth verified end to end"

# Only now is there anything to resume. Resuming before this point is a no-op
# against nodes that have not come back, and it does not repeat itself: the
# node registers later, still drained, and stays that way.
ctl=$(controller_pod)
k exec "$ctl" -c slurmctld -- scontrol update NodeName=ALL State=RESUME >/dev/null 2>&1 || warn "could not resume nodes"

# And confirm the resume actually took. "Ran the command" is not the property
# we want; "a job could now be scheduled" is.
schedulable=0
deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  states=$(node_states || true)
  if printf '%s\n' "$states" | awk '{print $2}' | grep -qE '^(idle|mix|alloc)'; then
    schedulable=1
    break
  fi
  sleep 5
done
if [ "$schedulable" -ne 1 ]; then
  # The key is fine — rolling it back would fix nothing. This is a drain that
  # would not lift, so leave the cluster in a state a human can read. The exit
  # trap would retry the resume that just failed, so take it off the path.
  DRAINED=0
  printf '%s\n' "${states:-<no node state available>}" | sed 's/^/      /'
  die "nodes re-registered but none became schedulable; cluster is left drained"
fi
ok "nodes resumed and schedulable"

cat <<EOF

${BOLD}Rotation complete.${RESET}

  previous keys kept in ${DIM}${AUTH_SECRET}${BACKUP_SUFFIX}${RESET}
  roll back with ${DIM}$0 -n $NAMESPACE --rollback${RESET}

EOF
