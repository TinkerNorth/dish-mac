#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  check-bundled-db.sh — the controller database a built app ships, checked.
#
#  The app falls back to an empty set when its bundled copy does not verify,
#  and still launches, so a packaging slip that drops or changes one file
#  ships green unless something reads the copy itself. This checks the folder
#  holds the manifest and the seven data files, that the manifest names those
#  seven and no other, and that each one's size and SHA-256 are the
#  manifest's. launch-smoke.sh runs it on the built app before launching it.
#
#  Usage: scripts/check-bundled-db.sh <path/to/controllers-v1>
# ============================================================================

set -euo pipefail

FOLDER="${1:?usage: check-bundled-db.sh <controllers-v1 folder>}"

python3 -I - "$FOLDER" << 'PY'
import hashlib, json, os, sys

folder = sys.argv[1]
data_files = ["controllers.json"] + ["strings/%s.json" % locale for locale in ["en", "bs", "de", "es", "fr", "pt-BR"]]
failures = []
for path in ["manifest.json"] + data_files:
    if not os.path.isfile(os.path.join(folder, path)):
        failures.append("missing " + path)
if not failures:
    with open(os.path.join(folder, "manifest.json"), "rb") as handle:
        named = json.load(handle).get("files", {})
    if sorted(named) != sorted(data_files):
        failures.append("the manifest names %s" % sorted(named))
    for path in data_files:
        with open(os.path.join(folder, path), "rb") as handle:
            body = handle.read()
        entry = named.get(path, {})
        if len(body) != entry.get("bytes"):
            failures.append("%s is %d bytes, the manifest says %s" % (path, len(body), entry.get("bytes")))
        elif hashlib.sha256(body).hexdigest() != str(entry.get("sha256", "")).lower():
            failures.append("%s does not match its SHA-256" % path)
for failure in failures:
    print("Bundled controller database: " + failure, file=sys.stderr)
sys.exit(1 if failures else 0)
PY
echo "The bundled controller database matches its manifest."
