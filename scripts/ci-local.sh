#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  ci-local.sh — run the macOS CI gates against this worktree, in CI's order.
#
#  A green run here is a green `macos-ci.yml` run: the same pinned
#  SwiftFormat and SwiftLint release binaries (scripts/tools.sh, downloaded
#  once into .build/tools and verified by SHA-256), then `swift build`, the test build,
#  `swift test`, the release build and `bundle.sh`.
#
#  Options:
#    --quick     skip the release build and the bundle
#    --no-tests  skip `swift test` (the test build still runs)
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

QUICK=0
RUN_TESTS=1
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --no-tests) RUN_TESTS=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# shellcheck source=scripts/tools.sh
. scripts/tools.sh

log() { tools_log "$@"; }

log "format and lint"
scripts/check-format.sh

log "swift build (debug, warnings are errors)"
swift build --configuration debug

log "swift build --build-tests"
swift build --build-tests
log "compile the String Catalog where SwiftPM copied it verbatim"
find .build -type d -name 'Dish_Dish.bundle' -exec ./scripts/compile-catalog.sh {} \;

if [ "$RUN_TESTS" -eq 1 ]; then
    log "swift test"
    swift test --parallel --skip-build
fi

if [ "$QUICK" -eq 0 ]; then
    log "swift build (release)"
    swift build --configuration release
    log "bundle.sh release"
    ./bundle.sh release
    log "launch the bundled app with no build tree beside it"
    scripts/launch-smoke.sh Dish.app
fi

log "all gates passed"
