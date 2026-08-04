$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$moon = Join-Path $repo 'zig-out/bin/moon.exe'
$work = Join-Path $env:RUNNER_TEMP 'moonstone-windows-core'
$project = Join-Path $work 'project'

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $project, (Join-Path $project '.moonstone/env/bin') | Out-Null

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

& $moon -C $project run check
if ($LASTEXITCODE -ne 0) { throw 'cmd-hosted opaque script failed' }

& $moon -C $project exec cmd /d /s /c 'exit /b 0'
if ($LASTEXITCODE -ne 0) { throw 'projected exec failed' }

Write-Output 'PASS: Moonstone Windows core CLI and process smoke test'
