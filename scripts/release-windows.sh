#!/bin/bash
# Dispatch the shared macOS, Linux, and Windows release workflow and wait for it.
# Usage: scripts/release-windows.sh [version]
#   version is required, e.g. 0.2 or 0.2.0
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="jdreioe/Flow"
WORKFLOW="release.yml"

command -v gh >/dev/null || { echo "error: gh (GitHub CLI) not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: not authenticated with gh. Run: gh auth login" >&2; exit 1; }

VERSION="${1:-}"
case "$VERSION" in
    v*) VERSION="${VERSION#v}" ;;
esac
case "$VERSION" in
    ""|*[!0-9.]|.*|*.)
        echo "error: pass a version of digits and dots: $0 0.2.0" >&2
        exit 1
        ;;
esac
case "$VERSION" in
    *.*) ;;
    *) VERSION="$VERSION.0" ;;
esac
TAG="v$VERSION"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: release $TAG already exists" >&2
    exit 1
fi

REF="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)"
case "$REF" in
    ""|HEAD) REF="main" ;;
esac

echo "Dispatching the shared release workflow on $REF for $TAG"
gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$REF" -f version="$VERSION"

sleep 5
RUN_ID="$(gh run list --repo "$REPO" --workflow="$WORKFLOW" --event=workflow_dispatch \
    --limit 1 --json databaseId --jq '.[0].databaseId')"
echo "Watching run https://github.com/$REPO/actions/runs/$RUN_ID"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status

gh release view "$TAG" --repo "$REPO" --json url --jq .url
