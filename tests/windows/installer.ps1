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
$transcript = Join-Path $work 'windows-installer-transcript.txt'
Start-Transcript -Path $transcript -Force | Out-Null

try {
    Write-Host "━━━ 1. Testing moon self install command generation ━━━"
    $outLatest = & $moon self install --latest
    if ($LASTEXITCODE -ne 0) { throw "moon self install --latest exited with code $LASTEXITCODE" }
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
        throw "Expected failure when running moon self install without version or --latest"
    }

    $threwConflict = $false
    try {
        & $moon self install --latest --version 0.4.3 2>$null
    } catch {
        $threwConflict = $true
    }
    if ($LASTEXITCODE -eq 0) {
        throw "Expected failure when passing both --latest and --version"
    }

    Write-Host "`n━━━ 3. Testing --json output mode ━━━"
    $jsonLatest = & $moon self install --latest --json | ConvertFrom-Json
    # Self-install JSON is the canonical single RESULT envelope, not a
    # command-specific { status = ... } object. Keep this syntax compatible
    # with both PowerShell 5.1 and PowerShell 7.
    if ($LASTEXITCODE -ne 0 -or
        $jsonLatest.kind -ne 'RESULT' -or
        $jsonLatest.value -ne 'ok' -or
        $jsonLatest.terminator -ne $true) {
        throw "moon self install --latest --json did not return the canonical RESULT envelope"
    }

    $jsonVersion = & $moon self install --version 0.4.3 --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or
        $jsonVersion.kind -ne 'RESULT' -or
        $jsonVersion.value -ne 'ok' -or
        $jsonVersion.terminator -ne $true) {
        throw "moon self install --version 0.4.3 --json did not return the canonical RESULT envelope"
    }

    Write-Host "`nPASS: Moonstone Windows self install and installer contract tests succeeded." -ForegroundColor Green
} finally {
    Stop-Transcript | Out-Null
}
