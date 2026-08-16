local output_dir = arg[1]

if not output_dir then
   io.stderr:write("usage: schema_mutation_matrix.lua <output-dir>\n")
   os.exit(64)
end

local cases = {
   {
      name = "baseline-format-3.1",
      expected = "accept",
      source = [[
rockspec_format = "3.1"
package = "matrix_baseline"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "builtin" }
]],
   },
   {
      name = "package-number",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = 1
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "builtin" }
]],
   },
   {
      name = "version-boolean",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = "matrix_version_boolean"
version = false
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "builtin" }
]],
   },
   {
      name = "root-unknown-field",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = "matrix_root_unknown"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "builtin" }
unknown = true
]],
   },
   {
      name = "source-url-number",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = "matrix_source_url_number"
version = "1.0-1"
source = { url = 1 }
build = { type = "builtin" }
]],
   },
   {
      name = "source-unknown-field",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = "matrix_source_unknown"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz", checksum = "x" }
build = { type = "builtin" }
]],
   },
   {
      name = "dependencies-number-entry",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = "matrix_dependencies_number"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
dependencies = { 1 }
build = { type = "builtin" }
]],
   },
   {
      name = "dependencies-platforms-string",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = "matrix_dependencies_platforms"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
dependencies = { platforms = "unix" }
build = { type = "builtin" }
]],
   },
   {
      name = "external-dependency-not-table",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = "matrix_external_dependency"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
external_dependencies = { FOO = "foo" }
build = { type = "builtin" }
]],
   },
   {
      name = "external-dependency-field-number",
      expected = "reject",
      source = [[
rockspec_format = "3.1"
package = "matrix_external_dependency_field"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
external_dependencies = { FOO = { header = 1 } }
build = { type = "builtin" }
]],
   },
   {
      name = "description-labels-format-1.0",
      expected = "reject",
      source = [[
rockspec_format = "1.0"
package = "matrix_description_labels"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
description = { labels = { "invalid" } }
build = { type = "builtin" }
]],
   },
   {
      name = "description-labels-number",
      expected = "accept",
      source = [[
rockspec_format = "3.1"
package = "matrix_description_label_number"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
description = { labels = { 1 } }
build = { type = "builtin" }
]],
   },
   {
      name = "deploy-format-1.0",
      expected = "reject",
      source = [[
rockspec_format = "1.0"
package = "matrix_deploy_format_1_0"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "builtin" }
deploy = { wrap_bin_scripts = false }
]],
   },
   {
      name = "deploy-string",
      expected = "reject",
      source = [[
rockspec_format = "1.1"
package = "matrix_deploy_string"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "builtin" }
deploy = { wrap_bin_scripts = "false" }
]],
   },
   {
      name = "test-format-1.1",
      expected = "reject",
      source = [[
rockspec_format = "1.1"
package = "matrix_test_format_1_1"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "builtin" }
test = { type = "custom" }
]],
   },
   {
      name = "build-omitted-format-3.0",
      expected = "accept",
      source = [[
rockspec_format = "3.0"
package = "matrix_build_omitted"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
]],
   },
   {
      name = "build-open-backend-payload",
      expected = "accept",
      source = [[
rockspec_format = "3.1"
package = "matrix_build_open_payload"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "custom", command = "tool --release", nested = { enabled = true } }
]],
   },
   {
      name = "test-open-backend-payload",
      expected = "accept",
      source = [[
rockspec_format = "3.1"
package = "matrix_test_open_payload"
version = "1.0-1"
source = { url = "https://example.invalid/matrix-1.0.tar.gz" }
build = { type = "builtin" }
test = { type = "custom", command = "tool --test", nested = { enabled = true } }
]],
   },
}

for _, case in ipairs(cases) do
   local path = output_dir .. "/" .. case.name .. ".rockspec"
   local file = assert(io.open(path, "wb"))
   file:write(case.source)
   file:close()
   io.write(case.name, "\t", case.expected, "\t", path, "\n")
end
