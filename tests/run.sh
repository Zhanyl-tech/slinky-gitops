#!/usr/bin/env bash
#
# tests/run.sh — offline tests for scripts/rotate-auth-key.sh.
#
# Runs the real script against tests/fake/kubectl.py, a fake cluster that
# models the behaviour the script depends on (immutable Secrets, the slurmd
# preStop hook, the stale-key failure, Slurm node states). No cluster, no
# Docker, a few seconds per scenario. What this cannot tell you: whether the
# real cluster behaves like the fake. That is what the KinD job in CI is for.
#
# Usage: tests/run.sh [NAME_FILTER]      PYTHON=... to pick the interpreter.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PYTHON="${PYTHON:-python3}"
FILTER="${1:-}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/slinky-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/kubectl" <<EOF
#!/bin/sh
exec "$PYTHON" "$ROOT/tests/fake/kubectl.py" "\$@"
EOF
# Every wait in the script is bounded by --timeout; a fast sleep keeps the
# polling loops cheap without changing their logic.
cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
exec /bin/sleep 0.01
EOF
chmod +x "$BIN/kubectl" "$BIN/sleep"
# No __pycache__ in the source tree from tests/fake/state.py importing authkey.
export PATH="$BIN:$PATH" PYTHON PYTHONDONTWRITEBYTECODE=1

PASS=0; FAIL=0; CASE_FAILED=0; SEQ=0
state() { "$PYTHON" "$ROOT/tests/fake/state.py" "$@"; }

check() {  # check DESCRIPTION CONDITION...
  local what="$1"; shift
  if "$@"; then :; else
    printf '    FAIL: %s\n' "$what"; CASE_FAILED=1
  fi
}
eq()       { [ "$1" = "$2" ] || { printf '      expected [%s]\n      got      [%s]\n' "$2" "$1"; return 1; }; }
contains() { grep -qF -- "$2" "$1" || { printf '      [%s] not in output\n' "$2"; return 1; }; }
lacks()    { ! grep -qF -- "$2" "$1" || { printf '      [%s] unexpectedly in output\n' "$2"; return 1; }; }

# run_script DIR ARGS... -> sets RC, OUTPUT (file)
run_script() {
  local dir="$1"; shift
  SEQ=$((SEQ + 1))
  OUTPUT="$dir/out.$SEQ.txt"
  FAKE_STATE="$dir" "$ROOT/scripts/rotate-auth-key.sh" -n slurm "$@" >"$OUTPUT" 2>&1
  RC=$?
}

new_cluster() {  # new_cluster NAME [state.py init options]
  local d="$WORK/$1"; shift
  state init "$d" "$@"
  printf '%s' "$d"
}

no_leaks() {
  local l; l=$(state leaks "$1")
  [ -z "$l" ] || { printf '      key material in kubectl argv: %s\n' "$l"; return 1; }
}
never_all()  { ! grep -q 'NodeName=ALL' "$1/scontrol.log"; }
no_resume_of() { ! grep -q "^RESUME $2 " "$1/events.log"; }
# The fake drained NODE on someone else's behalf (EXTERNAL-DRAIN in
# events.log), and nothing resumed NODE afterwards, whatever its reason had
# become by then. Matching on the reason alone missed a RESUME issued after
# the pod replacement had rewritten it.
no_resume_after_external_drain() {
  awk -v n="$2" '
    $1 == "EXTERNAL-DRAIN" && $2 == n { ext = 1; next }
    ext && $1 == "RESUME" && $2 == n  { bad = 1 }
    END { exit (ext && !bad) ? 0 : 1 }' "$1/events.log" \
    || { printf '      %s was resumed after someone else drained it (or the drain never happened):\n' "$2"
         sed 's/^/        /' "$1/events.log"; return 1; }
}
calls() { state count "$1" "$2"; }
# The live Secret NAME was deleted only after its backup and its staged
# replacement had been created (events.log records the order).
replacement_first() {
  awk -v n="$2" '
    $0 == "CREATE " n "-previous" { bk = 1 }
    $0 == "CREATE " n "-next"     { stg = 1 }
    $0 == "DELETE " n             { deletes++; if (!(bk && stg)) bad = 1; stg = 0 }
    END { exit (deletes > 0 && !bad) ? 0 : 1 }' "$1/events.log" \
    || { printf '      %s deleted before its replacement existed\n' "$2"; return 1; }
}

scenario() {  # scenario NAME: run test_NAME
  local name="$1"
  if [ -n "$FILTER" ] && ! printf '%s' "$name" | grep -q "$FILTER"; then return; fi
  CASE_FAILED=0
  "test_$name"
  if [ "$CASE_FAILED" -eq 0 ]; then
    PASS=$((PASS + 1)); printf 'ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %s  (exit %s; output below)\n' "$name" "${RC:-?}"
    [ -n "${OUTPUT:-}" ] && [ -f "$OUTPUT" ] && sed 's/^/      | /' "$OUTPUT"
  fi
}

# ── Usage ────────────────────────────────────────────────────────────────────

test_help_and_usage_errors() {
  local d; d=$(new_cluster usage)
  run_script "$d" --help
  check "--help exits 0" eq "$RC" 0
  check "--help prints usage" contains "$OUTPUT" "Usage:"
  check "--help documents exit 3" contains "$OUTPUT" "3  the new key did not take"
  FAKE_STATE="$d" "$ROOT/scripts/rotate-auth-key.sh" -n >"$d/o1" 2>&1; RC=$?
  check "-n without a value is a usage error, not 'unbound variable'" eq "$RC" 2
  check "-n without a value says so" contains "$d/o1" "needs a value"
  run_script "$d" --timeout abc
  check "--timeout abc is a usage error" eq "$RC" 2
  run_script "$d" --timeout --jwt
  check "--timeout swallowing a flag is a usage error" eq "$RC" 2
  run_script "$d" --rollback --cleanup
  check "--rollback --cleanup is a usage error" eq "$RC" 2
  run_script "$d" --frobnicate
  check "unknown flag is a usage error" eq "$RC" 2
  check "usage errors touch nothing" eq "$(calls "$d" 'kubectl ')" 0
}

# ── Dry run ──────────────────────────────────────────────────────────────────

test_dry_run_changes_nothing() {
  local d; d=$(new_cluster dry)
  local before; before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  run_script "$d" --dry-run
  check "exit 0" eq "$RC" 0
  check "prints the drain plan" contains "$OUTPUT" "will drain      slinky-0,slinky-1"
  check "no Secret created" eq "$(calls "$d" 'kubectl --namespace slurm create')" 0
  check "no Secret or pod deleted" eq "$(calls "$d" 'kubectl --namespace slurm delete')" 0
  check "no scontrol update" eq "$(wc -l < "$d/scontrol.log" | tr -d ' ')" 0
  check "Secret untouched" eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
}

# ── The paths that matter ────────────────────────────────────────────────────

