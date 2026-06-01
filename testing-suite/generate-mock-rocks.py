import os
import tarfile
import io
import hashlib
import json
import http.server
import socketserver
import sys

# Simple script to generate a mock LuaRocks-like directory structure
# and serve it over HTTP.

def create_tarball(files, dest):
    with tarfile.open(dest, "w:gz") as tar:
        for name, content in files.items():
            data = content.encode("utf-8")
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            info.mode = 0o755 # Make everything executable in mock rocks for simplicity
            tar.addfile(info, io.BytesIO(data))

def generate_mock_rocks(base_dir, port, mode="ok"):
    os.makedirs(base_dir, exist_ok=True)
    
    # 1. Builtin C Module Rock
    c_source = """#include <lua.h>
#include <lauxlib.h>

static int l_hello(lua_State *L) {
    lua_pushstring(L, "hello from builtin c module");
    return 1;
}

int luaopen_builtin_cmodule(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, l_hello);
    lua_setfield(L, -2, "hello");
    return 1;
}
"""
    rockspec_c = """
package = "builtin-cmodule"
version = "0.1.0-1"
source = {
   url = "http://localhost:%d/builtin-cmodule-0.1.0.tar.gz"
}
build = {
   type = "builtin",
   modules = {
      ["builtin_cmodule"] = "test_c.c"
   }
}
dependencies = { "lua >= 5.1" }
""" % port
    create_tarball({"test_c.c": c_source}, os.path.join(base_dir, "builtin-cmodule-0.1.0.tar.gz"))
    with open(os.path.join(base_dir, "builtin-cmodule-0.1.0-1.rockspec"), "w") as f:
        f.write(rockspec_c)

    # 2. Fakebin Rock
    fakebin_lua = """#!/usr/bin/env lua
print("lua_args: " .. table.concat(arg, " "))
"""
    rockspec_bin = """
package = "fakebin"
version = "1.0-1"
source = {
   url = "http://localhost:%d/fakebin-1.0.tar.gz"
}
build = {
   type = "builtin",
   modules = {
      ["fake"] = "fake.lua"
   },
   install = {
      bin = { "fake.lua" }
   }
}
dependencies = { "lua >= 5.1" }
""" % port
    # Note: the zip layout for rocks is specific. 
    # Usually it's a flat list of files or a subdirectory.
    create_tarball({"fake.lua": fakebin_lua}, os.path.join(base_dir, "fakebin-1.0.tar.gz"))
    with open(os.path.join(base_dir, "fakebin-1.0-1.rockspec"), "w") as f:
        f.write(rockspec_bin)

    # 3. Transitive dependency rocks: parent -> child
    child_lua = """return { hello = "from child" }
"""
    rockspec_child = """
package = "child"
version = "1.0-1"
source = { url = "http://localhost:%d/child-1.0.tar.gz" }
build = { type = "builtin", modules = { child = "child.lua" } }
dependencies = { "lua >= 5.1" }
""" % port
    create_tarball({"child.lua": child_lua}, os.path.join(base_dir, "child-1.0.tar.gz"))
    with open(os.path.join(base_dir, "child-1.0-1.rockspec"), "w") as f:
        f.write(rockspec_child)

    parent_lua = """local child = require("child")
return { greet = function() return child.hello end }
"""
    rockspec_parent = """
package = "parent"
version = "1.0-1"
source = { url = "http://localhost:%d/parent-1.0.tar.gz" }
build = { type = "builtin", modules = { parent = "parent.lua" } }
dependencies = { "lua >= 5.1", "child >= 1.0" }
""" % port
    create_tarball({"parent.lua": parent_lua}, os.path.join(base_dir, "parent-1.0.tar.gz"))
    with open(os.path.join(base_dir, "parent-1.0-1.rockspec"), "w") as f:
        f.write(rockspec_parent)

    # 4. LuaRocks Manifest (simplified)
    manifest = {
        "repository": {
            "builtin-cmodule": {
                "0.1.0-1": [{"arch": "rockspec"}]
            },
            "fakebin": {
                "1.0-1": [{"arch": "rockspec"}]
            },
            "child": {
                "1.0-1": [{"arch": "rockspec"}]
            },
            "parent": {
                "1.0-1": [{"arch": "rockspec"}]
            }
        }
    }
    with open(os.path.join(base_dir, "manifest-5.4.json"), "w") as f:
        if mode == "invalid-json":
            f.write("{ invalid json")
        elif mode == "missing-repository":
            json.dump({}, f)
        else:
            json.dump(manifest, f)

class MockRocksHandler(http.server.SimpleHTTPRequestHandler):
    mode = "ok"

    def do_GET(self):
        if self.path.startswith("/manifest-") and self.mode == "manifest-500":
            body = b"mock manifest error"
            self.send_response(500)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/manifest-") and self.mode == "manifest-404":
            body = b"mock manifest not found"
            self.send_response(404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        return super().do_GET()

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: generate-mock-rocks.py <dir> <port> [--mode MODE]")
        sys.exit(1)
    
    base_dir = sys.argv[1]
    port = int(sys.argv[2])
    mode = "ok"
    if "--mode" in sys.argv:
        idx = sys.argv.index("--mode")
        if idx + 1 < len(sys.argv):
            mode = sys.argv[idx + 1]
    
    generate_mock_rocks(base_dir, port, mode)

    os.chdir(base_dir)
    Handler = MockRocksHandler
    Handler.mode = mode
    with socketserver.TCPServer(("", port), Handler) as httpd:
        print(f"Serving mock rocks at port {port} (mode={mode})")
        httpd.serve_forever()
