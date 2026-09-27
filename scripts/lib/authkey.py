#!/usr/bin/env python3
"""JSON plumbing for rotate-auth-key.sh.

Why this is a separate program rather than inline `kubectl patch -p '{...}'`:
key material must never appear on a command line. argv is readable by every
local user through `ps` and /proc, and an earlier version of the rotation
script passed the base64 key to `kubectl patch -p` three times per run. Here,
every Secret manifest is built from JSON on stdin and printed on stdout, and
the shell hands it to `kubectl create -f -` on stdin. Nothing in this
program's argv is secret: arguments are object names, key names and
bookkeeping strings only.

Standard library only, so it runs on whatever python3 the admin host has
(3.8 or newer).

Usage: authkey.py MODE [ARGS...]   (input on stdin, output on stdout)

  clean                      live Secret -> manifest `kubectl create -f -` accepts
  sha KEY                    Secret -> sha256 of the decoded value of KEY ("" if absent)
  with-new-key KEY           manifest -> same manifest, KEY replaced by 1024 fresh random bytes
  backup NAME RUN CREATED ROTATED
                             live Secret -> immutable, labelled backup manifest called NAME
  staging NAME RUN           manifest -> the same data as an immutable Secret called NAME
  restore KEY NAME           {"live": Secret|null, "backup": Secret} -> manifest for NAME with
                             KEY taken from the backup
  annotation NAME            Secret -> value of annotation NAME ("" if absent)
  fingerprint KEY            Secret -> one line of JSON: what CI compares before/after
  nodesets                   NodeSetList -> one line per NodeSet that has not converged

Exit status: 0 on success, 3 when the input cannot be parsed or lacks what the
mode needs (so the shell can tell "bad input" from "empty answer").
"""

import base64
import hashlib
import json
import os
import sys

PREFIX = "rotate-auth-key/"
ROLE_LABEL = PREFIX + "role"
MANAGED_BY = "app.kubernetes.io/managed-by"
OUR_MANAGER = "rotate-auth-key"

# kubectl writes the full object, data included, into this annotation when a
# Secret is created with `kubectl apply`. Carrying it onto a recreated Secret
# would publish the previous key inside the new object, so it is dropped.
DROP_ANNOTATIONS = {"kubectl.kubernetes.io/last-applied-configuration"}

# auth/slurm's own documentation generates the key with
# `dd if=/dev/random of=/etc/slurm/slurm.key bs=1024 count=1`
# (https://slurm.schedmd.com/authentication.html).
KEY_BYTES = 1024


class BadInput(Exception):
    pass


def load():
    raw = sys.stdin.read()
    if not raw.strip():
        raise BadInput("empty input")
    try:
        return json.loads(raw)
    except ValueError as e:
        raise BadInput("not JSON: %s" % e) from None


def emit(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=True) + "\n")


def metadata_of(secret):
    md = secret.get("metadata") or {}
    if not md.get("name"):
        raise BadInput("object has no metadata.name")
    return md


def clean(secret):
    """A live Secret as a creatable manifest.

    Keeps what identifies the object to its owners -- labels and annotations
    (Helm records release ownership there), ownerReferences, type and the
    immutable flag -- and drops the fields the API server owns (uid,
    resourceVersion, creationTimestamp, managedFields).
    """
    md = metadata_of(secret)
    out_md = {"name": md["name"]}
    if md.get("namespace"):
        out_md["namespace"] = md["namespace"]
    labels = dict(md.get("labels") or {})
    annotations = {
        k: v for k, v in (md.get("annotations") or {}).items() if k not in DROP_ANNOTATIONS
    }
    if labels:
        out_md["labels"] = labels
    if annotations:
        out_md["annotations"] = annotations
    if md.get("ownerReferences"):
        out_md["ownerReferences"] = md["ownerReferences"]
    manifest = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": out_md,
        "type": secret.get("type") or "Opaque",
        "data": dict(secret.get("data") or {}),
    }
    if secret.get("immutable"):
        manifest["immutable"] = True
    return manifest