test_rotation_succeeds_when_the_key_propagates() {
  local d; d=$(new_cluster happy)
  local orig; orig=$(state sha "$d" slurm-auth-slurm slurm.key)
  run_script "$d" --timeout 5
  check "exit 0" eq "$RC" 0
  check "reports completion" contains "$OUTPUT" "Rotation complete."
  local now; now=$(state sha "$d" slurm-auth-slurm slurm.key)
  check "live key changed" test "$now" != "$orig"
  check "live Secret still immutable" contains <(state fingerprint "$d" slurm-auth-slurm slurm.key) '"immutable": true'
  check "Helm labels kept" eq "$(state label "$d" slurm-auth-slurm app.kubernetes.io/managed-by)" Helm
  check "Helm annotations kept" eq "$(state annotation "$d" slurm-auth-slurm meta.helm.sh/release-name)" slurm
  check "backup holds the previous key" eq "$(state sha "$d" slurm-auth-slurm-previous slurm.key)" "$orig"
  check "backup is immutable" contains <(state fingerprint "$d" slurm-auth-slurm-previous slurm.key) '"immutable": true'
  check "backup is labelled" eq "$(state label "$d" slurm-auth-slurm-previous rotate-auth-key/role)" backup
  check "backup records what changed" eq "$(state annotation "$d" slurm-auth-slurm-previous rotate-auth-key/rotated-keys)" slurm.key
  check "no staging Secret left" eq "$(state exists "$d" slurm-auth-slurm-next)" no
  check "jwt untouched" eq "$(state exists "$d" slurm-auth-jwt-previous)" no
  check "slinky-0 back in service" eq "$(state node "$d" slinky-0)" "idle|"
  check "slinky-1 back in service" eq "$(state node "$d" slinky-1)" "idle|"
  check "never NodeName=ALL" never_all "$d"
  check "no key material in argv" no_leaks "$d"
  check "live Secret deleted with --cascade=orphan" contains "$d/calls.log" "delete secret slurm-auth-slurm --cascade=orphan"
  check "live deleted only after backup and staging were created" replacement_first "$d" slurm-auth-slurm
}

test_stale_slurmd_key_is_detected_and_rolled_back() {
  local d; d=$(new_cluster stale)
  local before; before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  FAKE_SLURMD_STALE=1 run_script "$d" --timeout 2
  check "exit 3" eq "$RC" 3
  check "names the documented failure" contains "$OUTPUT" "slurmd never picked up the new key"
  check "reports the rollback" contains "$OUTPUT" "rotation failed and was rolled back"
  check "never claims success" lacks "$OUTPUT" "Rotation complete"
  check "live Secret identical to before (key, immutable, labels, annotations)" \
    eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
  check "nodes back in service" eq "$(state node "$d" slinky-0)|$(state node "$d" slinky-1)" "idle||idle|"
  check "no staging Secret left" eq "$(state exists "$d" slurm-auth-slurm-next)" no
  check "no key material in argv" no_leaks "$d"
  check "pod placement printed for the diagnosis" contains "$OUTPUT" "NODE"
  check "live deleted only after its replacement existed, both times" replacement_first "$d" slurm-auth-slurm
}

test_pre_drained_node_needs_allow_degraded() {
  local d; d=$(new_cluster degraded --node=slinky-0=idle "--node=slinky-1=drain:GPU XID 79 (health check)")
  local before; before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  run_script "$d" --timeout 2
  check "refuses with exit 1" eq "$RC" 1
  check "says why" contains "$OUTPUT" "refusing to rotate on a degraded cluster"
  check "lists the node and its reason" contains "$OUTPUT" "GPU XID 79 (health check)"
  check "nothing drained" eq "$(wc -l < "$d/scontrol.log" | tr -d ' ')" 0
  check "Secret untouched" eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
}

test_pre_drained_node_is_never_resumed() {
  local d; d=$(new_cluster predrain --node=slinky-0=idle "--node=slinky-1=drain:GPU XID 79 (health check)")
  run_script "$d" --timeout 3 --allow-degraded
  check "exit 0" eq "$RC" 0
  check "only slinky-0 drained" contains "$d/scontrol.log" "NodeName=slinky-0 State=DRAIN"
  check "slinky-1 never resumed" no_resume_of "$d" slinky-1
  check "slinky-1 still drained with its original reason" eq "$(state node "$d" slinky-1)" "drain|GPU XID 79 (health check)"
  check "slinky-0 back in service" eq "$(state node "$d" slinky-0)" "idle|"
  check "the overwritten reason was re-applied" contains "$OUTPUT" "re-applied the earlier drain on slinky-1"
  check "never NodeName=ALL" never_all "$d"
}

test_pre_drained_node_survives_a_rollback() {
  local d; d=$(new_cluster predrain-stale --node=slinky-0=idle "--node=slinky-1=drain:GPU XID 79 (health check)")
  FAKE_SLURMD_STALE=1 run_script "$d" --timeout 2 --allow-degraded
  check "exit 3" eq "$RC" 3
  check "slinky-1 never resumed" no_resume_of "$d" slinky-1
  check "slinky-1 still drained with its original reason" eq "$(state node "$d" slinky-1)" "drain|GPU XID 79 (health check)"
  check "slinky-0 back in service" eq "$(state node "$d" slinky-0)" "idle|"
}

test_node_states_are_classified_by_base_and_suffix() {
  # State strings from node_state_string_compact() in Slurm's
  # src/common/slurm_protocol_defs.c, lowercased as sinfo prints them.
  local s want got CASE_NODES
  CASE_NODES=$(
    # shellcheck source=scripts/lib/nodes.sh
    . "$ROOT/scripts/lib/nodes.sh"
    for s in idle mix alloc comp plnd alloc+ mix- idle* mix* alloc* drain drng drain* drng~ \
             down down* fail failg resv maint block boot idle~ idle# idle$ alloc$ mix@ unk; do
      printf '%s %s%s%s\n' "$s" \
        "$(printf 'n\t%s\t\n' "$s" | nodes_in_state "$SCHEDULABLE_RE" | sed 's/.*/S/')" \
        "$(printf 'n\t%s\t\n' "$s" | nodes_in_state "$IN_SERVICE_RE" | sed 's/.*/I/')" \
        "$(printf 'n\t%s\t\n' "$s" | nodes_in_state "$QUIESCED_RE" | sed 's/.*/Q/')"
    done)
  # S = schedulable, I = in service (drained and resumed by a rotation),
  # Q = Slurm starts no new job there (may be left alone with --allow-degraded).
  for want in "idle SI" "mix SI" "alloc SI" "comp I" "plnd SI" "alloc+ SI" "mix- SI" \
              "idle* Q" "mix* Q" "alloc* Q" "drain Q" "drng Q" "drain* Q" "drng~ Q" \
              "down Q" "down* Q" "fail Q" "failg Q" "resv " "maint " "block " "boot " \
              "idle~ " "idle# " 'idle$ ' 'alloc$ ' "mix@ " "unk "; do
    got=$(printf '%s\n' "$CASE_NODES" | awk -v s="${want%% *}" '$1 == s { print $1 " " $2 }')
    check "state ${want%% *} classified" eq "$got" "$want"
  done
}

test_busy_node_states_count_as_in_service() {
  # alloc+ (allocated, some jobs completing) and mix- (planned by backfill)
  # are in service: drained, waited for, and resumed like idle.
  local d; d=$(new_cluster busy-states --node=slinky-0=mix- --node=slinky-1=alloc+)
  run_script "$d" --dry-run
  check "dry run: not refused as degraded" eq "$RC" 0
  check "dry run: plans to drain both" contains "$OUTPUT" "will drain      slinky-0,slinky-1"
  run_script "$d" --timeout 3
  check "exit 0" eq "$RC" 0
  check "both were drained" contains "$d/scontrol.log" "NodeName=slinky-0,slinky-1 State=DRAIN"
  check "both back in service" eq "$(state node "$d" slinky-0)|$(state node "$d" slinky-1)" "idle||idle|"

  # A node the backfill scheduler plans a job on as soon as it is resumed
  # shows `plnd`, which is schedulable.
  d=$(new_cluster resumed-plnd)
  FAKE_RESUMED_STATE=plnd run_script "$d" --timeout 3
  check "resumed as plnd: exit 0" eq "$RC" 0
  check "resumed as plnd: reports completion" contains "$OUTPUT" "Rotation complete."
}

