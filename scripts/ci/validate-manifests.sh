#!/usr/bin/env bash
#
# validate-manifests.sh — render the Slurm chart with values/slurm.yaml at the
# pinned Slinky version and validate every object with kubeconform: built-in
# kinds against the Kubernetes schemas, Slinky custom resources against the
# CRDs from the same pinned slurm-operator-crds chart. The rotation script's
# documented Role (docs/rbac-rotate-auth-key.yaml) is validated alongside.
#
# Runs in seconds, needs no cluster, and fails before the KinD job would.
#
# Environment:
#   SLINKY_VERSION  chart version (default: the Makefile's pin)
#   CHART_SOURCE    where the charts live (default oci://ghcr.io/slinkyproject/charts);
#                   a local directory containing slurm/ and slurm-operator-crds/
#                   also works, e.g. a checkout of slurm-operator's helm/ at that tag
#   K8S_VERSION     Kubernetes schema version (default: the kind node image's)
#   OUT             working directory (default: a temp dir)
#   PYTHON          interpreter with PyYAML (default: python3)
#   HELM, KUBECONFORM  binaries (default: from PATH)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mk() { make -s -C "$ROOT" --no-print-directory "print-$1"; }
SLINKY_VERSION="${SLINKY_VERSION-$(mk SLINKY_VERSION)}"
K8S_VERSION="${K8S_VERSION:-$(mk KIND_NODE_IMAGE | sed -E 's/^[^:]+:v([0-9.]+).*/\1/')}"
CHART_SOURCE="${CHART_SOURCE:-oci://ghcr.io/slinkyproject/charts}"
PYTHON="${PYTHON:-python3}"
HELM="${HELM:-helm}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
OUT="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/slinky-validate.XXXXXX")}"
mkdir -p "$OUT"

version_flag=""
case "$CHART_SOURCE" in
  oci://*) [ -z "$SLINKY_VERSION" ] || version_flag="--version $SLINKY_VERSION" ;;
esac

echo "slurm chart ${SLINKY_VERSION:-<latest>} from $CHART_SOURCE; Kubernetes schemas v$K8S_VERSION"

# shellcheck disable=SC2086  # version_flag is empty or two words on purpose
"$HELM" template slurm "$CHART_SOURCE/slurm" $version_flag \
  --namespace slurm --values "$ROOT/values/slurm.yaml" > "$OUT/slurm.yaml"
# shellcheck disable=SC2086
"$HELM" template slurm-operator-crds "$CHART_SOURCE/slurm-operator-crds" $version_flag \
  > "$OUT/crds.yaml"

"$PYTHON" "$ROOT/scripts/ci/crd2schema.py" "$OUT/crds.yaml" "$OUT/schemas" >/dev/null

# The chart renders some optional custom-resource fields as `null` (e.g.
# Controller.spec.prologScriptRefs). The API server drops those before it
# validates: "Null values for fields that either don't specify the nullable
# flag, or give it a false value, will be pruned before defaulting happens"
# (https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#defaulting-and-nullable).
# Mirror that for custom resources, so the check fails on what the cluster
# would reject and not on what it would quietly prune.
echo "rendered objects:"
"$PYTHON" - "$OUT/slurm.yaml" "$OUT/validate.yaml" <<'PY'
import sys, yaml

def prune(node):
    if isinstance(node, dict):
        return {k: prune(v) for k, v in node.items() if v is not None}
    if isinstance(node, list):
        return [prune(v) for v in node]
    return node

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
if not docs:
    raise SystemExit("the chart rendered nothing")
out = []
for d in docs:
    print("  %s/%s %s" % (d.get("apiVersion"), d.get("kind"), d["metadata"]["name"]))
    api = d.get("apiVersion", "")
    group = api.split("/")[0] if "/" in api else ""
    custom = "." in group and not group.endswith(".k8s.io")
    out.append(prune(d) if custom else d)
with open(sys.argv[2], "w") as f:
    yaml.safe_dump_all(out, f, sort_keys=False)
PY

"$KUBECONFORM" -strict -summary \
  -kubernetes-version "$K8S_VERSION" \
  -schema-location default \
  -schema-location "$OUT/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "$OUT/validate.yaml" "$ROOT/docs/rbac-rotate-auth-key.yaml"
