#!/usr/bin/env bash
set -euo pipefail

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git fetch --no-tags https://github.com/bggRGjQaUbCoE/PiliPlus.git main
upstream_commit=$(git rev-parse FETCH_HEAD)

if ! git merge --no-edit "$upstream_commit"; then
    git merge --abort
    echo '::error::Upstream merge conflicts with fork changes. Resolve the conflicts on main, then rerun this workflow.'
    exit 1
fi

# A failed build can reuse its existing tag on the next daily run.
# Only releases with an actual ARM64 APK count as completed releases.
published_tags=$(gh api --paginate "repos/$GH_REPO/releases" --jq \
    '.[] | select(.draft == false and .prerelease == false) | select(any(.assets[]; .name | endswith("_arm64-v8a.apk"))) | .tag_name')
tag=''
while IFS= read -r candidate; do
    if [[ -z "$candidate" ]]; then
        continue
    fi
    if printf '%s\n' "$published_tags" | grep -Fxq -- "$candidate"; then
        echo 'This commit already has a published ARM64 APK.'
        exit 0
    fi
    tag="$candidate"
done < <(git tag --points-at HEAD --list '*F*' --sort=version:refname)

if [[ -z "$tag" ]]; then
    version=$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml)
    if [[ -z "$version" ]]; then
        echo '::error::Cannot determine version from pubspec.yaml.'
        exit 1
    fi
    tag="${version}F.$(date -u +%Y%m%d%H%M%S).$(git rev-parse --short=9 HEAD)"
    git tag "$tag"
fi

# Publish the merged branch and tag together; never overwrite remote changes.
git push --atomic origin HEAD:refs/heads/main "refs/tags/$tag"
printf 'tag=%s\nref=%s\n' "$tag" "$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
printf 'Prepared `%s` for ARM64 build and release.\n' "$tag" >> "$GITHUB_STEP_SUMMARY"
