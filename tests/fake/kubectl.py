#!/usr/bin/env python3
"""A fake `kubectl` for testing rotate-auth-key.sh without a cluster.

It models exactly the behaviour the rotation script depends on, each piece
taken from something observed on a live cluster or read in upstream source,
so that a test failing here means the script would misbehave there:

- Secrets: get / create -f - / delete. There is no `patch` and no `apply`:
  the chart's auth Secrets are immutable, so the only legal change is delete
  and recreate. Deleting without --cascade=orphan garbage-collects Secrets
  whose ownerReferences point at the deleted one (in Slinky v1.2.0 the
  auth-token Secrets are owned by the JWT key Secret: BuildTokenSecret).
- slurmd pods: deleting them runs the preStop hook from
  internal/builder/workerbuilder/worker_app.go at v1.2.0, which sets the
  node DOWN with reason "slurm-operator: Pod is terminating" (keeping any
  DRAIN flag). New pods mount the live Secret -- or, with
  FAKE_SLURMD_STALE=1, the copy the node cached at the start, which is the
  failure the README documents.
- Slurm nodes: DRAIN / RESUME with Slurm's state rules. RESUME on a node
  whose slurmd holds a different key from slurmctld leaves it "idle*" (not
  responding), which is what a failed authentication looks like.

State lives in $FAKE_STATE/state.json. Every invocation's argv is appended to
$FAKE_STATE/calls.log, so tests can assert what was (never) run, including
that no key material ever appeared on a command line. Scenario knobs are
FAKE_* environment variables, documented where they are read.
"""

import base64
import hashlib
import json
import os
import sys

STATE_DIR = os.environ["FAKE_STATE"]
STATE_PATH = os.path.join(STATE_DIR, "state.json")
env = os.environ.get


def load():
    with open(STATE_PATH) as f:
        return json.load(f)


st = load()


def save():
    with open(STATE_PATH, "w") as f:
        json.dump(st, f, indent=1, sort_keys=True)


def log(name, line):
    with open(os.path.join(STATE_DIR, name), "a") as f:
        f.write(line + "\n")


def out(s):
    sys.stdout.write(s)


def fail(msg, rc=1):
    save()
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


def done():
    save()
    sys.exit(0)


def sha_b64(v):
    return hashlib.sha256(base64.b64decode(v)).hexdigest()


def remember(secret):
    for v in (secret.get("data") or {}).values():
        if v not in st["seen_values"]:
            st["seen_values"].append(v)


def script_pid():
    """The rotation script's own pid: the topmost ancestor still running it
    (pipelines run kubectl from forked subshells with the same command line)."""
    import subprocess

    def info(pid):
        line = subprocess.run(["ps", "-o", "ppid=,command=", "-p", str(pid)],
                              capture_output=True, text=True).stdout.strip()
        ppid, _, cmd = line.partition(" ")
        return int(ppid or 0), cmd

    pid = os.getppid()
    while True:
        ppid, _ = info(pid)
        _, parent_cmd = info(ppid)
        if "rotate-auth-key.sh" not in parent_cmd:
            return pid
        pid = ppid


def next_uid():
    st["gen"] += 1
    return "uid-%d" % st["gen"]


argv = sys.argv[1:]
log("calls.log", "kubectl " + " ".join(argv))
args = []
i = 0
while i < len(argv):
    if argv[i] in ("--namespace", "-n"):
        i += 2
        continue
    args.append(argv[i])
    i += 1
joined = " ".join(args)
verb = args[0] if args else ""


def opt(name):
    for j, a in enumerate(args):
        if a == name and j + 1 < len(args):
            return args[j + 1]
        if a.startswith(name + "="):
            return a[len(name) + 1:]
    return None


# ── Slurm node model ────────────────────────────────────────────────────────


def compact(n):
    """sinfo %t. `state` may carry Slurm's `+` / `-` suffix (alloc+, mix-) or
    be plnd; a drain flag and not-responding take precedence over those, as in
    node_state_string_compact() (src/common/slurm_protocol_defs.c)."""
    base = n["state"].rstrip("+-")
    if n["drain"]:
        s = "drng" if base in ("alloc", "mix", "comp") else "drain"
    else:
        s = n["state"]
    if not n["responding"]:
        s = ("idle" if s == "plnd" else s.rstrip("+-")) + "*"
    return s


