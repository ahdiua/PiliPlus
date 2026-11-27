#Requires -Version 7.4

# Exercises the release scripts in lib/scripts against disposable local Git
# repositories under .fvm/release-policy-tests. Git merges, tags and pushes are
# real; only GitHub API calls and the upstream fetch URL are replaced, so
# nothing is published. See docs/releases.md.
#   ./tool/check_release_policy.ps1 [-Name <wildcard>]

param(
    # Runs only the tests whose names match.
    [string]$Name = '*'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repoRoot = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $repoRoot 'lib/scripts'
$harness = Join-Path $repoRoot '.fvm/release-policy-tests'
$pwshPath = [Environment]::ProcessPath
$upstreamName = 'bggRGjQaUbCoE/PiliPlus'

# Replaces gh and the upstream fetch URL, then runs the script in its scope.
# Like the Actions pwsh shell, it exits with the script's last exit code. The
# gh fixture fails loudly on any request the release scripts should not make.
$runner = @'
param([Parameter(Mandatory)][string]$Script)
$testGit = (Get-Command git -CommandType Application -TotalCount 1).Source
function git {
    if ($args.Count -ge 4 -and $args[0] -ceq 'fetch' -and $args[2] -ceq 'https://github.com/bggRGjQaUbCoE/PiliPlus.git') {
        & $testGit fetch --no-tags $env:TEST_UPSTREAM $args[3]
    }
    else {
        & $testGit @args
    }
}
function gh {
    $line = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($line.StartsWith('api repos/bggRGjQaUbCoE/PiliPlus/releases/latest ')) {
        if (-not $line.Contains('select(.draft == false and .prerelease == false)')) {
            throw 'Missing full-release filter'
        }
        if ($env:API_ERROR) {
            $global:LASTEXITCODE = 1; return "gh: fixture error (HTTP $env:API_ERROR)"
        }
        return $env:UPSTREAM_TAG
    }
    if ($line.StartsWith("api repos/$env:GH_REPO/releases/tags/$env:CURRENT_PRE_RELEASE_TAG ")) {
        if (-not $line.Contains('.prerelease == true and .draft == false and any(.assets[]; .state == "uploaded" and .size > 0 and (.name | endswith("_arm64-v8a.apk")))')) {
            throw 'Missing uploaded APK filter'
        }
        return $env:TEST_READY
    }
    if ($line.StartsWith("api --paginate repos/$env:GH_REPO/releases ")) {
        if (-not $line.Contains('select(.prerelease == true and .draft == false) | .tag_name')) {
            throw 'Missing prerelease filter'
        }
        return $env:TEST_PRERELEASES -split ','
    }
    if ($args.Count -eq 7 -and $args[0] -ceq 'release' -and $args[1] -ceq 'delete' -and
        "$($args[3..6])" -ceq "--repo $env:GH_REPO --yes --cleanup-tag") {
        Add-Content -LiteralPath $env:TEST_DELETED -Value $args[2]
        return
    }
    throw "Unexpected gh request: $line"
}
. $Script
exit $LASTEXITCODE
'@

# Runs git in a directory; returns its trimmed standard output.
function Invoke-Git {
    $PSNativeCommandUseErrorActionPreference = $false
    $dir = $args[0]
    [string[]]$rest = $args[1..($args.Count - 1)]
    $output = git -C $dir @rest 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $rest failed: $($output -join "`n")"
    }
    (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
}

function Set-TestFile([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text)
}

# Each test gets an upstream with a full release (v2.1.6) followed by an
# unreleased commit, and a fork whose main has one commit of its own.
function New-Fixture {
    New-Item -ItemType Directory -Path $harness -Force | Out-Null
    $root = Join-Path $harness ([System.IO.Path]::GetRandomFileName())
    $f = [pscustomobject]@{
        Root = $root
        Upstream = Join-Path $root 'upstream'
        Fork = Join-Path $root 'fork'
        Remote = Join-Path $root 'origin.git'
        Output = Join-Path $root 'output.txt'
        Summary = Join-Path $root 'summary.txt'
        Deleted = Join-Path $root 'deleted.txt'
        Runner = Join-Path $root 'runner.ps1'
        Initial = $null
    }
    New-Item -ItemType Directory -Path $f.Upstream | Out-Null
    Invoke-Git $f.Upstream init -b main | Out-Null
    Set-TestFile (Join-Path $f.Upstream 'pubspec.yaml') "version: 2.1.6+1`n"
    Invoke-Git $f.Upstream add . | Out-Null
    Invoke-Git $f.Upstream commit -m base | Out-Null
    $base = Invoke-Git $f.Upstream rev-parse HEAD
    Set-TestFile (Join-Path $f.Upstream 'stable.txt') "official change`n"
    Invoke-Git $f.Upstream add . | Out-Null
    Invoke-Git $f.Upstream commit -m stable | Out-Null
    Invoke-Git $f.Upstream tag -a v2.1.6 -m 'upstream stable' | Out-Null
    Set-TestFile (Join-Path $f.Upstream 'development.txt') "unreleased change`n"
    Invoke-Git $f.Upstream add . | Out-Null
    Invoke-Git $f.Upstream commit -m development | Out-Null
    Invoke-Git $f.Upstream tag v2.1.7-pre | Out-Null
    Invoke-Git $root init --bare $f.Remote | Out-Null
    Invoke-Git $root clone $f.Upstream $f.Fork | Out-Null
    Invoke-Git $f.Fork switch -C main $base | Out-Null
    Invoke-Git $f.Fork remote set-url origin $f.Remote | Out-Null
    Set-TestFile (Join-Path $f.Fork 'fork.txt') "fork feature`n"
    Invoke-Git $f.Fork add . | Out-Null
    Invoke-Git $f.Fork commit -m 'fork feature' | Out-Null
    Invoke-Git $f.Fork push origin main | Out-Null
    Invoke-Git $f.Fork fetch origin | Out-Null
    $f.Initial = Invoke-Git $f.Fork rev-parse HEAD
    Set-TestFile $f.Runner $runner
    $f
}

# Runs a release script in the fork as a separate pwsh process. Returns its
# exit code, its combined output and the step outputs it wrote.
function Invoke-ReleaseScript([string]$Script, [hashtable]$Environment = @{}) {
    Set-TestFile $f.Output ''
    Set-TestFile $f.Summary ''
    Set-TestFile $f.Deleted ''
    $values = @{
        TEST_UPSTREAM = $f.Upstream; UPSTREAM_TAG = 'v2.1.6'; API_ERROR = $null
        GITHUB_OUTPUT = $f.Output; GITHUB_STEP_SUMMARY = $f.Summary; TEST_DELETED = $f.Deleted
        SYNC_SOURCE = $null; RELEASE_TAG = $null; RELEASE_INPUT_TAG = $null; RELEASE_PRERELEASE = $null
        GH_REPO = $null; CURRENT_PRE_RELEASE_TAG = $null; TEST_READY = $null; TEST_PRERELEASES = $null
    }
    foreach ($key in $Environment.Keys) { $values[$key] = $Environment[$key] }
    $saved = @{}
    foreach ($key in $values.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $values[$key])
    }
    Push-Location $f.Fork
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $text = (& $pwshPath -NoProfile -NonInteractive -File $f.Runner (Join-Path $scripts $Script) 2>&1 |
            ForEach-Object { "$_" }) -join "`n"
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
    $data = [ordered]@{}
    foreach ($line in [System.IO.File]::ReadAllLines($f.Output)) {
        if ($line) {
            $key, $value = $line -split '=', 2
            $data[$key] = $value
        }
    }
    [pscustomobject]@{ Code = $code; Text = $text; Data = $data }
}