test_allow_degraded_refuses_a_node_that_can_still_run_jobs() {
  # Every slurmd pod is replaced, so a node left alone must be one Slurm
  # will not start a job on.
  local d; d=$(new_cluster maint --node=slinky-0=idle --node=slinky-1=maint)
  run_script "$d" --timeout 2 --allow-degraded
  check "exit 1" eq "$RC" 1
  check "says why" contains "$OUTPUT" "Slurm can still start a job on slinky-1 (maint)"
  check "nothing drained" eq "$(wc -l < "$d/scontrol.log" | tr -d ' ')" 0
  check "no Secret deleted" eq "$(calls "$d" 'delete secret')" 0
}

test_unresponsive_node_left_alone_is_not_left_down() {
  # idle* with no reason: left alone with --allow-degraded, but replacing its
  # pod sets it DOWN with the preStop reason, which nothing clears. It had no
  # drain to keep, so it is resumed once, after the replacement.
  local d; d=$(new_cluster unresp --node=slinky-0=idle "--node=slinky-1=idle*")
  run_script "$d" --timeout 3 --allow-degraded
  check "exit 0" eq "$RC" 0
  check "only slinky-0 drained" contains "$d/scontrol.log" "NodeName=slinky-0 State=DRAIN"
  check "never drained slinky-1" lacks "$d/scontrol.log" "NodeName=slinky-1 State=DRAIN"
  check "slinky-1 not left DOWN" eq "$(state node "$d" slinky-1)" "idle|"
  check "says so" contains "$OUTPUT" "resumed slinky-1 once"
  check "resumed only after its pod was replaced" \
    eq "$(awk '$1 == "RESUME" && $2 == "slinky-1" { print $3 " " $4 " " $5 " " $6; exit }' "$d/events.log")" \
       "reason=slurm-operator: Pod is terminating"
}

test_nodeset_convergence_uses_status_desired() {
  local A="$ROOT/scripts/lib/authkey.py" out
  # DaemonSet mode: spec.replicas keeps the CRD default of 1 and is ignored;
  # status.desired is the real target.
  out=$(printf '%s' '{"items":[{"metadata":{"name":"gpu","generation":2},"spec":{"replicas":1,"scalingMode":"DaemonSet"},"status":{"replicas":3,"updatedReplicas":3,"readyReplicas":3,"desired":3,"observedGeneration":2}}]}' | "$PYTHON" "$A" nodesets)
  check "converged DaemonSet NodeSet passes" eq "$out" ""
  out=$(printf '%s' '{"items":[{"metadata":{"name":"gpu"},"spec":{"replicas":1,"scalingMode":"DaemonSet"},"status":{"replicas":3,"updatedReplicas":3,"readyReplicas":2,"desired":3}}]}' | "$PYTHON" "$A" nodesets)
  check "DaemonSet NodeSet with a pod not ready is named" eq "$out" "gpu desired=3 replicas=3 updated=3 ready=2"
  out=$(printf '%s' '{"items":[{"metadata":{"name":"gpu"},"spec":{"replicas":1,"scalingMode":"DaemonSet"},"status":{}}]}' | "$PYTHON" "$A" nodesets)
  check "DaemonSet with no matching node (desired omitted = 0) passes" eq "$out" ""
  out=$(printf '%s' '{"items":[{"metadata":{"name":"cpu"},"spec":{"replicas":2},"status":{"replicas":2,"updatedReplicas":2,"readyReplicas":2}}]}' | "$PYTHON" "$A" nodesets)
  check "no status.desired: falls back to spec.replicas" eq "$out" ""
  out=$(printf '%s' '{"items":[{"metadata":{"name":"cpu","generation":3},"spec":{"replicas":4},"status":{"replicas":2,"updatedReplicas":2,"readyReplicas":2,"desired":2,"observedGeneration":2}}]}' | "$PYTHON" "$A" nodesets)
  check "a spec change the operator has not observed is not converged" \
    eq "$out" "cpu desired=2 replicas=2 updated=2 ready=2 (status from generation 2 of 3)"

  local d; d=$(new_cluster daemonset --daemonset --node=slinky-0=idle --node=slinky-1=idle --node=slinky-2=idle)
  run_script "$d" --dry-run
  check "preflight passes a healthy DaemonSet-mode cluster" eq "$RC" 0
  check "says converged" contains "$OUTPUT" "NodeSets converged"
}

test_rbac_role_covers_the_secret_calls() {
  # docs/rbac-rotate-auth-key.yaml says it is derived from the script's
  # kubectl calls. Hold it to that for Secrets, the resource it is most
  # tempting to under-grant: `kubectl delete --wait` also lists and watches.
  local d; d=$(new_cluster rbac)
  run_script "$d" --timeout 3
  run_script "$d" --rollback --timeout 3
  run_script "$d" --cleanup
  local need="get create delete" rule v
  grep -q 'delete secret .*--wait=true' "$d/calls.log" && need="$need list watch"
  check "the delete wait is bounded" contains "$d/calls.log" "--wait=true --timeout=3s"
  rule=$(awk '/resources: \["secrets"\]/ { getline; print; exit }' "$ROOT/docs/rbac-rotate-auth-key.yaml")
  for v in $need; do
    check "the Role grants $v on secrets" eq "$(printf '%s\n' "$rule" | grep -c "\"$v\"")" 1
  done
}

test_external_drain_mid_run_is_respected() {
  # Drained by a health check after the pods were replaced; the key took.
  local d; d=$(new_cluster external)
  FAKE_EXTERNAL_DRAIN="slinky-0:disk errors (health check)" run_script "$d" --timeout 2
  check "exit 4: a node this run drained could not be verified" eq "$RC" 4
  check "never claims success" lacks "$OUTPUT" "Rotation complete"
  check "no rollback: the key was measured in every pod" lacks "$OUTPUT" "rolling back"
  check "names the node and why" contains "$OUTPUT" "slinky-0 was drained by someone else during the run (disk errors (health check))"
  check "never resumed after the external drain" no_resume_after_external_drain "$d" slinky-0
  check "keeps the external drain" eq "$(state node "$d" slinky-0)" "drain|disk errors (health check)"
  check "the other node back in service" eq "$(state node "$d" slinky-1)" "idle|"

  # Same, but the key does not take, so the rollback replaces the pods a
  # second time: its preStop hook rewrites slinky-0's reason to one this
  # script would otherwise resume.
  d=$(new_cluster external-stale)
  local before; before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  FAKE_SLURMD_STALE=1 FAKE_EXTERNAL_DRAIN="slinky-0:disk errors (health check)" run_script "$d" --timeout 2
  check "stale + external: exit 4" eq "$RC" 4
  check "stale + external: rolled back" eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
  check "stale + external: does not claim slinky-0 was verified" \
    contains "$OUTPUT" "every node this run drained is schedulable again: slinky-1"
  check "stale + external: never resumed after the external drain" no_resume_after_external_drain "$d" slinky-0
  check "stale + external: keeps the external drain" eq "$(state node "$d" slinky-0)" "drain|disk errors (health check)"
}

