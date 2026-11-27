#!/usr/bin/env bash
set -euo pipefail

# Merges upstream into main and pushes main. It never tags or releases: a
# release is a tag pushed by hand (see docs/releases.md and release-tag.sh).
#   SYNC_SOURCE=release  the commit of upstream's latest full release
#   SYNC_SOURCE=main     upstream's latest main commit
: "${SYNC_SOURCE:?Sync source is required}"
upstream_repo='bggRGjQaUbCoE/PiliPlus'
upstream_url="https://github.com/$upstream_repo.git"

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

version_of() {
    sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml
}

case "$SYNC_SOURCE" in
    release)
        # Only a published full release qualifies, never an un-released Git tag.
        api_error=$(mktemp)
        trap 'rm -f "$api_error"' EXIT
        if ! upstream_tag=$(gh api "repos/$upstream_repo/releases/latest" --jq \
            'select(.draft == false and .prerelease == false) | .tag_name' 2>"$api_error"); then
            if grep -q '(HTTP 404)' "$api_error"; then
                echo 'Upstream has no official release yet.' >> "$GITHUB_STEP_SUMMARY"
                exit 0
            fi
            cat "$api_error" >&2
            exit 1
        fi
        if [[ -z "$upstream_tag" ]]; then
            echo 'Upstream has no official release yet.' >> "$GITHUB_STEP_SUMMARY"
            exit 0
        fi
        git fetch --no-tags "$upstream_url" "refs/tags/$upstream_tag"
        upstream_commit=$(git rev-parse 'FETCH_HEAD^{commit}')
        label="release $upstream_repo@$upstream_tag"
        suggestion="${upstream_tag}F"
        if git rev-parse --verify --quiet "refs/tags/$suggestion" > /dev/null; then
            suggestion="$suggestion.<n>"
        fi
        ;;
    main)
        git fetch --no-tags "$upstream_url" main
        upstream_commit=$(git rev-parse FETCH_HEAD)
        label="$upstream_repo@main ${upstream_commit:0:9}"
        suggestion=''
        ;;
    *)
        echo "::error::Unknown sync source: $SYNC_SOURCE"
        exit 1
        ;;
esac

if git merge-base --is-ancestor "$upstream_commit" HEAD; then
    echo "main already contains upstream $label." >> "$GITHUB_STEP_SUMMARY"
    exit 0
fi
if ! git merge --no-edit -m "Merge upstream $label" "$upstream_commit"; then
    git merge --abort
    echo '::error::Upstream merge conflicts with fork changes. Merge it locally, resolve the conflicts and push main.'
    exit 1
fi
git push origin HEAD:refs/heads/main

[[ -n "$suggestion" ]] || suggestion="$(version_of)F.<n>"
printf 'Merged upstream %s into main at %s. Nothing was released: push a tag such as %s to release it.\n' \
    "$label" "$(git rev-parse --short HEAD)" "$suggestion" >> "$GITHUB_STEP_SUMMARY"
