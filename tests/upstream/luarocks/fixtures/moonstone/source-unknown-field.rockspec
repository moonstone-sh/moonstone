rockspec_format = "3.1"
package = "source_unknown_field"
version = "1.0-1"

source = {
   url = "https://example.invalid/source-unknown-field.tar.gz",
   checksum = "not-a-rockspec-source-field",
}

build = {
   type = "builtin",
}
