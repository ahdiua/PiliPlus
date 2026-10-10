param(
    [string]$Arg = ''
)

try {
    $versionName = $null

    $versionCode = [int](git rev-list --count HEAD).Trim()

    $buildTime = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    if ($Arg -eq 'android') {
        . (Join-Path $PSScriptRoot 'android-version.ps1')
        $publishedCode = 0L
        if ($env:GITHUB_ACTIONS -eq 'true') {
            if ([string]::IsNullOrEmpty($env:GITHUB_REPOSITORY)) {
                throw 'GITHUB_REPOSITORY is required for Android release builds'
            }
            $assetNames = gh api --paginate "repos/$env:GITHUB_REPOSITORY/releases" --jq '.[] | .assets[] | .name'
            if ($LASTEXITCODE -ne 0) {
                throw 'Cannot determine published Android version codes'
            }
            foreach ($assetName in $assetNames) {
                if ($assetName -match '\+(\d+)_arm64-v8a\.apk$') {
                    $publishedCode = [Math]::Max($publishedCode, [long]$matches[1])
                }
            }
        }
        $versionCode = Get-AndroidVersionCode -UnixSeconds $buildTime -CommitCount $versionCode -PublishedCode $publishedCode
    }

    $commitHash = (git rev-parse HEAD).Trim()

    $updatedContent = foreach ($line in (Get-Content -Path 'pubspec.yaml' -Encoding UTF8)) {
        if ($line -match '^\s*version:\s*([\d\.]+)') {
            $versionName = $matches[1]
            if ($Arg -eq 'android') {
                $versionName += '-' + $commitHash.Substring(0, 9)
            }
            "version: $versionName+$versionCode"
        }
        else {
            $line
        }
    }

    if ($null -eq $versionName) {
        throw 'version not found'
    }

    $updatedContent | Set-Content -Path 'pubspec.yaml' -Encoding UTF8

    $data = @{
        'pili.name' = $versionName
        'pili.code' = $versionCode
        'pili.hash' = $commitHash
        'pili.time' = $buildTime
    }

    $data | ConvertTo-Json -Compress | Out-File 'pili_release.json' -Encoding UTF8

    Add-Content -Path $env:GITHUB_ENV -Value "version=$versionName+$versionCode"
}
catch {
    Write-Error "Prebuild Error: $($_.Exception.Message)"
    exit 1
}
