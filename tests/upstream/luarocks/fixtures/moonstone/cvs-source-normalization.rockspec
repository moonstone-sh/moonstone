rockspec_format = "3.1"
package = "cvs_source_normalization"
version = "1.0-1"

source = {
   url = "https://example.invalid/cvs-source-1.0.tar.gz",
   module = "modern-module",
   tag = "modern-tag",
   cvs_module = "legacy-cvs-module",
   cvs_tag = "LEGACY_CVS_TAG",
}

build = {
   type = "builtin",
}
