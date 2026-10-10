#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?Repository is required}"
: "${CURRENT_PRE_RELEASE_TAG:?Current prerelease tag is required}"

# Preserve the last working preview until its replacement is actually uploaded.
ready=$(gh api "repos/$GH_REPO/releases/tags/$CURRENT_PRE_RELEASE_TAG" --jq \
    '.prerelease == true and .draft == false and any(.assets[]; .state == "uploaded" and .size > 0 and (.name | endswith("_arm64-v8a.apk")))')
if [[ "$ready" != true ]]; then
    echo '::error::The new prerelease has no uploaded ARM64 APK; keeping existing prereleases.'
    exit 1
fi

old_tags=$(gh api --paginate "repos/$GH_REPO/releases" --jq \
    '.[] | select(.prerelease == true and .draft == false) | .tag_name')
while IFS= read -r old_tag; do
    if [[ -n "$old_tag" && "$old_tag" != "$CURRENT_PRE_RELEASE_TAG" ]]; then
        gh release delete "$old_tag" --repo "$GH_REPO" --yes --cleanup-tag
    fi
done <<< "$old_tags"
