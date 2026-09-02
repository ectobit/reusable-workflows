#!/bin/sh
set -eu

root=${1:-.}
workflow="$root/.github/workflows/buildx.yaml"

grep -Fq 'grype-vex:' "$workflow"
grep -Fq "description: newline-separated VEX documents passed explicitly to Grype" "$workflow"
grep -Fq 'vex: ${{ inputs.grype-vex }}' "$workflow"
grep -Fq 'uses: docker/setup-qemu-action@v4.3.0' "$workflow"

printf 'buildx workflow contract passed\n'
