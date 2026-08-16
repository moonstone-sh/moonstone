rockspec_format = "3.1"
package = "test_custom_backend_fields"
version = "1.0-1"

source = {
   url = "https://example.invalid/test-custom-1.0.tar.gz",
}

build = {
   type = "builtin",
}

test = {
   type = "custom",
   command = "test-tool --all",
   variables = {
      MODE = "ci",
   },
}
