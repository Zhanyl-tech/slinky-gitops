#!/usr/bin/env python3
"""check-yaml.py [ROOT] — parse every YAML file in the repo with PyYAML.

A YAML file that does not parse fails late and confusingly (kind, Helm and
GitHub Actions each report it differently), so CI parses all of them first.
Prints one line per file; exits 1 if any file fails to parse or none are found.
"""

import os
import sys

import yaml

SKIP_DIRS = {".git", ".ci-venv", ".venv", "node_modules", "diagnostics"}


def main(root):
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if name.endswith((".yaml", ".yml")):
                files.append(os.path.join(dirpath, name))
    if not files:
        print("no YAML files found under %s" % root)
        return 1
    bad = 0
    for path in files:
        rel = os.path.relpath(path, root)
        try:
            with open(path) as f:
                docs = [d for d in yaml.safe_load_all(f) if d is not None]
            print("ok    %s (%d document%s)" % (rel, len(docs), "" if len(docs) == 1 else "s"))
        except yaml.YAMLError as e:
            bad += 1
            print("FAIL  %s: %s" % (rel, e))
    print("%d file(s), %d failed" % (len(files), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
