#!/usr/bin/env python3
"""Exercise real signals against a registry which never finishes its response."""
import http.server
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import sys
import threading
import time

WINDOWS = os.name == 'nt'
MOON = Path(__file__).resolve().parents[2] / ('zig-out/bin/moon.exe' if WINDOWS else 'zig-out/bin/moon')


def check(mode, partial_body, sig, stage="metadata"):
    fixture = MOON.parents[2] / "fixtures/sandbox/registry"
    entered = threading.Event()
    release = threading.Event()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(fixture), **kwargs)

        def do_GET(self):
            if stage == 'build' or (stage == 'download' and not self.path.startswith('/blobs/')):
                return super().do_GET()
            if partial_body:
                self.send_response(200)
                self.send_header('Content-Length', '1000000')
                self.end_headers()
                self.wfile.write(b'[registry]\n')
                self.wfile.flush()
            entered.set()
            release.wait(15)

        def log_message(self, *_):
            pass

    with tempfile.TemporaryDirectory(prefix='moon-sync-cancel-') as root:
        root = Path(root)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (root / 'moonstone.toml').write_text(f'''[package]
name = "cancel-test"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[[registries]]
name = "stall"
resolver = "moonstone"
url = "http://127.0.0.1:{server.server_port}"
priority = 1

[dependencies.runtime]
"stall:missing" = "*"
''')
        env = dict(os.environ, MOONSTONE_HOME=str(root / 'home'), MOONSTONE_HTTP_TIMEOUT_MS='120000')
        marker = root / 'build-child'
        if stage == 'build':
            tools = root / 'tools'
            tools.mkdir()
            make = tools / 'make'
            make.write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then echo "GNU Make 4.3"; exit 0; fi\nsleep 60 &\necho $! > "$CANCEL_BUILD_MARKER"\nwait\n')
            make.chmod(0o755)
            env['PATH'] = str(tools) + os.pathsep + env['PATH']
            env['CANCEL_BUILD_MARKER'] = str(marker)
        if stage != 'metadata':
            manifest = root / 'moonstone.toml'
            manifest.write_text(manifest.read_text().replace('"stall:missing" = "*"', ''))
        env.pop('MOONSTONE_NO_PROGRESS', None)
        env.pop('CI', None)
        if mode == 'ci':
            env['CI'] = '1'
        args = [] if mode in ('default', 'ci') else (['--progress', mode] if mode in ('plain', 'fancy') else ['--' + mode])
        proc = subprocess.Popen([str(MOON), 'sync', *args], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=not WINDOWS,
                                creationflags=(subprocess.CREATE_NEW_PROCESS_GROUP if WINDOWS and sig == signal.CTRL_BREAK_EVENT else 0))
        try:
            if stage == 'build':
                for _ in range(1000):
                    if marker.exists():
                        entered.set()
                        break
                    if proc.poll() is not None:
                        break
                    time.sleep(.01)
            if not entered.wait(10):
                proc.kill()
                out, err = proc.communicate()
                raise AssertionError(f'never reached registry: {out!r} {err!r}')
            start = time.monotonic()
            if WINDOWS:
                import ctypes
                # This harness runs in its own console; never signal the CI host.
                group = proc.pid if sig == signal.CTRL_BREAK_EVENT else 0
                if not ctypes.windll.kernel32.GenerateConsoleCtrlEvent(sig, group):
                    raise ctypes.WinError()
            else:
                proc.send_signal(sig)  # Signal only moon; it must own cleanup.
            out, err = proc.communicate(timeout=3)
            elapsed = time.monotonic() - start
            assert proc.returncode == 130, (mode, proc.returncode, out, err)
            assert not (root / 'moonstone.lock').exists(), 'cancelled resolution published a lockfile'
            if stage == 'build':
                child_pid = int(marker.read_text())
                for _ in range(100):
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(.01)
                else:
                    raise AssertionError('build descendant survived cancellation')
            print(f'PASS {stage} {mode} {"body" if partial_body else "headers"} {getattr(sig, "name", str(sig))}: {elapsed:.3f}s')
        finally:
            if proc.poll() is None:
                if WINDOWS:
                    proc.kill()
                    proc.wait()
                elif marker.exists():
                    try:
                        child_group = os.getpgid(int(marker.read_text()))
                        if child_group != os.getpgrp():
                            os.killpg(child_group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if not WINDOWS:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            release.set()
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    if WINDOWS and '--private-console' not in sys.argv:
        # A separate console makes broadcast Ctrl-C safe for the runner shell.
        with tempfile.TemporaryFile(mode='w+b') as log:
            runner = subprocess.run([sys.executable, '-u', __file__, '--private-console', *sys.argv[1:]],
                                    creationflags=subprocess.CREATE_NEW_CONSOLE, stdout=log, stderr=log, timeout=120)
            log.seek(0)
            sys.stdout.buffer.write(log.read())
            sys.exit(runner.returncode)
    if WINDOWS:
        import ctypes
        callback_type = ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_uint)
        console_handler = callback_type(lambda event: 1 if event in (0, 1) else 0)
        if not ctypes.windll.kernel32.SetConsoleCtrlHandler(console_handler, True):
            raise ctypes.WinError()
    for mode in ('default', 'fancy', 'plain', 'quiet', 'json', 'ci'):
        for partial in (False, True):
            for sig in ((signal.CTRL_C_EVENT, signal.CTRL_BREAK_EVENT) if WINDOWS else (signal.SIGINT,)):
                check(mode, partial, sig)
    if not WINDOWS:
        check('fancy', False, signal.SIGTERM)

    if '--with-fixtures' in sys.argv and not WINDOWS:
        for mode in ('fancy', 'plain'):
            check(mode, False, signal.SIGINT, 'download')
            check(mode, True, signal.SIGINT, 'download')
            check(mode, False, signal.SIGINT, 'build')
