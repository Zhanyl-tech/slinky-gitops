#!/usr/bin/env bash
#
# rotate-auth-key.sh — rotate Slurm's shared auth key on a Slinky cluster,
# verify it by measurement, and roll back when it does not take.
#
# ── What is being rotated ────────────────────────────────────────────────────
#
# Slinky deploys Slurm with auth/slurm, Slurm's own credential plugin (added
# in 23.11), rather than MUNGE. Verified against Slinky v1.2 / Slurm 26.05:
#
#     AuthType=auth/slurm
#     CredType=cred/slurm
#     AuthAltTypes=auth/jwt
#     $ pgrep munged   ->   nothing
#
# so there is no munged to restart. The keys are two Kubernetes Secrets:
#
#     slurm-auth-slurm   key: slurm.key   the shared cluster auth key
#     slurm-auth-jwt     key: jwt.key     signs REST/scrontab tokens
#
# ── Why this is a drain-everything rotation ──────────────────────────────────
#
# Slurm itself can rotate auth/slurm keys without restarting the whole
# cluster: since 24.05 a slurm.jwks file can hold several keys (each with a
# `kid`, one marked `"use": "default"`, optionally an `exp`), and "an scontrol
# reconfigure is sufficient" to move to a new one
# (https://slurm.schedmd.com/authentication.html). Slinky's own architecture
# doc names slurm.jwks as the rotation mechanism.
#
# Slinky v1.2 gives no way to ship that file, though. The operator projects
# exactly one key, Controller.spec.slurmKeyRef, as /etc/slurm/slurm.key into
# every Slurm pod (internal/builder/*/*_app.go at v1.2.0), and its admission
# webhook rejects any change to slurmKeyRef after deployment. With one key
# there is no overlap: between writing the new key and every daemon reading
# it, some daemons hold the old key and some the new, and the two sets cannot
# authenticate to each other. So this script uses the single-key method:
#
#   1. Refuse to start unless the cluster is healthy and every Slurm node it
#      would touch is in service (--allow-degraded to proceed anyway).
#   2. Drain those nodes, and wait until no job is running.
#   3. Back up the current key, and stage the new one, before the live Secret
#      is ever deleted.
#   4. Restart every daemon that reads the key, measure the key each one
#      actually has, and roll back automatically if it did not take.
#
# ── Known limitation: the rotation does not currently succeed ────────────────
#
# On Slinky v1.2 / Slurm 26.05 the new key does not reach slurmd. Reproduced
# on a clean KinD cluster: with the Secret holding a new key and stable for
# five minutes, a slurmd pod deleted and recreated from scratch came up
# mounting the *previous* key.
#
#     secret                       sha c5016281…
#     slurmd pod created 02:28:25  sha 8cbda076…   (the pre-rotation key)
#
# Slinky ships the auth Secret `immutable: true`, so its data cannot be
# patched and delete-and-recreate is the only route. The best explanation so
# far is the kubelet's per-node Secret cache: once a kubelet has read an
# object as immutable it stops watching it, and it only forgets the object
# when no pod on that node references that name any more
# (pkg/kubelet/util/manager/watch_based_manager.go, Get /
# restartReflectorIfNeeded / DeleteReference, at v1.32.2). A new slurmd pod on
# a node where another pod still mounts slurm-auth-slurm would then be served
# the cached old bytes. That fits both observations in the README (a mutable
# *replacement* behaves the same; a node that never cached the Secret gets the
# new key), but it is a hypothesis from reading the code, not something this
# repo has reproduced in isolation. See README "The part I could not fix".
#
# So the script's first job is to *not lie about it*: it measures the key on
# disk inside every slurmd pod and in slurmctld, and when any of them does not
# match the Secret it restores the previous key, verifies that, and exits 3.
# Reporting success would leave a cluster that answers `sinfo` and cannot run
# a job.
#
# Rotating jwt.key (--jwt) additionally invalidates every outstanding REST
# token; that is intended on a credential rotation, but it will page whoever
# automated against the API, so it is opt-in.
#
# Run with --help for usage and exit codes.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/lib"
# shellcheck source=scripts/lib/nodes.sh
. "$LIB/nodes.sh"

NAMESPACE="slurm"
AUTH_SECRET="slurm-auth-slurm"
JWT_SECRET="slurm-auth-jwt"
BACKUP_SUFFIX="-previous"
STAGING_SUFFIX="-next"
MODE="rotate"
ROTATE_JWT=0
DRY_RUN=0
ALLOW_DEGRADED=0
TIMEOUT=300
PYTHON="${PYTHON:-python3}"

# Exit codes are part of the interface: CI asserts on 3, and a caller can tell
# "nothing changed" from "rolled back" from "look at this now".
EXIT_FAIL=1          # refused or aborted; the key in use is the one you started with
EXIT_USAGE=2
EXIT_ROLLED_BACK=3   # new key did not take; previous key restored and verified
EXIT_ATTENTION=4     # the cluster could not be verified as consistent afterwards

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
step() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
indent() { sed 's/^/      /'; }
# die MESSAGE [EXIT_CODE]
die()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1" >&2; exit "${2:-$EXIT_FAIL}"; }

usage() {
  cat <<'EOF'
Usage:
  rotate-auth-key.sh [-n NAMESPACE] [--jwt] [--dry-run] [--timeout SECONDS] [--allow-degraded]
  rotate-auth-key.sh [-n NAMESPACE] --rollback [--jwt] [--dry-run] [--timeout SECONDS] [--allow-degraded]
  rotate-auth-key.sh [-n NAMESPACE] --cleanup

Rotate Slurm's auth/slurm key (slurm.key, and jwt.key with --jwt) on a Slinky
cluster. Drains the Slurm nodes that are in service, waits for jobs to finish,
backs up the current key, restarts every daemon that reads it, measures the
key each daemon actually holds, and rolls back automatically if the new key
did not take.

Options:
  -n, --namespace NS   namespace of the Slurm cluster (default: slurm)
      --jwt            also rotate jwt.key; invalidates every outstanding REST token.
                       With --rollback: restore jwt.key even if the backup does not
                       record that the last rotation changed it.
      --dry-run        run the preflight checks and print the plan; change nothing
      --rollback       restore the key(s) the last rotation changed, cycle slurmd,
                       and verify the cluster is back on them
      --cleanup        delete the backup and staging Secrets this script created
                       (refuses while a live auth Secret is missing)
      --timeout SECS   bound for each wait: jobs draining, pods returning, keys
                       matching, nodes resuming (default: 300)
      --allow-degraded proceed although some Slurm nodes are already drained, down,
                       failed or not responding. Those nodes are never drained by
                       this script. Replacing their slurmd pod overwrites their
                       reason: a drain reason is put back, and a node that had
                       none (or only Slurm's "Not responding") is resumed once so
                       the replacement does not leave it DOWN. A node in any other
                       out-of-service state (resv, maint, powered down, ...) could
                       still be given a job that the pod replacement would kill,
                       so it is refused even with this flag: drain it first.
  -h, --help           show this help

Environment:
  PYTHON               interpreter for scripts/lib/authkey.py (default: python3)

Exit status:
  0  done and verified (or --dry-run, --cleanup, --help)
  1  refused or aborted; the key in use is the one you started with
  2  usage error
  3  the new key did not take; the previous key was restored and verified
  4  the cluster could not be verified as consistent afterwards; read the output.
     Also used when a node this run drained was drained by someone else during
     the run: it is left drained and was not verified.
EOF
}
usage_error() { printf 'rotate-auth-key.sh: %s\n\n' "$1" >&2; usage >&2; exit "$EXIT_USAGE"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace|--timeout)
      if [ $# -lt 2 ] || [ -z "$2" ]; then usage_error "$1 needs a value"; fi
      case "$2" in -*) usage_error "$1 needs a value, got '$2'" ;; esac
      if [ "$1" = "--timeout" ]; then TIMEOUT="$2"; else NAMESPACE="$2"; fi
      shift 2 ;;
    --jwt)            ROTATE_JWT=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --allow-degraded) ALLOW_DEGRADED=1; shift ;;
    --rollback|--cleanup)
      [ "$MODE" = "rotate" ] || usage_error "--rollback and --cleanup are separate runs"
      MODE="${1#--}"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage_error "unknown flag: $1" ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) usage_error "--timeout must be a whole number of seconds" ;; esac
