rockspec_format = "3.1"
package = "platform_specific_precedence"
version = "1.0-1"

source = {
   url = "https://example.invalid/platform-precedence-1.0.tar.gz",
   platforms = {
      unix = {
         url = "https://example.invalid/platform-precedence-unix.tar.gz",
      },
      macosx = {
         url = "https://example.invalid/platform-precedence-macosx.tar.gz",
      },
   },
}

dependencies = {
   "base-dependency",
   platforms = {
      unix = { "unix-dependency" },
      macosx = { "macosx-dependency" },
   },
}

build = {
   type = "builtin",
   modules = {
      ["platform.base"] = "base.lua",
   },
   platforms = {
      unix = {
         modules = {
            ["platform.unix"] = "unix.lua",
         },
      },
      macosx = {
         modules = {
            ["platform.macosx"] = "macosx.lua",
         },
      },
   },
}
