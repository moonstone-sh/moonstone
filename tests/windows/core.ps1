$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$moon = Join-Path $repo 'zig-out/bin/moon.exe'
$work = Join-Path $env:RUNNER_TEMP 'moonstone-windows-core'
$project = Join-Path $work 'project'
$nativeRegistry = Join-Path $work 'native-registry'
$nativePayload = Join-Path $work 'native-payload'
$nativeSources = Join-Path $work 'native-sources'
$nativePackage = 'native-loader-probe'
$nativeVersion = '0.1.0'

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

# Exercise the actual Windows dynamic-loader boundary. Moonstone must project
# native library provisions into .moonstone/env/lib/native and prepend that
# directory to PATH before the child process starts.
Copy-Item -Recurse -Force (Join-Path $repo 'fixtures/sandbox/registry') $nativeRegistry
Remove-Item -Force (Join-Path $nativeRegistry 'index.sqlite.zst') -ErrorAction SilentlyContinue
$registryMetadataPath = Join-Path $nativeRegistry 'registry.toml'
$registryMetadata = Get-Content -Raw $registryMetadataPath
$registryMetadata = [regex]::Replace($registryMetadata, '(?ms)^\[index\.compact\]\R.*?(?=^\[|\z)', '')
Set-Content -NoNewline -Encoding utf8 $registryMetadataPath $registryMetadata

New-Item -ItemType Directory -Force (Join-Path $nativePayload 'bin'), (Join-Path $nativePayload 'lib'), $nativeSources | Out-Null
$nativeLibrarySource = Join-Path $nativeSources 'native_probe.c'
$nativeProgramSource = Join-Path $nativeSources 'main.c'
$nativeLibrary = Join-Path $nativePayload 'lib/nativeprobe.dll'
$nativeProgram = Join-Path $nativePayload "bin/$nativePackage.exe"

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

$nativeArchive = Join-Path $work "$nativePackage.tar.gz"
& tar.exe -czf $nativeArchive -C $nativePayload bin lib
if ($LASTEXITCODE -ne 0) { throw 'failed to archive native loader package' }

$hashHelper = Join-Path $repo 'tests/helpers/blake3_file.zig'
$nativeHash = (& zig run $hashHelper -- $nativeArchive).Trim()
if ($LASTEXITCODE -ne 0 -or $nativeHash -notmatch '^[0-9a-f]{64}$') { throw 'failed to hash native loader archive' }
$nativeBytes = (Get-Item $nativeArchive).Length
$nativeShard = Join-Path $nativeRegistry ("blobs/b3/{0}/{1}" -f $nativeHash.Substring(0, 2), $nativeHash.Substring(2, 2))
New-Item -ItemType Directory -Force $nativeShard, (Join-Path $nativeRegistry "packages/$nativePackage/$nativeVersion") | Out-Null
Copy-Item -Force $nativeArchive (Join-Path $nativeShard "$nativeHash.tar.gz")

$descriptorPath = Join-Path $nativeRegistry "packages/$nativePackage/$nativeVersion/package.toml"
@"
[package]
name = "$nativePackage"
version = "$nativeVersion"
kind = "bin"
description = "Native loader projection probe"

[[artifacts]]
id = "native-loader-host"
kind = "bin"
target = "any"
lua_api = "5.4"
lua_abi = "lua-5.4"
runtime = "lua@5.4.7"
format = "tar.gz"
url = "blobs/b3/$($nativeHash.Substring(0, 2))/$($nativeHash.Substring(2, 2))/$nativeHash.tar.gz"
hash = "b3:$nativeHash"
recipe_hash = "b3:0000000000000000000000000000000000000000000000000000000000000000"
bytes = $nativeBytes

[artifacts.materialize]
type = "archive"
strip_components = 0

[[artifacts.provides]]
kind = "bin"
name = "$nativePackage"
path = "bin/$nativePackage.exe"

[[artifacts.provides]]
kind = "lib"
name = "native-probe"
path = "lib/nativeprobe.dll"
linkage = "shared"
"@ | Set-Content -NoNewline -Encoding utf8 $descriptorPath

$descriptorHash = (& zig run $hashHelper -- $descriptorPath).Trim()
if ($LASTEXITCODE -ne 0 -or $descriptorHash -notmatch '^[0-9a-f]{64}$') { throw 'failed to hash native loader descriptor' }
$indexPath = Join-Path $nativeRegistry 'index.toml'
@"

[[package]]
name = "$nativePackage"
version = "$nativeVersion"
kind = "bin"
descriptor = "packages/$nativePackage/$nativeVersion/package.toml"
descriptor_hash = "b3:$descriptorHash"
targets = ["any"]
runtimes = ["lua@5.4.7"]
"@ | Add-Content -Encoding utf8 $indexPath

$indexHash = (& zig run $hashHelper -- $indexPath).Trim()
if ($LASTEXITCODE -ne 0 -or $indexHash -notmatch '^[0-9a-f]{64}$') { throw 'failed to hash native registry index' }
$indexBytes = (Get-Item $indexPath).Length
$registryMetadata = Get-Content -Raw $registryMetadataPath
$registryMetadata = $registryMetadata -replace '(?m)^hash = "b3:[^"]+"$', ('hash = "b3:' + $indexHash + '"')
$registryMetadata = $registryMetadata -replace '(?m)^bytes = \d+$', ('bytes = ' + $indexBytes)
Set-Content -NoNewline -Encoding utf8 $registryMetadataPath $registryMetadata

& $moon -C $project registry add native-loader $nativeRegistry --default
if ($LASTEXITCODE -ne 0) { throw 'failed to register native loader probe registry' }
& $moon -C $project add "native-loader:$nativePackage"
if ($LASTEXITCODE -ne 0) { throw 'failed to materialize native loader probe' }

$projectedLibrary = Join-Path $project '.moonstone/env/lib/native/nativeprobe.dll'
if (-not (Test-Path $projectedLibrary)) { throw 'native DLL was not projected into the project environment' }
$nativeEnvironment = & $moon -C $project env --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $nativeEnvironment.native_lib_path -notmatch 'lib[\\/]native') { throw 'native library environment path was not exposed' }
$nativeOutput = & $moon -C $project exec $nativePackage
if ($LASTEXITCODE -ne 0 -or $nativeOutput -notmatch 'native loader projected') { throw 'native DLL was not visible through Moonstone PATH projection' }

Write-Output 'PASS: Moonstone Windows core CLI, projection, launcher, and native DLL loader smoke test'
} finally {
    Stop-Transcript | Out-Null
}
