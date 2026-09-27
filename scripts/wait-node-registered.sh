#!/usr/bin/env bash
#
# wait-node-registered.sh [NAMESPACE] [TIMEOUT_SECONDS]
#
# Wait until slurmctld reports at least one schedulable node, i.e. a slurmd
# has registered and authenticated. Pod-ready is not cluster-ready: a node
# takes noticeably longer to appear in sinfo than its pod takes to reach
# Running.
#
# Bounded, and noisy on failure. The first version of this wait was an
# unbounded `until` loop; it never actually hung CI (see README "What CI
# caught"), but a wait with no deadline and no diagnostics is the same
# defect whether or not it has bitten yet.
#
# "Schedulable" comes from lib/nodes.sh, shared with the rotation script. The
# Makefile used to test `grep -qE 'idle|alloc|mix'`, which also matches
# `idle*`, a node slurmctld cannot reach.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib/nodes.sh
. "$SCRIPT_DIR/lib/nodes.sh"

ns="${1:-slurm}"
timeout="${2:-600}"
case "$timeout" in ''|*[!0-9]*) echo "timeout must be a whole number of seconds" >&2; exit 2 ;; esac

k() { kubectl --namespace "$ns" "$@"; }

echo "waiting up to ${timeout}s for a Slurm node to register with the controller…"
deadline=$(( $(date +%s) + timeout ))
while :; do
  ctl=$({ k get pods -l app.kubernetes.io/component=controller -o name 2>/dev/null || true; } | head -1)
  if [ -n "$ctl" ] \
     && raw=$(k exec "$ctl" -c slurmctld -- sinfo -N --noheader -o '%N %t %E' 2>/dev/null); then
    ready=$(printf '%s\n' "$raw" | nodes_normalise | nodes_in_state "$SCHEDULABLE_RE" | paste -sd, -)
    if [ -n "$ready" ]; then
      echo "  node registered: $ready"
      exit 0
    fi
  fi
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 10
done

echo "  no node became schedulable within ${timeout}s — dumping state:"
k get pods -o wide || true
k get nodesets.slinky.slurm.net || true
if [ -n "${ctl:-}" ]; then k exec "$ctl" -c slurmctld -- sinfo -N -l || true; fi
k describe pods -l app.kubernetes.io/name=slurmd | tail -40 || true
exit 1
