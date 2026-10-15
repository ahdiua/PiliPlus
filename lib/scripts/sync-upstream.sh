#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?Fork repository is required}"
: "${SYNC_EVENT_NAME:?Sync event is required}"
upstream_repo='bggRGjQaUbCoE/PiliPlus'
prerelease=false

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

prepare_output() {
    printf 'tag=%s\nref=%s\nprerelease=%s\n' "$tag" "$release_commit" "$prerelease" >> "$GITHUB_OUTPUT"
    printf 'Prepared %s at %s for ARM64 build and release.\n' "$tag" "$release_commit" >> "$GITHUB_STEP_SUMMARY"
}

case "$SYNC_EVENT_NAME" in
    workflow_dispatch)
        prerelease=true
        git fetch --no-tags "https://github.com/$upstream_repo.git" main
        upstream_commit=$(git rev-parse FETCH_HEAD)
        tag_message="Upstream preview: $upstream_repo@$upstream_commit"
        ;;
    schedule)
        # Only published full releases qualify, never an un-released Git tag.
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
        tag_message="Upstream release: $upstream_repo@$upstream_tag"

        # Annotated fork tags track the upstream release across later main
        # commits and manual previews. An incomplete build reuses its tag/SHA.
        published_tags=$(gh api --paginate "repos/$GH_REPO/releases" --jq \
            '.[] | select(.draft == false and .prerelease == false) | select(any(.assets[]; .state == "uploaded" and .size > 0 and (.name | endswith("_arm64-v8a.apk")))) | .tag_name')
        tag=''
        candidates=$(git tag --list '*F*' --sort=version:refname)
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            case "$candidate" in
                *-pre|*.preview-*|preview-*) continue ;;
            esac
            if [[ "$(git for-each-ref --format='%(contents:subject)' "refs/tags/$candidate")" == "$tag_message" ]]; then
                if printf '%s\n' "$published_tags" | grep -Fxq -- "$candidate"; then
                    echo "Upstream release $upstream_tag is already published." >> "$GITHUB_STEP_SUMMARY"
                    exit 0
                fi
                tag="$candidate"
            fi
        done <<< "$candidates"
        if [[ -n "$tag" ]]; then
            release_commit=$(git rev-parse "$tag^{commit}")
            prepare_output
            exit 0
        fi

        git fetch --no-tags "https://github.com/$upstream_repo.git" "refs/tags/$upstream_tag"
        upstream_commit=$(git rev-parse 'FETCH_HEAD^{commit}')
        ;;
    *) echo '::error::Only scheduled or manual syncs are supported.'; exit 1 ;;
esac

if ! git merge --no-edit "$upstream_commit"; then
    git merge --abort
    echo '::error::Upstream merge conflicts with fork changes. Resolve the conflicts on main, then rerun this workflow.'
    exit 1
fi

if [[ "$prerelease" == true ]]; then
    version=$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml)
    if [[ -z "$version" ]]; then
        echo '::error::Cannot determine version from pubspec.yaml.'
        exit 1
    fi
    tag="${version}F.$(date -u +%Y%m%d%H%M%S)-pre"
else
    # Preserve the upstream release tag exactly, including v and extra parts.
    tag="${upstream_tag}F"
fi
if git show-ref --verify --quiet "refs/tags/$tag"; then
    echo "::error::Tag $tag already exists without matching upstream release metadata; refusing to overwrite it."
    exit 1
fi
git tag -a "$tag" -m "$tag_message"
release_commit=$(git rev-parse HEAD)

# The reusable build publishes this exact commit. Normal pushes never publish.
git push --atomic origin HEAD:refs/heads/main "refs/tags/$tag"
prepare_output
