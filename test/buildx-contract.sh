#!/bin/sh
set -eu

root=${1:-.}
workflow="$root/.github/workflows/buildx.yaml"

grep -Fq 'grype-vex:' "$workflow"
grep -Fq "description: newline-separated VEX documents passed explicitly to Grype" "$workflow"
grep -Fq 'vex: ${{ inputs.grype-vex }}' "$workflow"
grep -Eq '^ *uses: docker/setup-qemu-action@v[0-9]+\.[0-9]+\.[0-9]+$' "$workflow"

printf 'buildx workflow contract passed\n'
