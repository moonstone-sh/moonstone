"""One public-command fixture for native Windows, macOS and Linux.

Never invokes an installed moon or writes Moonstone's store/lock/environment.
The C probe is a fake runtime: it tests process/environment plumbing, not Lua.
"""
import json
import os
from pathlib import Path
import subprocess
import shutil
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[2]
WINDOWS = os.name == 'nt'
MOON = Path(os.environ.get('MOON_BIN', REPO / 'zig-out/bin' / ('moon.exe' if WINDOWS else 'moon'))).resolve()


def main():
    with tempfile.TemporaryDirectory(prefix='moon lifecycle ü ') as tmp:
        work = Path(tmp)
        env = dict(os.environ, MOONSTONE_HOME=str(work / 'home'), MOONSTONE_NO_PROGRESS='1')
        def moon(*args, cwd=work, failure=False):
            result = subprocess.run([str(MOON), *args], cwd=cwd, env=env, capture_output=True)
            if (result.returncode != 0) != failure:
                trace = subprocess.run([str(MOON), *args], cwd=cwd, env=dict(env, MOONSTONE_TRACE_ERRORS='1'), capture_output=True)
                raise AssertionError((args, result.returncode, result.stdout, result.stderr, trace.stderr.decode('utf-8', errors='replace')))
            assert b'\x1b[' not in result.stdout + result.stderr, (args, result.stdout, result.stderr)
            return result.stdout.decode('utf-8')
        source = work / 'runtime.c'
        source.write_text('#include <stdio.h>\nint main(void) { puts("fixture runtime"); return 0; }\n')
        binary = work / ('lua.exe' if WINDOWS else 'lua')
        subprocess.run(['zig', 'cc', str(source), '-o', str(binary)], check=True)
        archive = work / 'runtime.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(binary, arcname='bin/' + binary.name)
        registry = work / 'registry'
        moon('registry', 'init', '--file', str(registry), '--name', 'native-fixture')
        descriptor = work / 'package.toml'
        descriptor.write_text('''[package]
name = "moonstone/lua"
version = "5.4.123"
kind = "runtime"
[[artifacts]]
id = "any"
kind = "runtime"
target = "any"
lua_abi = "5.4"
format = "tar.gz"
url = "placeholder.tar.gz"
hash = "b3:placeholder"
[artifacts.materialize]
type = "archive"
[[artifacts.provides]]
kind = "runtime"
name = "lua"
version = "5.4.123"
lua_abi = "5.4"
[[artifacts.provides]]
kind = "bin"
name = "lua"
path = "bin/''' + binary.name + '"\n')
        moon('registry', '--file', str(registry), 'publish', '--descriptor', str(descriptor), '--artifact', str(archive))
        rows = [json.loads(line) for line in moon('add', '--global', 'lua@5.4.123', '--registry', registry.as_uri(), '--json').splitlines()]
        assert rows[-1]['terminator'] and rows[-1]['kind'] == 'RESULT'
        project = work / 'project ü'
        moon('init', str(project), '--name', 'native-lifecycle', '--interpreter', 'lua@5.4.123', '--no-sync', '--no-git')
        moon('registry', 'add', '--name', 'fixture', '--url', registry.as_uri(), cwd=project)
        moon('registry', 'fixture:', 'doctor', cwd=project)
        moon('registry', 'fixture:', 'sync', cwd=project)
        moon('registry', 'fixture:', 'fetch', '--descriptor', 'moonstone/lua@5.4.123', '--output', str(work / 'fetched.toml'), cwd=project)
        assert (work / 'fetched.toml').exists()
        # Real copy-only source materialization, unlike the prebuilt runtime.
        # Publication must close hashing handles before renaming its output.
        module = work / 'portable.lua'
        module.write_text('return { portable = true }\n')
        source_archive = work / 'source.tar.gz'
        with tarfile.open(source_archive, 'w:gz') as tar:
            tar.add(module, arcname='src/portable.lua')
        source_descriptor = work / 'source-package.toml'
        source_descriptor.write_text('[package]\nname = "fixture/portable"\nversion = "1.0.0"\nkind = "lib"\n[[artifacts]]\nid = "source"\nkind = "source"\ntarget = "source"\nlua_abi = "5.4"\nformat = "tar.gz"\nurl = "placeholder.tar.gz"\nhash = "b3:placeholder"\n[artifacts.materialize]\ntype = "command"\ncommand = "true"\n[artifacts.materialize.collect]\nlua_modules = [{ name = "portable.lua", path = "src/portable.lua" }]\n')
        moon('registry', '--file', str(registry), 'publish', '--descriptor', str(source_descriptor), '--artifact', str(source_archive))
        moon('registry', 'fixture:', 'sync', cwd=project)
        moon('add', 'fixture/portable', '--no-sync', cwd=project)
        moon('set', 'lua@5.4.123', '--no-sync', cwd=project)
        moon('sync', '--offline', cwd=project)
        assert 'fixture runtime' in moon('exec', '--', 'lua', cwd=project)
        assert (project / '.moonstone/env/share/lua/5.4/portable.lua').read_text() == module.read_text()
        setup = [json.loads(line) for line in moon('setup', '--force', '--json', cwd=project).splitlines()][-1]
        shim = Path(setup['data']['shim_dir']) / ('lua.cmd' if WINDOWS else 'lua')
        argv = [env.get('COMSPEC', 'cmd.exe'), '/d', '/v:off', '/c', str(shim)] if WINDOWS else [str(shim)]
        probe = subprocess.run(argv, cwd=project, env=env, capture_output=True, check=True)
        assert b'fixture runtime' in probe.stdout, probe.stdout
        projected = json.loads(moon('env', '--json', cwd=project))
        assert str(project) in projected['path'], projected
        moon('init', 'child', '--name', 'native-child', '--interpreter', 'lua@5.4.123', '--no-sync', '--no-git', cwd=project)
        moon('orbit', 'add', '--name', 'child', '--path', 'child', cwd=project)
        rows = [json.loads(line) for line in moon('sync', '--all', '--offline', '--json', cwd=project).splitlines()]
        assert sum(row['terminator'] for row in rows) == 1
        assert rows[-1]['value'] == 'workspace.complete'
        assert 'fixture runtime' in moon('--orbit', 'child', 'exec', '--', 'lua', cwd=project)
        moon('-C', str(project / 'child'), 'link')
        moon('add', 'link:native-child', '--no-sync', cwd=project)
        moon('remove', 'native-child', '--no-sync', cwd=project)
        moon('store', 'list', '--links', '--json')
        moon('remove', '--global', 'link:native-child', cwd=project)
        assert (project / 'child' / 'moonstone.toml').exists()
        moon('remove', '--global', 'lua@5.4.123', cwd=project, failure=True)
        moon('store', 'list', '--query', 'lua', '--json')
        moon('store', 'prune', '--compact', '--dry-run')
        moon('interpreter', 'list', failure=True)
        moon('store', 'query', 'lua', failure=True)
        moon('registry', 'fixture:', 'remove', 'moonstone/lua@5.4.123', cwd=project)
        moon('registry', 'remove', 'fixture', cwd=project)
        shutil.rmtree(project)
        moon('remove', '--global', 'lua@5.4.123')
        moon('store', 'prune', '--compact')
        print('Native public-command lifecycle passed')


if __name__ == '__main__':
    main()
