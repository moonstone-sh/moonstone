"""Argument boundaries through the public moon run command on each native host."""
import json
import os
from pathlib import Path
import sys


def verify(moon, project):
    probe = project / 'argument probe.py'
    probe.write_text('import json, sys\nprint(json.dumps(sys.argv[1:], ensure_ascii=True))\nsys.exit(17 if sys.argv[1:]==["fail"] else 0)\n')
    python = Path(sys.executable).as_posix()
    direct = f'"{python}" "{probe.name}" "preset value" ""'
    plain = f'"{python}" "{probe.name}"'
    shell = (f'"{python}" "{probe.name}" %*' if os.name == 'nt'
             else f'"{python}" "{probe.name}" "$@"')
    with (project / 'moonstone.toml').open('a', encoding='utf-8') as manifest:
        manifest.write('\n[scripts]\nforward = ' + json.dumps(direct) + '\n')
        manifest.write('fail = ' + json.dumps(plain) + '\n')
        manifest.write('legacy = ' + json.dumps(plain + ' "$@"') + '\n')
        manifest.write('shell = { shell = ' + json.dumps(shell) + ' }\n')
        manifest.write('expression = "echo hello && echo bye"\n')
    values = ['', 'two words', 'a&b', 'x|y', '%PATH%', '$HOME', 'a!b', 'a^b', 'quote"inside', 'end\\', 'café λ']
    output = moon('run', 'forward', '--', *values, cwd=project)
    assert json.loads(next(line for line in output.splitlines() if line.startswith('['))) == ['preset value', '', *values], output
    shell_values = ['first', 'two words', '']
    output = moon('run', 'shell', '--', *shell_values, cwd=project)
    assert json.loads(next(line for line in output.splitlines() if line.startswith('['))) == shell_values, output
    moon('run', 'fail', '--', 'fail', cwd=project, failure=True, expected_exit=17)
    assert 'forward arguments automatically' in moon('run', 'legacy', cwd=project, failure=True)
    exported = json.loads(moon('manifest', 'script', 'get', 'shell', '--json', cwd=project))
    assert exported['script']['shell'] is True
    assert 'explicit' in moon('run', 'expression', cwd=project, failure=True).lower()
