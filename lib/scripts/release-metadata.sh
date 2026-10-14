#!/usr/bin/env bash
set -euo pipefail

: "${RELEASE_INPUT_TAG:?Release tag is required}"
: "${RELEASE_PRERELEASE:?Release channel is required}"

case "$RELEASE_PRERELEASE" in
    true|false) ;;
    *) echo '::error::Invalid release channel.'; exit 1 ;;
esac
if [[ "$RELEASE_PRERELEASE" == true && "$RELEASE_INPUT_TAG" != *-pre ]] ||
   [[ "$RELEASE_PRERELEASE" == false && ("$RELEASE_INPUT_TAG" == *-pre || "$RELEASE_INPUT_TAG" == *.preview-* || "$RELEASE_INPUT_TAG" == preview-*) ]]; then
    echo '::error::Release tag does not match its channel.'
    exit 1
fi

commit=$(git rev-parse HEAD)
if [[ "$(git rev-parse "$RELEASE_INPUT_TAG^{commit}")" != "$commit" ]]; then
    echo '::error::Release tag does not point to the checked-out commit.'
    exit 1
fi

printf 'tag=%s\nname=%s\nprerelease=%s\ncommit=%s\n' \
    "$RELEASE_INPUT_TAG" "$RELEASE_INPUT_TAG" "$RELEASE_PRERELEASE" "$commit" >> "$GITHUB_OUTPUT"