test_external_drain_during_the_drain_wait_survives_the_rotation() {
  # An epilog drains slinky-0 while the script waits for jobs; the jobs then
  # finish. That is the last moment the drain can be told from the script's
  # own before the pod replacement overwrites the reason.
  local d; d=$(new_cluster ext-wait)
  FAKE_EXTERNAL_DRAIN="slinky-0:GPU XID 79 (epilog)" FAKE_EXTERNAL_DRAIN_AT=drain-wait run_script "$d" --timeout 3
  check "exit 4" eq "$RC" 4
  check "never claims success" lacks "$OUTPUT" "Rotation complete"
  check "names the node" contains "$OUTPUT" "slinky-0 was drained by someone else during the run (GPU XID 79 (epilog))"
  check "never resumed after the external drain" no_resume_after_external_drain "$d" slinky-0
  check "keeps the epilog's reason" eq "$(state node "$d" slinky-0)" "drain|GPU XID 79 (epilog)"
  check "the reason was put back after the pod replacement" contains "$OUTPUT" "re-applied the earlier drain on slinky-0"
  check "... right after it, before any node was resumed" \
    awk '/^DRAIN slinky-0 GPU XID 79/ && !d { d = NR } /^RESUME / && !r { r = NR }
         END { exit (d && r && d < r) ? 0 : 1 }' "$d/events.log"
  check "the other node back in service" eq "$(state node "$d" slinky-1)" "idle|"

  d=$(new_cluster ext-wait-stale)
  FAKE_SLURMD_STALE=1 FAKE_EXTERNAL_DRAIN="slinky-0:GPU XID 79 (epilog)" FAKE_EXTERNAL_DRAIN_AT=drain-wait \
    run_script "$d" --timeout 2
  check "stale: exit 4" eq "$RC" 4
  check "stale: does not claim slinky-0 was verified" \
    contains "$OUTPUT" "every node this run drained is schedulable again: slinky-1"
  check "stale: never resumed after the external drain" no_resume_after_external_drain "$d" slinky-0
  check "stale: keeps the epilog's reason" eq "$(state node "$d" slinky-0)" "drain|GPU XID 79 (epilog)"
}

test_drain_timeout_leaves_an_external_drain_alone() {
  # The documented common abort: jobs outlive --timeout. The exit trap lifts
  # the run's drain, and only the run's drain.
  local d; d=$(new_cluster ext-timeout)
  local before; before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  FAKE_RUNNING_JOBS=2 FAKE_EXTERNAL_DRAIN="slinky-0:GPU XID 79 (epilog)" FAKE_EXTERNAL_DRAIN_AT=drain-wait \
    run_script "$d" --timeout 1
  check "exit 1" eq "$RC" 1
  check "Secret untouched" eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
  check "never resumed after the external drain" no_resume_after_external_drain "$d" slinky-0
  check "keeps the epilog's reason" eq "$(state node "$d" slinky-0)" "drain|GPU XID 79 (epilog)"
  check "says so" contains "$OUTPUT" "slinky-0 was drained by someone else during the run"
  check "the run's own drain lifted" eq "$(state node "$d" slinky-1)" "idle|"
}

test_operator_drain_reason_is_not_resumed() {
  # The operator drains a Slurm node when its Kubernetes node is cordoned,
  # with its own "slurm-operator: " prefix. Only the preStop reason is the
  # residue of a pod replacement; this one is the operator's.
  local d; d=$(new_cluster ext-cordon)
  local r="slurm-operator: Node (kind-worker) was cordoned, Pod (slurm/slurm-worker-slinky-0) must be cordoned"
  FAKE_EXTERNAL_DRAIN="slinky-0:$r" run_script "$d" --timeout 2
  check "exit 4" eq "$RC" 4
  check "never resumed after the operator's drain" no_resume_after_external_drain "$d" slinky-0
  check "keeps the operator's reason" eq "$(state node "$d" slinky-0)" "drain|$r"
  check "leaves the operator's reason to the operator" lacks "$d/scontrol.log" "Reason=slurm-operator"
}

# ── The operator's undrain after a pod replacement ───────────────────────────
#
# On KinD with slurm-operator v1.2.0, replacing a slurmd pod ends with the
# operator undraining the node itself, reason "slurm-operator: Pod
# (slurm/<pod>) was uncordoned" (FAKE_OPERATOR=1 models it). Before this was
# understood, the rollback took that for someone else's drain and exited 4.

test_operator_undrain_of_our_replacement_is_ours() {
  # (a) The CI failure: one node, the key does not take, and the rollback's
  # re-read finds the operator's reason on the node this run drained, naming
  # the pod this run replaced there.
  local d A="$ROOT/scripts/ci/assert-rotation.sh"
  local r0="slurm-operator: Pod (slurm/slurm-worker-slinky-0) was uncordoned"
  d=$(new_cluster op-stale --node=slinky-0=idle)
  FAKE_STATE="$d" "$A" record "$d/rec" >/dev/null 2>&1
  FAKE_OPERATOR=1 FAKE_SLURMD_STALE=1 run_script "$d" --timeout 2
  check "exit 3, as documented" eq "$RC" 3
  check "the operator did undrain it" contains "$d/events.log" "OPERATOR-UNDRAIN slinky-0 $r0"
  check "not taken for someone else's drain" lacks "$OUTPUT" "drained by someone else"
  check "verified on the previous key" contains "$OUTPUT" "every node this run drained is schedulable again: slinky-0"
  check "slinky-0 resumed" grep -q '^RESUME slinky-0 ' "$d/events.log"
  check "slinky-0 in service" eq "$(state node "$d" slinky-0)" "idle|"
  FAKE_STATE="$d" "$A" expect-rolled-back "$RC" "$OUTPUT" "$d/rec" >"$d/a1" 2>&1
  check "the CI assertion passes" eq "$?" 0

  # The next CI step, a manual --rollback: its own pod replacement is followed
  # by the same undrain, which the resume loop meets this time.
  FAKE_OPERATOR=1 FAKE_SLURMD_STALE=1 run_script "$d" --rollback --timeout 3
  check "manual rollback: exit 0" eq "$RC" 0
  check "manual rollback: resumed from the operator's reason" contains "$d/events.log" "RESUME slinky-0 reason=$r0"
  check "manual rollback: slinky-0 in service" eq "$(state node "$d" slinky-0)" "idle|"
  FAKE_STATE="$d" "$A" expect-restored "$RC" "$OUTPUT" "$d/rec" >"$d/a2" 2>&1
  check "manual rollback: the CI assertion passes" eq "$?" 0

  # And when the key does take.
  d=$(new_cluster op-happy)
  FAKE_OPERATOR=1 run_script "$d" --timeout 3
  check "key takes: exit 0" eq "$RC" 0
  check "key takes: reports completion" contains "$OUTPUT" "Rotation complete."
  check "key takes: both back in service" eq "$(state node "$d" slinky-0)|$(state node "$d" slinky-1)" "idle||idle|"

  # DaemonSet mode: the replacement pod has a new name, and that is the pod
  # the operator names.
  d=$(new_cluster op-daemonset --daemonset --node=slinky-0=idle)
  FAKE_OPERATOR=1 FAKE_SLURMD_STALE=1 run_script "$d" --timeout 2
  check "DaemonSet mode: exit 3" eq "$RC" 3
  check "DaemonSet mode: the operator named the replacement" \
    grep -q '^OPERATOR-UNDRAIN slinky-0 slurm-operator: Pod (slurm/slurm-worker-slinky-x[0-9]*) was uncordoned$' "$d/events.log"
  check "DaemonSet mode: slinky-0 in service" eq "$(state node "$d" slinky-0)" "idle|"
}

# someone_elses_reason NAME REASON: REASON is put on slinky-0 right after the
# first pod replacement of a rotation whose key does not take, which is where
# the CI run met the operator's undrain. It is not the operator's undrain of
# a pod this run replaced on slinky-0, so slinky-0 is handed over: named,
# never resumed, left out of service, exit 4. slinky-1 is still verified.
someone_elses_reason() {
  local d; d=$(new_cluster "$1")
  FAKE_SLURMD_STALE=1 FAKE_EXTERNAL_DRAIN="slinky-0:$2" run_script "$d" --timeout 2
  check "[$2] exit 4" eq "$RC" 4
  check "[$2] handed over" contains "$OUTPUT" "slinky-0 was drained by someone else during the run ($2)"
  check "[$2] never resumed after it was set" no_resume_after_external_drain "$d" slinky-0
  check "[$2] left out of service" test "$(state node "$d" slinky-0 | cut -d'|' -f1)" != idle
  check "[$2] slinky-1 verified on the previous key" \
    contains "$OUTPUT" "every node this run drained is schedulable again: slinky-1"
}

