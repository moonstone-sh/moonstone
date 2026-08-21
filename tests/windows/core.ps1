$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$moon = Join-Path $repo 'zig-out/bin/moon.exe'
$work = Join-Path $env:RUNNER_TEMP 'moonstone-windows-core'
$project = Join-Path $work 'project'
$nativeSources = Join-Path $work 'native-sources'
$nativePackage = 'native-loader-probe'
$nativeLibraryDirectory = Join-Path $project '.moonstone/env/lib/native'
$nativeProgram = Join-Path $project ".moonstone/env/bin/$nativePackage.exe"

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $project, (Join-Path $project '.moonstone/env/bin') | Out-Null
$transcript = Join-Path $work 'windows-core-transcript.txt'
Start-Transcript -Path $transcript -Force | Out-Null

try {

$env:MOONSTONE_HOME = Join-Path $work 'moonstone-home'
$env:MOONSTONE_DATA = Join-Path $work 'moonstone-data'
$env:MOONSTONE_CACHE = Join-Path $work 'moonstone-cache'
$env:MOONSTONE_CONFIG = Join-Path $work 'moonstone-config'
$env:HOME = Join-Path $work 'home'

@'
manifest_version = 2

[package]
name = "windows-core"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[scripts]
check = "exit /b 0"
'@ | Set-Content -NoNewline (Join-Path $project 'moonstone.toml')

@'
[runtime]
name = "lua"
version = "5.4"
abi = "lua54"
'@ | Set-Content -NoNewline (Join-Path $project '.moonstone/env/env.toml')

$manifest = & $moon -C $project manifest export --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $manifest.manifest.project.name -ne 'windows-core') { throw 'manifest export through -C failed' }

$scripts = & $moon "--directory=$project" manifest script list --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $scripts.scripts[0].name -ne 'check') { throw 'script inspection through --directory failed' }

& $moon -C $project env --json | ConvertFrom-Json | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'environment projection failed' }

$environment = & $moon -C $project env --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $environment.lua_cpath -notmatch '\?\.dll') { throw 'Windows Lua C module projection did not use .dll paths' }

& $moon -C $project run check
if ($LASTEXITCODE -ne 0) { throw 'cmd-hosted opaque script failed' }

& $moon -C $project exec cmd /d /s /c 'exit /b 0'
if ($LASTEXITCODE -ne 0) { throw 'projected exec failed' }

$probeExe = Join-Path $project '.moonstone/env/bin/probe.exe'
Copy-Item -Force $env:ComSpec $probeExe
& $moon -C $project exec probe /d /s /c 'exit /b 0'
if ($LASTEXITCODE -ne 0) { throw 'extensionless .exe resolution failed' }

@'
@echo off
exit /b 0
'@ | Set-Content -NoNewline (Join-Path $project '.moonstone/env/bin/live-tool.cmd')

& $moon -C $project exec live-tool
if ($LASTEXITCODE -ne 0) { throw 'extensionless .cmd launcher resolution failed' }

# Exercise the actual Windows dynamic-loader boundary. The native package
# materialization contract is covered on Linux; this harness isolates the
# Windows-specific guarantee that moon exec prepends env/lib/native to PATH.
New-Item -ItemType Directory -Force $nativeLibraryDirectory, $nativeSources | Out-Null
$nativeLibrarySource = Join-Path $nativeSources 'native_probe.c'
$nativeProgramSource = Join-Path $nativeSources 'main.c'
$nativeLibrary = Join-Path $nativeLibraryDirectory 'nativeprobe.dll'

@'
__declspec(dllexport) const char *native_probe_message(void) {
    return "native loader projected";
}
'@ | Set-Content -NoNewline -Encoding utf8 $nativeLibrarySource

@'
#include <windows.h>
#include <stdio.h>

typedef const char *(__cdecl *native_probe_message_fn)(void);

int main(void) {
    HMODULE library = LoadLibraryA("nativeprobe.dll");
    if (library == NULL) {
        fprintf(stderr, "LoadLibraryA failed: %lu\n", GetLastError());
        return 1;
    }

    native_probe_message_fn message = (native_probe_message_fn)GetProcAddress(library, "native_probe_message");
    if (message == NULL) {
        fprintf(stderr, "GetProcAddress failed: %lu\n", GetLastError());
        FreeLibrary(library);
        return 1;
    }

    puts(message());
    FreeLibrary(library);
    return 0;
}
'@ | Set-Content -NoNewline -Encoding utf8 $nativeProgramSource

& zig cc -shared $nativeLibrarySource -o $nativeLibrary
if ($LASTEXITCODE -ne 0) { throw 'failed to compile native DLL probe' }
& zig cc $nativeProgramSource -o $nativeProgram
if ($LASTEXITCODE -ne 0) { throw 'failed to compile native loader executable' }

$nativeEnvironment = & $moon -C $project env --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $nativeEnvironment.native_lib_path -notmatch 'lib[\\/]native') { throw 'native library environment path was not exposed' }
$nativeOutput = & $moon -C $project exec $nativePackage
if ($LASTEXITCODE -ne 0 -or $nativeOutput -notmatch 'native loader projected') { throw 'native DLL was not visible through Moonstone PATH projection' }

Write-Output 'PASS: Moonstone Windows core CLI, projection, launcher, and native DLL loader smoke test'
} finally {
    Stop-Transcript | Out-Null
}
