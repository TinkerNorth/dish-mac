#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  tools.sh — the pinned release binaries the gates run with, fetched once
#  into .build/tools and verified by SHA-256. Sourced by ci-local.sh and by
#  check-format.sh, which macos-ci.yml calls; dish-ios's scripts/tools.sh has
#  the same shape and the same versions. A bump is a deliberate commit that
#  reformats the tree with it, in this file and THIRD_PARTY.md together
#  (VersionConsistencyTests pins the two).
# ============================================================================

SWIFTFORMAT_VERSION="0.61.1"
SWIFTFORMAT_SHA256="b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584"
SWIFTLINT_VERSION="0.65.0"
SWIFTLINT_SHA256="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6"

TOOLS="${TOOLS:-.build/tools}"

tools_log() { printf '\n== %s ==\n' "$*"; }

# fetch_pinned <binary path inside the zip> <url> <sha256>
# Skips the download when the binary is present and was unpacked from this digest.
fetch_pinned() {
    local binary="$1" url="$2" sha="$3"
    local name zip
    name="$(basename "$binary")"
    zip="$TOOLS/$name.zip"
    if [ -x "$TOOLS/$binary" ] && [ "$(cat "$TOOLS/$name.version" 2>/dev/null)" = "$sha" ]; then
        return
    fi
    tools_log "fetching $name $url"
    mkdir -p "$TOOLS"
    curl -fsSL --retry 3 -o "$zip" "$url"
    echo "$sha  $zip" | shasum -a 256 -c -
    unzip -q -o "$zip" -d "$TOOLS"
    chmod +x "$TOOLS/$binary"
    echo "$sha" > "$TOOLS/$name.version"
}

fetch_swiftformat() {
    fetch_pinned swiftformat \
        "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip" \
        "$SWIFTFORMAT_SHA256"
}

fetch_swiftlint() {
    fetch_pinned swiftlint \
        "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip" \
        "$SWIFTLINT_SHA256"
}
