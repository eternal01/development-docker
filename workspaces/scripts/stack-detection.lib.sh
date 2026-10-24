#!/usr/bin/env bash

# Populate detected_tools and detected_versions for the current directory.
# The caller must source languages.defaults before invoking this function.

# Select a usable lower-bound/exact version without concatenating range parts
# (for example, ">=18 <21" must never become the invalid version "1821").
version_from_constraint() {
  local constraint="$1" candidate upper
  # Alternatives and wildcard constraints have language-specific semantics;
  # leave them for the project owner instead of guessing a possibly invalid
  # runtime version.
  [[ "${constraint}" != *'||'* ]] || return 0

  if [[ "${constraint}" =~ (==|>=|~=|~|\^)[[:space:]]*([0-9]+(\.[0-9]+){0,2}) ]]; then
    candidate="${BASH_REMATCH[2]}"
  elif [[ "${constraint}" =~ ^[[:space:]]*([0-9]+(\.[0-9]+){0,2})([[:space:]]|$) ]]; then
    candidate="${BASH_REMATCH[1]}"
  elif [[ "${constraint}" =~ ^[[:space:]]*([0-9]+)\.[xX*]([[:space:]]|$) ]]; then
    candidate="${BASH_REMATCH[1]}"
  else
    return 0
  fi

  # A lower bound is a safe candidate only when it is below every explicit
  # exclusive upper bound in the expression (e.g. >=3.10,<3.13).
  if [[ "${constraint}" =~ [\<][=]?[[:space:]]*([0-9]+(\.[0-9]+){0,2}) ]]; then
    upper="${BASH_REMATCH[1]}"
    local IFS=.
    local -a lower_parts upper_parts
    read -r -a lower_parts <<<"${candidate}"
    read -r -a upper_parts <<<"${upper}"
    local i lower_part upper_part
    for i in 0 1 2; do
      lower_part="${lower_parts[$i]:-0}"
      upper_part="${upper_parts[$i]:-0}"
      lower_part=$((10#${lower_part}))
      upper_part=$((10#${upper_part}))
      if (( lower_part < upper_part )); then break; fi
      if (( lower_part > upper_part )); then return 0; fi
      if (( i == 2 )); then return 0; fi
    done
  fi
  printf '%s\n' "${candidate}"
}
detect_project_stack() {
  detected_tools=()
  detected_versions=()

  if [ -f package.json ]; then
    local node_ver=""
    if command -v jq >/dev/null 2>&1; then
      local raw
      raw=$(jq -r '.engines.node // empty' package.json 2>/dev/null || true)
      if [ -n "$raw" ] && [ "$raw" != "null" ]; then
        node_ver=$(version_from_constraint "$raw")
        if [ -z "${node_ver}" ]; then
          echo "[detect-stack] cannot safely infer Node version from engines.node='${raw}'; choose one with mise use node@VERSION" >&2
        fi
      fi
    fi
    detected_tools+=("node")
    if [ -n "${node_ver}" ] || [ -z "${raw:-}" ]; then
      detected_versions+=("${node_ver:-${node:-22}}")
    else
      detected_versions+=("")
    fi
  fi

  if [ -f go.mod ]; then
    local go_ver
    go_ver=$(awk '/^go[[:space:]]/{print $2; exit}' go.mod 2>/dev/null)
    detected_tools+=("go")
    detected_versions+=("${go_ver:-${go:-1.23}}")
  fi

  if [ -f Cargo.toml ]; then
    local rust_ver=""
    if grep -qE '^[[:space:]]*rust-version' Cargo.toml 2>/dev/null; then
      rust_ver=$(awk -F'"' '/^[[:space:]]*rust-version/ {print $2; exit}' Cargo.toml 2>/dev/null)
    fi
    detected_tools+=("rust")
    detected_versions+=("${rust_ver:-${rust:-stable}}")
  fi

  if [ -f composer.json ]; then
    local php_ver=""
    if command -v jq >/dev/null 2>&1; then
      local raw
      raw=$(jq -r '.require.php // empty' composer.json 2>/dev/null || true)
      if [ -n "$raw" ] && [ "$raw" != "null" ]; then
        php_ver=$(version_from_constraint "$raw")
        if [ -z "${php_ver}" ]; then
          echo "[detect-stack] cannot safely infer PHP version from require.php='${raw}'; choose one with mise use php@VERSION" >&2
        fi
      fi
    fi
    detected_tools+=("php")
    if [ -n "${php_ver}" ] || [ -z "${raw:-}" ]; then
      detected_versions+=("${php_ver:-${php:-8.3}}")
    else
      detected_versions+=("")
    fi
  fi

  if [ -f pyproject.toml ] || [ -f requirements.txt ]; then
    local python_ver=""
    if [ -f pyproject.toml ]; then
      local raw
      raw=$(awk -F'"' '/requires-python/ {print $2; exit}' pyproject.toml 2>/dev/null)
      if [ -n "$raw" ]; then
        python_ver=$(version_from_constraint "$raw")
        if [ -z "${python_ver}" ]; then
          echo "[detect-stack] cannot safely infer Python version from requires-python='${raw}'; choose one with mise use python@VERSION" >&2
        fi
      fi
    fi
    detected_tools+=("python")
    if [ -n "${python_ver}" ] || [ -z "${raw:-}" ]; then
      detected_versions+=("${python_ver:-${python:-3.12}}")
    else
      detected_versions+=("")
    fi
  fi
}