def sha_of(secret, key):
    value = (secret.get("data") or {}).get(key)
    if not value:
        return ""
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise BadInput("data.%s is not valid base64" % key) from None
    return hashlib.sha256(raw).hexdigest()


def with_new_key(manifest, key):
    out = json.loads(json.dumps(manifest))
    out.setdefault("data", {})[key] = base64.b64encode(os.urandom(KEY_BYTES)).decode("ascii")
    return out


def source_metadata(secret):
    """What is needed to rebuild the live Secret if it is ever missing."""
    m = clean(secret)
    return {
        "labels": m["metadata"].get("labels", {}),
        "annotations": m["metadata"].get("annotations", {}),
        "ownerReferences": m["metadata"].get("ownerReferences", []),
        "type": m["type"],
        "immutable": bool(m.get("immutable")),
    }


def backup(secret, name, run_id, created, rotated):
    """An immutable, labelled copy of the live Secret.

    Immutable so it cannot be edited into something that is not the previous
    key; labelled and annotated so `kubectl get secret -l
    rotate-auth-key/role=backup` finds it, and so `--rollback` knows which
    rotation it belongs to and which keys that rotation changed.
    """
    m = clean(secret)
    src = m["metadata"]["name"]
    md = {
        "name": name,
        "labels": {MANAGED_BY: OUR_MANAGER, ROLE_LABEL: "backup"},
        "annotations": {
            PREFIX + "source": src,
            PREFIX + "source-resource-version": str(
                (secret.get("metadata") or {}).get("resourceVersion", "")
            ),
            PREFIX + "source-metadata": json.dumps(source_metadata(secret), sort_keys=True),
            PREFIX + "run-id": run_id,
            PREFIX + "created-at": created,
            PREFIX + "rotated-keys": rotated,
        },
    }
    if m["metadata"].get("namespace"):
        md["namespace"] = m["metadata"]["namespace"]
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": md,
        "type": m["type"],
        "immutable": True,
        "data": m["data"],
    }


def staging(manifest, name, run_id):
    """The replacement, parked under its own name before the live one is deleted."""
    src = metadata_of(manifest)["name"]
    md = {
        "name": name,
        "labels": {MANAGED_BY: OUR_MANAGER, ROLE_LABEL: "staging"},
        "annotations": {PREFIX + "source": src, PREFIX + "run-id": run_id},
    }
    if manifest["metadata"].get("namespace"):
        md["namespace"] = manifest["metadata"]["namespace"]
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": md,
        "type": manifest.get("type") or "Opaque",
        "immutable": True,
        "data": dict(manifest.get("data") or {}),
    }


def restore(doc, key, name):
    live = doc.get("live")
    bk = doc.get("backup")
    if not bk:
        raise BadInput("no backup Secret given")
    value = (bk.get("data") or {}).get(key)
    if not value:
        raise BadInput("backup has no data.%s" % key)
    if live:
        out = clean(live)
    else:
        # The live Secret is gone (an interrupted run). Rebuild it from what
        # the backup recorded about it, so labels, annotations and the
        # immutable flag come back too, not just the bytes.
        ann = (bk.get("metadata") or {}).get("annotations") or {}
        raw = ann.get(PREFIX + "source-metadata")
        meta = json.loads(raw) if raw else {}
        out = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": name},
            "type": meta.get("type") or bk.get("type") or "Opaque",
            "data": dict(bk.get("data") or {}),
        }
        ns = (bk.get("metadata") or {}).get("namespace")
        if ns:
            out["metadata"]["namespace"] = ns
        for field in ("labels", "annotations", "ownerReferences"):
            if meta.get(field):
                out["metadata"][field] = meta[field]
        # A backup written before this metadata was recorded says nothing
        # about the original flag. Slinky ships these Secrets immutable, and
        # silently recreating them mutable would weaken the cluster, so
        # default to immutable.
        if meta.get("immutable", True):
            out["immutable"] = True
    out["metadata"]["name"] = name
    out.setdefault("data", {})[key] = value
    return out


