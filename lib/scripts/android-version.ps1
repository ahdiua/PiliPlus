function Get-AndroidVersionCode {
    param(
        [long]$UnixSeconds,
        [long]$CommitCount,
        [long]$PublishedCode = 0
    )

    # Seconds since 2020 fit Android's versionCode range for decades and are
    # independent of branch history. Also advance past every published APK.
    $code = [Math]::Max($UnixSeconds - 1577836800, $CommitCount)
    $code = [Math]::Max($code, $PublishedCode + 1)
    if ($code -lt 1 -or $code -gt 2100000000) {
        throw "Android versionCode outside the supported range: $code"
    }
    return [int]$code
}
