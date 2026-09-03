#!/bin/sh
set -eu

root=${1:-.}
workflow="$root/.github/workflows/go-check.yaml"

awk '
  /^      cache:$/ { in_cache_input = 1; next }
  in_cache_input && /^      [A-Za-z0-9_-]+:$/ { exit }
  in_cache_input && $0 == "        type: boolean" { has_type = 1 }
  in_cache_input && $0 == "        default: true" { has_default = 1 }
  END { exit !(has_type && has_default) }
' "$workflow"

awk '
  $0 == "      - name: Set up go cache" { in_cache_step = 1; next }
  in_cache_step && /^      - name:/ { exit }
  in_cache_step && $0 == "        if: ${{ inputs.cache }}" { has_condition = 1 }
  END { exit !has_condition }
' "$workflow"

grep -Fq '          cache: false' "$workflow"
grep -Fq '      - name: Set up tools cache' "$workflow"

printf 'go-check workflow contract passed\n'
