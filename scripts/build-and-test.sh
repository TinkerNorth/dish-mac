#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  build-and-test.sh — the debug build with tests and coverage, the String
#  Catalog compiled where SwiftPM copied it verbatim, then `swift test`.
#  ci-local.sh and macos-ci.yml both call it.
#
#  Usage: scripts/build-and-test.sh [--no-tests]
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUN_TESTS=1
for arg in "$@"; do
    case "$arg" in
        --no-tests) RUN_TESTS=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

echo "== swift build --build-tests (debug, warnings are errors) =="
swift build --build-tests --enable-code-coverage

# Some toolchains' SwiftPM copies the String Catalog verbatim, which nothing
# reads at run time; the tests read the compiled tables.
echo "== compile the String Catalog where SwiftPM copied it =="
find .build -type d -name 'Dish_Dish.bundle' -exec ./scripts/compile-catalog.sh {} \;

if [ "$RUN_TESTS" -eq 1 ]; then
    echo "== swift test =="
    swift test --skip-build --parallel --enable-code-coverage
fi