test_operator_undrain_of_a_pod_we_did_not_replace_is_someone_elses() {
  # (b) The operator's message, but not for the pod this run replaced on
  # slinky-0: slinky-1's pod (replaced by this run, on another node), a pod
  # that does not exist, and the right pod name in another namespace.
  someone_elses_reason op-other-node "slurm-operator: Pod (slurm/slurm-worker-slinky-1) was uncordoned"
  someone_elses_reason op-no-such-pod "slurm-operator: Pod (slurm/slurm-worker-slinky-7) was uncordoned"
  someone_elses_reason op-other-ns "slurm-operator: Pod (other/slurm-worker-slinky-0) was uncordoned"
}

test_operator_cordon_reasons_are_someone_elses() {
  # (c) The operator draining for a cordoned pod: someone asked for it. v1.2.0
  # writes this reason only on a node that had none; on a node with a reason
  # it keeps that one (next test).
  someone_elses_reason op-pod-cordon "slurm-operator: Pod (slurm/slurm-worker-slinky-0) was cordoned"
}

test_a_cordon_after_the_operators_undrain_is_someone_elses() {
  # The operator's cordon drains (Kubernetes node cordoned, or the pod-cordon
  # annotation set) keep any reason the node already has (MakeNodeDrain with
  # overrideReason false, slurmcontrol.go lines 227-231 at v1.2.0). A cordon
  # that lands after the operator's undrain therefore drains the node again
  # under exactly the reason this run accepts. The undrain is the write that
  # cleared the DRAIN flag, so that reason on a node carrying the flag again
  # is someone else's drain: handed over, never resumed, exit 4.
  local r0="slurm-operator: Pod (slurm/slurm-worker-slinky-0) was uncordoned" d
  # The key takes: the resume loop meets it.
  d=$(new_cluster op-recordon)
  FAKE_OPERATOR=1 FAKE_EXTERNAL_DRAIN="slinky-0:$r0" run_script "$d" --timeout 3
  check "[key takes] the operator undrained it first" contains "$d/events.log" "OPERATOR-UNDRAIN slinky-0 $r0"
  check "[key takes] exit 4" eq "$RC" 4
  check "[key takes] not reported complete" lacks "$OUTPUT" "Rotation complete."
  check "[key takes] handed over" contains "$OUTPUT" "slinky-0 was drained by someone else during the run ($r0)"
  check "[key takes] never resumed after the cordon" no_resume_after_external_drain "$d" slinky-0
  check "[key takes] still drained" eq "$(state node "$d" slinky-0)" "drain|$r0"
  check "[key takes] slinky-1 verified on the new key" \
    contains "$OUTPUT" "every node this run drained is schedulable again: slinky-1"
  # The key does not take: the rollback's re-read, before its own pod
  # replacement, meets it.
  FAKE_OPERATOR=1 someone_elses_reason op-recordon-stale "$r0"
}

test_admin_reason_after_replacement_is_someone_elses() {
  # (d) An admin's drain, with the operator running: the next pod replacement
  # rewrites slinky-0's reason to the preStop one and the operator then
  # writes exactly the undrain this run would accept on a node it still
  # held. Handed over is handed over: slinky-0 is never taken back, and the
  # admin's reason is put back.
  local r="replace DIMM B2 (ops ticket 4411)"
  FAKE_OPERATOR=1 someone_elses_reason op-admin "$r"
  local d="$WORK/op-admin"
  check "the operator did rewrite it" \
    contains "$d/events.log" "OPERATOR-UNDRAIN slinky-0 slurm-operator: Pod (slurm/slurm-worker-slinky-0) was uncordoned"
  check "the admin's reason is back" eq "$(state node "$d" slinky-0)" "drain|$r"

  # A node drained before the run is never this run's, whatever the operator
  # writes on it after its pod is replaced.
  d=$(new_cluster op-predrain --node=slinky-0=idle "--node=slinky-1=drain:GPU XID 79 (health check)")
  FAKE_OPERATOR=1 FAKE_SLURMD_STALE=1 run_script "$d" --timeout 2 --allow-degraded
  check "pre-drained: exit 3" eq "$RC" 3
  check "pre-drained: the operator did undrain slinky-1" \
    contains "$d/events.log" "OPERATOR-UNDRAIN slinky-1 slurm-operator: Pod (slurm/slurm-worker-slinky-1) was uncordoned"
  check "pre-drained: slinky-1 never resumed" no_resume_of "$d" slinky-1
  check "pre-drained: slinky-1 keeps its reason" eq "$(state node "$d" slinky-1)" "drain|GPU XID 79 (health check)"
  check "pre-drained: slinky-0 in service" eq "$(state node "$d" slinky-0)" "idle|"
}

test_operator_undrain_lookalikes_are_someone_elses() {
  # (e) Matched as a whole string, not a pattern. The last one turns into the
  # real reason if it goes through `awk -v`, which processes escapes.
  local r d i=0
  for r in \
    "x slurm-operator: Pod (slurm/slurm-worker-slinky-0) was uncordoned" \
    "slurm-operator: Pod (slurm/slurm-worker-slinky-0) was uncordoned; GPU XID 79 (epilog)" \
    "Pod (slurm/slurm-worker-slinky-0) was uncordoned" \
    "slurm-operator: Pod (slurm/slurm-worker-slinky-0x) was uncordoned" \
    'slurm-operator: Pod (slurm/slurm-worker-slinky-0) was uncordone\d'
  do
    i=$((i + 1)); d=$(new_cluster "op-lookalike-$i")
    # The key takes: the resume loop, not the rollback's re-read, judges it.
    FAKE_EXTERNAL_DRAIN="slinky-0:$r" run_script "$d" --timeout 2
    check "[$r] exit 4" eq "$RC" 4
    check "[$r] handed over" contains "$OUTPUT" "slinky-0 was drained by someone else during the run ($r)"
    check "[$r] never resumed" no_resume_after_external_drain "$d" slinky-0
    check "[$r] keeps the reason" eq "$(state node "$d" slinky-0)" "drain|$r"
  done
  # The same through the rollback's re-read, as in CI.
  someone_elses_reason op-lookalike-stale "slurm-operator: Pod (slurm/slurm-worker-slinky-0) was uncordoned (and drained by ops)"
}

test_slurmd_pods_map_to_slurm_nodes_like_the_operator() {
  # GetSlurmNodeName (internal/controller/nodeset/utils/utils.go at v1.2.0).
  local A="$ROOT/scripts/lib/authkey.py" out
  out=$(printf '%s' '{"items":[
    {"metadata":{"name":"slurm-worker-slinky-0","namespace":"slurm","uid":"u0","labels":{"nodeset.slinky.slurm.net/scaling-mode":"StatefulSet"}},"spec":{"hostname":"slinky-0","nodeName":"kind-worker"}},
    {"metadata":{"name":"slurm-worker-slinky-1","namespace":"slurm","uid":"u1","labels":{"nodeset.slinky.slurm.net/scaling-mode":"StatefulSet"}},"spec":{"nodeName":"kind-worker"}},
    {"metadata":{"name":"slurm-worker-slinky-2","namespace":"slurm","uid":"u2","labels":{"nodeset.slinky.slurm.net/scaling-mode":"StatefulSet"}},"spec":{"hostNetwork":true,"hostname":"slinky-2","nodeName":"gpu-7"}},
    {"metadata":{"name":"slurm-worker-gpu-x7k2p","namespace":"slurm","uid":"u3","labels":{"nodeset.slinky.slurm.net/scaling-mode":"DaemonSet"}},"spec":{"hostname":"gpu-8","nodeName":"gpu-8.example.org"}},
    {"metadata":{"name":"slurm-worker-gpu-q9z","namespace":"slurm","uid":"u4","labels":{"nodeset.slinky.slurm.net/scaling-mode":"DaemonSet"}},"spec":{"nodeName":"gpu-9"}}
  ]}' | "$PYTHON" "$A" slurmd-nodes | tr '\t' ' ')
  check "StatefulSet: the Kubernetes node if hostNetwork, else hostname, else pod name; DaemonSet: hostname only" \
    eq "$out" "slurm/slurm-worker-slinky-0 u0 slinky-0
