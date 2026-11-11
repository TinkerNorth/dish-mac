#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  launch-smoke.sh — launch the bundled app the way a user's Mac does.
#
#  A user's Mac has no build tree. SwiftPM's native resource accessor falls
#  back to the absolute build directory of the machine that compiled the app,
#  so an app launched where that directory still exists can hide a missing
#  resource bundle: releases 1.0.2 to 1.2.0 crashed at launch everywhere else.
#  This moves .build aside, runs the app with a throwaway preferences home,
#  and fails when the app has quit before DISH_SMOKE_SECONDS (default 8).
#
#  Usage: scripts/launch-smoke.sh [path/to/Dish.app]
# ============================================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP="${1:-Dish.app}"
ALIVE_SECONDS="${DISH_SMOKE_SECONDS:-8}"
EXECUTABLE="$APP/Contents/MacOS/Dish"
HIDDEN_BUILD=".build-hidden-for-launch-smoke"
PREFERENCES_HOME="$(mktemp -d)"
LAUNCH_LOG="$PREFERENCES_HOME/launch.log"

if [ ! -x "$EXECUTABLE" ]; then
    echo "No app at $EXECUTABLE — run ./bundle.sh first." >&2
    exit 1
fi

restore_build() {
    if [ -d "$HIDDEN_BUILD" ]; then
        mv "$HIDDEN_BUILD" .build
    fi
}
trap restore_build EXIT

if [ -d .build ]; then
    mv .build "$HIDDEN_BUILD"
fi

CFFIXED_USER_HOME="$PREFERENCES_HOME" "$EXECUTABLE" > "$LAUNCH_LOG" 2>&1 &
APP_PID=$!
sleep "$ALIVE_SECONDS"

if ! kill -0 "$APP_PID" 2> /dev/null; then
    STATUS=0
    wait "$APP_PID" || STATUS=$?
    echo "Dish quit within ${ALIVE_SECONDS}s of launch (status $STATUS):" >&2
    cat "$LAUNCH_LOG" >&2
    exit 1
fi

kill "$APP_PID" 2> /dev/null || true
wait "$APP_PID" 2> /dev/null || true
echo "Dish stayed up for ${ALIVE_SECONDS}s with no build tree beside it."