[ "$TIMEOUT" -gt 0 ] || usage_error "--timeout must be greater than zero"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v "$PYTHON" >/dev/null 2>&1 \
  || die "$PYTHON not found; it builds Secret manifests so key material never goes on a command line (set PYTHON to override)"

k()  { kubectl --namespace "$NAMESPACE" "$@"; }
py() { "$PYTHON" "$LIB/authkey.py" "$@"; }
now() { date +%s; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
# The drain reason this run sets. Distinct per run so the resume step can tell
# a node this run drained from one a health check drained while it was going.
# Deliberately not prefixed "slurm-operator: ": the operator treats reasons
# without its prefix as set externally and leaves them alone
# (IsNodeReasonOurs in internal/controller/nodeset/slurmcontrol at v1.2.0).
DRAIN_REASON="rotate-auth-key $RUN_ID"
# What the slurmd container's preStop hook sets on every pod replacement:
# `scontrol update nodename=$(hostname) state=down reason='slurm-operator: Pod
# is terminating'` (internal/builder/workerbuilder/worker_app.go at v1.2.0).
# Matched exactly: the operator sets other "slurm-operator: " reasons too
# (a cordoned Kubernetes node, propagated node conditions), and those are its
# drains, not the residue of a pod replacement.
PRESTOP_REASON="slurm-operator: Pod is terminating"
# The one other reason a pod replacement leaves behind, written by the
# operator rather than the pod. The operator counts a node whose reason is
# empty or carries its prefix as its own (IsNodeReasonOurs), and the preStop
# reason carries that prefix, so when the new pod is not cordoned it undrains
# the node with reason "slurm-operator: Pod (<namespace>/<pod>) was
# uncordoned" (syncCordon, internal/controller/nodeset/nodeset_sync.go lines
# 456-563 at v1.2.0). Slurm's UNDRAIN clears only the DRAIN flag, so a node
# the preStop hook set DOWN stays DOWN until this run resumes it. See
# operator_undrained_ours for when that reason counts as this run's.

# ── State the exit trap reads ────────────────────────────────────────────────
OUR_NODES=""            # nodes this run drained and still holds: the only ones it resumes
DRAINED_NODES=""        # nodes this run's drain step drained (never shrinks)
REPLACED_PODS=""        # "namespace/pod<TAB>Slurm node" of slurmd pods this run replaced, and their replacements
LEFT_ALONE=""           # "name<TAB>state<TAB>reason" of nodes not in service at start
EXTERNAL_DRAINS=""      # "name<TAB>state<TAB>reason" of nodes of ours someone else drained mid-run
START_SHAS=""           # "SECRET SHA" of each live key at preflight, for the exit-1 promise
EXPECTED_SLURMD=0       # slurmd pods at preflight; every one must be measured
DRAIN_ACTIVE=0          # 1 while OUR_NODES are drained and not yet verified back
PODS_CYCLED=0           # 1 once slurmd pods were deleted (their preStop rewrites reasons)
PREDRAINS_RESTORED=0
LIVE_AT_RISK=""         # a live Secret that is deleted and not yet recreated
ORIG_AUTH=""; ORIG_JWT=""   # live Secrets as read at start (cleaned manifests)
KEYS=""                 # "SECRET KEY" pairs this run changes (rotate) or restores (rollback)
VERIFY_FAIL=""
KEYS_VERIFIED=0         # 1 when exit 4 is only about nodes handed over to someone else's drain
TRAP_ARMED=0

orig_of() {
  case "$1" in
    "$AUTH_SECRET") printf '%s' "$ORIG_AUTH" ;;
    "$JWT_SECRET")  printf '%s' "$ORIG_JWT" ;;
  esac
}
set_orig() {
  case "$1" in
    "$AUTH_SECRET") ORIG_AUTH="$2" ;;
    "$JWT_SECRET")  ORIG_JWT="$2" ;;
  esac
}

# ── Cluster queries ──────────────────────────────────────────────────────────

# Never fails: an empty answer is handled by the caller. Written so that a
# kubectl error cannot trip `set -e` inside a command substitution and end
# the script without a word.
controller_pod() {
  { k get pods -l app.kubernetes.io/component=controller -o name 2>/dev/null || true; } | head -1
}

ctl_exec() {
  local c; c=$(controller_pod)
  [ -n "$c" ] || return 1
  k exec "$c" -c slurmctld -- "$@"
}

# Normalised node table (see lib/nodes.sh). Non-zero if slurmctld did not answer.
node_table() {
  local raw
  raw=$(ctl_exec sinfo -N --noheader -o '%N %t %E' 2>/dev/null) || return 1
  printf '%s\n' "$raw" | nodes_normalise
}

# Jobs whose processes live on a slurmd: running, completing (epilogs, e.g. a
# GPU health check, still running) or suspended. Prints the count; non-zero
# when squeue itself failed, because "could not ask" is not "zero jobs".
count_jobs() {
  local out
  out=$(ctl_exec squeue --noheader --states=RUNNING,COMPLETING,SUSPENDED 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk 'NF' | wc -l | tr -d ' '
}

secret_json() { k get secret "$1" -o json 2>/dev/null; }
secret_exists() { k get secret "$1" >/dev/null 2>&1; }

# sha256 of KEY in Secret NAME, or empty if the Secret or key is missing.
secret_sha() {
  local j
  j=$(secret_json "$1") || return 0
  printf '%s' "$j" | py sha "$2" 2>/dev/null || true
}

# sha256 of a file inside a container, or non-zero if it could not be read.
file_sha_in() {
  local s
  s=$(k exec "$1" -c "$2" -- sha256sum "$3" 2>/dev/null | awk 'NR == 1 { print $1 }') || return 1
  case "$s" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#s}" -eq 64 ] && printf '%s\n' "$s" ;;
    *) return 1 ;;
  esac
}

# "pod sha" for every slurmd pod; a pod that cannot be read prints
# "<unreadable>" and makes the whole measurement fail. An earlier version
# dropped such pods silently, so one reachable pod with the right key
# certified a fleet whose other pods were never looked at.
measure_slurmd() {
  local pods p s n=0 bad=0
  pods=$(k get pods -l app.kubernetes.io/name=slurmd -o name 2>/dev/null) || return 1
  for p in $pods; do
    n=$((n + 1))
    if s=$(file_sha_in "$p" slurmd /etc/slurm/slurm.key); then
      printf '%s %s\n' "$p" "$s"
    else
      printf '%s %s\n' "$p" "<unreadable>"; bad=1
    fi
  done
  [ "$n" -gt 0 ] && [ "$n" -ge "$EXPECTED_SLURMD" ] && [ "$bad" -eq 0 ]
}

# wait_slurmd_key WANT: every slurmd pod, and no fewer than there were, holds WANT.
wait_slurmd_key() {
  local want="$1" deadline have=""
  deadline=$(( $(now) + TIMEOUT ))
  while [ "$(now)" -lt "$deadline" ]; do
    if have=$(measure_slurmd) && [ -n "$want" ] \
       && ! printf '%s\n' "$have" | awk -v w="$want" '$2 != w' | grep -q .; then
      return 0
    fi
    sleep 10
  done
  note "want $want  (expected $EXPECTED_SLURMD slurmd pod(s))"
  printf '%s\n' "${have:-<no slurmd pod reachable>}" | sed 's/^/      have /'
  return 1
}

# wait_ctld_file PATH WANT: slurmctld's copy of PATH hashes to WANT.
wait_ctld_file() {
  local path="$1" want="$2" deadline have="" c
  deadline=$(( $(now) + TIMEOUT ))
  while [ "$(now)" -lt "$deadline" ]; do
    c=$(controller_pod)
    if [ -n "$c" ] && have=$(file_sha_in "$c" slurmctld "$path") && [ "$have" = "$want" ]; then
      return 0
    fi
    sleep 5
  done
  note "want $want"
  note "have ${have:-<slurmctld not reachable>}  ($path in slurmctld)"
  return 1
}