slurm/slurm-worker-slinky-1 u1 slurm-worker-slinky-1
slurm/slurm-worker-slinky-2 u2 gpu-7
slurm/slurm-worker-gpu-x7k2p u3 gpu-8"
}

test_drain_timeout_stops_before_touching_keys() {
  local d; d=$(new_cluster busy)
  local before; before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  FAKE_RUNNING_JOBS=2 run_script "$d" --timeout 1
  check "exit 1" eq "$RC" 1
  check "does not claim the jobs are gone" lacks "$OUTPUT" "no running jobs"
  check "says jobs are still running" contains "$OUTPUT" "jobs still running"
  check "no Secret created" eq "$(calls "$d" 'create -f -')" 0
  check "no Secret deleted" eq "$(calls "$d" 'delete secret')" 0
  check "no slurmd pod deleted" eq "$(calls "$d" 'delete pod')" 0
  check "Secret untouched" eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
  check "drain lifted by the exit trap" eq "$(state node "$d" slinky-0)|$(state node "$d" slinky-1)" "idle||idle|"
}

test_squeue_failure_is_not_zero_jobs() {
  local d; d=$(new_cluster squeue)
  FAKE_SQUEUE_FAIL=1 run_script "$d" --timeout 1
  check "exit 1" eq "$RC" 1
  check "plan says unknown" contains "$OUTPUT" "running jobs    unknown"
  check "never 'no running jobs'" lacks "$OUTPUT" "no running jobs"
  check "no slurmd pod deleted" eq "$(calls "$d" 'delete pod')" 0
}

test_preflight_fails_closed() {
  local d
  d=$(new_cluster pf-nodesets)
  FAKE_NODESETS_FAIL=1 run_script "$d"
  check "NodeSet query failure: exit 1" eq "$RC" 1
  check "NodeSet query failure: says so" contains "$OUTPUT" "could not list NodeSets"
  check "NodeSet query failure: nothing drained" eq "$(wc -l < "$d/scontrol.log" | tr -d ' ')" 0

  d=$(new_cluster pf-notready --not-ready)
  run_script "$d"
  check "NodeSet not ready: exit 1" eq "$RC" 1
  check "NodeSet not ready: names it" contains "$OUTPUT" "ready=0"

  d=$(new_cluster pf-sinfo)
  FAKE_SINFO_FAIL=1 run_script "$d"
  check "sinfo failure: exit 1" eq "$RC" 1

  d=$(new_cluster pf-munge)
  FAKE_AUTHTYPE=auth/munge run_script "$d"
  check "auth/munge: exit 1" eq "$RC" 1
  check "auth/munge: says so" contains "$OUTPUT" "auth/munge"

  d=$(new_cluster pf-authtype)
  FAKE_AUTHTYPE="" run_script "$d"
  check "unreadable AuthType: exit 1" eq "$RC" 1
  check "none of the preflight failures touched a Secret" eq "$(calls "$WORK/pf-authtype" 'delete secret')" 0
}

test_drain_command_failure_changes_nothing() {
  local d; d=$(new_cluster drainfail)
  FAKE_SCONTROL_FAIL=DRAIN run_script "$d" --timeout 1
  check "exit 1" eq "$RC" 1
  check "no Secret deleted" eq "$(calls "$d" 'delete secret')" 0
}

# ── Never delete a live Secret before its replacement exists ─────────────────

test_create_failure_once_is_retried() {
  local d; d=$(new_cluster create-once)
  FAKE_CREATE_FAIL=slurm-auth-slurm:1 run_script "$d" --timeout 3
  check "exit 0" eq "$RC" 0
  check "retry was needed" contains "$OUTPUT" "creating slurm-auth-slurm failed (attempt 1/5)"
  check "live Secret present" eq "$(state exists "$d" slurm-auth-slurm)" yes
}

test_live_secret_is_never_lost() {
  local d; d=$(new_cluster create-always)
  local orig before
  orig=$(state sha "$d" slurm-auth-slurm slurm.key)
  before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  FAKE_CREATE_FAIL=slurm-auth-slurm:always run_script "$d" --timeout 2
  check "exit 4 (needs attention)" eq "$RC" 4
  check "the previous key is still in the backup" eq "$(state sha "$d" slurm-auth-slurm-previous slurm.key)" "$orig"
  check "the new key is still staged" eq "$(state exists "$d" slurm-auth-slurm-next)" yes
  check "says how to recover" contains "$OUTPUT" "--rollback"
  check "no slurmd pod was deleted" eq "$(calls "$d" 'delete pod')" 0
  check "drain lifted by the exit trap" eq "$(state node "$d" slinky-0)" "idle|"
  check "live deleted only after backup and staging were created" replacement_first "$d" slurm-auth-slurm

  # Recovery: the next --rollback rebuilds the live Secret from the backup,
  # metadata included.
  run_script "$d" --rollback --timeout 3
  check "rollback exit 0" eq "$RC" 0
  check "live Secret identical to the original" eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
}

test_interrupt_between_delete_and_create_restores_the_secret() {
  local d; d=$(new_cluster interrupt)
  local before; before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  FAKE_TERM_ON_CREATE=slurm-auth-slurm run_script "$d" --timeout 2
  check "exit 143 (SIGTERM)" eq "$RC" 143
  check "the exit trap noticed the missing Secret" contains "$OUTPUT" "slurm-auth-slurm is missing — recreating it"
  check "live Secret back, identical to before" eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
  check "no slurmd pod was deleted" eq "$(calls "$d" 'delete pod')" 0
  check "drain lifted" eq "$(state node "$d" slinky-0)|$(state node "$d" slinky-1)" "idle||idle|"
}

test_missing_live_secret_points_at_rollback() {
  local d; d=$(new_cluster missing)
  run_script "$d" --timeout 3
  "$PYTHON" - "$d/state.json" <<'PY'
import json, sys
p = sys.argv[1]; st = json.load(open(p)); del st["secrets"]["slurm-auth-slurm"]; json.dump(st, open(p, "w"))
PY
  run_script "$d" --timeout 2
  check "exit 1" eq "$RC" 1
  check "points at --rollback" contains "$OUTPUT" "an earlier run was interrupted"
}

# ── Measurement ──────────────────────────────────────────────────────────────

test_unmeasurable_slurmd_pod_is_a_failure() {
  local d; d=$(new_cluster noexec)
  FAKE_EXEC_FAIL_POD=slinky-1 run_script "$d" --timeout 2
  check "does not report success" lacks "$OUTPUT" "Rotation complete"
  check "exit 4: not even the rollback can be verified" eq "$RC" 4
  check "the unreadable pod is named" contains "$OUTPUT" "slurm-worker-slinky-1 <unreadable>"
}

