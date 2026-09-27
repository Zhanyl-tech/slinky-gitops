#!/usr/bin/env python3
"""crd2schema.py CRDS.yaml OUTDIR — turn CustomResourceDefinitions into JSON
schemas laid out for kubeconform's
    -schema-location 'OUTDIR/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

Why: values/slurm.yaml is only as good as what the chart renders from it, and
the chart renders Slinky custom resources (Controller, NodeSet, RestApi) that
kubeconform has no built-in schema for. Validating them against the CRDs of
the *pinned* slurm-operator-crds chart catches a values key that renders into
a field the operator does not know, before a KinD run spends minutes finding
out.

Objects that declare properties get `additionalProperties: false` (unless the
CRD marks them x-kubernetes-preserve-unknown-fields), which is what makes
kubeconform reject unknown fields; the same approach as kubeconform's
openapi2jsonschema helper. Needs PyYAML.
"""

import json
import os
import sys

import yaml


def tighten(node):
    if isinstance(node, dict):
        if (
            node.get("type") == "object"
            and "properties" in node
            and "additionalProperties" not in node
            and not node.get("x-kubernetes-preserve-unknown-fields")
        ):
            node["additionalProperties"] = False
        for v in node.values():
            tighten(v)
    elif isinstance(node, list):
        for v in node:
            tighten(v)
    return node


def main(src, outdir):
    written = 0
    with open(src) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    for doc in docs:
        if doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc["spec"]
        group = spec["group"]
        kind = spec["names"]["kind"].lower()
        for v in spec.get("versions", []):
            schema = (v.get("schema") or {}).get("openAPIV3Schema")
            if not schema:
                continue
            path = os.path.join(outdir, group, "%s_%s.json" % (kind, v["name"]))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as out:
                json.dump(tighten(schema), out, indent=1, sort_keys=True)
            written += 1
            print(path)
    if not written:
        raise SystemExit("no CRD schemas found in %s" % src)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
