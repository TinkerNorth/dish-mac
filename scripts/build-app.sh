#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  build-app.sh — the release build, the bench's smoke run against it, and
#  Dish.app through bundle.sh. ci-local.sh, macos-ci.yml and (through the
#  same bundle.sh) release.yml build the app this way.
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== swift build (release) =="
swift build --configuration release

# Every scenario for 0.2 s against the release build; the exit status is the
# harness's own accounting (pacing, arrivals), never a latency.
echo "== DishBench --smoke =="
"$(swift build --configuration release --show-bin-path)/DishBench" --smoke

echo "== bundle.sh release =="
./bundle.sh release
