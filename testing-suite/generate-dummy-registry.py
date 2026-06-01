import os
import tarfile
import io

try:
    import blake3

    def b3(data):
        return blake3.blake3(data).hexdigest()
except ImportError:

    def b3(data):
        return "dummy"


def create_lua_artifact(name, version, abi):
    os.makedirs("fixtures/sandbox/registry/blobs/b3", exist_ok=True)
    tar_stream = io.BytesIO()
    with tarfile.open(fileobj=tar_stream, mode="w:gz") as tar:
        d = f"#!/bin/sh\necho '{name} {version} dummy'\nexit 0\n".encode()
        info = tarfile.TarInfo(name="bin/lua")
        info.size = len(d)
        info.mode = 0o755
        tar.addfile(info, io.BytesIO(d))

    tar_data = tar_stream.getvalue()
    h = b3(tar_data)
    shard_dir = f"fixtures/sandbox/registry/blobs/b3/{h[:2]}/{h[2:4]}"
    os.makedirs(shard_dir, exist_ok=True)
    with open(f"{shard_dir}/{h}.tar.gz", "wb") as f:
        f.write(tar_data)

    desc_dir = f"fixtures/sandbox/registry/packages/{name}/{version}"
    os.makedirs(desc_dir, exist_ok=True)
    with open(f"{desc_dir}/package.toml", "w") as f:
        f.write(f'''[package]
name = "{name}"
version = "{version}"
kind = "runtime"

[compat]
runtimes = ["{name}@{version}"]

[[artifact]]
target = "native"
lua_abi = "{abi}"
runtime = "{name}@{version}"
runtime_artifact_hash = "b3:{h}"
url = "../../../blobs/b3/{h[:2]}/{h[2:4]}/{h}.tar.gz"
hash = "b3:{h}"
format = "tar.gz"
[artifact.provides]
runtime = [{{ name = "{name}", version = "{version}", abi = "{abi}" }}]
bin = [{{ name = "{name}", path = "bin/lua" }}]
''')
    return {
        "name": name,
        "version": version,
        "kind": "runtime",
        "descriptor": f"packages/{name}/{version}/package.toml",
        "descriptor_hash": "b3:0000",
        "targets": ["native"],
        "runtimes": [f"{name}@{version}"],
    }


packages = []
packages.append(create_lua_artifact("lua", "5.4.7", "lua-5.4"))
packages.append(create_lua_artifact("lua", "5.1.5", "lua-5.1"))
packages.append(create_lua_artifact("luajit", "2.1.0-beta3", "lua-5.1"))

# Create index
import json

index_content = b""
for p in packages:
    # Manual toml-ish index entry
    index_content += f'''[[package]]
name = "{p["name"]}"
version = "{p["version"]}"
kind = "{p["kind"]}"
descriptor = "{p["descriptor"]}"
descriptor_hash = "{p["descriptor_hash"]}"
targets = {json.dumps(p["targets"])}
runtimes = {json.dumps(p["runtimes"])}

'''.encode()

index_hash = b3(index_content)

registry_toml = f"""[registry]
id = "synthetic"
name = "Synthetic"
protocol = "moonstone.registry.v0"
revision = 1
generated_at = "2026-05-19T00:00:00Z"
min_client = "0.1.0"

[index]
format = "toml"
url = "index.toml"
hash = "b3:{index_hash}"
bytes = {len(index_content)}

[blobs]
algorithm = "blake3"
layout = "shard"

[capabilities]
runtimes = true
artifacts = true
source_packages = true
rocks_bridge = false
private = false
"""

os.makedirs("fixtures/sandbox/registry", exist_ok=True)
with open("fixtures/sandbox/registry/registry.toml", "w") as f:
    f.write(registry_toml)
with open("fixtures/sandbox/registry/index.toml", "wb") as f:
    f.write(index_content)

print(f"Registry with multiple runtimes generated.")
