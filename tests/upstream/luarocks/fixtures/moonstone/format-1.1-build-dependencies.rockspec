rockspec_format = "1.1"
package = "format_1_1_build_dependencies"
version = "1.0-1"

source = {
   url = "https://example.invalid/format-1.1-build-dependencies.tar.gz",
}

build = {
   type = "builtin",
}

build_dependencies = {
   "luacheck >= 1",
}
