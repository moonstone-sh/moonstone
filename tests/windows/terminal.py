"""Native ConPTY regression: ASCII progress, resize and keyboard cancellation."""
import ctypes as c
from ctypes import wintypes as w
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

k = c.WinDLL('kernel32', use_last_error=True)
class Coord(c.Structure):
    _fields_ = [('x', c.c_short), ('y', c.c_short)]
class Startup(c.Structure):
    _fields_ = [('cb', w.DWORD), ('reserved', w.LPWSTR), ('desktop', w.LPWSTR), ('title', w.LPWSTR),
                ('x', w.DWORD), ('y', w.DWORD), ('width', w.DWORD), ('height', w.DWORD),
                ('chars_x', w.DWORD), ('chars_y', w.DWORD), ('fill', w.DWORD), ('flags', w.DWORD),
                ('show', w.WORD), ('reserved_size', w.WORD), ('reserved_bytes', c.c_void_p),
                ('stdin', w.HANDLE), ('stdout', w.HANDLE), ('stderr', w.HANDLE)]
class StartupEx(c.Structure):
    _fields_ = [('startup', Startup), ('attributes', c.c_void_p)]
class Process(c.Structure):
    _fields_ = [('process', w.HANDLE), ('thread', w.HANDLE), ('pid', w.DWORD), ('tid', w.DWORD)]
k.CreatePipe.argtypes = [c.POINTER(w.HANDLE), c.POINTER(w.HANDLE), c.c_void_p, w.DWORD]
k.CreatePseudoConsole.argtypes = [Coord, w.HANDLE, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE)]
k.CreatePseudoConsole.restype = c.c_long
k.ResizePseudoConsole.argtypes = [w.HANDLE, Coord]
k.ClosePseudoConsole.argtypes = [w.HANDLE]
k.InitializeProcThreadAttributeList.argtypes = [c.c_void_p, w.DWORD, w.DWORD, c.POINTER(c.c_size_t)]
k.UpdateProcThreadAttribute.argtypes = [c.c_void_p, w.DWORD, c.c_size_t, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p]
k.DeleteProcThreadAttributeList.argtypes = [c.c_void_p]
k.CreateProcessW.argtypes = [w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL, w.DWORD, c.c_void_p, w.LPCWSTR, c.POINTER(StartupEx), c.POINTER(Process)]
k.ReadFile.argtypes = [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p]
k.WriteFile.argtypes = k.ReadFile.argtypes
k.CloseHandle.argtypes = [w.HANDLE]
k.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
k.GetExitCodeProcess.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]
k.TerminateProcess.argtypes = [w.HANDLE, w.UINT]

def check(ok):
    if not ok: raise c.WinError(c.get_last_error())

def main():
    entered, release = threading.Event(), threading.Event()
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            entered.set()
            release.wait(15)
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='moon-conpty-') as tmp:
        root = Path(tmp)
        (root / 'moonstone.toml').write_text(f'''[package]
name = "terminal-test"
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
        input_read, input_write, output_read, output_write, console = [w.HANDLE() for _ in range(5)]
        check(k.CreatePipe(c.byref(input_read), c.byref(input_write), None, 0))
        check(k.CreatePipe(c.byref(output_read), c.byref(output_write), None, 0))
        assert k.CreatePseudoConsole(Coord(80, 24), input_read, output_write, 0, c.byref(console)) == 0
        k.CloseHandle(input_read); k.CloseHandle(output_write)
        size = c.c_size_t()
        k.InitializeProcThreadAttributeList(None, 1, 0, c.byref(size))
        attributes = c.create_string_buffer(size.value)
        check(k.InitializeProcThreadAttributeList(attributes, 1, 0, c.byref(size)))
        check(k.UpdateProcThreadAttribute(attributes, 0, 0x20016, console, c.sizeof(w.HANDLE), None, None))
        startup = StartupEx(); startup.startup.cb = c.sizeof(startup); startup.attributes = c.addressof(attributes)
        process = Process()
        env = dict(os.environ, MOONSTONE_HOME=str(root / 'home'), MOONSTONE_PROGRESS_GLYPHS='ascii', MOONSTONE_HTTP_TIMEOUT_MS='120000')
        env.pop('MOONSTONE_NO_PROGRESS', None); env.pop('CI', None); env.pop('TERM', None)
        environment = c.create_unicode_buffer('\0'.join(f'{key}={value}' for key, value in sorted(env.items())) + '\0\0')
        moon = Path('zig-out/bin/moon.exe').resolve()
        command = c.create_unicode_buffer(subprocess.list2cmdline([str(moon), 'sync', '--progress', 'fancy']))
        transcript = bytearray()
        def drain():
            buf = c.create_string_buffer(4096); count = w.DWORD()
            while k.ReadFile(output_read, buf, len(buf), c.byref(count), None) and count.value:
                transcript.extend(buf.raw[:count.value])
        reader = threading.Thread(target=drain, daemon=True); reader.start()
        try:
            check(k.CreateProcessW(None, command, None, None, False, 0x80000 | 0x400, environment, str(root), c.byref(startup), c.byref(process)))
            k.CloseHandle(process.thread)
            assert entered.wait(10), 'No registry request reached the fixture'
            for width in (24, 120, 40):
                assert k.ResizePseudoConsole(console, Coord(width, 16)) == 0
                time.sleep(.15)
            count = w.DWORD()
            check(k.WriteFile(input_write, c.c_char_p(b'\x03'), 1, c.byref(count), None))
            assert k.WaitForSingleObject(process.process, 3000) == 0, 'Ctrl-C left the CLI running'
            code = w.DWORD(); check(k.GetExitCodeProcess(process.process, c.byref(code)))
            assert code.value == 130, code.value
        finally:
            if process.process:
                k.TerminateProcess(process.process, 1)
                k.CloseHandle(process.process)
            k.CloseHandle(input_write)
            k.ClosePseudoConsole(console)
            reader.join(5)
            k.CloseHandle(output_read)
            k.DeleteProcThreadAttributeList(attributes)
            release.set(); server.shutdown(); server.server_close()
        text = transcript.decode('utf-8', errors='replace')
        assert not any('\u2800' <= char <= '\u28ff' for char in text), text
        assert '\x1b[?25h' in text, 'Cursor was not restored after cancellation'
        assert not (root / 'moonstone.lock').exists()
        print('ConPTY ASCII, resize and cancellation passed')

if __name__ == '__main__': main()
