#!/usr/bin/env bash
###############################################################################
# Prepend a new release section to bar-assistant/CHANGELOG.md.
#
# The changelog is a "# Changelog" title + a short preamble, then one
# "## <version>" section per release, newest first. This inserts a new
# "## <version>" section immediately BELOW the preamble (above the current
# newest entry), preserving the preamble.
#
# Used by the post-merge `bump-version` workflow so every auto <pkg> bump also
# records a changelog entry. The bullet body is read from stdin.
#
# Usage: printf '%s\n' '- did a thing' | scripts/changelog-prepend.sh <version>
###############################################################################
set -euo pipefail

cd "$(dirname "$0")/.."
CL="bar-assistant/CHANGELOG.md"
ver="${1:?usage: changelog-prepend.sh <version> (body on stdin)}"
body="$(cat)"

awk -v ver="$ver" -v body="$body" '
  BEGIN { done = 0 }
  # Insert the new section just before the first existing release header.
  /^## / && !done {
    print "## " ver
    print ""
    print body
    print ""
    done = 1
  }
  { print }
  # No existing release header (e.g. empty changelog): append at the end.
  END { if (!done) { print ""; print "## " ver; print ""; print body } }
' "$CL" > "$CL.tmp"
mv "$CL.tmp" "$CL"

echo "changelog-prepend: added '## ${ver}' section" >&2
