#!/usr/bin/env bash
set -euo pipefail

commit=$(git rev-parse HEAD)
tag=${RELEASE_INPUT_TAG:-${GITHUB_REF_NAME}}
name="$tag"
prerelease=false

# Branch pushes publish previews. Tagged and daily main releases stay stable.
if [[ "$GITHUB_EVENT_NAME" == push && "$GITHUB_REF_TYPE" == branch && "$GITHUB_REF_NAME" != main ]]; then
    version=$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml)
    if [[ -z "$version" ]]; then
        echo '::error::Cannot determine release version from pubspec.yaml.'
        exit 1
    fi
    tag="${version}F.$(date -u +%Y%m%d%H%M%S)-pre"
    name="$tag (${GITHUB_REF_NAME})"
    prerelease=true
fi

# A preview tag pushed manually must remain a prerelease as well.
if [[ "$tag" == *-pre || "$tag" == *.preview-* || "$tag" == preview-* ]]; then
    prerelease=true
fi

printf 'tag=%s\nname=%s\nprerelease=%s\ncommit=%s\n' \
    "$tag" "$name" "$prerelease" "$commit" >> "$GITHUB_OUTPUT"