test_rollback_survives_a_failed_diagnostic() {
  # rollback_after_failure runs under `set -e`. Its pod listing is for the
  # diagnosis only; when that one API call fails, the rollback must go on.
  local d; d=$(new_cluster wide-fail)
  local before; before=$(state fingerprint "$d" slurm-auth-slurm slurm.key)
  FAKE_SLURMD_STALE=1 FAKE_WIDE_FAIL=1 run_script "$d" --timeout 2
  check "exit 3, not 1" eq "$RC" 3
  check "reports the rollback" contains "$OUTPUT" "rotation failed and was rolled back"
  check "live Secret identical to before" eq "$(state fingerprint "$d" slurm-auth-slurm slurm.key)" "$before"
  check "nodes back in service" eq "$(state node "$d" slinky-0)|$(state node "$d" slinky-1)" "idle||idle|"
}

test_exit_1_is_never_reported_after_the_key_changed() {
  # Defence in depth behind the guard above: a copy of the script with the
  # old unguarded listing put back. Whatever makes the script die, exit 1
  # ("the key in use is the one you started with") must be measurably true.
  local d m; d=$(new_cluster exit1-net); m="$WORK/exit1-net-scripts"
  cp -R "$ROOT/scripts" "$m"
  sed -i.orig 's/^  { k get pods -o wide 2>&1 || true; } | indent$/  k get pods -o wide 2>\&1 | indent/' "$m/rotate-auth-key.sh"
  check "the copy has the unguarded listing" contains "$m/rotate-auth-key.sh" "  k get pods -o wide 2>&1 | indent"
  SEQ=$((SEQ + 1)); OUTPUT="$d/out.$SEQ.txt"
  FAKE_STATE="$d" FAKE_SLURMD_STALE=1 FAKE_WIDE_FAIL=1 "$m/rotate-auth-key.sh" -n slurm --timeout 2 >"$OUTPUT" 2>&1; RC=$?
  check "exit 4, not 1" eq "$RC" 4
  check "says the key changed" contains "$OUTPUT" "slurm-auth-slurm no longer holds (or could not be read to confirm) the key this run started with"
  check "points at --rollback" contains "$OUTPUT" "--rollback"
}

test_slurmctld_key_is_measured() {
  local d; d=$(new_cluster ctld)
  FAKE_CTLD_STALE=1 run_script "$d" --timeout 2
  check "exit 3" eq "$RC" 3
  check "names slurmctld" contains "$OUTPUT" "slurmctld never picked up the new key"
}

# ── JWT ──────────────────────────────────────────────────────────────────────

test_jwt_rotation_measures_slurmctld_and_keeps_tokens() {
  local d; d=$(new_cluster jwt)
  local orig; orig=$(state sha "$d" slurm-auth-jwt jwt.key)
  run_script "$d" --jwt --timeout 3
  check "exit 0" eq "$RC" 0
  check "jwt.key changed" test "$(state sha "$d" slurm-auth-jwt jwt.key)" != "$orig"
  check "slurmctld's jwt.key was measured" contains "$OUTPUT" "slurmctld holds the new jwt.key"
  check "token Secret owned by the JWT Secret not garbage-collected" eq "$(state exists "$d" slurm-token-exporter)" yes
  check "backup records both keys" eq "$(state annotation "$d" slurm-auth-slurm-previous rotate-auth-key/rotated-keys)" "slurm.key,jwt.key"
  check "no key material in argv" no_leaks "$d"
}

test_jwt_stale_in_slurmctld_is_rolled_back() {
  local d; d=$(new_cluster jwt-stale)
  local before; before=$(state fingerprint "$d" slurm-auth-jwt jwt.key)
  FAKE_CTLD_JWT_STALE=1 run_script "$d" --jwt --timeout 2
  check "exit 3" eq "$RC" 3
  check "names jwt.key" contains "$OUTPUT" "slurmctld never picked up the new jwt.key"
  check "jwt Secret identical to before" eq "$(state fingerprint "$d" slurm-auth-jwt jwt.key)" "$before"
}

# ── Rollback ─────────────────────────────────────────────────────────────────

test_manual_rollback_cycles_slurmd_and_verifies() {
  local d; d=$(new_cluster rollback)
  local orig; orig=$(state sha "$d" slurm-auth-slurm slurm.key)
  run_script "$d" --timeout 3
  check "rotation exit 0" eq "$RC" 0
  local pods_before; pods_before=$(calls "$d" 'delete pod')
  run_script "$d" --rollback --timeout 3
  check "rollback exit 0" eq "$RC" 0
  check "rollback deleted the slurmd pods" test "$(calls "$d" 'delete pod')" -gt "$pods_before"
  check "rollback measured slurmd" contains "$OUTPUT" "every slurmd pod holds the previous slurm.key"
  check "rollback resumed the nodes" eq "$(state node "$d" slinky-0)|$(state node "$d" slinky-1)" "idle||idle|"
  check "live key is the original again" eq "$(state sha "$d" slurm-auth-slurm slurm.key)" "$orig"
  check "consumed backup deleted" eq "$(state exists "$d" slurm-auth-slurm-previous)" no
  check "never NodeName=ALL" never_all "$d"
}

test_rollback_restores_only_what_the_last_rotation_changed() {
  local d; d=$(new_cluster jwt-scope)
  run_script "$d" --jwt --timeout 3
  check "first rotation (--jwt) exit 0" eq "$RC" 0
  local jwt1 slurm1
  jwt1=$(state sha "$d" slurm-auth-jwt jwt.key)
  slurm1=$(state sha "$d" slurm-auth-slurm slurm.key)
  run_script "$d" --timeout 3
  check "second rotation (slurm.key only) exit 0" eq "$RC" 0
  run_script "$d" --rollback --timeout 3
  check "rollback exit 0" eq "$RC" 0
  check "slurm.key back to the first rotation's key" eq "$(state sha "$d" slurm-auth-slurm slurm.key)" "$slurm1"
  check "jwt.key NOT reverted to an older rotation's key" eq "$(state sha "$d" slurm-auth-jwt jwt.key)" "$jwt1"
  check "says why jwt.key was left alone" contains "$OUTPUT" "leaving jwt.key alone"
}

# Leave DIR as an interrupted run would: slinky-0 down with the preStop
# reason, slinky-1 down and not responding.
break_like_an_interrupted_run() {
  "$PYTHON" - "$1/state.json" <<'PY2'
import json, sys
p = sys.argv[1]; st = json.load(open(p))
st["nodes"]["slinky-0"].update(state="down", reason="slurm-operator: Pod is terminating")
st["nodes"]["slinky-1"].update(state="down", reason="Not responding", responding=False)
json.dump(st, open(p, "w"))
PY2
}

test_rollback_takes_back_nodes_a_rotation_left_down() {
  local d; d=$(new_cluster rb-recover)
  run_script "$d" --timeout 3
  check "rotation exit 0" eq "$RC" 0
  break_like_an_interrupted_run "$d"
  run_script "$d" --rollback --timeout 3
  check "rollback exit 0 without --allow-degraded" eq "$RC" 0
  check "says which nodes it took back" contains "$OUTPUT" "taking back nodes an earlier rotation left out of service: slinky-0,slinky-1"
  check "slinky-0 back in service" eq "$(state node "$d" slinky-0)" "idle|"
  check "slinky-1 back in service" eq "$(state node "$d" slinky-1)" "idle|"

  # Someone else's drain still needs --allow-degraded, and is left alone.
  d=$(new_cluster rb-recover-ext --node=slinky-0=idle --node=slinky-1=idle "--node=slinky-2=drain:PSU fault")
  run_script "$d" --timeout 3 --allow-degraded
  check "rotation exit 0" eq "$RC" 0
  break_like_an_interrupted_run "$d"
  run_script "$d" --rollback --timeout 3
  check "an external drain still requires --allow-degraded" eq "$RC" 1
  run_script "$d" --rollback --timeout 3 --allow-degraded
  check "rollback exit 0 with --allow-degraded" eq "$RC" 0
  check "casualties back in service" eq "$(state node "$d" slinky-0)|$(state node "$d" slinky-1)" "idle||idle|"
  check "someone else's drain left alone" eq "$(state node "$d" slinky-2)" "drain|PSU fault"
  check "slinky-2 never resumed" no_resume_of "$d" slinky-2
}

