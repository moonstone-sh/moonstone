$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$moon = Join-Path $repo 'zig-out/bin/moon.exe'
$work = Join-Path $env:RUNNER_TEMP 'moonstone-windows-core'
$project = Join-Path $work 'project'
$bootstrapProject = Join-Path $work 'bootstrap-project'
$windowsProfile = Join-Path $work 'windows-profile'
$windowsAppData = Join-Path $windowsProfile 'AppData/Roaming'
$windowsLocalAppData = Join-Path $windowsProfile 'AppData/Local'
$nativeSources = Join-Path $work 'native-sources'
$runtimeSources = Join-Path $work 'runtime-sources'
$runtimeHash = 'b3:1111111111111111111111111111111111111111111111111111111111111111'
$nativePackage = 'native-loader-probe'
$nativeLibraryDirectory = Join-Path $project '.moonstone/env/lib/native'
$nativeProgram = Join-Path $project ".moonstone/env/bin/$nativePackage.exe"

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $project | Out-Null
$transcript = Join-Path $work 'windows-core-transcript.txt'
Start-Transcript -Path $transcript -Force | Out-Null

try {

# Start from the environment a normal PowerShell user has: HOME and the
# Moonstone-specific overrides are absent, while Windows profile variables are
# available. This protects the default-path contract before the isolated core
# projection fixture below installs explicit test paths.
Remove-Item Env:HOME -ErrorAction SilentlyContinue
Remove-Item Env:MOONSTONE_HOME -ErrorAction SilentlyContinue
Remove-Item Env:MOONSTONE_DATA -ErrorAction SilentlyContinue
Remove-Item Env:MOONSTONE_CACHE -ErrorAction SilentlyContinue
Remove-Item Env:MOONSTONE_CONFIG -ErrorAction SilentlyContinue
Remove-Item Env:MOONSTONE_CONFIG_FILE -ErrorAction SilentlyContinue
$env:USERPROFILE = $windowsProfile
$env:APPDATA = $windowsAppData
$env:LOCALAPPDATA = $windowsLocalAppData

# Git is optional: use an empty PATH to reproduce a fresh Windows installation
# without Git, while invoking moon through its absolute path.
$noGitPath = Join-Path $work 'no-git-path'
New-Item -ItemType Directory -Force $noGitPath | Out-Null
$originalPath = $env:PATH
try {
    $env:PATH = $noGitPath
    $bootstrapOutput = & $moon init $bootstrapProject --name windows-bootstrap --kind script --interpreter lua@5.4 --no-sync
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $bootstrapProject 'moonstone.toml'))) { throw 'moon init failed when Git was absent from PATH' }
    if (($bootstrapOutput -join "`n") -notmatch 'skipped Git initialization') { throw 'moon init did not report that optional Git initialization was skipped' }
} finally {
    $env:PATH = $originalPath
}

Push-Location $bootstrapProject
try {
    # Query remote metadata without requiring a published Windows runtime.
    # This exercises the default registry and cache paths in a normal Windows
    # environment; runtime installation belongs to the runtime release matrix.
    $availableInterpreters = & $moon interpreter list --available
    if ($LASTEXITCODE -ne 0 -or -not ($availableInterpreters -match 'moonstone/lua@')) { throw 'moon interpreter list --available failed in the normal Windows environment' }
} finally {
    Pop-Location
}

if (-not (Test-Path (Join-Path $windowsLocalAppData 'moonstone/data/index'))) { throw 'Moonstone did not create its data index below LOCALAPPDATA' }
if (-not (Test-Path (Join-Path $windowsLocalAppData 'moonstone/cache'))) { throw 'Moonstone did not create its cache below LOCALAPPDATA' }

$env:MOONSTONE_HOME = Join-Path $work 'moonstone-home'
$env:MOONSTONE_DATA = Join-Path $work 'moonstone-data'
$env:MOONSTONE_CACHE = Join-Path $work 'moonstone-cache'
$env:MOONSTONE_CONFIG = Join-Path $work 'moonstone-config'
$env:HOME = Join-Path $work 'home'

