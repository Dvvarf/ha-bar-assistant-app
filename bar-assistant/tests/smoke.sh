#!/usr/bin/env bash
###############################################################################
# Boot smoke test for the Bar Assistant HA add-on image.
#
# Builds nothing; expects an already-built image (default tag ha-bar-assistant:test,
# override with $IMAGE). Boots it the way Home Assistant would -- a NAMED volume
# mounted at /data with a seeded options.json -- waits for the stack to come up,
# then asserts every published route plus static upload serving.
#
# A NAMED volume is used deliberately (not a bind mount): on Docker Desktop
# (virtiofs) an in-container chown to www-data does not stick on a bind mount, so
# Meilisearch would hit "Permission denied (os error 13)" on /data/meilisearch --
# a test artifact that does NOT happen on a real HA volume. See CLAUDE.md.
#
# Usage:  IMAGE=ha-bar-assistant:test ./tests/smoke.sh
#         PLATFORM=linux/arm64 IMAGE=... ./tests/smoke.sh   # emulated arch
# Exit 0 = all checks passed; non-zero = a check failed (CI gate).
###############################################################################
set -euo pipefail

IMAGE="${IMAGE:-ha-bar-assistant:test}"
# When the image's arch differs from the host (e.g. CI runs the arm64 build on an
# amd64 runner under QEMU), docker run warns and guesses unless told the platform.
# Pass PLATFORM (e.g. linux/arm64) to make it explicit and silence the mismatch.
PLATFORM="${PLATFORM:-}"
PLATFORM_ARG=()
[ -n "$PLATFORM" ] && PLATFORM_ARG=(--platform "$PLATFORM")
PORT="${PORT:-2118}"
VOLUME="ba-smoke-data"
CONTAINER="ba-smoke"
BASE="http://localhost:${PORT}"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

echo "==> Seeding /data/options.json into a named volume"
docker volume create "$VOLUME" >/dev/null
docker run --rm -v "$VOLUME":/data alpine:3.20 sh -c 'printf "%s" "$1" > /data/options.json' _ \
  '{"MEILI_MASTER_KEY":"super-secret-key-987654321","BASE_URL":"http://localhost:2118","ALLOW_REGISTRATION":true}'

echo "==> Starting $IMAGE${PLATFORM:+ (platform $PLATFORM)}"
docker run -d "${PLATFORM_ARG[@]}" --name "$CONTAINER" -p "${PORT}:2118" -v "$VOLUME":/data "$IMAGE" >/dev/null

echo "==> Waiting for the stack to boot (up to 180s)"
ready=""
for _ in $(seq 1 90); do
    if curl -fsS "${BASE}/bar/api/server/version" >/dev/null 2>&1; then
        ready=1; break
    fi
    sleep 2
done
if [ -z "$ready" ]; then
    echo "!! Stack did not come up in time. Container logs:" >&2
    docker logs "$CONTAINER" 2>&1 | tail -n 80 >&2
    exit 1
fi

fail=0
check() {  # check <description> <expected-status> <url>
    local desc="$1" want="$2" url="$3" got
    got="$(curl -s -o /dev/null -w '%{http_code}' "$url")"
    if [ "$got" = "$want" ]; then
        echo "  ok   [$got] $desc"
    else
        echo "  FAIL [$got, want $want] $desc -> $url"; fail=1
    fi
}

echo "==> Checking routes"
check "Salt Rim UI (/)"                "200" "${BASE}/"
check "config.js generated"            "200" "${BASE}/config.js"
check "Bar Assistant API version"      "200" "${BASE}/bar/api/server/version"
check "Meilisearch health"             "200" "${BASE}/search/health"

echo "==> Checking config.js reflects seeded options"
cfg="$(curl -s "${BASE}/config.js")"
echo "$cfg" | grep -q "localhost:2118/bar"    || { echo "  FAIL config.js missing API_URL"; fail=1; }
echo "$cfg" | grep -q "localhost:2118/search" || { echo "  FAIL config.js missing MEILISEARCH_URL"; fail=1; }
[ "$fail" = 0 ] && echo "  ok   config.js contains API_URL + MEILISEARCH_URL"

echo "==> Checking Meilisearch reports available"
curl -s "${BASE}/search/health" | grep -q '"status":"available"' \
    && echo "  ok   meilisearch available" \
    || { echo "  FAIL meilisearch not available"; fail=1; }

