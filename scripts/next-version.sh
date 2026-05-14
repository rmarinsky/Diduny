#!/usr/bin/env bash
# Compute the next release tag from the latest `v*` git tag.
#
# Usage: next-version.sh <patch|minor|major>
# Prints: vX.Y.Z
#
# Pure tag math — the git tag is the single source of truth for the app
# version. CI (prepare-release.yml) uses this on PR merge; humans can run
# it locally to preview the next version. It writes nothing.
set -euo pipefail

bump="${1:?usage: next-version.sh <patch|minor|major>}"

git fetch --tags --quiet 2>/dev/null || true

latest="$(git tag -l 'v*' | sed 's/^v//' | sort -V | tail -1)"
latest="${latest:-0.0.0}"

IFS=. read -r major minor patch <<<"$latest"
major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"

case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "unknown bump: $bump (expected patch|minor|major)" >&2; exit 1 ;;
esac

echo "v${major}.${minor}.${patch}"
