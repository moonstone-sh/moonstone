rockspec_format = "3.1"
package = "hooks_unknown_field"
version = "1.0-1"

source = {
   url = "https://example.invalid/hooks-unknown-field.tar.gz",
}

build = {
   type = "builtin",
}

hooks = {
   post_remove = "echo removed",
}
