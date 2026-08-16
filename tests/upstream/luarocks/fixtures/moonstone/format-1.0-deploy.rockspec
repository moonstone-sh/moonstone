rockspec_format = "1.0"
package = "format_1_0_deploy"
version = "1.0-1"

source = {
   url = "https://example.invalid/format-1.0-deploy.tar.gz",
}

build = {
   type = "builtin",
}

deploy = {
   wrap_bin_scripts = false,
}