# Any path that restarts the controller must wait for it before touching it.
# Without this, the next `kubectl exec` races the restart and dies with
#   error: ... unable to upgrade connection: container not found ("slurmctld")
# which reads like a broken cluster and is really just an impatient script.
wait_controller_ready() {
  k wait --for=condition=ready pod \
    -l app.kubernetes.io/component=controller --timeout="${TIMEOUT}s" >/dev/null 2>&1
}

# ── Node drain and resume, scoped to the nodes this run drained ──────────────

# reason_is_ours NODE REASON STATE: could this run have set REASON on NODE, a
# node it drained, now in sinfo state STATE? Before any slurmd pod is
# replaced, only its own drain tag. After a replacement, also the preStop
# reason, what Slurm itself records for a node whose slurmd has not come back
# yet ("Not responding", or no reason on a node such as `idle*`), and the
# operator's undrain that follows the preStop reason (operator_undrained_ours).
#
# Anything else was set by someone else -- an epilog health check draining a
# node with `scontrol update State=DRAIN`, which replaces the reason, or the
# operator's own drain of a cordoned Kubernetes node ("slurm-operator: Node
# (...) was cordoned, ...") or of a cordoned pod ("slurm-operator: Pod (...)
# was cordoned"). An earlier version accepted every
# "slurm-operator: " reason and judged only the *current* reason, so a node
# drained for a GPU fault during the drain wait was resumed as soon as the
# pod replacement had rewritten its reason, and resumed unconditionally when
# the run stopped before the replacement.
reason_is_ours() {
  [ "$2" = "$DRAIN_REASON" ] && return 0
  [ "$PODS_CYCLED" -eq 1 ] || return 1
  case "$2" in
    ""|"$PRESTOP_REASON"|"Not responding") return 0 ;;
  esac
  operator_undrained_ours "$1" "$2" "${3:-}"
}

# operator_undrained_ours NODE REASON STATE: REASON is the operator's undrain
# of NODE after this run replaced its slurmd pod. All of these must hold:
#   - NODE is one this run's drain step drained (DRAINED_NODES);
#   - REASON is exactly "slurm-operator: Pod (<namespace>/<pod>) was
#     uncordoned" -- compared as a whole string, never as a pattern, so a
#     reason with anything before or after it does not count;
#   - <namespace>/<pod> is a slurmd pod on NODE that this run replaced, or
#     the pod that replaced it (REPLACED_PODS: the operator names the pod it
#     is reconciling, which in DaemonSet mode has a new name);
#   - NODE does not show the DRAIN flag: STATE is known (empty counts as
#     drained) and is not drain or drng (with any suffix), nor boot (a
#     pending reboot, which this run never requests, hides the flag in
#     sinfo's compact state).
# The operator writes that reason only on a node whose reason is empty or
# carries its prefix (IsNodeReasonOurs), which after this run's drain means
# the preStop reason of this run's replacement (or one of its own cordon
# reasons being lifted), and the UNDRAIN that writes it clears the DRAIN
# flag. (Not on a node Slurm marks INVALID_REG, shown as `inval`: Slurm
# writes the reason and refuses the UNDRAIN, and it refuses RESUME there too.)
# The flag coming back means someone drained the node again, and in v1.2.0
# the operator's own cordon drains (a cordoned Kubernetes node, the
# pod-cordon annotation) keep a reason the node already has (MakeNodeDrain
# with overrideReason false), so their drain arrives under this very reason.
# Every other reason stays someone else's, including "Pod (...) was
# cordoned" and "Node (...) was cordoned, ...", which the operator writes
# only on a node that had no reason.
operator_undrained_ours() {
  local node="$1" reason="$2" state="${3:-}" pod n
  [ -n "$node" ] || return 1
  case "$state" in ""|drain*|drng*|boot*) return 1 ;; esac
  printf '%s\n' "$DRAINED_NODES" | grep -qxF -- "$node" || return 1
  while IFS=$'\t' read -r pod n; do
    { [ -n "$pod" ] && [ "$n" = "$node" ]; } || continue
    [ "$reason" = "slurm-operator: Pod ($pod) was uncordoned" ] && return 0
  done <<EOF
$REPLACED_PODS
EOF
  return 1
}

csv() { printf '%s\n' "$1" | awk 'NF' | paste -sd, -; }

# hand_over NAME STATE REASON: someone else drained NAME, a node this run
# drained, during the run. It is theirs from now on: removed from OUR_NODES,
# so no path of this script resumes it again, and recorded in EXTERNAL_DRAINS
# so restore_predrains puts that drain back whenever a pod replacement
# overwrites it. It is also no longer verified, which is why a run that hands
# a node over does not exit 0.
hand_over() {
  local n="$1"
  OUR_NODES=$(printf '%s\n' "$OUR_NODES" | awk -v n="$n" 'NF && $1 != n')
  EXTERNAL_DRAINS=$(printf '%s\n' "$EXTERNAL_DRAINS" | awk -F '\t' -v n="$n" 'NF && $1 != n')
  EXTERNAL_DRAINS="$EXTERNAL_DRAINS"$'\n'"$n"$'\t'"$2"$'\t'"$3"
  warn "$n was drained by someone else during the run (${3:-no reason}); left drained, never resumed by this run"
}

# Re-read, just before the slurmd pods are replaced, which of OUR_NODES this
# run still holds, and hand over the rest. The replacement's preStop hook
# overwrites every node's reason with its own, so this is the last moment a
# drain someone else set during the run can be told apart from ours -- and
# the drain wait, when jobs end and their epilogs run health checks, is
# exactly when such drains happen. Retries while slurmctld restarts (the
# operator rolls it as soon as the key Secret changes).
claim_before_cycle() {
  local deadline tbl n st reason
  deadline=$(( $(now) + TIMEOUT ))
  until tbl=$(node_table); do
    [ "$(now)" -lt "$deadline" ] || { warn "slurmctld did not answer sinfo for ${TIMEOUT}s"; return 1; }
    sleep 5
  done
  for n in $OUR_NODES; do
    st=$(printf '%s\n' "$tbl" | node_field "$n" 2)
    reason=$(printf '%s\n' "$tbl" | node_field "$n" 3)
    reason_is_ours "$n" "$reason" "$st" && continue
    if printf '%s\n' "$st" | grep -qE "$IN_SERVICE_RE"; then
      # Not drained any more: someone resumed it. Nothing of theirs to
      # preserve, and its pod is replaced regardless, so it stays in the set
      # this run returns to service.
      warn "$n was returned to service by someone else during the run; its slurmd pod is replaced anyway (a job that started there is killed), and it is resumed afterwards"
      continue
    fi
    hand_over "$n" "${st:-missing}" "$reason"
  done
}

