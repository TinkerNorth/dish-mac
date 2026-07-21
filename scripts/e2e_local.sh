#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# ============================================================================
#  e2e_local.sh — loopback end-to-end: this client vs the REAL satellite
#
#  Builds the actual C++ satellite server (sibling repo), runs it headless
#  with an isolated $HOME (its config / paired devices / keys never touch
#  your real profile), then drives a full protocol-1 session from the
#  dish-mac stack via the env-gated XCTest driver
#  `IntegrationLiveSatelliteE2ETests`:
#
#      pair (path A, real rotating PIN, TOFU-pins the real self-signed cert)
#      → declarative PUT /api/connections (slot descriptor on the first PUT)
#      → encrypted UDP input/touchpad + heartbeats the server actually
#        decrypts (its admin API must report the session "active" — the
#        satellite's liveness machine only advances on authenticated frames)
#      → latency window seeds from real acks
#      → graceful DELETE (admin row drains) → self-unpair (device row gone).
#
#  WHAT THIS VERIFIES (unentitled satellite build — the default here):
#    real-binary interop of pairing, TOFU TLS pinning, hmacProof auth, the
#    declarative session/controller REST surface, HKDF/ChaCha20-Poly1305
#    UDP both directions, liveness, and teardown. The virtual-pad backend is
#    inert without the `com.apple.developer.hid.virtual.device` entitlement,
#    so the slot applies as `backendUnavailable` and the driver asserts that
#    honest failure path instead.
#
#  WHAT STILL NEEDS ENTITLED HARDWARE (Wave-4):
#    IOHIDUserDevice pad creation, a game adopting the virtual DS4, and the
#    live rumble/lightbar return path driven by real host software.
#
#  Environment knobs:
#    SATELLITE_REPO       satellite checkout (default: ../satellite)
#    SATELLITE_BIN        prebuilt binary; skips the build when set
#    SATELLITE_BUILD_DIR  cmake build dir name (default: build-e2e)
#    BUILD_TYPE           cmake build type (default: Release)
#
#  Requires: cmake + the satellite deps (Homebrew libsodium, pkg-config),
#  a logged-in GUI session (the satellite runs an NSApplication tray app;
#  a GUI-less SSH session can't host it — run from a local terminal).
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SATELLITE_REPO="${SATELLITE_REPO:-$(cd "${DISH_ROOT}/.." && pwd)/satellite}"
SATELLITE_BUILD_DIR="${SATELLITE_BUILD_DIR:-build-e2e}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

REST_PORT=9443   # compile-time constant in the satellite (DEFAULT_CLIENT_PORT)
ADMIN_PORT=9877  # loopback admin surface (DEFAULT_WEB_PORT)
UDP_PORT=9876    # data plane (DEFAULT_UDP_PORT)

log()  { printf '[e2e] %s\n' "$*"; }
fail() { printf '[e2e] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[ -d "${SATELLITE_REPO}" ] || fail "satellite repo not found at ${SATELLITE_REPO} (set SATELLITE_REPO)"

for port in "${REST_PORT}" "${ADMIN_PORT}"; do
    if nc -z 127.0.0.1 "${port}" >/dev/null 2>&1; then
        fail "port ${port} is already in use — is a real satellite running? Stop it first."
    fi
done
# UDP has no connect-probe; a stale binding on the data-plane port would make
# the satellite's bind fail (or worse, a stray listener eat the datagrams).
if lsof -nP -iUDP:"${UDP_PORT}" >/dev/null 2>&1; then
    fail "UDP port ${UDP_PORT} is already bound — is a real satellite running? Stop it first."
fi

# ------------------------------------------------------------------- build
if [ -n "${SATELLITE_BIN:-}" ]; then
    log "using prebuilt satellite: ${SATELLITE_BIN}"
else
    log "building satellite (${BUILD_TYPE}) in ${SATELLITE_REPO}/${SATELLITE_BUILD_DIR}"
    cmake -S "${SATELLITE_REPO}" -B "${SATELLITE_REPO}/${SATELLITE_BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" >/dev/null
    cmake --build "${SATELLITE_REPO}/${SATELLITE_BUILD_DIR}" --target satellite -j >/dev/null
    # The macOS target drops its bundle at the repo root (build convention).
    SATELLITE_BIN="${SATELLITE_REPO}/satellite.app/Contents/MacOS/satellite"
fi
[ -x "${SATELLITE_BIN}" ] || fail "satellite binary not found/executable at ${SATELLITE_BIN}"

# ------------------------------------------------------------------ launch
E2E_HOME="$(mktemp -d /tmp/dish-e2e-home.XXXXXX)"
SAT_LOG="${E2E_HOME}/satellite.log"
SAT_PID=""

cleanup() {
    if [ -n "${SAT_PID}" ] && kill -0 "${SAT_PID}" >/dev/null 2>&1; then
        log "stopping satellite (pid ${SAT_PID})"
        kill -TERM "${SAT_PID}" >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            kill -0 "${SAT_PID}" >/dev/null 2>&1 || break
            sleep 0.25
        done
        kill -KILL "${SAT_PID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${E2E_HOME}"
}
trap cleanup EXIT

log "starting satellite headless (isolated HOME=${E2E_HOME})"
HOME="${E2E_HOME}" "${SATELLITE_BIN}" >"${SAT_LOG}" 2>&1 &
SAT_PID=$!

# Readiness: the loopback admin surface answers AND the HTTPS client API
# completes a handshake (self-signed → -k; trust is the CLIENT's TOFU job).
ready=""
for _ in $(seq 1 60); do
    if ! kill -0 "${SAT_PID}" >/dev/null 2>&1; then
        sed 's/^/[satellite] /' "${SAT_LOG}" >&2 || true
        fail "satellite exited during startup (no GUI session? see header)"
    fi
    if curl -sf "http://127.0.0.1:${ADMIN_PORT}/api/pin/status" >/dev/null 2>&1 &&
        curl -skf "https://127.0.0.1:${REST_PORT}/api/server/capabilities" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
done
[ -n "${ready}" ] || { sed 's/^/[satellite] /' "${SAT_LOG}" >&2 || true; fail "satellite never became ready"; }
log "satellite is up: admin :${ADMIN_PORT}, client API :${REST_PORT}, UDP :${UDP_PORT}"

# ------------------------------------------------------------------ driver
log "driving the session from the dish-mac stack (swift test driver)"
status=0
(
    cd "${DISH_ROOT}"
    DISH_E2E_LIVE=1 \
    DISH_E2E_HOST=127.0.0.1 \
    DISH_E2E_REST_PORT="${REST_PORT}" \
    DISH_E2E_UDP_PORT="${UDP_PORT}" \
    DISH_E2E_ADMIN_PORT="${ADMIN_PORT}" \
        swift test --filter IntegrationLiveSatelliteE2ETests
) || status=$?

# ------------------------------------------------------------------ report
echo
if [ "${status}" -eq 0 ]; then
    log "PASS — verified against the real satellite binary:"
    log "  pairing (path A, rotating PIN) · TOFU pin of the real cert"
    log "  hmacProof auth · declarative PUT + slot descriptor"
    log "  HKDF/AEAD UDP both directions (server marked session ACTIVE)"
    log "  latency seeding · graceful DELETE · self-unpair"
    log "still needs entitled hardware (Wave-4): IOHIDUserDevice pad"
    log "  creation, game adoption, live rumble/lightbar return path"
else
    log "FAIL (exit ${status}) — satellite log tail:"
    tail -40 "${SAT_LOG}" | sed 's/^/[satellite] /' >&2 || true
fi
exit "${status}"
