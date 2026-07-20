#!/usr/bin/env bash
###############################################################################
# Increment the packaging revision (<pkg>, the 5th field) of the add-on version
# and write it to BOTH coupled locations at once:
#
#   * config.yaml  version:                    <- source of truth
#   * Dockerfile   LABEL io.hass.version="..."
#
# The version is a 5-part <BA_maj>.<BA_min>.<SR_maj>.<SR_min>.<pkg> string (see
# bar-assistant/CLAUDE.md "Versioning"); only <pkg> changes here. Used by the
# post-merge `bump-version` workflow to auto-bump <pkg> on merges that change
# the built image without an upstream major/minor move (those set the leading
# fields by hand in the PR). Runs check-version-sync.sh afterwards so a bad edit
# fails loudly rather than pushing a broken version.
#
# Usage: scripts/bump-pkg.sh   -> bumps <pkg> by 1; prints the new version on
#                                 stdout (diagnostics go to stderr).
###############################################################################
set -euo pipefail

cd "$(dirname "$0")/.."
CFG="bar-assistant/config.yaml"
DOCKERFILE="bar-assistant/Dockerfile"

old="$(grep -E '^version:' "$CFG" | head -1 | sed -E 's/^version:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/')"
if ! [[ "$old" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "bump-pkg: config.yaml version '$old' is not a 5-part <BA_maj>.<BA_min>.<SR_maj>.<SR_min>.<pkg> string" >&2
    exit 1
fi
new="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}.$((BASH_REMATCH[5] + 1))"

# config.yaml `version:` (kept quoted) and the Dockerfile LABEL value.
sed -i -E "s|^(version:[[:space:]]*).*$|\1\"${new}\"|" "$CFG"
sed -i -E "s|(io\.hass\.version=\")[^\"]+(\")|\1${new}\2|" "$DOCKERFILE"

echo "bump-pkg: ${old} -> ${new}" >&2
bash scripts/check-version-sync.sh >&2
printf '%s\n' "$new"
