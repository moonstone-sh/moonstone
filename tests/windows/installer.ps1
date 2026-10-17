<#
.SYNOPSIS
    Windows Installer and Self-Lifecycle Test Suite
.DESCRIPTION
    Exercises Moonstone self-install command generation, argument validation,
    and Windows installation contract in a native Windows environment.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$moon = Join-Path $repo 'zig-out/bin/moon.exe'
$work = Join-Path $env:RUNNER_TEMP 'moonstone-windows-installer'

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
$previousHome = $env:MOONSTONE_HOME
$env:MOONSTONE_HOME = Join-Path $work 'home'
$transcript = Join-Path $work 'windows-installer-transcript.txt'
Start-Transcript -Path $transcript -Force | Out-Null

try {
    Write-Host "━━━ 1. Testing moon self install command generation ━━━"
    $outLatest = & $moon self update
    if ($LASTEXITCODE -ne 0) { throw "moon self update exited with code $LASTEXITCODE" }
    Write-Host "Latest output: $outLatest"

    $outVersion = & $moon self install --version 0.4.3
    if ($LASTEXITCODE -ne 0) { throw "moon self install --version 0.4.3 exited with code $LASTEXITCODE" }
    Write-Host "Version output: $outVersion"

    Write-Host "`n━━━ 2. Testing argument validation and conflicts ━━━"
    $threwMissing = $false
    try {
        & $moon self install 2>$null
    } catch {
        $threwMissing = $true
    }
    if ($LASTEXITCODE -eq 0) {
        throw "Expected failure when running moon self install without --version"
    }

    $threwConflict = $false
    try {
        & $moon self update --version 0.4.3 2>$null
    } catch {
        $threwConflict = $true
    }
    if ($LASTEXITCODE -eq 0) {
        throw "Expected failure when passing --version to self update"
    }

    Write-Host "`n━━━ 3. Testing --json output mode ━━━"
    $jsonLatest = & $moon self update --json | ConvertFrom-Json
    # Self-install JSON is the canonical single RESULT envelope, not a
    # command-specific { status = ... } object. Keep this syntax compatible
    # with both PowerShell 5.1 and PowerShell 7.
    if ($LASTEXITCODE -ne 0 -or
        $jsonLatest.kind -ne 'RESULT' -or
        $jsonLatest.value -ne 'ok' -or
        $jsonLatest.terminator -ne $true) {
        throw "moon self update --json did not return the canonical RESULT envelope"
    }

    $jsonVersion = & $moon self install --version 0.4.3 --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or
        $jsonVersion.kind -ne 'RESULT' -or
        $jsonVersion.value -ne 'ok' -or
        $jsonVersion.terminator -ne $true) {
        throw "moon self install --version 0.4.3 --json did not return the canonical RESULT envelope"
    }

    Write-Host "`n━━━ 4. Testing deferred executable removal and data preservation ━━━"
    $store = Join-Path $env:MOONSTONE_HOME 'data/store/v0'
    $shims = Join-Path $env:MOONSTONE_HOME 'data/v0/shims'
    New-Item -ItemType Directory -Force $store, $shims | Out-Null
    $marker = Join-Path $store 'keep.txt'
    Set-Content -Path $marker -Value 'preserve'
    $copy = Join-Path $work 'moon-copy.exe'
    Copy-Item $moon $copy
    $preview = & $copy self uninstall --dry-run --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $preview.value -ne 'planned' -or !(Test-Path $copy)) {
        throw 'Uninstall preview changed the executable or failed'
    }
    $result = & $copy self uninstall --yes --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.value -ne 'scheduled') { throw 'Uninstall helper was not scheduled' }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Test-Path $copy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ((Test-Path $copy) -or !(Test-Path $marker) -or (Test-Path $shims)) {
        throw 'Executable/shim removal or default data preservation failed'
    }
    $unrelated = Join-Path $env:MOONSTONE_HOME 'unrelated.txt'
    Set-Content -Path $unrelated -Value 'keep'
    Copy-Item $moon $copy
    $result = & $copy self uninstall --yes --purge-data --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Explicit managed-data purge failed' }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Test-Path $copy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ((Test-Path $copy) -or (Test-Path $marker) -or !(Test-Path $unrelated)) {
        throw 'Explicit purge removed unrelated data or left managed data behind'
    }

    Write-Host "`nPASS: Moonstone Windows self install and installer contract tests succeeded." -ForegroundColor Green
} finally {
    $env:MOONSTONE_HOME = $previousHome
    Stop-Transcript | Out-Null
}
