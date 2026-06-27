#!/usr/bin/env bash
###############################################################################
# Version-coupling guard for the Bar Assistant add-on.
#
# The add-on version is a 5-part string <BA_maj>.<BA_min>.<SR_maj>.<SR_min>.<pkg>
# that embeds both upstreams' major.minor (see bar-assistant/CLAUDE.md
# "Versioning"). Several places must agree, and nothing else enforces it:
#
#   * config.yaml  version:                      <- source of truth
#   * Dockerfile   LABEL io.hass.version="..."   <- must equal it
#   * Dockerfile   ARG BUILD_FROM=...server:M.m  <- must equal BA_maj.BA_min
#   * Dockerfile   FROM ...salt-rim:M.m          <- must equal SR_maj.SR_min
#
# Run in CI (lint.yaml) and locally. Exit 0 = consistent; non-zero = mismatch.
###############################################################################
set -euo pipefail

cd "$(dirname "$0")/.."
CFG="bar-assistant/config.yaml"
DOCKERFILE="bar-assistant/Dockerfile"

fail=0
err() { echo "  MISMATCH: $*" >&2; fail=1; }

ver="$(grep -E '^version:' "$CFG" | head -1 | sed -E 's/^version:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/')"
label="$(grep -oE 'io\.hass\.version="[^"]+"' "$DOCKERFILE" | head -1 | sed -E 's/.*="([^"]+)"/\1/')"
ba_tag="$(grep -oE 'barassistant/server:[0-9]+\.[0-9]+' "$DOCKERFILE" | head -1 | sed -E 's/.*:([0-9]+\.[0-9]+)/\1/')"
sr_tag="$(grep -oE 'barassistant/salt-rim:[0-9]+\.[0-9]+' "$DOCKERFILE" | head -1 | sed -E 's/.*:([0-9]+\.[0-9]+)/\1/')"

echo "config.yaml version : $ver"
echo "Dockerfile LABEL    : $label"
echo "server tag          : $ba_tag"
echo "salt-rim tag        : $sr_tag"

if ! [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    err "config.yaml version '$ver' is not a 5-part <BA_maj>.<BA_min>.<SR_maj>.<SR_min>.<pkg> string"
    exit 1
fi
ba_embed="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
sr_embed="${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"

[ "$label" = "$ver" ]      || err "Dockerfile io.hass.version ('$label') != config.yaml version ('$ver')"
[ "$ba_tag" = "$ba_embed" ] || err "embedded server major.minor ('$ba_embed') != Dockerfile server tag ('$ba_tag')"
[ "$sr_tag" = "$sr_embed" ] || err "embedded salt-rim major.minor ('$sr_embed') != Dockerfile salt-rim tag ('$sr_tag')"

if [ "$fail" != 0 ]; then
    echo "==> VERSION SYNC FAILED -- see bar-assistant/CLAUDE.md 'Versioning'" >&2
    exit 1
fi
echo "==> Version sync OK"
