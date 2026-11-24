#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  stage-zip.sh — zip Dish.app into dist/ the way a release names it.
#  release.yml (with the tag) and macos-ci.yml (with the version in VERSION,
#  unsigned) both call it, so the PR-time hardening dry run signs and scans the
#  same files a tag does.
#
#  The versioned zip carries `-unsigned` when there is no Developer ID. The
#  stable name dish-mac.zip is a permanent download URL that latest.json and
#  the website read by name, so it never changes shape, signed or not (the
#  Windows client's dish-setup.exe rule).
#
#  Beside the zips it writes dish-mac-components.spdx.json (write-sbom.sh),
#  the bill of materials the hardening folds into the product SBOM, since
#  Syft does not look inside the zip.
#
#  Usage: scripts/stage-zip.sh <tag-or-version> <true | anything else = unsigned> [path/to/Dish.app]
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TAG="${1:?usage: stage-zip.sh <tag-or-version> <signed: true|false> [Dish.app]}"
SIGNED="${2:?usage: stage-zip.sh <tag-or-version> <signed: true|false> [Dish.app]}"
APP="${3:-Dish.app}"

suffix=""
if [ "$SIGNED" != "true" ]; then
    suffix="-unsigned"
fi

mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/dish-${TAG}${suffix}.zip"
cp "dist/dish-${TAG}${suffix}.zip" "dist/dish-mac.zip"
scripts/write-sbom.sh "dist/dish-mac-components.spdx.json" "${TAG}"
ls -l dist/