test_rollback_without_backup_refuses() {
  local d; d=$(new_cluster nobackup)
  run_script "$d" --rollback
  check "exit 1" eq "$RC" 1
  check "says so" contains "$OUTPUT" "nothing to roll back to"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

test_cleanup_deletes_only_backups_and_refuses_without_live() {
  local d; d=$(new_cluster cleanup)
  run_script "$d" --timeout 3
  local live; live=$(state sha "$d" slurm-auth-slurm slurm.key)
  run_script "$d" --cleanup
  check "exit 0" eq "$RC" 0
  check "backup deleted" eq "$(state exists "$d" slurm-auth-slurm-previous)" no
  check "live untouched" eq "$(state sha "$d" slurm-auth-slurm slurm.key)" "$live"
  check "token Secret untouched" eq "$(state exists "$d" slurm-token-exporter)" yes

  d=$(new_cluster cleanup-refuse)
  FAKE_CREATE_FAIL=slurm-auth-slurm:always run_script "$d" --timeout 2
  run_script "$d" --cleanup
  check "refuses while the live Secret is missing" eq "$RC" 1
  check "backup kept" eq "$(state exists "$d" slurm-auth-slurm-previous)" yes
}

# ── Registration wait (Makefile `slurm` target) ──────────────────────────────

test_registration_wait_rejects_unreachable_nodes() {
  local d; d=$(new_cluster reg-star "--node=slinky-0=idle*")
  FAKE_STATE="$d" "$ROOT/scripts/wait-node-registered.sh" slurm 1 >"$d/o" 2>&1; RC=$?
  OUTPUT="$d/o"
  check "idle* is not registered: exit 1" eq "$RC" 1
  d=$(new_cluster reg-ok)
  FAKE_STATE="$d" "$ROOT/scripts/wait-node-registered.sh" slurm 1 >"$d/o" 2>&1; RC=$?
  OUTPUT="$d/o"
  check "idle is registered: exit 0" eq "$RC" 0
  check "names the node" contains "$d/o" "node registered: slinky-0,slinky-1"
}

# ── The CI assertion itself must be able to fail ─────────────────────────────

test_ci_assertion_fails_on_the_wrong_failure() {
  local d; d=$(new_cluster ci)
  local A="$ROOT/scripts/ci/assert-rotation.sh"
  FAKE_STATE="$d" "$A" record "$d/rec" >/dev/null 2>&1
  FAKE_SLURMD_STALE=1 run_script "$d" --timeout 2
  FAKE_STATE="$d" "$A" expect-rolled-back "$RC" "$OUTPUT" "$d/rec" >"$d/a1" 2>&1
  check "passes on the documented rollback" eq "$?" 0

  # Preflight refusal: exit 1, nothing rolled back.
  FAKE_NODESETS_FAIL=1 run_script "$d"
  FAKE_STATE="$d" "$A" expect-rolled-back "$RC" "$OUTPUT" "$d/rec" >"$d/a2" 2>&1
  check "fails on a preflight refusal" eq "$?" 1

  # A script that does not even parse.
  printf 'if [ ; then\n' > "$d/broken.sh"
  bash "$d/broken.sh" >"$d/b.txt" 2>&1; local brc=$?
  FAKE_STATE="$d" "$A" expect-rolled-back "$brc" "$d/b.txt" "$d/rec" >"$d/a3" 2>&1
  check "fails on a syntax error" eq "$?" 1

  # Exit 3 for another reason.
  printf 'rotation failed and was rolled back (slurmd pods did not come back)\n' > "$d/other.txt"
  FAKE_STATE="$d" "$A" expect-rolled-back 3 "$d/other.txt" "$d/rec" >"$d/a4" 2>&1
  check "fails on exit 3 for an undocumented reason" eq "$?" 1

  # The right exit and message, but the Secret lost its immutable flag.
  "$PYTHON" - "$d/state.json" <<'PY'
import json, sys
p = sys.argv[1]; st = json.load(open(p)); st["secrets"]["slurm-auth-slurm"].pop("immutable"); json.dump(st, open(p, "w"))
PY
  FAKE_STATE="$d" "$A" expect-rolled-back 3 "$OUTPUT" "$d/rec" >"$d/a5" 2>&1
  check "fails when the Secret is not restored exactly" eq "$?" 1
}

test_ci_assertion_for_manual_rollback() {
  local d; d=$(new_cluster ci-rb)
  local A="$ROOT/scripts/ci/assert-rotation.sh"
  FAKE_STATE="$d" "$A" record "$d/rec" >/dev/null 2>&1
  FAKE_SLURMD_STALE=1 run_script "$d" --timeout 2
  run_script "$d" --rollback --timeout 3
  FAKE_STATE="$d" "$A" expect-restored "$RC" "$OUTPUT" "$d/rec" >"$d/a1" 2>&1
  check "rollback after a rolled-back rotation passes the CI check" eq "$?" 0
}

for t in \
  help_and_usage_errors dry_run_changes_nothing \
  rotation_succeeds_when_the_key_propagates stale_slurmd_key_is_detected_and_rolled_back \
  pre_drained_node_needs_allow_degraded pre_drained_node_is_never_resumed \
  pre_drained_node_survives_a_rollback node_states_are_classified_by_base_and_suffix \
  busy_node_states_count_as_in_service allow_degraded_refuses_a_node_that_can_still_run_jobs \
  unresponsive_node_left_alone_is_not_left_down nodeset_convergence_uses_status_desired \
  external_drain_mid_run_is_respected external_drain_during_the_drain_wait_survives_the_rotation \
  drain_timeout_leaves_an_external_drain_alone operator_drain_reason_is_not_resumed \
  operator_undrain_of_our_replacement_is_ours operator_undrain_of_a_pod_we_did_not_replace_is_someone_elses \
  operator_cordon_reasons_are_someone_elses a_cordon_after_the_operators_undrain_is_someone_elses \
  admin_reason_after_replacement_is_someone_elses \
  operator_undrain_lookalikes_are_someone_elses slurmd_pods_map_to_slurm_nodes_like_the_operator \
  drain_timeout_stops_before_touching_keys squeue_failure_is_not_zero_jobs \
  preflight_fails_closed drain_command_failure_changes_nothing \
  create_failure_once_is_retried live_secret_is_never_lost \
  interrupt_between_delete_and_create_restores_the_secret missing_live_secret_points_at_rollback \
  unmeasurable_slurmd_pod_is_a_failure rollback_survives_a_failed_diagnostic \
  exit_1_is_never_reported_after_the_key_changed slurmctld_key_is_measured \
  jwt_rotation_measures_slurmctld_and_keeps_tokens jwt_stale_in_slurmctld_is_rolled_back \
  manual_rollback_cycles_slurmd_and_verifies rollback_restores_only_what_the_last_rotation_changed \
  rollback_takes_back_nodes_a_rotation_left_down \
  rollback_without_backup_refuses cleanup_deletes_only_backups_and_refuses_without_live \
  rbac_role_covers_the_secret_calls \
  registration_wait_rejects_unreachable_nodes \
  ci_assertion_fails_on_the_wrong_failure ci_assertion_for_manual_rollback
do
  scenario "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
