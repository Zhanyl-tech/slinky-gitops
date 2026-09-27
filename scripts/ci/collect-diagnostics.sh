#!/usr/bin/env bash
#
# collect-diagnostics.sh OUTDIR — gather what a failed CI run needs for a
# diagnosis, so it survives as a downloadable artifact instead of only a step
# log. Every command is allowed to fail: this runs after something already has.
#
# Pod placement (`-o wide`) is collected on purpose: whether the rotation's
# stale key appears plausibly depends on which pods share a kubelet (README,
# "The part I could not fix").
set -u

out="${1:-diagnostics}"
ns="${NAMESPACE:-slurm}"
mkdir -p "$out"

run() {  # run FILE CMD...
  local f="$1"; shift
  { echo "\$ $*"; "$@"; } >"$out/$f" 2>&1 || true
}
ctl() { kubectl -n "$ns" exec slurm-controller-0 -c slurmctld -- "$@"; }

run versions.txt       helm list -A
run kubectl-version.txt kubectl version
run nodes.txt          kubectl get nodes -o wide
run pods.txt           kubectl get pods -A -o wide
run events.txt         kubectl get events -A --sort-by=.lastTimestamp
run nodesets.yaml      kubectl -n "$ns" get nodesets.slinky.slurm.net -o yaml
run nodeset-describe.txt kubectl -n "$ns" describe nodesets.slinky.slurm.net
# Metadata only: never dump Secret data into a CI artifact.
run secrets.txt        kubectl -n "$ns" get secrets --show-labels
run sinfo.txt          ctl sinfo -N -l
run sinfo-reasons.txt  ctl sinfo -R
run squeue.txt         ctl squeue -l
run slurmctld.log      kubectl -n "$ns" logs -l app.kubernetes.io/component=controller -c slurmctld --tail=500
run slurmd.log         kubectl -n "$ns" logs -l app.kubernetes.io/name=slurmd -c slurmd --tail=500 --prefix
run slurmrestd.log     kubectl -n "$ns" logs -l app.kubernetes.io/name=slurmrestd --tail=300
run operator.log       kubectl -n slinky logs -l app.kubernetes.io/instance=slurm-operator --tail=500 --prefix

echo "diagnostics written to $out/"
ls -l "$out"
