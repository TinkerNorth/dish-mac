#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  launch-smoke.sh — launch the bundled app the way a user's Mac does.
#
#  A user's Mac has no build tree. SwiftPM's native resource accessor falls
#  back to the absolute build directory of the machine that compiled the app,
#  so an app launched where that directory still exists can hide a missing
#  resource bundle: releases 1.0.2 to 1.2.0 crashed at launch everywhere else.
#  This moves .build aside and runs a copy of the app under its own bundle
#  identifier, with a throwaway home for its support files, logs and caches,
#  and fails when the app has quit before DISH_SMOKE_SECONDS (default 8).
#  The copy is what keeps the developer's own preferences out of it: on macOS
#  27.2 preferences are written through cfprefsd into the real
#  ~/Library/Preferences whatever CFFIXED_USER_HOME and
#  __CFPREFERENCES_AVOID_DAEMON say (measured), so the copy writes into its
#  own domain, which is deleted however the launch ends. The login keychain
#  is not redirected: the launch reads, or on a Mac without one mints, the
#  Moonlight identity there, as any launch does. First it checks the controller database the app ships
#  (check-bundled-db.sh), which a broken copy would otherwise pass silently.
#
#  DISH_SMOKE_AS_SIGNED=1 launches the app in place instead, with its own
#  signature and bundle identifier: how release.yml checks the final, signed
#  bundle (a re-signed copy would drop the hardened runtime). That writes the
#  app's real preferences, so it is for CI runners only, never a developer's Mac.
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
SMOKE_ID="com.tinkernorth.dish.mac.launch-smoke"
SMOKE_APP="$PREFERENCES_HOME/Dish.app"
SMOKE_EXECUTABLE="$SMOKE_APP/Contents/MacOS/Dish"

if [ ! -x "$EXECUTABLE" ]; then
    echo "No app at $EXECUTABLE — run ./bundle.sh first." >&2
    exit 1
fi

scripts/check-bundled-db.sh "$APP/Contents/Resources/Dish_DishCore.bundle"

restore_build() {
    if [ -d "$HIDDEN_BUILD" ]; then
        mv "$HIDDEN_BUILD" .build
    fi
    defaults delete "$SMOKE_ID" > /dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$SMOKE_ID.plist"
}
trap restore_build EXIT

if [ "${DISH_SMOKE_AS_SIGNED:-0}" = "1" ]; then
    SMOKE_EXECUTABLE="$EXECUTABLE"
else
    cp -R "$APP" "$SMOKE_APP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SMOKE_ID" "$SMOKE_APP/Contents/Info.plist"
    codesign --force --sign - "$SMOKE_APP" 2> /dev/null
fi

if [ -d .build ]; then
    mv .build "$HIDDEN_BUILD"
fi

CFFIXED_USER_HOME="$PREFERENCES_HOME" "$SMOKE_EXECUTABLE" > "$LAUNCH_LOG" 2>&1 &
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
