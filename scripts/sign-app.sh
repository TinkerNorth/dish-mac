#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  sign-app.sh — sign Dish.app with the hardened runtime and the entitlements
#  in packaging/Dish.entitlements, then verify the signature and that the
#  audio-input entitlement rides it. release.yml calls it with the Developer ID
#  identity; macos-ci.yml and ci-local.sh call it with `-` (ad hoc, no secure
#  timestamp), so the hardened-runtime signing and the launch of the result are
#  exercised on every pull request. Only notarisation needs the Apple secrets.
#
#  Usage: scripts/sign-app.sh <identity | -> [path/to/Dish.app]
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IDENTITY="${1:?usage: sign-app.sh <identity | -> [Dish.app]}"
APP="${2:-Dish.app}"

TIMESTAMP="--timestamp"
if [ "$IDENTITY" = "-" ]; then
    TIMESTAMP="--timestamp=none"
fi

# The hardened runtime denies audio input unless the entitlement rides the
# signature; a controller's own microphone is the one audio input Dish opens.
codesign --force --options runtime "$TIMESTAMP" \
    --entitlements packaging/Dish.entitlements \
    --sign "$IDENTITY" --deep "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --display --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.device.audio-input"
echo "$APP is signed with the hardened runtime and the audio-input entitlement."
