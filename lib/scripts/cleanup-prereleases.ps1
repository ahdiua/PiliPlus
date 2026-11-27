#Requires -Version 7.4

# Deletes every other published prerelease and its tag once the new one has
# its ARM64 APK. Full releases and drafts are kept.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repo = $env:GH_REPO
$current = $env:CURRENT_PRE_RELEASE_TAG
if ([string]::IsNullOrEmpty($repo) -or [string]::IsNullOrEmpty($current)) {
    Write-Host '::error::Repository and current prerelease tag are required.'
    exit 1
}

# Preserve the last working preview until its replacement is actually uploaded.
$ready = gh api "repos/$repo/releases/tags/$current" --jq '.prerelease == true and .draft == false and any(.assets[]; .state == "uploaded" and .size > 0 and (.name | endswith("_arm64-v8a.apk")))'
if ($ready -cne 'true') {
    Write-Host '::error::The new prerelease has no uploaded ARM64 APK; keeping existing prereleases.'
    exit 1
}

$oldTags = gh api --paginate "repos/$repo/releases" --jq '.[] | select(.prerelease == true and .draft == false) | .tag_name'
foreach ($oldTag in $oldTags) {
    if (-not [string]::IsNullOrEmpty($oldTag) -and $oldTag -cne $current) {
        gh release delete $oldTag --repo $repo --yes --cleanup-tag
    }
}
