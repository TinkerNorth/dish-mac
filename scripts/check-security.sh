#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  check-security.sh — the security gates security.yml runs through the shared
#  _security.yml, against this worktree: the action-pin lint, the allowlist
#  gate, OSV-Scanner (scripts/osv-scan.sh, reading Package.resolved) and
#  gitleaks over the git history. The scanners are the pinned binaries
#  scripts/tools.sh fetches (darwin-arm64); CI runs the same versions on Linux.
#
#  Not run here: dependency review, which needs GitHub's dependency graph (a
#  repository setting that is off, so security.yml passes
#  dependency_review_enabled: false), and CodeQL, which codeql.yml runs.
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/tools.sh
. scripts/tools.sh

fetch_osv_scanner
fetch_gitleaks
ensure_pyyaml_python

tools_log "action pin lint"
sh scripts/check-action-pins.sh

tools_log "vulnerability allowlist"
"$PYTHON_FOR_GATES" scripts/security-allowlist.py check

tools_log "OSV-Scanner"
OSV_SCANNER="$TOOLS/osv-scanner" bash scripts/osv-scan.sh -- .

tools_log "gitleaks"
"$TOOLS/gitleaks" git --config=.gitleaks.toml --redact --exit-code=1 .
