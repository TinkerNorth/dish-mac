#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  lock-stats.sh — the LOCK_STATS build, which counts every tracked lock by
#  thread role: its own tests, the lock-law test, and the bench's smoke run.
#  macos-ci.yml's lock-stats job calls it; ci-local.sh --with-lock-stats too.
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== swift build --build-tests -DLOCK_STATS =="
swift build --build-tests -Xswiftc -DLOCK_STATS

echo "== lock statistics tests =="
swift test --skip-build --filter 'TrackedLockStatsTests|LockLawTests'

echo "== DishBench --smoke with lock statistics =="
"$(swift build -Xswiftc -DLOCK_STATS --show-bin-path)/DishBench" --smoke