def pod_for(node):
    for p in st["slurmd"]:
        if p["node"] == node:
            return p
    return None


def slurmd_authenticates(node):
    p = pod_for(node)
    return p is not None and p["key"] == st["controller"]["slurm.key"]


def external_drain(phase):
    """FAKE_EXTERNAL_DRAIN=node:reason drains that node once, with that reason,
    the way `scontrol update State=DRAIN Reason=...` from a health check does
    (it replaces whatever reason the node had). When is set by
    FAKE_EXTERNAL_DRAIN_AT:
      after-cycle (default)  on the first sinfo after slurmd pods were replaced
      drain-wait             on the first squeue while the node carries the
                             rotation's own drain tag, i.e. while the script
                             waits for jobs -- when epilogs run
    Logged to events.log as EXTERNAL-DRAIN so tests can check what came after."""
    spec = env("FAKE_EXTERNAL_DRAIN")
    if not spec or st.get("external_done") or env("FAKE_EXTERNAL_DRAIN_AT", "after-cycle") != phase:
        return
    node, reason = spec.split(":", 1)
    n = st["nodes"][node]
    if phase == "after-cycle" and st["pod_cycles"] == 0:
        return
    if phase == "drain-wait" and not n["reason"].startswith("rotate-auth-key "):
        return
    n["drain"] = True
    n["reason"] = reason
    st["external_done"] = True
    log("events.log", "EXTERNAL-DRAIN %s %s" % (node, reason))


def scontrol_update(rest):
    kv = {}
    for a in rest[2:]:
        if "=" in a:
            k, v = a.split("=", 1)
            kv[k.lower()] = v
    names = kv.get("nodename", "")
    state = kv.get("state", "").upper()
    targets = list(st["nodes"]) if names == "ALL" else names.split(",")
    log("scontrol.log", " ".join(rest))
    if env("FAKE_SCONTROL_FAIL") == state:
        fail("slurm_update error: Unable to contact slurm controller")
    rc = 0
    for name in targets:
        n = st["nodes"].get(name)
        if n is None:
            fail("Invalid node name specified")
        if state == "DRAIN":
            if not kv.get("reason"):
                fail("You must specify a reason when DOWNING or DRAINING a node. Request denied")
            n["drain"] = True
            n["reason"] = kv["reason"]
            log("events.log", "DRAIN %s %s" % (name, kv["reason"]))
        elif state == "RESUME":
            log("events.log", "RESUME %s reason=%s" % (name, n["reason"]))
            if not (n["drain"] or n["state"] == "down"):
                sys.stderr.write("Invalid node state transition requested\n")
                rc = 1
                continue
            n["drain"] = False
            n["reason"] = ""
            # FAKE_RESUMED_STATE=plnd (or mix-, alloc+): what the node shows
            # once back, e.g. planned at once by the backfill scheduler.
            n["state"] = env("FAKE_RESUMED_STATE", "idle")
            n["responding"] = slurmd_authenticates(name)
        else:
            fail("fake scontrol: unhandled state %r" % state, 2)
    save()
    sys.exit(rc)


# ── Commands ────────────────────────────────────────────────────────────────

if verb == "get" and len(args) > 1 and args[1] == "secret":
    name = args[2]
    sec = st["secrets"].get(name)
    if sec is None:
        fail('Error from server (NotFound): secrets "%s" not found' % name)
    fmt = opt("-o")
    if fmt == "json":
        out(json.dumps(sec))
    elif fmt == "jsonpath={.immutable}":
        out("true" if sec.get("immutable") else "")
    elif fmt is None:
        out("NAME TYPE DATA\n%s %s %d\n" % (name, sec.get("type", "Opaque"), len(sec.get("data", {}))))
    else:
        fail("fake kubectl: unhandled secret output %r" % fmt, 2)
    done()

