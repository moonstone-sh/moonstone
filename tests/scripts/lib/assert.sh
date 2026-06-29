#!/usr/bin/env bash

assert_success() {
  local label="$1"
  shift
  if ! "$@"; then
    echo "✗ ${label}: expected success"
    return 1
  fi
}

assert_fails() {
  local label="$1"
  shift
  if "$@"; then
    echo "✗ ${label}: expected failure"
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="${3:-contains}"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "✗ ${label}: expected output to contain: ${needle}"
    echo "--- output ---"
    printf '%s\n' "${haystack}"
    return 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "${needle}" "${file}"; then
    echo "✗ expected ${file} to contain: ${needle}"
    echo "--- ${file} ---"
    cat "${file}" || true
    return 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "${needle}" "${file}"; then
    echo "✗ expected ${file} not to contain: ${needle}"
    echo "--- ${file} ---"
    cat "${file}" || true
    return 1
  fi
}

assert_json_valid() {
  local payload="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "${payload}" | jq . >/dev/null
  else
    python3 - <<'PY' <<<"${payload}"
import json, sys
for line in sys.stdin:
    if line.strip():
        json.loads(line)
PY
  fi
}

assert_ndjson_terminator() {
  local payload="$1"
  python3 -c 'import json,sys; lines=[json.loads(line) for line in sys.stdin if line.strip()]; assert lines, "no json messages"; assert lines[-1].get("terminator") is True, lines[-1]; print(lines[-1].get("kind", ""))' <<<"${payload}" >/dev/null
}

assert_last_json_field() {
  local payload="$1"
  local field="$2"
  local expected="$3"
  python3 -c 'import json,sys; field=sys.argv[1].split("."); expected=sys.argv[2]; lines=[json.loads(line) for line in sys.stdin if line.strip()]; value=lines[-1];
for part in field: value=value[part]
assert str(value).lower() == expected.lower(), f"expected {field}={expected}, got {value}"' "${field}" "${expected}" <<<"${payload}"
}
