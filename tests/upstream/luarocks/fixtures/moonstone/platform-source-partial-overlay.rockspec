rockspec_format = "3.1"
package = "platform_source_partial_overlay"
version = "1.0-1"

source = {
   url = "https://example.invalid/platform-source-1.0.tar.gz",
   platforms = {
      unix = {
         dir = "platform-source-1.0-unix",
      },
   },
}

build = {
   type = "builtin",
}
