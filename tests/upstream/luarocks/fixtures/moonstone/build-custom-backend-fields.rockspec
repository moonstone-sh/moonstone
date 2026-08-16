package = "build_custom_backend_fields"
version = "1.0-1"

source = {
   url = "https://example.invalid/build-custom-1.0.tar.gz",
}

build = {
   type = "custom",
   command = "build-tool --flag",
   variables = {
      MODE = "release",
   },
}
