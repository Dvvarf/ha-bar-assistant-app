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
# Exit 0 = all checks passed; non-zero = a check failed (CI gate).
###############################################################################
set -euo pipefail

IMAGE="${IMAGE:-ha-bar-assistant:test}"
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
  '{"MEILI_MASTER_KEY":"super-secret-key-987654321","API_URL":"http://localhost:2118/bar","MEILISEARCH_URL":"http://localhost:2118/search","ALLOW_REGISTRATION":true}'

echo "==> Starting $IMAGE"
docker run -d --name "$CONTAINER" -p "${PORT}:2118" -v "$VOLUME":/data "$IMAGE" >/dev/null

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

if [ "$fail" != 0 ]; then
    echo "==> SMOKE TEST FAILED" >&2
    docker logs "$CONTAINER" 2>&1 | tail -n 80 >&2
    exit 1
fi
echo "==> SMOKE TEST PASSED"
