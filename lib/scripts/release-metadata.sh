#!/usr/bin/env bash
set -euo pipefail

commit=$(git rev-parse HEAD)
tag=${RELEASE_INPUT_TAG:-${GITHUB_REF_NAME}}
name="$tag"
prerelease=false

# Branch pushes publish previews. Tagged and daily main releases stay stable.
if [[ "$GITHUB_EVENT_NAME" == push && "$GITHUB_REF_TYPE" == branch && "$GITHUB_REF_NAME" != main ]]; then
    branch=$(printf '%s' "$GITHUB_REF_NAME" | LC_ALL=C tr '[:upper:]' '[:lower:]' |
        LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-64)
    branch=${branch:-branch}
    tag="preview-${branch}-${GITHUB_RUN_ID}-${commit:0:9}"
    name="Preview ${GITHUB_REF_NAME} (${commit:0:9})"
    prerelease=true
fi

printf 'tag=%s\nname=%s\nprerelease=%s\ncommit=%s\n' \
    "$tag" "$name" "$prerelease" "$commit" >> "$GITHUB_OUTPUT"
