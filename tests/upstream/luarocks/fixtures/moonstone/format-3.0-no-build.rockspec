rockspec_format = "3.0"
package = "no_build"
version = "1.0-1"

source = {
   url = "https://example.invalid/no-build-1.0.tar.gz",
}

description = {
   summary = "A valid format-3.0 rockspec without a build table",
}

dependencies = {
   "lua >= 5.1",
}