function Invoke-Sync([string]$Source = 'release', [hashtable]$Environment = @{}) {
    Invoke-ReleaseScript 'sync-upstream.ps1' (@{ SYNC_SOURCE = $Source } + $Environment)
}

function Invoke-ReleaseTag([string]$Tag) {
    Invoke-ReleaseScript 'release-tag.ps1' @{ RELEASE_TAG = $Tag }
}

function Invoke-Metadata([string]$Tag, [string]$Channel) {
    Invoke-ReleaseScript 'release-metadata.ps1' @{ RELEASE_INPUT_TAG = $Tag; RELEASE_PRERELEASE = $Channel }
}

function Invoke-Cleanup([string]$Ready, [string[]]$Prereleases) {
    Invoke-ReleaseScript 'cleanup-prereleases.ps1' @{
        GH_REPO = 'ahdiua/PiliPlus'; CURRENT_PRE_RELEASE_TAG = '2.1.6F.2-pre'
        TEST_READY = $Ready; TEST_PRERELEASES = $Prereleases -join ','
    }
}

function Assert-Equal($Actual, $Expected, [string]$Message = '') {
    if ("$Actual" -cne "$Expected") {
        throw "Expected [$Expected] but got [$Actual]. $Message"
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Contains([string]$Text, [string]$Part) {
    if (-not $Text.Contains($Part)) { throw "Expected [$Part] in:`n$Text" }
}

function Assert-Succeeded($Result) {
    Assert-Equal $Result.Code 0 $Result.Text
}

function Assert-Failed($Result) {
    Assert-True ($Result.Code -ne 0) "Expected failure:`n$($Result.Text)"
    Assert-Equal $Result.Data.Count 0 'A failed check must not hand anything to the build.'
}

function Get-Data($Result) {
    ($Result.Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
}

function Get-RemoteMain { Invoke-Git $f.Remote rev-parse main }
function Get-ReleaseTags { Invoke-Git $f.Fork tag --list '*F*' }

function Test-Sync([string]$Source = 'release', [hashtable]$Environment = @{}) {
    $result = Invoke-Sync $Source $Environment
    Assert-Succeeded $result
    # Syncing never hands a release to the build.
    Assert-Equal $result.Data.Count 0
    [System.IO.File]::ReadAllText($f.Summary)
}

function Test-ForkFile([string]$Name) {
    Test-Path -LiteralPath (Join-Path $f.Fork $Name)
}

$tests = [ordered]@{}

# Syncing upstream

$tests['release source merges only the official tag and pushes main'] = {
    $summary = Test-Sync
    Assert-True (Test-ForkFile 'stable.txt') 'The released change is missing.'
    Assert-True (Test-ForkFile 'fork.txt') 'The fork change is missing.'
    Assert-True (-not (Test-ForkFile 'development.txt')) 'An unreleased change was merged.'
    Assert-Equal (Get-RemoteMain) (Invoke-Git $f.Fork rev-parse HEAD)
    Assert-Contains (Invoke-Git $f.Fork log -1 --format=%s) "$upstreamName@v2.1.6"
    Assert-Equal (Get-ReleaseTags) ''
    Assert-Contains $summary 'push a tag such as v2.1.6F '
}

$tests['release source suggests a fork number after a release'] = {
    Invoke-Git $f.Fork tag v2.1.6F | Out-Null
    Assert-Contains (Test-Sync) 'push a tag such as v2.1.6F.<n> '
}

$tests['main source merges upstream development'] = {
    $summary = Test-Sync 'main'
    Assert-True (Test-ForkFile 'development.txt') 'The upstream main change is missing.'
    Assert-True (Test-ForkFile 'fork.txt') 'The fork change is missing.'
    Assert-Equal (Get-RemoteMain) (Invoke-Git $f.Fork rev-parse HEAD)
    Assert-Equal (Get-ReleaseTags) ''
    Assert-Contains $summary 'push a tag such as 2.1.6F.<n> '
}

$tests['merged upstream is not merged again'] = {
    Test-Sync | Out-Null
    $before = Invoke-Git $f.Fork rev-parse HEAD
    Assert-Contains (Test-Sync) 'already contains'
    Assert-Equal (Invoke-Git $f.Fork rev-parse HEAD) $before
    Assert-Equal (Get-RemoteMain) $before
}

$tests['no official release does nothing'] = {
    foreach ($environment in @{ API_ERROR = '404' }, @{ UPSTREAM_TAG = '' }) {
        Assert-Contains (Test-Sync 'release' $environment) 'no official release'
        Assert-Equal (Invoke-Git $f.Fork rev-parse HEAD) $f.Initial
        Assert-Equal (Get-RemoteMain) $f.Initial
    }
}

$tests['api failure stops without merge'] = {
    $result = Invoke-Sync 'release' @{ API_ERROR = '403' }
    Assert-Failed $result
    Assert-Contains $result.Text 'HTTP 403'
    Assert-Equal (Invoke-Git $f.Fork rev-parse HEAD) $f.Initial
    Assert-Equal (Get-RemoteMain) $f.Initial
}

$tests['merge conflict does not push'] = {
    Set-TestFile (Join-Path $f.Fork 'stable.txt') "conflicting fork change`n"
    Invoke-Git $f.Fork add . | Out-Null
    Invoke-Git $f.Fork commit -m 'fork conflict' | Out-Null
    $before = Invoke-Git $f.Fork rev-parse HEAD
    $result = Invoke-Sync
    Assert-Failed $result
    Assert-Contains $result.Text 'conflicts'
    Assert-Equal (Invoke-Git $f.Fork rev-parse HEAD) $before
    Assert-Equal (Invoke-Git $f.Fork status --porcelain) ''
    Assert-Equal (Get-RemoteMain) $f.Initial
}

$tests['unknown source fails'] = {
    Assert-Failed (Invoke-Sync 'schedule')
    Assert-Equal (Get-RemoteMain) $f.Initial
}

# Releasing a pushed tag

$tests['release tag forms and channels'] = {
    $forms = [ordered]@{
        '2.1.6F' = 'false'; '2.1.6F.1' = 'false'; '2.1.6.2F.3' = 'false'; 'v2.1.6F.12' = 'false'
        '2.1.6F-pre' = 'true'; '2.1.6F.2-pre' = 'true'
    }
    foreach ($tag in $forms.Keys) {
        Invoke-Git $f.Fork tag $tag | Out-Null
        $result = Invoke-ReleaseTag $tag
        Assert-Succeeded $result
        Assert-Equal (Get-Data $result) "tag=$tag;ref=$($f.Initial);prerelease=$($forms[$tag])" $tag
        $channel = $forms[$tag] -eq 'true' ? 'prerelease' : 'release'
        Assert-Contains ([System.IO.File]::ReadAllText($f.Summary)) "Building $channel $tag from"
    }
}

$tests['release tag rejects other forms'] = {
    foreach ($tag in '2.1.6', '2.1.6.1', '2.1.6F.0', '2.1.6F.01', '2.1.6F1', '2.1.6f',
        '2.1.6-pre', '2.1.6F.1-beta', 'F2.1.6', '2.1.6F.1.2') {
        Invoke-Git $f.Fork tag $tag | Out-Null
        $result = Invoke-ReleaseTag $tag
        Assert-Failed $result
        Assert-Contains $result.Text 'is not <upstream version>F'
    }
}

$tests['release tag must match pubspec'] = {
    Invoke-Git $f.Fork tag 2.1.7F.1 | Out-Null
    $result = Invoke-ReleaseTag '2.1.7F.1'
    Assert-Failed $result
    Assert-Contains $result.Text 'pubspec.yaml'
}

$tests['release tag must be on main'] = {
    Invoke-Git $f.Fork switch -c side | Out-Null
    Set-TestFile (Join-Path $f.Fork 'side.txt') "not on main`n"
    Invoke-Git $f.Fork add . | Out-Null
    Invoke-Git $f.Fork commit -m side | Out-Null
    Invoke-Git $f.Fork tag 2.1.6F.1 | Out-Null
    $result = Invoke-ReleaseTag '2.1.6F.1'
    Assert-Failed $result
    Assert-Contains $result.Text 'not on main'
}

$tests['missing release tag fails'] = {
    $result = Invoke-ReleaseTag '2.1.6F.9'
    Assert-Failed $result
    Assert-Contains $result.Text 'does not exist'
}

$tests['metadata rejects channel mismatch and wrong commit'] = {
    Invoke-Git $f.Fork tag 2.1.6F.1 | Out-Null
    Invoke-Git $f.Fork tag 2.1.6F.2-pre | Out-Null
    $result = Invoke-Metadata '2.1.6F.1' 'false'
    Assert-Succeeded $result
    Assert-Equal (Get-Data $result) "tag=2.1.6F.1;name=2.1.6F.1;prerelease=false;commit=$($f.Initial)"
    $result = Invoke-Metadata '2.1.6F.2-pre' 'true'
    Assert-Succeeded $result
    Assert-Equal $result.Data['prerelease'] 'true'
    foreach ($case in @('2.1.6F.1', 'true'), @('2.1.6F.2-pre', 'false'), @('2.1.6F.1', 'yes')) {
        Assert-Failed (Invoke-Metadata $case[0] $case[1])
    }
    Set-TestFile (Join-Path $f.Fork 'later.txt') "later`n"
    Invoke-Git $f.Fork add . | Out-Null
    Invoke-Git $f.Fork commit -m later | Out-Null
    $result = Invoke-Metadata '2.1.6F.1' 'false'
    Assert-Failed $result
    Assert-Contains $result.Text 'does not point to the checked-out commit'
}

# Removing old prereleases

$tests['cleanup keeps prereleases until the new APK is uploaded'] = {
    $result = Invoke-Cleanup 'false' '2.1.6F.1-pre', '2.1.6F.2-pre'
    Assert-True ($result.Code -ne 0) "Expected failure:`n$($result.Text)"
    Assert-Contains $result.Text 'keeping existing prereleases'
    Assert-Equal ([System.IO.File]::ReadAllText($f.Deleted)) ''
}

$tests['cleanup deletes only the other prereleases'] = {
    $result = Invoke-Cleanup 'true' '2.1.6F.1-pre', '', '2.1.6F.2-pre', '2.1.5F-pre'
    Assert-Succeeded $result
    Assert-Equal (([System.IO.File]::ReadAllLines($f.Deleted)) -join ',') '2.1.6F.1-pre,2.1.5F-pre'
}

# Test identities only; the user's Git configuration is never read.
$gitEnvironment = @{
    GIT_CONFIG_NOSYSTEM = '1'; GIT_CONFIG_GLOBAL = $IsWindows ? 'NUL' : '/dev/null'; GIT_TERMINAL_PROMPT = '0'
    GIT_AUTHOR_NAME = 'Test'; GIT_AUTHOR_EMAIL = 'test@example.com'
    GIT_COMMITTER_NAME = 'Test'; GIT_COMMITTER_EMAIL = 'test@example.com'
}
$savedGitEnvironment = @{}
foreach ($key in $gitEnvironment.Keys) {
    $savedGitEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
    [Environment]::SetEnvironmentVariable($key, $gitEnvironment[$key])
}

$failed = 0
$ran = 0
try {
    foreach ($testName in $tests.Keys) {
        if ($testName -notlike $Name) { continue }
        $ran++
        $f = New-Fixture
        try {
            & $tests[$testName]
            Write-Host "ok    $testName"
        }
        catch {
            $failed++
            Write-Host "FAIL  $testName`n      $($_.Exception.Message)`n      $($_.InvocationInfo.PositionMessage)"
        }
        finally {
            # Only the disposable fixture under the harness is removed.
            if ($f.Root.StartsWith((Resolve-Path $harness).Path)) {
                Remove-Item -LiteralPath $f.Root -Recurse -Force
            }
        }
    }
}
finally {
    foreach ($key in $savedGitEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedGitEnvironment[$key])
    }
}

Write-Host "$($ran - $failed) passed, $failed failed"
if ($failed -gt 0 -or $ran -eq 0) {
    exit 1
}