# Resume until every node this run still holds is genuinely schedulable,
# re-issuing every pass.
#
# One RESUME is not enough and never was. Replacing a slurmd pod runs its
# preStop hook (PRESTOP_REASON above), and nothing clears that, so a resume
# fired before the pod comes back is lost.
#
# Only nodes in OUR_NODES are ever resumed, and only while their reason is one
# this run could have set (reason_is_ours). An earlier version resumed
# NodeName=ALL, which put a node a GPU health check had drained back into
# service and erased why. A node of ours that someone else drains is handed
# over and never resumed again, whatever its reason later becomes; every pass
# also puts back the drains that are not ours. Every node still in OUR_NODES
# must come back: one good node is not evidence about the others, and when no
# node is left to verify against, that is a failure, not a pass.
UNSCHEDULABLE=""
resume_until_schedulable() {
  local deadline tbl n st reason pending
  deadline=$(( $(now) + ${1:-$TIMEOUT} ))
  while :; do
    pending=""
    if tbl=$(node_table); then
      for n in $OUR_NODES; do
        st=$(printf '%s\n' "$tbl" | node_field "$n" 2)
        if printf '%s\n' "$st" | grep -qE "$SCHEDULABLE_RE"; then continue; fi
        reason=$(printf '%s\n' "$tbl" | node_field "$n" 3)
        if reason_is_ours "$n" "$reason" "$st"; then
          pending="$pending$n (${st:-missing}${reason:+, $reason})"$'\n'
          ctl_exec scontrol update "NodeName=$n" State=RESUME >/dev/null 2>&1 || true
        else
          hand_over "$n" "$st" "$reason"
        fi
      done
      restore_predrains "$tbl" || true
      if [ -z "$(printf '%s\n' "$OUR_NODES" | awk 'NF')" ]; then
        UNSCHEDULABLE="no node this run drained is left to verify against (drained by someone else: $(printf '%s\n' "$EXTERNAL_DRAINS" | awk -F '\t' 'NF { printf "%s%s", sep, $1; sep = "," }'))"$'\n'
        return 1
      fi
      if [ -z "$pending" ]; then UNSCHEDULABLE=""; return 0; fi
    else
      pending="<slurmctld did not answer sinfo>"
    fi
    UNSCHEDULABLE="$pending"
    [ "$(now)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# After a pod replacement, put back what it did to nodes this run does not
# hold: those out of service before the run (LEFT_ALONE) and those someone
# else drained during it (EXTERNAL_DRAINS). Optional argument: a node table
# already read by the caller.
#
# - A drain reason the replacement overwrote is re-applied with DRAIN, the
#   fail-safe choice: it keeps the node out of service and restores the
#   evidence of why. Called right after every replacement and on every resume
#   pass, not only at the end, so no such node spends the verification window
#   under the preStop reason, which this script's own rules would treat as
#   resumable. Reasons the operator itself owns ("slurm-operator: ...") are
#   left to the operator, which reconciles them.
# - A node that had no drain to keep (no reason, or Slurm's own "Not
#   responding", e.g. `idle*`) is resumed once when the replacement has set it
#   DOWN with the preStop reason, which nothing else clears. That hands it
#   back to Slurm as it was: in service if its slurmd answers, not responding
#   again if not. It is not verified; it was not in service to begin with.
restore_predrains() {
  local tbl="${1:-}" name state reason cur failed=0 all
  all=$(printf '%s\n%s\n' "$LEFT_ALONE" "$EXTERNAL_DRAINS" | awk 'NF')
  [ -n "$all" ] || { PREDRAINS_RESTORED=1; return 0; }
  if [ -z "$tbl" ]; then
    tbl=$(node_table) || { warn "could not read node states to re-apply earlier drains"; return 1; }
  fi
  while IFS=$'\t' read -r name state reason; do
    [ -n "$name" ] || continue
    cur=$(printf '%s\n' "$tbl" | node_field "$name" 3)
    if { [ -z "$reason" ] || [ "$reason" = "Not responding" ]; } \
       && ! printf '%s\n' "$state" | grep -qE '^(drain|drng)'; then
      [ "$cur" = "$PRESTOP_REASON" ] || continue
      if ctl_exec scontrol update "NodeName=$name" State=RESUME >/dev/null 2>&1; then
        note "resumed $name once (was $state${reason:+, $reason}): replacing its slurmd pod had set it DOWN, and it had no drain to keep"
      else
        warn "could not resume $name, which replacing its slurmd pod set DOWN (was $state)"; failed=1
      fi
      continue
    fi
    [ -n "$reason" ] || continue
    case "$reason" in "slurm-operator: "*) continue ;; esac
    [ "$cur" = "$reason" ] && continue
    if ctl_exec scontrol update "NodeName=$name" State=DRAIN "Reason=$reason" >/dev/null 2>&1; then
      note "re-applied the earlier drain on $name (was $state): $reason"
    else
      warn "could not re-apply the earlier drain on $name: $reason"; failed=1
    fi
  done <<EOF
$all
EOF
  [ "$failed" -eq 0 ] && PREDRAINS_RESTORED=1
  [ "$failed" -eq 0 ]
}

# A node this run drained was handed over to someone else's drain. Say so and
# exit 4: the key was measured, but that node's registration was not.
exit_if_handed_over() {  # exit_if_handed_over WHAT
  [ -n "$EXTERNAL_DRAINS" ] || return 0
  printf '%s\n' "$EXTERNAL_DRAINS" | awk -F '\t' 'NF { printf "%s  %s  %s\n", $1, $2, ($3 == "" ? "(no reason)" : $3) }' | indent
  KEYS_VERIFIED=1   # the exit trap's generic "check the key, or --rollback" hint does not apply
  die "$1, but the node(s) above were drained by someone else during the run: they are left drained with that reason and were not verified on the key. Check them before resuming them." "$EXIT_ATTENTION"
}

# ── Secrets: never delete a live one before its replacement exists ───────────

create_json() { printf '%s' "$1" | k create -f - >/dev/null; }

# replace_live NAME MANIFEST KEY WANT_SHA
#
# Order, and why:
#   1. Park the replacement as NAME-next and read it back. From here on the
#      new bytes exist in the cluster, not only in this shell.
#   2. Delete the live Secret with --cascade=orphan. The chart's Secrets are
#      immutable, so delete-and-recreate is the only way to change them; and
#      in v1.2.0 the operator makes auth-token Secrets owned by the JWT key
#      Secret (BuildTokenSecret), so a default delete would garbage-collect
#      them along with it.
#   3. Recreate NAME from the full manifest (labels, annotations, type,
#      immutable all carried over) on stdin, retrying, and read it back.
#   4. Only then remove NAME-next.
# While NAME is missing, LIVE_AT_RISK tells the exit trap to put it back.
# Returns 0 on success, 1 if nothing changed, 2 if NAME is now wrong or missing.
replace_live() {
  local name="$1" manifest="$2" key="$3" want="$4" staging="${1}${STAGING_SUFFIX}" smanifest i
  smanifest=$(printf '%s' "$manifest" | py staging "$staging" "$RUN_ID") || return 1
  if secret_exists "$staging"; then
    k delete secret "$staging" >/dev/null 2>&1 || return 1   # left by an interrupted run
  fi
  create_json "$smanifest" || { warn "could not stage $staging"; return 1; }
  if [ "$(secret_sha "$staging" "$key")" != "$want" ]; then
    warn "$staging does not hold the intended key"; return 1
  fi

  if secret_exists "$name"; then
    LIVE_AT_RISK="$name"
    # --wait makes kubectl list and watch the Secret until it is gone (the
    # orphan finalizer keeps it briefly), which is why the Role in
    # docs/rbac-rotate-auth-key.yaml grants list/watch on secrets. Bounded:
    # with no --timeout, kubectl v1.32 waits up to a week (delete.go).
    k delete secret "$name" --cascade=orphan --wait=true --timeout="${TIMEOUT}s" >/dev/null 2>&1 || true
    if secret_exists "$name"; then LIVE_AT_RISK=""; warn "could not delete $name"; return 1; fi
  else
    LIVE_AT_RISK="$name"
  fi

  for i in 1 2 3 4 5; do
    if create_json "$manifest"; then break; fi
    warn "creating $name failed (attempt $i/5)"
    sleep 2
  done
  if [ "$(secret_sha "$name" "$key")" != "$want" ]; then
    return 2    # LIVE_AT_RISK stays set: the caller or the exit trap recovers
  fi
  LIVE_AT_RISK=""
  k delete secret "$staging" >/dev/null 2>&1 || warn "could not remove $staging (harmless; --cleanup removes it)"
  return 0
}

# Put NAME back if it is missing: first from the copy read at the start of
# this run, then from its backup. Returns non-zero if NAME is still missing.
recover_live() {
  local name="$1" orig bk m i
  secret_exists "$name" && return 0
  orig=$(orig_of "$name")
  if [ -n "$orig" ]; then
    for i in 1 2 3; do create_json "$orig" && break; sleep 2; done
  fi
  if ! secret_exists "$name" && bk=$(secret_json "${name}${BACKUP_SUFFIX}"); then
    if m=$(printf '{"live": null, "backup": %s}' "$bk" | py restore "$(key_of "$name")" "$name"); then
      create_json "$m" || true
    fi
  fi
  secret_exists "$name"
}

key_of() {
  case "$1" in
    "$AUTH_SECRET") printf 'slurm.key' ;;
    "$JWT_SECRET")  printf 'jwt.key' ;;
  esac
}

