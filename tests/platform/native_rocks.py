"""Build and load real LuaRocks C modules on the native Windows runtime."""
import os
from pathlib import Path
import subprocess
import tempfile
import shutil
import time
from contextlib import contextmanager

repo = Path(__file__).resolve().parents[2]
moon = repo/'zig-out/bin'/('moon.exe' if os.name == 'nt' else 'moon')
@contextmanager
def workspace():
    directory = tempfile.mkdtemp(prefix='moon native rocks ')
    try:
        yield directory
    finally:
        # Native DLL scans can briefly retain a file after the child exits.
        # Also use extended paths when removing deep CAS payloads on Windows.
        target = ('\\\\?\\' + directory) if os.name == 'nt' else directory
        for attempt in range(10):
            try:
                shutil.rmtree(target)
                break
            except OSError:
                if attempt == 9:
                    raise
                time.sleep(0.5)

with workspace() as directory:
    root = Path(directory)
    env = dict(os.environ, MOONSTONE_HOME=str(root/'home'))
    def run(*args):
        result = subprocess.run([str(moon), '-C', str(root), *args], env=env, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=600)
        assert result.returncode == 0, (args,result.stdout,result.stderr)
    run('init',str(root),'--name','native-rocks','--interpreter','lua@5.4','--no-git','--no-sync')
    run('add','rocks:lpeg@1.1.0-2','rocks:luafilesystem@1.9.0-1')
    extension = '.dll' if os.name == 'nt' else '.so'
    for module in ('lpeg','lfs'):
        assert (root/('.moonstone/env/lib/lua/5.4/'+module+extension)).is_file(), module
    run('exec','--','lua','-e','local p=require("lpeg");assert(p.match(p.P("love"),"love")==5);assert(require("lfs").attributes("moonstone.toml").mode=="file")')
print('PASS: native LPeg and LuaFileSystem are built, projected, and loadable')