# Stage a valid, Windows-targeted runtime directly in the local immutable store.
# `moon index rebuild` makes sync exercise the same runtime projection path as a
# registry/store hit without relying on public-network availability. The PE
# launcher loads its adjacent DLL, proving that a no-symlink fallback copies
# both the .exe and its co-located runtime dependency.
$runtimeStore = Join-Path $env:MOONSTONE_DATA 'store/v0/b3/11/11/111111111111111111111111111111111111111111111111111111111111-lua-5.4.9'
$runtimeBin = Join-Path $runtimeStore 'files/bin'
New-Item -ItemType Directory -Force $runtimeBin, $runtimeSources | Out-Null
$runtimeDllSource = Join-Path $runtimeSources 'runtime_sibling.c'
$runtimeExeSource = Join-Path $runtimeSources 'runtime_main.c'

@'
__declspec(dllexport) int runtime_sibling_value(void) { return 7; }
'@ | Set-Content -NoNewline -Encoding utf8 $runtimeDllSource

@'
#include <windows.h>
#include <stdio.h>
typedef int (__cdecl *runtime_sibling_value_fn)(void);
int main(void) {
    HMODULE library = LoadLibraryA("runtime-sibling.dll");
    if (library == NULL) return 10;
    runtime_sibling_value_fn value = (runtime_sibling_value_fn)GetProcAddress(library, "runtime_sibling_value");
    if (value == NULL || value() != 7) return 11;
    puts("runtime sibling loaded");
    FreeLibrary(library);
    return 0;
}
'@ | Set-Content -NoNewline -Encoding utf8 $runtimeExeSource

& zig cc -shared $runtimeDllSource -o (Join-Path $runtimeBin 'runtime-sibling.dll')
if ($LASTEXITCODE -ne 0) { throw 'failed to compile runtime sibling DLL' }
& zig cc $runtimeExeSource -o (Join-Path $runtimeBin 'lua.exe')
if ($LASTEXITCODE -ne 0) { throw 'failed to compile Windows runtime launcher' }

@"
[artifact]
name = "moonstone/lua"
version = "5.4.9"
kind = "runtime"
source_hash = ""
recipe_hash = ""
artifact_hash = "$runtimeHash"
target = "x86_64-windows-gnu"

[origin]
resolver = "moonstone"
source = ""

[compat]
runtime_version = "lua@5.4.9"
lua_abi = "lua54"
interpreter_artifact_hash = ""

[provides]
runtime = [{ name = "lua", version = "5.4.9", abi = "lua54" }]
bin = [{ name = "lua", path = "bin/lua.exe" }]
"@ | Set-Content -NoNewline (Join-Path $runtimeStore 'manifest.toml')

& $moon index rebuild
if ($LASTEXITCODE -ne 0) { throw 'failed to index staged Windows runtime' }

@'
manifest_version = 2

[package]
name = "windows-core"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4.9"
abi = "5.4"

[scripts]
check = "lua"
'@ | Set-Content -NoNewline (Join-Path $project 'moonstone.toml')

& $moon -C $project sync --offline
if ($LASTEXITCODE -ne 0) { throw 'moon sync failed to project the staged Windows Lua runtime' }
if (-not (Test-Path (Join-Path $project '.moonstone/env/bin/lua.exe'))) { throw 'Windows runtime projection did not retain lua.exe' }
& $moon -C $project run check
if ($LASTEXITCODE -ne 0) { throw 'projected Windows runtime could not load its sibling DLL' }

$runtimeProjection = Get-Item -Force (Join-Path $project '.moonstone/env/bin/lua.exe')
if (($runtimeProjection.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
    if (-not (Test-Path (Join-Path $project '.moonstone/env/bin/runtime-sibling.dll'))) {
        throw 'copy fallback for a non-symlink Windows runtime did not project the sibling DLL'
    }
}

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

@'
@echo off
exit /b 0
'@ | Set-Content -NoNewline (Join-Path $project '.moonstone/env/bin/live-tool-bat.bat')

& $moon -C $project exec live-tool-bat
if ($LASTEXITCODE -ne 0) { throw 'extensionless .bat launcher resolution failed' }

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