if verb == "create":
    if opt("-f") != "-":
        # The script must never pass key material as arguments
        # (e.g. `create secret generic --from-literal`).
        fail("fake kubectl: only `create -f -` is modelled; got: " + joined, 2)
    try:
        obj = json.load(sys.stdin)
    except ValueError as e:
        fail("error: error parsing STDIN: %s" % e)
    if obj.get("kind") != "Secret" or obj.get("apiVersion") != "v1":
        fail("fake kubectl: only v1 Secrets are modelled", 2)
    name = obj["metadata"]["name"]
    # FAKE_TERM_ON_CREATE=<name>: the first create of <name> fails and the
    # rotation script receives SIGTERM, as if the operator hit Ctrl-C (or CI
    # cancelled the job) in the window between deleting and recreating it.
    if env("FAKE_TERM_ON_CREATE") == name and not st.get("term_sent"):
        st["term_sent"] = True
        os.kill(script_pid(), 15)
        fail("error: context canceled")
    # FAKE_CREATE_FAIL=<name>:<count|always> fails that many creates of <name>.
    spec = env("FAKE_CREATE_FAIL")
    if spec:
        fname, count = spec.split(":")
        used = st.setdefault("create_failures", {}).get(fname, 0)
        if fname == name and (count == "always" or used < int(count)):
            st["create_failures"][fname] = used + 1
            fail('error: failed to create secret: Post "https://127.0.0.1:6443/api/v1/'
                 'namespaces/slurm/secrets": context deadline exceeded')
    if name in st["secrets"]:
        fail('Error from server (AlreadyExists): secrets "%s" already exists' % name)
    for v in (obj.get("data") or {}).values():
        base64.b64decode(v, validate=True)
    obj["metadata"]["uid"] = next_uid()
    obj["metadata"]["resourceVersion"] = str(st["gen"])
    obj["metadata"]["creationTimestamp"] = "2026-09-26T00:00:00Z"
    obj["metadata"]["managedFields"] = [{"manager": "kubectl-create"}]
    st["secrets"][name] = obj
    remember(obj)
    log("events.log", "CREATE %s" % name)
    out("secret/%s created\n" % name)
    done()

if verb == "delete" and args[1] == "secret":
    name = args[2]
    sec = st["secrets"].pop(name, None)
    if sec is None:
        fail('Error from server (NotFound): secrets "%s" not found' % name)
    log("events.log", "DELETE %s" % name)
    if opt("--cascade") != "orphan":
        uid = sec["metadata"]["uid"]
        for other in list(st["secrets"]):
            refs = st["secrets"][other]["metadata"].get("ownerReferences") or []
            if any(r.get("uid") == uid for r in refs):
                del st["secrets"][other]
                log("events.log", "GC %s (owner %s deleted)" % (other, name))
    out('secret "%s" deleted\n' % name)
    done()

if verb in ("patch", "apply", "replace", "edit", "annotate", "label"):
    fail("fake kubectl: `%s` is not modelled on purpose: the auth Secrets are immutable" % verb, 2)

if verb == "get" and args[1].startswith("nodesets"):
    # FAKE_NODESETS_FAIL=1: the CRD is missing or RBAC denies the list.
    if env("FAKE_NODESETS_FAIL") == "1":
        fail('error: the server doesn\'t have a resource type "nodesets"')
    if opt("-o") == "json":
        out(json.dumps({"apiVersion": "v1", "kind": "List", "items": st["nodesets"]}))
    else:
        out("NAME REPLICAS UPDATED READY\n")
        for n in st["nodesets"]:
            s = n.get("status", {})
            out("%s %s %s %s\n" % (n["metadata"]["name"], s.get("replicas"), s.get("updatedReplicas"),
                                   s.get("readyReplicas")))
    done()

if verb == "get" and args[1] == "pods":
    fmt = opt("-o") or ""
    if "app.kubernetes.io/component=controller" in joined:
        out("pod/slurm-controller-0\n" if fmt == "name" else "slurm-controller-0 1/1 Running\n")
        done()
    if "app.kubernetes.io/name=slurmd" in joined:
        if fmt == "name":
            out("".join("pod/%s\n" % p["name"] for p in st["slurmd"]))
        elif "containerStatuses" in fmt:
            ready = "false" if env("FAKE_PODS_NEVER_READY") == "1" else "true"
            out("".join("%s %s\n" % (p["uid"], ready) for p in st["slurmd"]))
        else:
            fail("fake kubectl: unhandled slurmd pod output %r" % fmt, 2)
        done()
    # `kubectl get pods -o wide`: diagnostics only. FAKE_WIDE_FAIL=1: it fails,
    # as one API call in the middle of a rollback can.
    if env("FAKE_WIDE_FAIL") == "1":
        fail("error: the server was unable to return a response in the time allotted, "
             "but may still be processing the request (get pods)")
    out("NAME READY STATUS NODE\nslurm-controller-0 1/1 Running kind-worker\n")
    out("".join("%s 1/1 Running kind-worker\n" % p["name"] for p in st["slurmd"]))
    done()