echo "==> Checking static upload serving (regression guard for the 403 traversal fix)"
docker exec -u 0 "$CONTAINER" sh -c \
  'mkdir -p /data/bar-assistant/uploads/cocktails/1 && printf JPEG > /data/bar-assistant/uploads/cocktails/1/x.jpg && chown -R www-data:www-data /data/bar-assistant/uploads'
check "upload served as static asset"  "200" "${BASE}/bar/uploads/cocktails/1/x.jpg"

echo "==> Checking the container HEALTHCHECK reports healthy (up to 60s)"
# The Dockerfile HEALTHCHECK starts "starting" during the start-period; poll
# until Docker flips it to "healthy" so we exercise the instruction itself, not
# just the underlying routes. A "none" status means no HEALTHCHECK is set.
health=""
for _ in $(seq 1 30); do
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo none)"
    [ "$health" = "healthy" ] && break
    [ "$health" = "none" ] && break
    sleep 2
done
if [ "$health" = "healthy" ]; then
    echo "  ok   container reports healthy"
else
    echo "  FAIL container health = '${health:-unknown}' (want healthy)"; fail=1
fi

# ---------------------------------------------------------------------------
# Upgrade-path test: simulate the bundled Meilisearch engine being started on a
# /data created by a DIFFERENT version. We stamp a version into the on-disk
# Meilisearch VERSION file (read by ba-prep's guard BEFORE the engine starts) and
# restart. ba-prep must purge the stale DB so the engine boots clean; if the
# purge fails, Meilisearch refuses to boot on the incompatible DB and the
# container never reaches healthy -- so this phase fails. (We don't assert the
# index repopulated, only that it boots healthy and the stale DB was purged.)
#
# We stamp 1.0.0 deliberately: it sits well below any realistic bundled engine,
# so the major.minor mismatch (and thus the purge) holds no matter which
# Meilisearch the image ships -- this also covers an image ROLLBACK to an older
# engine, where the on-disk DB is NEWER than the engine. A nearer value like
# 1.15.0 would falsely MATCH if the image were ever bundled with 1.15.
# ---------------------------------------------------------------------------
echo "==> Upgrade-path test: seed an old Meilisearch DB version and restart"
docker stop "$CONTAINER" >/dev/null
docker run --rm -v "$VOLUME":/data alpine:3.20 sh -c 'printf "1.0.0\n" > /data/meilisearch/VERSION'
docker start "$CONTAINER" >/dev/null

echo "==> Waiting for the stack to come back up after the simulated upgrade (up to 180s)"
ready=""
for _ in $(seq 1 90); do
    if curl -fsS "${BASE}/bar/api/server/version" >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
done
if [ -z "$ready" ]; then
    echo "  FAIL stack did not come back up after the simulated upgrade"; fail=1
    docker logs "$CONTAINER" 2>&1 | tail -n 80 >&2
fi

check "Meilisearch health after upgrade" "200" "${BASE}/search/health"

echo "==> Confirming the stale Meilisearch DB was purged (VERSION no longer 1.0.x)"
upv="$(docker run --rm -v "$VOLUME":/data alpine:3.20 sh -c 'cat /data/meilisearch/VERSION 2>/dev/null' || true)"
case "$upv" in
    1.0.*) echo "  FAIL stale VERSION ($upv) still present -- purge did not run"; fail=1 ;;
    "")    echo "  FAIL no VERSION file after upgrade boot"; fail=1 ;;
    *)     echo "  ok   stale DB purged; Meilisearch recreated VERSION ($upv)" ;;
esac

echo "==> Confirming the container is healthy again after the upgrade (up to 60s)"
health=""
for _ in $(seq 1 30); do
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo none)"
    [ "$health" = "healthy" ] && break
    [ "$health" = "none" ] && break
    sleep 2
done
if [ "$health" = "healthy" ]; then
    echo "  ok   container healthy after upgrade"
else
    echo "  FAIL container health = '${health:-unknown}' after upgrade (want healthy)"; fail=1
fi

if [ "$fail" != 0 ]; then
    echo "==> SMOKE TEST FAILED" >&2
    docker logs "$CONTAINER" 2>&1 | tail -n 80 >&2
    exit 1
fi
echo "==> SMOKE TEST PASSED"
