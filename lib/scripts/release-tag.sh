#!/usr/bin/env bash
set -euo pipefail

# A pushed tag releases the commit it points to. The tag is the upstream
# version the fork builds on, then F, an optional fork release number and,
# for a prerelease, -pre:
#   2.2.1F  2.2.1F.1  2.2.0.1F.2  2.2.1F.3-pre
# The upstream version must match pubspec.yaml at that commit (its first three
# parts: upstream's fourth, as in 2.2.0.1, is not in pubspec), and the commit
# must already be on main. See docs/releases.md.
: "${RELEASE_TAG:?Release tag is required}"

fail() {
    echo "::error::$1"
    exit 1
}

pattern='^v?([0-9]+\.[0-9]+\.[0-9]+)(\.[0-9]+)?F(\.[1-9][0-9]*)?(-pre)?$'
[[ "$RELEASE_TAG" =~ $pattern ]] ||
    fail "Release tag $RELEASE_TAG is not <upstream version>F[.N][-pre], such as 2.2.1F.1 or 2.2.1F.2-pre."
base=${BASH_REMATCH[1]}
prerelease=false
[[ -z "${BASH_REMATCH[4]}" ]] || prerelease=true

commit=$(git rev-parse --verify --quiet "refs/tags/$RELEASE_TAG^{commit}") ||
    fail "Tag $RELEASE_TAG does not exist."
version=$(git show "$commit:pubspec.yaml" | sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
[[ "$version" == "$base" ]] ||
    fail "Tag $RELEASE_TAG builds on $base, but pubspec.yaml at ${commit:0:9} has version ${version:-none}."
git merge-base --is-ancestor "$commit" origin/main ||
    fail "Tag $RELEASE_TAG points to ${commit:0:9}, which is not on main. Push the commit to main first."

printf 'tag=%s\nref=%s\nprerelease=%s\n' "$RELEASE_TAG" "$commit" "$prerelease" >> "$GITHUB_OUTPUT"
channel=release
[[ "$prerelease" == false ]] || channel=prerelease
printf 'Building %s %s from %s.\n' "$channel" "$RELEASE_TAG" "${commit:0:9}" >> "$GITHUB_STEP_SUMMARY"
