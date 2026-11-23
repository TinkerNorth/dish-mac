#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  ci-local.sh — run the macOS CI gates against this worktree, in CI's order.
#
#  A green run here is a green `macos-ci.yml` run: each gate is one script
#  under scripts/ that the workflow calls too.
#
#    scripts/check-security.sh   action-pin lint, vulnerability allowlist,
#                                OSV-Scanner (reads Package.resolved), gitleaks
#    scripts/check-format.sh     SwiftFormat --lint and SwiftLint --strict at
#                                the versions scripts/tools.sh pins
#    scripts/build-and-test.sh   the debug build with tests and coverage, the
#                                String Catalog, `swift test`
#    scripts/build-app.sh        the release build, DishBench --smoke, bundle.sh
#    scripts/sign-app.sh -       hardened-runtime ad-hoc signature, verified
#    scripts/launch-smoke.sh     the bundle (and the bundled controller
#                                database) launched with no build tree beside it
#
#  Options:
#    --quick             skip the release build, the bundle and the lock lane
#    --no-tests          skip `swift test` (the test build still runs)
#    --with-lock-stats   also run the LOCK_STATS build and its tests (CI's
#                        second job; a separate build, so slow)
#    --allow-missing     accepted for the fleet's interface; every tool this
#                        script needs is fetched, so nothing can be missing
#
#  CI only: dependency review (it reads GitHub's dependency graph for the
#  pull request), CodeQL, and the release-hardening dry run (a Linux job: Grype, Syft
#  and cosign of the PR-built zip). Also CI only, because each needs a runner
#  secret or a Developer ID: the
#  Developer ID signature, notarisation and stapling, and the final-bundle
#  launch in release.yml. CI also uploads the app and the coverage data.
#  Local Xcode may be newer than the macos-26 image's Xcode 26.6: trust CI for
#  the pinned toolchain.
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

QUICK=0
RUN_TESTS=1
LOCK_STATS=0
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --no-tests) RUN_TESTS=0 ;;
        --with-lock-stats) LOCK_STATS=1 ;;
        --allow-missing) ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\n=== %s ===\n' "$*"; }

log "security gates"
scripts/check-security.sh

log "format and lint"
scripts/check-format.sh

log "build and test"
if [ "$RUN_TESTS" -eq 1 ]; then
    scripts/build-and-test.sh
else
    scripts/build-and-test.sh --no-tests
fi

if [ "$QUICK" -eq 0 ]; then
    log "release build, bench smoke, bundle"
    scripts/build-app.sh
    log "sign with the hardened runtime (ad hoc)"
    scripts/sign-app.sh - Dish.app
    log "launch the bundled app with no build tree beside it"
    scripts/launch-smoke.sh Dish.app
    if [ "$LOCK_STATS" -eq 1 ]; then
        log "lock statistics"
        scripts/lock-stats.sh
    fi
elif [ "$LOCK_STATS" -eq 1 ]; then
    log "lock statistics"
    scripts/lock-stats.sh
fi

log "all gates passed"
