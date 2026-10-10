param(
    [string]$Dart = "dart"
)

$ErrorActionPreference = "Stop"
$networkRepo = Split-Path -Parent $PSScriptRoot
$networkHarness = Join-Path $networkRepo ".fvm/network-core-tests"
$networkLib = Join-Path $networkHarness "lib/services/thread_ripper"
$networkTests = Join-Path $networkHarness "test"
New-Item -ItemType Directory -Path $networkLib, "$networkTests/fixtures" -Force | Out-Null

# Compile and test the actual network core without requiring Flutter or the
# app's patched UI dependencies. Only the test framework import is changed.
Get-ChildItem -LiteralPath "$networkRepo/lib/services/thread_ripper" -Filter "*.dart" |
    Copy-Item -Destination $networkLib -Force
foreach ($networkTestName in @("thread_ripper_test.dart", "thread_ripper_auto_test.dart", "playback_network_test.dart")) {
    $networkTestText = [System.IO.File]::ReadAllText("$networkRepo/test/$networkTestName")
    $networkTestText = $networkTestText.Replace("package:flutter_test/flutter_test.dart", "package:test/test.dart")
    [System.IO.File]::WriteAllText("$networkTests/$networkTestName", $networkTestText)
}
Get-ChildItem -LiteralPath "$networkRepo/test/fixtures" -Filter "ripper_*.json" |
    Copy-Item -Destination "$networkTests/fixtures" -Force

@'
name: PiliPlus
environment:
  sdk: '>=3.13.0 <4.0.0'
dev_dependencies:
  test: ^1.26.3
'@ | Set-Content -LiteralPath "$networkHarness/pubspec.yaml" -Encoding utf8
@'
analyzer:
  errors:
    unused_import: error
'@ | Set-Content -LiteralPath "$networkHarness/analysis_options.yaml" -Encoding utf8

$networkOldPubCache = $env:PUB_CACHE
$env:PUB_CACHE = Join-Path $networkHarness "pub_cache"
Push-Location $networkHarness
try {
    & $Dart pub get
    if ($LASTEXITCODE -ne 0) { throw "Network core dependency resolution failed" }
    & $Dart analyze lib test
    if ($LASTEXITCODE -ne 0) { throw "Network core analysis failed" }
    & $Dart test --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw "Network core tests failed" }
} finally {
    Pop-Location
    $env:PUB_CACHE = $networkOldPubCache
}
