#Requires -Version 7.4

# Checks the tag and channel handed to the build and passes them on as step
# outputs. The tag must point to the checked-out commit.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Stop-Release([string]$Message) {
    Write-Host "::error::$Message"
    exit 1
}

$tag = $env:RELEASE_INPUT_TAG
$prerelease = $env:RELEASE_PRERELEASE
if ([string]::IsNullOrEmpty($tag)) {
    Stop-Release 'Release tag is required.'
}
if ($prerelease -cnotin 'true', 'false') {
    Stop-Release 'Invalid release channel.'
}

$looksPre = $tag.EndsWith('-pre', [StringComparison]::Ordinal)
$looksPreview = $looksPre -or $tag.Contains('.preview-', [StringComparison]::Ordinal) -or
    $tag.StartsWith('preview-', [StringComparison]::Ordinal)
if (($prerelease -ceq 'true' -and -not $looksPre) -or ($prerelease -ceq 'false' -and $looksPreview)) {
    Stop-Release 'Release tag does not match its channel.'
}

$commit = git rev-parse HEAD
$tagged = & { $PSNativeCommandUseErrorActionPreference = $false; git rev-parse --verify --quiet "refs/tags/$tag^{commit}" }
if ($LASTEXITCODE -ne 0 -or $tagged -cne $commit) {
    Stop-Release 'Release tag does not point to the checked-out commit.'
}

Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "tag=$tag", "name=$tag", "prerelease=$prerelease", "commit=$commit"