def fingerprint(secret, key):
    m = clean(secret)
    return {
        "sha256": sha_of(secret, key),
        "immutable": bool(m.get("immutable")),
        "type": m["type"],
        "labels": m["metadata"].get("labels", {}),
        "annotations": m["metadata"].get("annotations", {}),
        "data_keys": sorted((secret.get("data") or {}).keys()),
    }


def nodeset_desired(item):
    """How many pods the operator wants for this NodeSet, or None if unknown.

    In slurm-operator v1.2.0 the operator publishes it as status.desired for
    both scaling modes (nodeset_sync_status.go: spec.replicas in StatefulSet
    mode, the number of matching Kubernetes nodes in DaemonSet mode).
    spec.replicas alone is wrong in DaemonSet mode: the CRD defaults it to 1
    and documents "When ScalingMode is daemonset, this field is ignored"
    (api/v1beta1/nodeset_types.go), so comparing against it refused every
    healthy DaemonSet-mode cluster with more than one node.
    """
    spec = item.get("spec") or {}
    st = item.get("status") or {}
    if "desired" in st:
        return int(st.get("desired") or 0)
    # status.desired is omitempty, so in DaemonSet mode its absence means 0.
    if spec.get("scalingMode") == "DaemonSet":
        return 0
    # An operator that does not publish status.desired: StatefulSet
    # semantics, where spec.replicas is the target.
    if spec.get("replicas") is None:
        return None
    return int(spec["replicas"])


def nodesets(doc):
    """NodeSets whose pods are not all created, updated and ready."""
    bad = []
    for item in doc.get("items") or []:
        md = item.get("metadata") or {}
        name = md.get("name", "?")
        st = item.get("status") or {}
        # status fields are omitempty in api/v1beta1, so absent means 0.
        have = int(st.get("replicas") or 0)
        want = nodeset_desired(item)
        want = have if want is None else want
        updated = int(st.get("updatedReplicas") or 0)
        ready = int(st.get("readyReplicas") or 0)
        # status.desired is only as current as the last reconcile. A spec
        # change the operator has not observed yet (observedGeneration behind
        # generation) is not converged, whatever the counts say.
        gen, seen = md.get("generation"), st.get("observedGeneration")
        stale = gen is not None and seen is not None and int(seen) < int(gen)
        if stale or not (have == want and updated == want and ready == want):
            bad.append(
                "%s desired=%d replicas=%d updated=%d ready=%d%s"
                % (name, want, have, updated, ready,
                   " (status from generation %s of %s)" % (seen, gen) if stale else "")
            )
    return bad


def main(argv):
    if not argv:
        raise BadInput("no mode given")
    mode, args = argv[0], argv[1:]

    def need(n):
        if len(args) != n:
            raise BadInput("%s takes %d argument(s)" % (mode, n))

    if mode == "clean":
        need(0)
        emit(clean(load()))
    elif mode == "sha":
        need(1)
        print(sha_of(load(), args[0]))
    elif mode == "with-new-key":
        need(1)
        emit(with_new_key(load(), args[0]))
    elif mode == "backup":
        need(4)
        emit(backup(load(), *args))
    elif mode == "staging":
        need(2)
        emit(staging(load(), *args))
    elif mode == "restore":
        need(2)
        emit(restore(load(), *args))
    elif mode == "annotation":
        need(1)
        ann = (load().get("metadata") or {}).get("annotations") or {}
        print(ann.get(args[0], ""))
    elif mode == "fingerprint":
        need(1)
        emit(fingerprint(load(), args[0]))
    elif mode == "nodesets":
        need(0)
        for line in nodesets(load()):
            print(line)
    else:
        raise BadInput("unknown mode %r" % mode)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BadInput as e:
        sys.stderr.write("authkey.py: %s\n" % e)
        sys.exit(3)
