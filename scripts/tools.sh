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

SWIFTFORMAT_VERSION="0.64.7"
SWIFTFORMAT_SHA256="e82e224325cbd3403fc7b68caf6c917926dc106de3af875fca4b87e3c4634038"
SWIFTLINT_VERSION="0.65.1"
SWIFTLINT_SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
# The security gates' scanners, the darwin-arm64 assets (CI's copies are the linux-amd64
# ones _security.yml pins, at these same versions). Digests are from the upstream
# checksum files: osv-scanner_SHA256SUMS and gitleaks_<version>_checksums.txt.
OSV_SCANNER_VERSION="2.7.1"
OSV_SCANNER_SHA256="b22c02877a811c8f78956e8643efa554932b7378f590d13f8e97d4e9448a29f3"
GITLEAKS_VERSION="8.30.1"
GITLEAKS_SHA256="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
PYYAML_VERSION="6.0.4"

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

# The security gates' binaries exist here for arm64 Macs only; fail clearly elsewhere.
require_arm64_mac() {
    if [ "$(uname -s)-$(uname -m)" != "Darwin-arm64" ]; then
        echo "scripts/tools.sh pins the darwin-arm64 scanners; run the security gates on an Apple-silicon Mac or rely on CI" >&2
        return 1
    fi
}

# fetch_pinned_file <name> <url> <sha256>: a single downloaded binary, no archive.
fetch_pinned_file() {
    local name="$1" url="$2" sha="$3"
    if [ -x "$TOOLS/$name" ] && [ "$(cat "$TOOLS/$name.version" 2>/dev/null)" = "$sha" ]; then
        return
    fi
    tools_log "fetching $name $url"
    mkdir -p "$TOOLS"
    curl -fsSL --retry 3 -o "$TOOLS/$name.download" "$url"
    echo "$sha  $TOOLS/$name.download" | shasum -a 256 -c -
    mv "$TOOLS/$name.download" "$TOOLS/$name"
    chmod +x "$TOOLS/$name"
    echo "$sha" > "$TOOLS/$name.version"
}

fetch_osv_scanner() {
    require_arm64_mac
    fetch_pinned_file osv-scanner \
        "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_darwin_arm64" \
        "$OSV_SCANNER_SHA256"
}

fetch_gitleaks() {
    require_arm64_mac
    local archive="$TOOLS/gitleaks.tar.gz"
    if [ -x "$TOOLS/gitleaks" ] && [ "$(cat "$TOOLS/gitleaks.version" 2>/dev/null)" = "$GITLEAKS_SHA256" ]; then
        return
    fi
    tools_log "fetching gitleaks ${GITLEAKS_VERSION}"
    mkdir -p "$TOOLS"
    curl -fsSL --retry 3 -o "$archive" \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz"
    echo "$GITLEAKS_SHA256  $archive" | shasum -a 256 -c -
    tar -xzf "$archive" -C "$TOOLS" gitleaks
    chmod +x "$TOOLS/gitleaks"
    echo "$GITLEAKS_SHA256" > "$TOOLS/gitleaks.version"
}

# security-allowlist.py needs Python 3.11+ and PyYAML at the version _security.yml installs.
# A virtual environment under $TOOLS keeps the system Python untouched.
ensure_pyyaml_python() {
    local venv="$TOOLS/venv"
    if [ ! -x "$venv/bin/python3" ] || ! "$venv/bin/python3" -c "import yaml, sys; sys.exit(0 if yaml.__version__ == '$PYYAML_VERSION' else 1)" 2>/dev/null; then
        tools_log "creating the PyYAML $PYYAML_VERSION environment"
        mkdir -p "$TOOLS"
        python3 -m venv "$venv"
        "$venv/bin/python3" -m pip install --quiet "PyYAML==$PYYAML_VERSION"
    fi
    PYTHON_FOR_GATES="$venv/bin/python3"
}
