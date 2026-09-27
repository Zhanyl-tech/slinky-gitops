# shellcheck shell=bash
#
# nodes.sh — one definition of "which Slurm nodes are usable", sourced by
# rotate-auth-key.sh and wait-node-registered.sh.
#
# It lives in one file because it used to live in two and they drifted: the
# rotation script's check was anchored at both ends, while the Makefile's
# bring-up gate was `grep -qE 'idle|alloc|mix'`, which also matches `idle*`
# and so reported "node registered" for a node slurmctld could not reach.
#
# Input everywhere is the output of
#
#     sinfo -N --noheader -o '%N %t %E'
#
# one line per node *per partition*, fields: node name, compact state, reason.
# Compact states and their suffixes are listed under NODE STATE CODES in
# https://slurm.schedmd.com/sinfo.html; the exact strings come from
# node_state_string_compact() in src/common/slurm_protocol_defs.c, which sinfo
# lowercases for `%t`. The suffixes are load-bearing, in both directions:
#
#   *  "not responding and will not be allocated any new work" -- exactly what
#      a slurmd holding the wrong key looks like. Out of service.
#   ~ # ! % $ @ ^   powered off / powering up / pending power down / powering
#      down / maintenance reservation / pending reboot / reboot issued.
#      Out of service.
#   +  `alloc+`: allocated, with some jobs still COMPLETING. In service.
#   -  `mix-`: "planned by the backfill scheduler for a higher priority job".
#      In service. An idle node that is planned prints as `plnd`.
#
# An earlier version matched only the bare base names, so a busy node in
# `alloc+` or `mix-` counted as out of service: it was left undrained while
# its slurmd pod was still replaced, and after the resume a `plnd` node never
# counted as schedulable.

# A node that can take a job right now. Anchored at both ends so that `idle*`,
# `idle~` and the other out-of-service suffixes do not match.
# shellcheck disable=SC2034  # used by the scripts that source this file
SCHEDULABLE_RE='^(idle|mix|alloc|plnd)[+-]?$'

# A node that is in service: schedulable, or finishing a job (`comp`). These
# are the nodes a rotation drains and must return to service afterwards.
# Anything else (drain, drng, down, fail, maint, resv, an out-of-service
# suffix, ...) was unavailable before the rotation started and is not the
# rotation's to change.
# shellcheck disable=SC2034
IN_SERVICE_RE='^(idle|mix|alloc|comp|plnd)[+-]?$'

# A node Slurm will not start a new job on: drained or draining, down, failed
# or failing (whatever the suffix), or not responding (a `*` suffix). Every
# slurmd pod is replaced by a rotation, including those of nodes it does not
# drain, so a node it leaves alone must be one of these; otherwise a job could
# start there after the drain wait and be killed by the pod replacement.
# `resv`, `maint`, `block`, `boot`, a powered-down node and the like are not:
# Slurm may still place a job on them. (The star is written `[*]` because awk
# -v processes backslash escapes in its value and `\*` is not a defined one.)
# shellcheck disable=SC2034
QUIESCED_RE='^((drain|drng|down|fail|failg)[^a-z]*|[a-z]+[*])$'

# nodes_normalise: sinfo lines -> "name<TAB>state<TAB>reason", one per node.
# sinfo prints a node once per partition, so keep the first line per name.
# sinfo prints "none" for an empty reason.
nodes_normalise() {
  awk '
    NF == 0 { next }
    seen[$1]++ { next }
    {
      reason = $0
      sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", reason)
      sub(/[ \t]+$/, "", reason)
      if (reason == "none" || reason == "(null)") reason = ""
      printf "%s\t%s\t%s\n", $1, $2, reason
    }'
}

# nodes_in_state RE: normalised table -> names whose state matches RE.
nodes_in_state() {
  awk -F '\t' -v re="$1" '$2 ~ re { print $1 }'
}

# nodes_not_in_state RE: normalised table -> full lines whose state does not match RE.
nodes_not_in_state() {
  awk -F '\t' -v re="$1" 'NF && $2 !~ re { print }'
}

# node_field NAME N: normalised table -> field N (2 = state, 3 = reason) of NAME.
node_field() {
  awk -F '\t' -v n="$1" -v f="$2" '$1 == n { print $f; exit }'
}