# restore_key NAME: make NAME hold its backup's key again.
restore_key() {
  local name="$1" key bk live m want rc=0
  key=$(key_of "$name")
  bk=$(secret_json "${name}${BACKUP_SUFFIX}") || { warn "no ${name}${BACKUP_SUFFIX} to restore from"; return 1; }
  live=$(secret_json "$name") || live="null"
  m=$(printf '{"live": %s, "backup": %s}' "$live" "$bk" | py restore "$key" "$name") || return 1
  want=$(printf '%s' "$bk" | py sha "$key")
  replace_live "$name" "$m" "$key" "$want" || rc=$?
  if [ "$rc" -eq 2 ]; then recover_live "$name" || true; fi
  [ "$rc" -eq 0 ]
}

# ── Pod cycle and verification ───────────────────────────────────────────────

slurmd_uids_ready() {
  k get pods -l app.kubernetes.io/name=slurmd \
    -o jsonpath='{range .items[*]}{.metadata.uid}{" "}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null
}

# record_replaced [SKIP_UIDS]: add "namespace/pod<TAB>Slurm node" of every
# slurmd pod, except those whose uid is in SKIP_UIDS, to REPLACED_PODS. The
# Slurm node is the one the operator writes that pod's reasons on
# (authkey.py slurmd-nodes). If the pods cannot be listed nothing is added,
# and an operator reason naming them then counts as someone else's: exit 4,
# as before this bookkeeping existed.
record_replaced() {
  local j pods
  if j=$(k get pods -l app.kubernetes.io/name=slurmd -o json 2>/dev/null) \
     && pods=$(printf '%s' "$j" | py slurmd-nodes 2>/dev/null); then
    pods=$(printf '%s\n' "$pods" | awk -F '\t' -v skip="$(printf '%s\n' "${1:-}" | tr '\n' ' ')" '
      BEGIN { n = split(skip, s, " "); for (i = 1; i <= n; i++) old[s[i]] = 1 }
      NF >= 3 && !($2 in old) { printf "%s\t%s\n", $1, $3 }')
    REPLACED_PODS=$(printf '%s\n%s\n' "$REPLACED_PODS" "$pods" | awk 'NF && !seen[$0]++')
  else
    warn "could not map the slurmd pods to their Slurm nodes; an operator reason naming one will be treated as someone else's"
  fi
}

# Restart every daemon that reads the key.
#
# `kubectl rollout restart` only understands built-in workload kinds. Checked
# against a live cluster:
#
#   $ kubectl -n slurm get statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm
#   statefulset.apps/slurm-controller
#   deployment.apps/slurm-restapi
#   $ kubectl -n slurm get pod slurm-worker-slinky-0 -o jsonpath='{.metadata.ownerReferences[*].kind}'
#   NodeSet
#
# so it restarts the controller and the REST API and leaves slurmd, the one
# daemon on the other side of the trust boundary being rotated, untouched.
# NodeSet is a CRD with no rollout to restart; deleting the pods is the
# supported way to cycle them, and the NodeSet controller replaces them.
cycle_slurm_pods() {
  local old deadline cur ready_all
  old=$(slurmd_uids_ready | awk 'NF { print $1 }') || old=""
  k rollout restart statefulset,deployment,daemonset -l app.kubernetes.io/instance=slurm >/dev/null 2>&1 \
    || warn "rollout restart of the controller and restapi failed"
  record_replaced   # the pods about to be deleted, for reason_is_ours
  k delete pod -l app.kubernetes.io/name=slurmd --wait=false >/dev/null 2>&1 \
    || { warn "could not delete the slurmd pods"; return 1; }
  # Every preStop hook has just rewritten its node's reason, including any
  # drain that was put back after an earlier replacement.
  PODS_CYCLED=1; PREDRAINS_RESTORED=0
  k rollout status statefulset -l app.kubernetes.io/instance=slurm --timeout="${TIMEOUT}s" >/dev/null 2>&1 \
    || warn "controller rollout did not settle in ${TIMEOUT}s"

  # Wait for every slurmd pod to be a *new* pod and ready. Readiness alone
  # would pass instantly against the pods just asked to die, and a loop that
  # simply ends at its deadline falls through to the next green tick: a wait
  # that cannot fail. Hence the explicit success condition.
  deadline=$(( $(now) + TIMEOUT ))
  while [ "$(now)" -lt "$deadline" ]; do
    cur=$(slurmd_uids_ready) || cur=""
    ready_all=$(printf '%s\n' "$cur" | awk -v old="$(printf '%s\n' "$old" | tr '\n' ' ')" -v want="$EXPECTED_SLURMD" '
      BEGIN { n = split(old, o, " "); for (i = 1; i <= n; i++) was[o[i]] = 1 }
      NF == 0 { next }
      { pods++; if ($1 in was) stale++; if (NF < 2 || $0 ~ /false/) notready++ }
      END { print (pods >= want && pods > 0 && !stale && !notready) ? "yes" : "no" }')
    if [ "$ready_all" = "yes" ]; then
      record_replaced "$old"   # and the pods that replaced them
      wait_controller_ready || warn "controller did not become ready in ${TIMEOUT}s"
      return 0
    fi
    sleep 5
  done
  { k get pods -o wide 2>&1 || true; } | indent   # diagnostics only; must not decide the exit
  return 1
}

# verify_keys WHICH: slurmd (every pod) and slurmctld hold the key(s) in the
# Secrets now. WHICH is "new" or "previous", for the messages.
#
# This is a direct measurement of the property the whole rotation depends on,
# rather than an inference from "we restarted the pods". The REST API pod
# also mounts slurm.key (restapi_app.go) but is not measured: whether its
# container user can read the 0600 projected file has not been checked.
verify_keys() {
  local which="$1" want
  want=$(secret_sha "$AUTH_SECRET" slurm.key)
  if ! wait_slurmd_key "$want"; then
    VERIFY_FAIL="slurmd never picked up the $which key"; return 1
  fi
  ok "every slurmd pod holds the $which slurm.key"
  if ! wait_ctld_file /etc/slurm/slurm.key "$want"; then
    VERIFY_FAIL="slurmctld never picked up the $which key"; return 1
  fi
  ok "slurmctld holds the $which slurm.key"
  if printf '%s\n' "$KEYS" | grep -q "^$JWT_SECRET "; then
    want=$(secret_sha "$JWT_SECRET" jwt.key)
    if ! wait_ctld_file /etc/slurm/jwt.key "$want"; then
      VERIFY_FAIL="slurmctld never picked up the $which jwt.key"; return 1
    fi
    ok "slurmctld holds the $which jwt.key"
  fi
  return 0
}

# settle WHICH: claim, cycle, measure, resume. Non-zero with VERIFY_FAIL set
# on failure.
settle() {
  local which="$1"
  VERIFY_FAIL=""
  if ! claim_before_cycle; then
    VERIFY_FAIL="could not read the node states before replacing the slurmd pods"; return 1
  fi
  if ! cycle_slurm_pods; then VERIFY_FAIL="slurmd pods did not come back"; return 1; fi
  ok "slurmd pods replaced; controller restarted"
  restore_predrains || warn "earlier drains not re-applied yet; retried while nodes resume"
  verify_keys "$which" || return 1
  if ! resume_until_schedulable "$TIMEOUT"; then
    VERIFY_FAIL="not every drained node returned to service on the $which key"
    printf '%s' "$UNSCHEDULABLE" | indent
    return 1
  fi
  ok "every node this run drained is schedulable again: $(csv "$OUR_NODES")"
  DRAIN_ACTIVE=0
  return 0
}

# The automatic rollback. Same routine as --rollback: restore, cycle, measure,
# resume. Exits 3 when the cluster is verified back on the previous key.
#
# `set -e` is in force here (this runs in the `then` branch of the caller's
# `if`), so nothing on the way to restore_key may be allowed to fail: an
# earlier version listed the pods as an unguarded pipeline, and one failed
# `kubectl get pods` (an API timeout) ended the script with exit 1 -- "the
# key in use is the one you started with" -- while the new key was live and
# slurmd held the old one.
rollback_after_failure() {
  local why="$1" s
  warn "$why — rolling back"
  # Placement matters for the kubelet-cache hypothesis. Diagnostics only.
  { k get pods -o wide 2>&1 || true; } | indent
  for s in $(printf '%s\n' "$KEYS" | awk '{ print $1 }'); do
    restore_key "$s" || die "could not restore $s from ${s}${BACKUP_SUFFIX}; the previous key is still in that Secret" "$EXIT_ATTENTION"
  done
  ok "previous key(s) restored in the Secret(s)"
  if settle previous && restore_predrains; then
    ok "cluster back to schedulable on the previous key"
    exit_if_handed_over "rotation failed ($why) and was rolled back"
    die "rotation failed and was rolled back ($why)" "$EXIT_ROLLED_BACK"
  fi
  die "rotation failed, and the rollback could not be verified: ${VERIFY_FAIL:-earlier drains not re-applied}" "$EXIT_ATTENTION"
}

# ── Exit trap ────────────────────────────────────────────────────────────────
#
# From the drain on, a failure must not leave the cluster drained, a live
# Secret missing, or an earlier drain reason overwritten. The trap repairs
# each of those it finds, says what it could not repair, and turns exit 1
# into 4 when "the key in use is the one you started with" is not measurably
# true any more.
# shellcheck disable=SC2329  # invoked by `trap on_exit EXIT` in arm_trap
on_exit() {
  local rc=$? s t tbl st reason
  set +e
  [ "$TRAP_ARMED" -eq 1 ] || exit "$rc"
  if [ -n "$LIVE_AT_RISK" ]; then
    warn "$LIVE_AT_RISK is missing — recreating it"
    if recover_live "$LIVE_AT_RISK"; then ok "$LIVE_AT_RISK recreated"; LIVE_AT_RISK=""
    else warn "$LIVE_AT_RISK could not be recreated; the key is in ${LIVE_AT_RISK}${BACKUP_SUFFIX} (and ${LIVE_AT_RISK}${STAGING_SUFFIX}). Run: $0 -n $NAMESPACE --rollback"
      [ "$rc" -eq 0 ] && rc=$EXIT_ATTENTION
    fi
  fi
  if [ "$DRAIN_ACTIVE" -eq 1 ]; then
    warn "stopped with nodes drained — resuming the nodes this run drained: $(csv "$OUR_NODES")"
    if [ "$PODS_CYCLED" -eq 1 ]; then
      # Bounded so an interrupted run still exits promptly.
      t=60; [ "$TIMEOUT" -lt "$t" ] && t=$TIMEOUT
      resume_until_schedulable "$t" || { warn "not schedulable yet:"; printf '%s' "$UNSCHEDULABLE" | indent; }
    elif tbl=$(node_table); then
      # No pod has been replaced, so a node this run still holds carries its
      # drain tag. Any other reason was set by someone else while the run
      # waited for jobs -- most likely an epilog health check, since that is
      # when jobs end -- and resuming it would put a faulty node back into
      # service with its reason erased. An earlier version resumed every
      # node here without looking.
      for s in $OUR_NODES; do
        st=$(printf '%s\n' "$tbl" | node_field "$s" 2)
        reason=$(printf '%s\n' "$tbl" | node_field "$s" 3)
        if [ "$reason" = "$DRAIN_REASON" ]; then
          ctl_exec scontrol update "NodeName=$s" State=RESUME >/dev/null 2>&1 \
            || { warn "could not resume $s"; { [ "$rc" -eq 0 ] || [ "$rc" -eq "$EXIT_FAIL" ]; } && rc=$EXIT_ATTENTION; }
        elif ! printf '%s\n' "$st" | grep -qE "$IN_SERVICE_RE"; then
          hand_over "$s" "${st:-missing}" "$reason"
        fi
      done
    else
      # Resuming blindly is what the check above exists to prevent.
      warn "could not read node states, so the drain was not lifted. Once slurmctld answers, resume those of $(csv "$OUR_NODES") whose reason is still: $DRAIN_REASON"
      { [ "$rc" -eq 0 ] || [ "$rc" -eq "$EXIT_FAIL" ]; } && rc=$EXIT_ATTENTION
    fi
  fi
  if [ "$PODS_CYCLED" -eq 1 ] && [ "$PREDRAINS_RESTORED" -eq 0 ]; then
    restore_predrains || true
  fi
  # Exit 1 promises the key in use is the one the run started with. Measure it
  # rather than assume it, so that an unexpected failure after the keys were
  # changed is never reported as "nothing changed".
  if [ "$rc" -eq "$EXIT_FAIL" ]; then
    while read -r s t; do
      [ -n "$s" ] || continue
      if [ "$(secret_sha "$s" "$(key_of "$s")")" != "$t" ]; then
        warn "$s no longer holds (or could not be read to confirm) the key this run started with"
        rc=$EXIT_ATTENTION
      fi
    done <<EOF
$START_SHAS
EOF
  fi
  if [ "$rc" -eq "$EXIT_ATTENTION" ] || [ "$rc" -ge 128 ]; then
    for s in "$AUTH_SECRET" "$JWT_SECRET"; do
      note "$s: $(secret_exists "$s" && echo present || echo MISSING)$(secret_exists "${s}${BACKUP_SUFFIX}" && echo ", backup ${s}${BACKUP_SUFFIX} present")"
    done
    [ "$KEYS_VERIFIED" -eq 1 ] \
      || note "if slurmd pods were replaced, check the key they hold, or run: $0 -n $NAMESPACE --rollback"
  fi
  exit "$rc"
}
arm_trap() {
  TRAP_ARMED=1
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# ── Cleanup mode ─────────────────────────────────────────────────────────────
if [ "$MODE" = "cleanup" ]; then
  step "Cleanup"
  for s in "$AUTH_SECRET" "$JWT_SECRET"; do
    for extra in "${s}${BACKUP_SUFFIX}" "${s}${STAGING_SUFFIX}"; do
      secret_exists "$extra" || continue
      # A backup is only disposable while the Secret it backs up exists;
      # otherwise it may hold the only copy of a key the cluster still uses.
      secret_exists "$s" \
        || die "refusing to delete $extra: $s is missing, so $extra may hold the only copy of a key. Run --rollback first."
      if [ "$DRY_RUN" -eq 1 ]; then note "would delete $extra"; continue; fi
      k delete secret "$extra" >/dev/null || die "could not delete $extra"
      ok "deleted $extra"
    done
  done
  ok "nothing else to clean up"
  exit 0
fi

# ── 1. Preflight ─────────────────────────────────────────────────────────────
step "1/6  Preflight"

ctl=$(controller_pod)
[ -n "$ctl" ] || die "no Slurm controller pod in $NAMESPACE"

# Confirm this cluster really is on auth/slurm. If a site is still on MUNGE,
# rotating these Secrets accomplishes nothing and the operator should know.
authtype=$(ctl_exec scontrol show config 2>/dev/null | awk -F'= *' '/^AuthType/ { print $2 }' | tr -d ' ') || authtype=""
case "$authtype" in
  auth/slurm) ok "AuthType=auth/slurm" ;;
  auth/munge) die "this cluster uses auth/munge; rotating $AUTH_SECRET would do nothing" ;;
  "")         die "could not read AuthType from slurmctld; a controller that cannot answer cannot verify a rotation either" ;;
  *)          die "unexpected AuthType=$authtype; this script only knows auth/slurm" ;;
