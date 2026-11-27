#Requires -Version 7.4

# A pushed tag releases the commit it points to. The tag is the upstream
# version the fork builds on, then F, an optional fork release number and,
# for a prerelease, -pre:
#   2.2.1F  2.2.1F.1  2.2.0.1F.2  2.2.1F.3-pre
# The upstream version must match pubspec.yaml at that commit (its first three
# parts: upstream's fourth, as in 2.2.0.1, is not in pubspec), and the commit
# must already be on main. See docs/releases.md.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Stop-Release([string]$Message) {
    Write-Host "::error::$Message"
    exit 1
}

$releaseTag = $env:RELEASE_TAG
if ([string]::IsNullOrEmpty($releaseTag)) {
    Stop-Release 'Release tag is required.'
}

$match = [regex]::Match($releaseTag, '^v?([0-9]+\.[0-9]+\.[0-9]+)(\.[0-9]+)?F(\.[1-9][0-9]*)?(-pre)?\z')
if (-not $match.Success) {
    Stop-Release "Release tag $releaseTag is not <upstream version>F[.N][-pre], such as 2.2.1F.1 or 2.2.1F.2-pre."
}
$base = $match.Groups[1].Value
$prerelease = $match.Groups[4].Success

$commit = & { $PSNativeCommandUseErrorActionPreference = $false; git rev-parse --verify --quiet "refs/tags/$releaseTag^{commit}" }
if ($LASTEXITCODE -ne 0) {
    Stop-Release "Tag $releaseTag does not exist."
}
$short = $commit.Substring(0, 9)

$version = $null
foreach ($line in (git show "${commit}:pubspec.yaml")) {
    if ($line -match '^version: ([0-9]+\.[0-9]+\.[0-9]+)') {
        $version = $Matches[1]
        break
    }
}
if ($version -ne $base) {
    Stop-Release "Tag $releaseTag builds on $base, but pubspec.yaml at $short has version $($version ?? 'none')."
}

& { $PSNativeCommandUseErrorActionPreference = $false; git merge-base --is-ancestor $commit origin/main }
if ($LASTEXITCODE -ne 0) {
    Stop-Release "Tag $releaseTag points to $short, which is not on main. Push the commit to main first."
}

$prereleaseText = $prerelease ? 'true' : 'false'
Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "tag=$releaseTag", "ref=$commit", "prerelease=$prereleaseText"
$channel = $prerelease ? 'prerelease' : 'release'
Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "Building $channel $releaseTag from $short."
