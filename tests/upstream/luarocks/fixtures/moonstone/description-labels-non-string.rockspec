rockspec_format = "3.1"
package = "description_labels_non_string"
version = "1.0-1"

source = {
   url = "https://example.invalid/description-labels-1.0.tar.gz",
}

description = {
   labels = { 1 },
}

build = {
   type = "builtin",
}
