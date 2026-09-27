#!/usr/bin/env bash
#
# assert-rotation.sh — what the CI rotation steps actually assert.
#
#   assert-rotation.sh record DIR
#       Save a fingerprint of each live auth Secret (sha256 of the key,
#       immutable flag, type, labels, annotations, data keys) into DIR.
#
#   assert-rotation.sh expect-rolled-back RC LOG DIR
#       The rotation must have exited 3 ("did not take; previous key restored
#       and verified"), for the documented reason (slurmd never picked up the
#       new key), and left each live Secret exactly as recorded, with its
#       backup present and immutable.
#
#   assert-rotation.sh expect-restored RC LOG DIR
#       A --rollback must have exited 0 and left each live Secret exactly as
#       recorded, with the backup it consumed deleted.
#
# Why this exists: the first version of this CI step was
#     if make rotate; then exit 1; fi; echo "rolled back, as expected"
# which passes on *any* failure, including the script dying in preflight or
# not parsing at all. A check that cannot fail in the direction that matters
# is the defect this repo is about, so each condition here is explicit.
# It also calls the script directly in CI rather than through make, because
# make reports every recipe failure as exit 2 and would hide the code.
#
# Environment: NAMESPACE (default slurm), PYTHON (default python3).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NAMESPACE="${NAMESPACE:-slurm}"
PYTHON="${PYTHON:-python3}"
SECRETS="slurm-auth-slurm:slurm.key slurm-auth-jwt:jwt.key"

fail() { echo "::error::$1"; echo "FAIL: $1" >&2; exit 1; }
fingerprint() {
  kubectl --namespace "$NAMESPACE" get secret "$1" -o json 2>/dev/null \
    | "$PYTHON" "$ROOT/scripts/lib/authkey.py" fingerprint "$2" 2>/dev/null || echo MISSING
}

compare_to_record() {
  local dir="$1" spec name key now
  for spec in $SECRETS; do
    name=${spec%%:*}; key=${spec#*:}
    [ -f "$dir/$name.json" ] || fail "no recorded fingerprint for $name in $dir"
    now=$(fingerprint "$name" "$key")
    [ "$now" = "$(cat "$dir/$name.json")" ] \
      || fail "$name is not what it was before the rotation. before: $(cat "$dir/$name.json") now: $now"
    echo "ok: $name matches its pre-rotation fingerprint (key, immutable, labels, annotations)"
  done
}

case "${1:-}" in
  record)
    dir="$2"; mkdir -p "$dir"
    for spec in $SECRETS; do
      name=${spec%%:*}; key=${spec#*:}
      fp=$(fingerprint "$name" "$key")
      [ "$fp" != MISSING ] || fail "$name not found; cannot record it"
      printf '%s\n' "$fp" > "$dir/$name.json"
      echo "recorded $name: $fp"
    done
    ;;
  expect-rolled-back)
    rc="$2"; log="$3"; dir="$4"
    [ "$rc" = 3 ] || fail "expected exit 3 (new key did not take, previous key restored and verified); got $rc. If it is 0, rotation now works on this version: update the README and this step."
    grep -q "slurmd never picked up the new key" "$log" \
      || fail "exit 3, but not for the documented reason (slurmd never picked up the new key); read the log"
    grep -q "rotation failed and was rolled back" "$log" || fail "no rollback confirmation in the log"
    compare_to_record "$dir"
    for spec in $SECRETS; do
      name=${spec%%:*}
      if kubectl --namespace "$NAMESPACE" get secret "$name-previous" >/dev/null 2>&1; then
        [ "$(kubectl --namespace "$NAMESPACE" get secret "$name-previous" -o jsonpath='{.immutable}')" = true ] \
          || fail "$name-previous exists but is not immutable"
        echo "ok: $name-previous present and immutable"
      fi
    done
    kubectl --namespace "$NAMESPACE" get secret slurm-auth-slurm-previous >/dev/null 2>&1 \
      || fail "slurm-auth-slurm-previous missing after a rolled-back rotation"
    ;;
  expect-restored)
    rc="$2"; log="$3"; dir="$4"
    [ "$rc" = 0 ] || fail "expected --rollback to exit 0; got $rc"
    grep -q "Rollback complete" "$log" || fail "no 'Rollback complete' in the log"
    compare_to_record "$dir"
    ! kubectl --namespace "$NAMESPACE" get secret slurm-auth-slurm-previous >/dev/null 2>&1 \
      || fail "slurm-auth-slurm-previous still present after a verified rollback"
    echo "ok: the consumed backup was deleted"
    ;;
  *)
    echo "usage: $0 record DIR | expect-rolled-back RC LOG DIR | expect-restored RC LOG DIR" >&2
    exit 2
    ;;
esac
