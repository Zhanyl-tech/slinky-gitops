#!/usr/bin/env python3
"""Create and inspect the fake cluster used by tests/run.sh.

  state.py init DIR [--node NAME=STATE[:REASON]]... [--not-ready] [--daemonset]
      A healthy Slinky-shaped cluster: immutable, Helm-labelled auth Secrets,
      one slurmd pod per node, and an auth-token Secret owned by the JWT key
      Secret (as BuildTokenSecret does in slurm-operator v1.2.0). STATE is a
      compact sinfo state (idle, alloc+, mix-, drain, idle*, maint, ...).
      --daemonset: the NodeSet uses scalingMode DaemonSet, so spec.replicas
      keeps the CRD default of 1 and only status.desired has the real target.
  state.py sha DIR SECRET KEY        sha256 of the key, or MISSING
  state.py fingerprint DIR SECRET KEY
                                     what CI compares: sha, immutable, labels, annotations
  state.py exists DIR SECRET         yes / no
  state.py annotation DIR SECRET NAME
  state.py label DIR SECRET NAME
  state.py node DIR NODE             "<compact state>|<reason>"
  state.py leaks DIR                 key values found in calls.log (argv), if any
  state.py count DIR PATTERN         lines of calls.log containing PATTERN
"""

import base64
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts", "lib"))
import authkey  # noqa: E402


def key():
    return base64.b64encode(os.urandom(1024)).decode("ascii")


def helm_secret(name, k, value):
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": name,
            "namespace": "slurm",
            "uid": "uid-%s" % name,
            "resourceVersion": "100",
            "creationTimestamp": "2026-09-01T00:00:00Z",
            "labels": {
                "app.kubernetes.io/managed-by": "Helm",
                "app.kubernetes.io/instance": "slurm",
                "app.kubernetes.io/name": "slurm",
            },
            "annotations": {
                "meta.helm.sh/release-name": "slurm",
                "meta.helm.sh/release-namespace": "slurm",
            },
            "managedFields": [{"manager": "helm"}],
        },
        "type": "Opaque",
        "immutable": True,
        "data": {k: value},
    }


def init(d, argv):
    nodes = {}
    not_ready = False
    daemonset = False
    for a in argv:
        if a == "--not-ready":
            not_ready = True
        elif a == "--daemonset":
            daemonset = True
        elif a.startswith("--node="):
            spec = a[len("--node="):]
            name, _, rest = spec.partition("=")
            state, _, reason = rest.partition(":")
            drain = state in ("drain", "drng")
            base = {"drain": "idle", "drng": "alloc"}.get(state, state)
            responding = not base.endswith("*")
            nodes[name] = {"state": base.rstrip("*"), "drain": drain, "reason": reason,
                           "responding": responding}
        else:
            raise SystemExit("unknown init option %r" % a)
    if not nodes:
        nodes = {n: {"state": "idle", "drain": False, "reason": "", "responding": True}
                 for n in ("slinky-0", "slinky-1")}
    slurm_key, jwt_key = key(), key()
    auth = helm_secret("slurm-auth-slurm", "slurm.key", slurm_key)
    jwt = helm_secret("slurm-auth-jwt", "jwt.key", jwt_key)
    token = {
        "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
        "metadata": {"name": "slurm-token-exporter", "namespace": "slurm", "uid": "uid-token",
                     "ownerReferences": [{"apiVersion": "v1", "kind": "Secret", "name": "slurm-auth-jwt",
                                          "uid": "uid-slurm-auth-jwt", "controller": True}]},
        "data": {"auth-token": base64.b64encode(b"a-jwt").decode()},
    }
    n = len(nodes)
    st = {
        "gen": 1000,
        "pod_cycles": 0,
        "node_cache": slurm_key,
        "seen_values": [slurm_key, jwt_key],
        "partitions": ["all", "debug"],
        "secrets": {"slurm-auth-slurm": auth, "slurm-auth-jwt": jwt, "slurm-token-exporter": token},
        "controller": {"slurm.key": slurm_key, "jwt.key": jwt_key},
        "slurmd": [{"name": "slurm-worker-%s" % name, "node": name, "uid": "uid-0-%s" % name,
                    "key": slurm_key} for name in nodes],
        "nodes": nodes,
        # Shaped like v1.2.0: status.desired is published in both scaling
        # modes (nodeset_sync_status.go).
        "nodesets": [{"metadata": {"name": "slurm-worker-slinky", "generation": 1},
                      "spec": ({"replicas": 1, "scalingMode": "DaemonSet"} if daemonset
                               else {"replicas": n, "scalingMode": "StatefulSet"}),
                      "status": {"replicas": n, "updatedReplicas": n, "desired": n,
                                 "observedGeneration": 1,
                                 "readyReplicas": 0 if not_ready else n}}],
    }
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "state.json"), "w") as f:
        json.dump(st, f, indent=1, sort_keys=True)
    for name in ("calls.log", "scontrol.log", "events.log"):
        open(os.path.join(d, name), "w").close()


def load(d):
    with open(os.path.join(d, "state.json")) as f:
        return json.load(f)


def compact(n):
    # Same rules as compact() in kubectl.py.
    base = n["state"].rstrip("+-")
    if n["drain"]:
        s = "drng" if base in ("alloc", "mix", "comp") else "drain"
    else:
        s = n["state"]
    if not n["responding"]:
        s = ("idle" if s == "plnd" else s.rstrip("+-")) + "*"
    return s


def main(argv):
    cmd, d = argv[0], argv[1]
    if cmd == "init":
        init(d, argv[2:])
        return
    st = load(d)
    secrets = st["secrets"]
    if cmd == "sha":
        s = secrets.get(argv[2])
        v = (s or {}).get("data", {}).get(argv[3])
        print(hashlib.sha256(base64.b64decode(v)).hexdigest() if v else "MISSING")
    elif cmd == "fingerprint":
        s = secrets.get(argv[2])
        print(json.dumps(authkey.fingerprint(s, argv[3]), sort_keys=True) if s else "MISSING")
    elif cmd == "exists":
        print("yes" if argv[2] in secrets else "no")
    elif cmd == "annotation":
        s = secrets.get(argv[2]) or {}
        print((s.get("metadata", {}).get("annotations") or {}).get(argv[3], ""))
    elif cmd == "label":
        s = secrets.get(argv[2]) or {}
        print((s.get("metadata", {}).get("labels") or {}).get(argv[3], ""))
    elif cmd == "node":
        n = st["nodes"][argv[2]]
        print("%s|%s" % (compact(n), n["reason"]))
    elif cmd == "leaks":
        with open(os.path.join(d, "calls.log")) as f:
            calls = f.read()
        for v in st["seen_values"]:
            # Any 24-character run of a key's base64 is enough to call it a leak.
            for i in range(0, len(v) - 24, 24):
                if v[i:i + 24] in calls:
                    print(v[:12] + "...")
                    break
    elif cmd == "count":
        with open(os.path.join(d, "calls.log")) as f:
            print(sum(1 for line in f if argv[2] in line))
    else:
        raise SystemExit("unknown command %r" % cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
