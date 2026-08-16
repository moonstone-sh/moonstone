rockspec_format = "1.1"
package = "legacy_namespaced_dependency"
version = "1.0-1"

source = {
   url = "https://example.invalid/legacy-namespaced-dependency-1.0.tar.gz",
}

build = {}

dependencies = {
   "owner/package >= 1.0",
}
