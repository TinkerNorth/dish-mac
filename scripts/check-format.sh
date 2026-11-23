#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  check-format.sh — SwiftFormat (lint only) and SwiftLint (strict), at the
#  versions scripts/tools.sh pins. ci-local.sh and macos-ci.yml both call it.
#  GITHUB_ACTIONS=true switches SwiftLint to the annotation reporter.
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/tools.sh
. scripts/tools.sh

fetch_swiftformat
fetch_swiftlint

tools_log "swiftformat --lint"
"$TOOLS/swiftformat" --version
"$TOOLS/swiftformat" --lint .

tools_log "swiftlint --strict"
"$TOOLS/swiftlint" --version
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    "$TOOLS/swiftlint" lint --strict --reporter github-actions-logging
else
    "$TOOLS/swiftlint" lint --strict --quiet
fi
