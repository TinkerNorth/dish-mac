#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  ci-local.sh — run the macOS CI gates against this worktree, in CI's order.
#
#  A green run here is a green `macos-ci.yml` run: the same pinned
#  SwiftFormat and SwiftLint release binaries (downloaded once into
#  .build/tools and verified by SHA-256), then `swift build`, the test build,
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

# The versions and digests below are the ones macos-ci.yml pins; bump them
# together, in the same commit that reformats the tree.
SWIFTFORMAT_VERSION="0.61.1"
SWIFTFORMAT_SHA256="b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584"
SWIFTLINT_VERSION="0.65.0"
SWIFTLINT_SHA256="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6"

TOOLS=".build/tools"
mkdir -p "$TOOLS"

log() { printf '\n== %s ==\n' "$*"; }

fetch_pinned() {
    local name="$1" url="$2" sha="$3" zip="$TOOLS/$1.zip"
    if [ -x "$TOOLS/$name" ] && [ "$(cat "$TOOLS/$name.version" 2>/dev/null)" = "$sha" ]; then
        return
    fi
    log "fetching $name"
    curl -fsSL --retry 3 -o "$zip" "$url"
    echo "$sha  $zip" | shasum -a 256 -c -
    unzip -q -o "$zip" -d "$TOOLS"
    chmod +x "$TOOLS/$name"
    echo "$sha" > "$TOOLS/$name.version"
}

fetch_pinned swiftformat \
    "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip" \
    "$SWIFTFORMAT_SHA256"
fetch_pinned swiftlint \
    "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip" \
    "$SWIFTLINT_SHA256"

log "swiftformat --lint"
"$TOOLS/swiftformat" --lint .

log "swiftlint --strict"
"$TOOLS/swiftlint" lint --strict --quiet

log "swift build (debug, warnings are errors)"
swift build --configuration debug

log "swift build --build-tests"
swift build --build-tests

if [ "$RUN_TESTS" -eq 1 ]; then
    log "swift test"
    swift test --parallel --skip-build
fi

if [ "$QUICK" -eq 0 ]; then
    log "swift build (release)"
    swift build --configuration release
    log "bundle.sh release"
    ./bundle.sh release
fi

log "all gates passed"
