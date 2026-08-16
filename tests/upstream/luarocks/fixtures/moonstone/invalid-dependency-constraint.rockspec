rockspec_format = "3.1"
package = "invalid_dependency_constraint"
version = "1.0-1"

source = {
   url = "https://example.invalid/invalid-dependency-constraint-1.0.tar.gz",
}

dependencies = {
   "package / invalid",
}
