rockspec_format = "1.0"
package = "format_1_0_description_labels"
version = "1.0-1"

source = {
   url = "https://example.invalid/format-1.0-description-labels.tar.gz",
}

description = {
   summary = "Format-gated description field.",
   labels = { "invalid-for-1.0" },
}

build = {
   type = "builtin",
}
