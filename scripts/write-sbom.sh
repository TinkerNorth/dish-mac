#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  write-sbom.sh: the SPDX bill of materials of what Dish.app carries,
#  dish-mac-components.spdx.json.
#
#  Syft, which the release hardening runs over the release directory, does not
#  look inside dish-mac.zip and names nothing in it. This document is written
#  from the tree the build used instead:
#
#    * every package Package.resolved pins (today sentry-cocoa), at its version
#      and revision;
#    * ENet, ported to Swift from the cgutman fork at the commit THIRD_PARTY.md
#      names (no C is compiled, but the protocol logic is the fork's);
#    * the controller database the app bundles, at the dbVersion its manifest
#      names.
#
#  stage-zip.sh writes it into dist/ beside the zip, so macos-ci.yml's dry run
#  and release.yml's tag both hand it to _release_harden.yml, whose Syft folds
#  it into the product SBOM and whose Grype scans it. DocumentFactsTests runs
#  this script and fails when the document misses a component THIRD_PARTY.md
#  says reaches the user.
#
#  Usage: scripts/write-sbom.sh <out.spdx.json> [version]
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

OUT="${1:?usage: write-sbom.sh <out.spdx.json> [version]}"
VERSION="${2:-$(tr -d '[:space:]' < VERSION)}"

python3 -I - "$OUT" "$VERSION" <<'PY'
import datetime
import json
import re
import sys
import uuid

out, version = sys.argv[1], sys.argv[2]

packages = []


def add(name, package_version, licence, download, purl=None, comment=None):
    package = {
        "name": name,
        "SPDXID": "SPDXRef-Package-" + re.sub(r"[^A-Za-z0-9.-]", "-", name),
        "versionInfo": package_version,
        "downloadLocation": download,
        "filesAnalyzed": False,
        "licenseConcluded": licence,
        "licenseDeclared": licence,
        "copyrightText": "NOASSERTION",
    }
    if purl:
        package["externalRefs"] = [
            {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": purl}
        ]
    if comment:
        package["comment"] = comment
    packages.append(package)


# Every package SwiftPM resolved, as Package.resolved pins it.
LICENCES = {"sentry-cocoa": "MIT"}
with open("Package.resolved", encoding="utf-8") as handle:
    resolved = json.load(handle)
for pin in resolved["pins"]:
    identity = pin["identity"]
    if identity not in LICENCES:
        sys.exit(f"Package.resolved pins {identity}, which write-sbom.sh has no licence for: add it here and to THIRD_PARTY.md")
    location = pin["location"].removesuffix(".git")
    host_path = re.sub(r"^https://", "", location)
    add(
        identity,
        pin["state"]["version"],
        LICENCES[identity],
        f"git+{location}@{pin['state']['revision']}",
        purl=f"pkg:swift/{host_path}@{pin['state']['version']}",
    )

# ENet: the commit THIRD_PARTY.md section 2c names.
with open("THIRD_PARTY.md", encoding="utf-8") as handle:
    notice = handle.read()
match = re.search(r"https://github\.com/cgutman/enet>,\s*`([0-9a-f]{40})`", notice)
if not match:
    sys.exit("THIRD_PARTY.md section 2c names no ENet commit")
commit = match.group(1)
add(
    "enet",
    commit,
    "MIT",
    f"git+https://github.com/cgutman/enet@{commit}",
    purl=f"pkg:github/cgutman/enet@{commit}",
    comment="The client subset of its reliable-UDP protocol, ported to Swift under Sources/DishCore/Moonlight/Enet/; no C is compiled.",
)

# The controller database the app bundles.
with open("Sources/DishCore/Resources/controllers-v1/manifest.json", encoding="utf-8") as handle:
    manifest = json.load(handle)
add(
    "dish-controller-database",
    str(manifest["dbVersion"]),
    "NOASSERTION",
    "https://dish.tinkernorth.com/controllers/v1/",
    comment=f"TinkerNorth's controller list, published {manifest['publishedAt']}, bundled byte for byte with its manifest.",
)

root = "SPDXRef-Package-dish-mac"
relationships = [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": root}]
relationships += [
    {"spdxElementId": root, "relationshipType": "CONTAINS", "relatedSpdxElement": package["SPDXID"]}
    for package in packages
]
document = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": f"dish-mac-{version}-components",
    "documentNamespace": f"https://github.com/TinkerNorth/dish-mac/sbom/{version}/{uuid.uuid4()}",
    "creationInfo": {
        "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "creators": ["Organization: TinkerNorth", "Tool: dish-mac-scripts/write-sbom.sh"],
    },
    "packages": [
        {
            "name": "dish-mac",
            "SPDXID": root,
            "versionInfo": version,
            "downloadLocation": "https://github.com/TinkerNorth/dish-mac",
            "filesAnalyzed": False,
            "licenseConcluded": "LGPL-3.0-or-later",
            "licenseDeclared": "LGPL-3.0-or-later",
            "copyrightText": "Copyright (C) 2026 Dish contributors.",
        }
    ]
    + packages,
    "relationships": relationships,
}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
print(f"Wrote {out}: {len(packages)} components of dish-mac {version}")
PY