esac

# Rotating on top of an existing fault turns one incident into two. A health
# query that fails is not a healthy answer, so every step here fails closed.
# stdout only: a kubectl warning on stderr must not end up inside the JSON.
if ! nodesets=$(k get nodesets.slinky.slurm.net -o json 2>/dev/null); then
  die "could not list NodeSets: $(k get nodesets.slinky.slurm.net 2>&1 | head -1)"
fi
if ! notready=$(printf '%s' "$nodesets" | py nodesets); then
  die "could not parse the NodeSet list"
fi
[ -z "$notready" ] || die "NodeSets not converged: $notready"
ok "NodeSets converged (desired = replicas = updated = ready)"

EXPECTED_SLURMD=$(k get pods -l app.kubernetes.io/name=slurmd -o name 2>/dev/null | awk 'NF' | wc -l | tr -d ' ') || EXPECTED_SLURMD=0
[ "$EXPECTED_SLURMD" -gt 0 ] || die "no slurmd pods in $NAMESPACE"

table=$(node_table) || die "could not read Slurm node states from slurmctld"
[ -n "$table" ] || die "slurmctld reports no nodes"
OUR_NODES=$(printf '%s\n' "$table" | nodes_in_state "$IN_SERVICE_RE")
LEFT_ALONE=$(printf '%s\n' "$table" | nodes_not_in_state "$IN_SERVICE_RE")
if [ "$MODE" = "rollback" ] && [ -n "$LEFT_ALONE" ]; then
  # A rollback is often run to repair what an earlier rotation left behind.
  # Nodes whose only problem is one a rotation causes (this script's drain
  # tag, the slurmd preStop reason, not responding) are taken back into the
  # set this run drains and must return to service; any other reason is
  # someone else's and is left alone.
  recovered=$(printf '%s\n' "$LEFT_ALONE" | awk -F '\t' -v p="$PRESTOP_REASON" 'NF && ($3 == "" || $3 == "Not responding" || $3 ~ /^rotate-auth-key / || $3 == p) { print $1 }')
  if [ -n "$recovered" ]; then
    note "taking back nodes an earlier rotation left out of service: $(csv "$recovered")"
    OUR_NODES=$(printf '%s\n%s\n' "$OUR_NODES" "$recovered" | awk 'NF')
    LEFT_ALONE=$(printf '%s\n' "$LEFT_ALONE" | awk -F '\t' -v r="$(printf '%s\n' "$recovered" | tr '\n' ' ')" '
      BEGIN { n = split(r, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
      NF && !($1 in skip)')
  fi
fi
if [ -n "$LEFT_ALONE" ]; then
  warn "Slurm nodes already out of service:"
  printf '%s\n' "$LEFT_ALONE" | awk -F '\t' '{ printf "%s  %s  %s\n", $1, $2, ($3 == "" ? "(no reason)" : $3) }' | indent
  [ "$ALLOW_DEGRADED" -eq 1 ] \
    || die "refusing to rotate on a degraded cluster. Fix those nodes, or pass --allow-degraded: they will not be drained by this script, and a drain reason overwritten by the pod replacement is put back."
  # Every slurmd pod is replaced, including those of the nodes left alone, so
  # each of them must be one Slurm will not start a job on. Otherwise a job
  # could land there after the drain wait counted zero and be killed by the
  # replacement, with nothing in the output to say so.
  busy=$(printf '%s\n' "$LEFT_ALONE" | nodes_not_in_state "$QUIESCED_RE" | awk -F '\t' 'NF { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
  [ -z "$busy" ] \
    || die "refusing even with --allow-degraded: Slurm can still start a job on $busy, and replacing its slurmd pod would kill that job. Drain it first (scontrol update NodeName=... State=DRAIN Reason=...), or return it to service."
fi
[ -n "$OUR_NODES" ] || die "no Slurm node is in service, so there is nothing to verify a new key against"
ok "$(printf '%s\n' "$OUR_NODES" | awk 'NF' | wc -l | tr -d ' ') node(s) in service, $EXPECTED_SLURMD slurmd pod(s)"

if [ "$MODE" = "rotate" ]; then
  wanted="$AUTH_SECRET"
  if [ "$ROTATE_JWT" -eq 1 ]; then wanted="$wanted $JWT_SECRET"; fi
  for s in $wanted; do
    if ! secret_exists "$s"; then
      if secret_exists "${s}${BACKUP_SUFFIX}"; then
        die "secret $s not found, but ${s}${BACKUP_SUFFIX} exists: an earlier run was interrupted. Run: $0 -n $NAMESPACE --rollback"
      fi
      die "secret $s not found in $NAMESPACE"
    fi
    KEYS="$KEYS$s $(key_of "$s")"$'\n'
  done
  ok "found $(printf '%s\n' "$KEYS" | awk 'NF { printf "%s%s", sep, $1; sep = ", " }')"
else
  bk=$(secret_json "${AUTH_SECRET}${BACKUP_SUFFIX}") \
    || die "no ${AUTH_SECRET}${BACKUP_SUFFIX} — nothing to roll back to"
  rotated=$(printf '%s' "$bk" | py annotation rotate-auth-key/rotated-keys)
  run=$(printf '%s' "$bk" | py annotation rotate-auth-key/run-id)
  KEYS="$AUTH_SECRET slurm.key"$'\n'
  # Restore jwt.key only if the rotation this backup belongs to changed it.
  # An earlier version restored any jwt backup it found, reverting jwt.key to
  # a key from an older rotation and invalidating every current REST token.
  jbk=""; jwt_same_run=0; jwt_recorded=0
  if jbk=$(secret_json "${JWT_SECRET}${BACKUP_SUFFIX}"); then
    if [ -n "$run" ] && [ "$(printf '%s' "$jbk" | py annotation rotate-auth-key/run-id)" = "$run" ]; then
      jwt_same_run=1
    fi
  else
    jbk=""
  fi
  case ",$rotated," in *,jwt.key,*) jwt_recorded=1 ;; esac
  if [ "$ROTATE_JWT" -eq 1 ] || { [ "$jwt_recorded" -eq 1 ] && [ "$jwt_same_run" -eq 1 ]; }; then
    [ -n "$jbk" ] || die "--jwt given but there is no ${JWT_SECRET}${BACKUP_SUFFIX}"
    KEYS="$KEYS$JWT_SECRET jwt.key"$'\n'
  elif [ -n "$jbk" ]; then
    note "leaving jwt.key alone: ${JWT_SECRET}${BACKUP_SUFFIX} is not recorded as part of the last rotation (use --jwt to restore it anyway)"
  fi
  ok "backup from run ${run:-<unrecorded: written by an older version>}"
fi
for s in $(printf '%s\n' "$KEYS" | awk '{ print $1 }'); do
  START_SHAS="$START_SHAS$s $(secret_sha "$s" "$(key_of "$s")")"$'\n'
done

# ── 2. Plan ──────────────────────────────────────────────────────────────────
step "2/6  Plan"
note "namespace       $NAMESPACE"
note "run id          $RUN_ID"
if [ "$MODE" = "rotate" ]; then
  note "rotating        $(printf '%s\n' "$KEYS" | awk 'NF { printf "%s%s", sep, $2; sep = " + " }')"
  note "backups         $(printf '%s\n' "$KEYS" | awk -v s="$BACKUP_SUFFIX" 'NF { printf "%s%s%s", sep, $1, s; sep = ", " }')"
else
  note "restoring       $(printf '%s\n' "$KEYS" | awk 'NF { printf "%s%s", sep, $2; sep = " + " }') from backup"
fi
note "will drain      $(csv "$OUR_NODES")  (reason: $DRAIN_REASON)"
if [ -n "$LEFT_ALONE" ]; then
  note "left alone      $(printf '%s\n' "$LEFT_ALONE" | awk -F '\t' 'NF { printf "%s%s", sep, $1; sep = ", " }')"
fi
if jobs_now=$(count_jobs); then
  note "running jobs    $jobs_now (the drain waits up to ${TIMEOUT}s for them)"
else
  note "running jobs    unknown (squeue did not answer)"
fi
if printf '%s\n' "$KEYS" | grep -q "^$JWT_SECRET "; then
  warn "changing jwt.key invalidates every outstanding REST token"
  # internal/controller/slurmclient/slurmclient_sync.go at v1.2.0 signs a
  # 15-minute token from jwt.key and refreshes it at 4/5 of that lifetime,
  # reconciling on RestApi objects rather than on the Secret.
  note "the slurm-operator's own REST token is refreshed every 12 minutes; until then its calls may be rejected (not measured)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  warn "dry run — stopping here"
  exit 0
fi

# ── 3. Drain ─────────────────────────────────────────────────────────────────
arm_trap
step "3/6  Drain"
DRAIN_ACTIVE=1
ctl_exec scontrol update "NodeName=$(csv "$OUR_NODES")" State=DRAIN "Reason=$DRAIN_REASON" >/dev/null 2>&1 \
  || die "scontrol could not drain $(csv "$OUR_NODES"); nothing was changed"
DRAINED_NODES="$OUR_NODES"
ok "drained $(csv "$OUR_NODES")"

# Replacing the slurmd pods kills whatever runs on them, so every job has to
# be gone first. `drained` is set only by an answer of zero; a timeout, or an
# squeue that did not answer, stops the run here with nothing changed (the
# exit trap lifts the drain). An earlier version fell out of this loop on the
# deadline and printed "no running jobs" regardless.
drained=0
deadline=$(( $(now) + TIMEOUT ))
while :; do
  if n=$(count_jobs); then
    if [ "$n" -eq 0 ]; then drained=1; break; fi
    note "waiting on $n job(s)…"
  else
    note "job count unknown (squeue did not answer); waiting…"
  fi
  [ "$(now)" -lt "$deadline" ] || break
  sleep 10
done
[ "$drained" -eq 1 ] \
  || die "jobs still running, or the job count could not be read, after ${TIMEOUT}s. Nothing was changed. Let them finish (or cancel them yourself) and run again; --timeout raises the wait."
ok "no running jobs"

if [ "$MODE" = "rotate" ]; then
  # ── 4. Back up and stage ───────────────────────────────────────────────────
  step "4/6  Back up current keys"
  rotated_list=$(printf '%s\n' "$KEYS" | awk 'NF { printf "%s%s", sep, $2; sep = "," }')
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for s in $(printf '%s\n' "$KEYS" | awk '{ print $1 }'); do
    key=$(key_of "$s")
    live=$(secret_json "$s") || die "could not read $s; nothing was changed"
    cleaned=$(printf '%s' "$live" | py clean) || die "could not read $s as a Secret; nothing was changed"
    set_orig "$s" "$cleaned"
    want=$(printf '%s' "$live" | py sha "$key")
    [ -n "$want" ] || die "$s has no $key; nothing was changed"
    manifest=$(printf '%s' "$live" | py backup "${s}${BACKUP_SUFFIX}" "$RUN_ID" "$created" "$rotated_list") \
      || die "could not build the backup of $s; nothing was changed"
    # The backup this replaces belongs to an earlier rotation; the live
    # Secret it would roll back to has just been read and is intact.
    if secret_exists "${s}${BACKUP_SUFFIX}"; then
      k delete secret "${s}${BACKUP_SUFFIX}" >/dev/null || die "could not replace the old ${s}${BACKUP_SUFFIX}; nothing was changed"
    fi
    create_json "$manifest" || die "could not create ${s}${BACKUP_SUFFIX}; nothing was changed"
    [ "$(secret_sha "${s}${BACKUP_SUFFIX}" "$key")" = "$want" ] \
      || die "${s}${BACKUP_SUFFIX} does not match $s; nothing was changed"
    ok "$key -> ${s}${BACKUP_SUFFIX} (immutable, sha ${want:0:8}…)"
  done

  # ── 5. Rotate ──────────────────────────────────────────────────────────────
  step "5/6  Rotate"
  done_keys=""
  for s in $(printf '%s\n' "$KEYS" | awk '{ print $1 }'); do
    key=$(key_of "$s")
    new=$(orig_of "$s" | py with-new-key "$key") || die "could not build the new $s"
    want=$(printf '%s' "$new" | py sha "$key")
    rc=0; replace_live "$s" "$new" "$key" "$want" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 2 ]; then
        recover_live "$s" || die "$s is missing and could not be recreated" "$EXIT_ATTENTION"
        LIVE_AT_RISK=""
      fi
      # Nothing has restarted yet, so putting back what was changed is enough.
      for d in $done_keys; do
        restore_key "$d" || die "could not put back $d" "$EXIT_ATTENTION"
      done
      if [ "$(secret_sha "$s" "$key")" != "$(orig_of "$s" | py sha "$key")" ]; then
        restore_key "$s" || die "could not put back $s" "$EXIT_ATTENTION"
      fi
      die "could not replace $s; the previous key(s) are in place and no daemon was restarted"
    fi
    done_keys="$done_keys $s"
    ok "$key rotated (sha ${want:0:8}…, immutable=$(k get secret "$s" -o jsonpath='{.immutable}' 2>/dev/null || true))"
  done

  # ── 6. Verify or roll back ─────────────────────────────────────────────────
  step "6/6  Restart and verify"
  # What has to be true here, and what the weaker checks missed.
  #
  # The boundary this rotation can break is controller <-> slurmd: those two
  # authenticate with the key that just changed. Two checks were tried and
  # both were wrong in the same way:
  #
  #   `sinfo` exits 0        — never leaves the controller pod; passes with
  #                            zero usable compute.
  #   no `*` on any state    — crosses the boundary, but raced the restart; it
  #                            passed 130ms after the rollout, reading the node
  #                            as it was before the new key was in play.
  #
  # What holds: the key file measured in every slurmd pod and in slurmctld,
  # then every drained node back to a schedulable state. A slurmd holding the
  # wrong key cannot register, and an unregistered node cannot reach idle.
  if ! settle new; then
    rollback_after_failure "$VERIFY_FAIL"
  fi
  restore_predrains || die "rotated and verified, but an earlier drain could not be re-applied (see above)" "$EXIT_ATTENTION"
  exit_if_handed_over "rotated: every slurmd pod and slurmctld hold the new key, and $(csv "$OUR_NODES") returned to service on it"

  cat <<EOF

${BOLD}Rotation complete.${RESET}

  previous keys kept in ${DIM}$(printf '%s\n' "$KEYS" | awk -v s="$BACKUP_SUFFIX" 'NF { printf "%s%s%s", sep, $1, s; sep = ", " }')${RESET}
  roll back with        ${DIM}$0 -n $NAMESPACE --rollback${RESET}
  delete the backups    ${DIM}$0 -n $NAMESPACE --cleanup${RESET}  (they hold the previous key)

EOF
  exit 0
fi

# ── Rollback mode: the same restore, cycle, measure, resume ──────────────────
step "4/6  Restore"
for s in $(printf '%s\n' "$KEYS" | awk '{ print $1 }'); do
  restore_key "$s" || die "could not restore $s; its backup is untouched" "$EXIT_ATTENTION"
  ok "restored $(key_of "$s") in $s"
done
step "5/6  Restart and verify"
if ! settle previous; then
  die "rollback could not be verified: $VERIFY_FAIL. The backups are kept." "$EXIT_ATTENTION"
fi
restore_predrains || die "restored and verified, but an earlier drain could not be re-applied (see above)" "$EXIT_ATTENTION"

# A verified restore consumes the backup: the live Secret now holds the same
# bytes, so the backup is a redundant copy of a live credential. It is only
# deleted when that is measurably true.
step "6/6  Retire the used backups"
for s in $(printf '%s\n' "$KEYS" | awk '{ print $1 }'); do
  key=$(key_of "$s")
  if [ "$(secret_sha "$s" "$key")" = "$(secret_sha "${s}${BACKUP_SUFFIX}" "$key")" ]; then
    if k delete secret "${s}${BACKUP_SUFFIX}" >/dev/null 2>&1; then
      ok "deleted ${s}${BACKUP_SUFFIX} (identical to the live key)"
    else
      warn "could not delete ${s}${BACKUP_SUFFIX}"
    fi
  else
    warn "kept ${s}${BACKUP_SUFFIX}: it does not match the live key"
  fi
done
exit_if_handed_over "restored: every slurmd pod and slurmctld hold the previous key, and $(csv "$OUR_NODES") returned to service on it"

printf '\n%sRollback complete.%s\n\n' "$BOLD" "$RESET"
exit 0
