#Requires -Version 7.4

# Merges upstream into main and pushes main. It never tags or releases: a
# release is a tag pushed by hand (see docs/releases.md and release-tag.ps1).
#   SYNC_SOURCE=release  the commit of upstream's latest full release
#   SYNC_SOURCE=main     upstream's latest main commit

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$source = $env:SYNC_SOURCE
$upstreamRepo = 'bggRGjQaUbCoE/PiliPlus'
$upstreamUrl = "https://github.com/$upstreamRepo.git"

function Add-Summary([string]$Text) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Text
}

if ($source -cnotin 'release', 'main') {
    Write-Host "::error::Unknown sync source: $source"
    exit 1
}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

if ($source -ceq 'release') {
    # Only a published full release qualifies, never an un-released Git tag.
    $response = & {
        $PSNativeCommandUseErrorActionPreference = $false
        gh api "repos/$upstreamRepo/releases/latest" --jq 'select(.draft == false and .prerelease == false) | .tag_name' 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        $message = ($response | ForEach-Object { "$_" }) -join "`n"
        if ($message.Contains('(HTTP 404)')) {
            Add-Summary 'Upstream has no official release yet.'
            exit 0
        }
        [Console]::Error.WriteLine($message)
        exit 1
    }
    $upstreamTag = "$($response | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })".Trim()
    if ([string]::IsNullOrEmpty($upstreamTag)) {
        Add-Summary 'Upstream has no official release yet.'
        exit 0
    }
    git fetch --no-tags $upstreamUrl "refs/tags/$upstreamTag"
    $upstreamCommit = git rev-parse 'FETCH_HEAD^{commit}'
    $label = "release $upstreamRepo@$upstreamTag"
    $suggestion = "${upstreamTag}F"
    & { $PSNativeCommandUseErrorActionPreference = $false; git rev-parse --verify --quiet "refs/tags/$suggestion" } | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $suggestion += '.<n>'
    }
}
else {
    git fetch --no-tags $upstreamUrl main
    $upstreamCommit = git rev-parse FETCH_HEAD
    $label = "$upstreamRepo@main $($upstreamCommit.Substring(0, 9))"
    $suggestion = $null
}

& { $PSNativeCommandUseErrorActionPreference = $false; git merge-base --is-ancestor $upstreamCommit HEAD }
if ($LASTEXITCODE -eq 0) {
    Add-Summary "main already contains upstream $label."
    exit 0
}
& { $PSNativeCommandUseErrorActionPreference = $false; git merge --no-edit -m "Merge upstream $label" $upstreamCommit }
if ($LASTEXITCODE -ne 0) {
    git merge --abort
    Write-Host '::error::Upstream merge conflicts with fork changes. Merge it locally, resolve the conflicts and push main.'
    exit 1
}
git push origin HEAD:refs/heads/main

if (-not $suggestion) {
    foreach ($line in (Get-Content -LiteralPath 'pubspec.yaml')) {
        if ($line -match '^version: ([0-9]+\.[0-9]+\.[0-9]+)') {
            $suggestion = "$($Matches[1])F.<n>"
            break
        }
    }
}
$head = git rev-parse --short HEAD
Add-Summary "Merged upstream $label into main at $head. Nothing was released: push a tag such as $suggestion to release it."