if verb == "delete" and args[1] == "pod":
    if "app.kubernetes.io/name=slurmd" not in joined:
        fail("fake kubectl: unhandled pod delete", 2)
    st["pod_cycles"] += 1
    live = st["secrets"].get("slurm-auth-slurm", {}).get("data", {}).get("slurm.key")
    for p in st["slurmd"]:
        # preStop hook of the slurmd container (worker_app.go, v1.2.0).
        n = st["nodes"][p["node"]]
        n["state"] = "down"
        n["reason"] = "slurm-operator: Pod is terminating"
        # The replacement pod.
        p["uid"] = next_uid()
        if env("FAKE_SLURMD_STALE") == "1":
            p["key"] = st["node_cache"]
        else:
            p["key"] = live
    done()

if verb == "rollout":
    if args[1] == "restart":
        c = st["controller"]
        for key, secret, knob in (("slurm.key", "slurm-auth-slurm", "FAKE_CTLD_STALE"),
                                  ("jwt.key", "slurm-auth-jwt", "FAKE_CTLD_JWT_STALE")):
            if env(knob) != "1" and secret in st["secrets"]:
                c[key] = st["secrets"][secret]["data"][key]
    done()

if verb == "wait":
    done()

if verb == "exec":
    pod = args[1].split("/")[-1]
    rest = args[args.index("--") + 1:]
    tool = rest[0]
    is_ctld = pod.startswith("slurm-controller")
    if tool == "sha256sum":
        # FAKE_EXEC_FAIL_POD=<substring>: exec into matching pods fails.
        if env("FAKE_EXEC_FAIL_POD") and env("FAKE_EXEC_FAIL_POD") in pod:
            fail('error: unable to upgrade connection: container not found ("slurmd")')
        path = rest[1]
        key = os.path.basename(path)
        if is_ctld:
            value = st["controller"].get(key)
        else:
            p = [x for x in st["slurmd"] if x["name"] == pod]
            value = p[0]["key"] if p and key == "slurm.key" else None
        if not value:
            fail("sha256sum: %s: No such file or directory" % path)
        out("%s  %s\n" % (sha_b64(value), path))
        done()
    if not is_ctld:
        fail("fake kubectl: unhandled exec in %s: %s" % (pod, " ".join(rest)), 2)
    if tool == "sinfo":
        # FAKE_SINFO_FAIL=1: slurmctld does not answer.
        if env("FAKE_SINFO_FAIL") == "1":
            fail("sinfo: error: Unable to contact slurm controller (connect failure)")
        external_drain("after-cycle")
        # One line per node per partition, as `sinfo -N` prints them.
        for _partition in st.get("partitions", ["all"]):
            for name, n in st["nodes"].items():
                out("%s %s %s\n" % (name, compact(n), n["reason"] or "none"))
        done()
    if tool == "squeue":
        # FAKE_RUNNING_JOBS=N: N jobs never finish. FAKE_SQUEUE_FAIL=1: squeue errors.
        if env("FAKE_SQUEUE_FAIL") == "1":
            fail("squeue: error: Unable to contact slurm controller (connect failure)")
        external_drain("drain-wait")
        for j in range(int(env("FAKE_RUNNING_JOBS", "0"))):
            out("%d all job%d user R 5:00 1 slinky-0\n" % (100 + j, j))
        done()
    if tool == "scontrol" and rest[1] == "show":
        out("AuthType                = %s\nCredType                = cred/slurm\n"
            % env("FAKE_AUTHTYPE", "auth/slurm"))
        done()
    if tool == "scontrol" and rest[1] == "update":
        scontrol_update(rest)
    fail("fake kubectl: unhandled exec: " + " ".join(rest), 2)

fail("fake kubectl: unhandled: " + joined, 2)
