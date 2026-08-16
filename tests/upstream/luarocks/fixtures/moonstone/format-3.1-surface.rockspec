rockspec_format = "3.1"
package = "surface"
version = "1.2.3-1"

source = {
   url = "https://example.invalid/surface-1.2.3.tar.gz",
   md5 = "0123456789abcdef0123456789abcdef",
   file = "surface.tar.gz",
   dir = "surface-1.2.3",
   tag = "v1.2.3",
   branch = "main",
   module = "surface-module",
   cvs_tag = "SURFACE_1_2_3",
   cvs_module = "surface-cvs",
   platforms = {
      unix = { url = "https://example.invalid/surface-unix.tar.gz" },
      win32 = { url = "https://example.invalid/surface-win.zip" },
   },
}

description = {
   summary = "Complete rockspec parser surface",
   detailed = "Preserves every versioned LuaRocks declaration field.",
   homepage = "https://example.invalid/surface",
   license = "MIT",
   maintainer = "Moonstone",
   labels = { "parser", "coverage" },
   issues_url = "https://example.invalid/surface/issues",
}

supported_platforms = { "unix", "win32" }

dependencies = {
   "lua >= 5.1",
   platforms = {
      unix = { "luafilesystem >= 1.8" },
      win32 = { "winapi" },
   },
}

build_dependencies = {
   "luacheck >= 1",
   platforms = {
      win32 = { "winapi" },
   },
}

test_dependencies = {
   "busted >= 2",
   platforms = {
      unix = { "busted >= 2" },
   },
}

external_dependencies = {
   FOO = {
      program = "foo-config",
      header = "foo.h",
      library = "foo",
   },
   platforms = {
      unix = {
         BAR = { header = "bar.h" },
      },
   },
}

build = {
   type = "builtin",
   modules = {
      ["surface.core"] = {
         sources = { "src/core.c" },
         defines = { "SURFACE=1" },
         incdirs = { "include" },
         libdirs = { "lib" },
         libraries = { "surface" },
      },
   },
   install = {
      lua = { ["surface.init"] = "src/init.lua" },
      lib = { ["surface.lib"] = "lib/surface.a" },
      conf = { ["surface.conf"] = "etc/surface.conf" },
      bin = { surface = "bin/surface" },
   },
   copy_directories = { "assets", "templates" },
   platforms = {
      unix = {
         modules = { ["surface.unix"] = "src/unix.lua" },
      },
      win32 = {
         modules = { ["surface.windows"] = "src/windows.lua" },
      },
   },
}

test = {
   type = "busted",
   platforms = {
      unix = { type = "busted" },
   },
}

hooks = {
   post_install = "echo installed",
   platforms = {
      unix = { post_install = "echo unix-installed" },
   },
}

deploy = {
   wrap_bin_scripts = false,
}
