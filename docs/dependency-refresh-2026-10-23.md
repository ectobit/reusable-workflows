# Dependency refresh — 2026-10-23

## Changes

- Grype: explicitly select `v0.121.0` through scan-action's supported
  `grype-version` input. The current scan-action `v7.4.2` bundles `v0.118.0`,
  so updating the action reference alone would leave the scanner behind.
- Docker login-action: `v4.6.0` → `v4.7.0` in both registry login steps.
- Bun: `1.4.3` → `1.4.4`, including the README. The Bun contract fixtures now
  read the workflow version, as the Playwright fixtures already do, so they
  exercise the selected workflow toolchain rather than an independent pin.

Callers must align their Bun `packageManager` and preinstalled runner Bun
with `1.4.4`. Playwright stays at `1.64.1`; browser compatibility checks and
all scan failure thresholds are retained.

## Verified inventory

GitHub's latest non-prerelease release metadata was checked for every
versioned action reference and the tools below. Go, PyYAML, govulncheck, and
the Cargo helper versions were checked against their respective registries.
There are no application manifests or lockfiles in this repository.

| Dependency | Current stable version |
| --- | --- |
| actions/checkout | 7.0.1 |
| actions/setup-go | 7.0.0 |
| actions/cache | 6.1.0 |
| actions/upload-artifact | 7.0.2 |
| anchore/scan-action | 7.4.2 |
| Grype | 0.121.0 |
| azure/setup-helm | 5.0.1 |
| docker/build-push-action | 7.4.0 |
| docker/login-action | 4.7.0 |
| docker/metadata-action | 6.2.0 |
| docker/setup-buildx-action | 4.4.1 |
| docker/setup-qemu-action | 4.4.0 |
| hadolint/hadolint-action | 3.5.0 |
| oven-sh/setup-bun | 2.2.0 |
| peter-evans/create-pull-request | 8.1.1 |
| raven-actions/actionlint | 2.2.0 |
| Go | 1.27.3 |
| golangci-lint | 2.15.0 |
| govulncheck | 1.9.0 |
| Bun | 1.4.4 |
| Playwright | 1.64.1 |
| Helm | 4.3.1 |
| Hadolint | 2.15.1 |
| actionlint | 1.7.12 |
| PyYAML | 6.0.3 |
| cargo-deny | 0.20.2 |
| cargo-outdated | 0.19.0 |
| cargo-udeps | 0.1.61 |
| cargo-audit | 0.22.2 |
| cargo-pants | 0.4.38 |

Existing floating major action aliases, Helm's `latest` installer default,
and Cargo's stable crate resolution remain in place. The Rust check's
nightly default remains necessary for cargo-udeps. The Ubuntu 24.04 labels
remain compatible with stable actionlint; see the October 20 refresh note
for the existing Ubuntu 26.04 validation blocker.

The pipeline retains its early blocking `raven-actions/actionlint@v2` job.
The Buildx workflow has an explicit optional Grype image scan, enabled by
`grype: true`, with findings blocking by default. Private callers should use
`platforms: linux/amd64` unless their deployment requires another architecture.
The README deployment example already restricts deployments to pushes to main.

## Validation

- actionlint passed.
- Buildx, Go check, and Go dependency-diff contract scripts passed.
- All 13 runner/frontend tool contract tests passed.
- `git diff --check` passed.

These checks validate workflow syntax and local contracts; no hosted image
build, registry push, or image scan was executed during local validation.
No runner deployment or manual external CI run was triggered.

## Primary sources

- [Grype 0.121.0](https://github.com/anchore/grype/releases/tag/v0.121.0)
- [scan-action's bundled Grype version](https://github.com/anchore/scan-action/blob/v7.4.2/GrypeVersion.js)
- [scan-action's supported inputs](https://github.com/anchore/scan-action/blob/v7.4.2/action.yml)
- [Docker login-action 4.7.0](https://github.com/docker/login-action/releases/tag/v4.7.0)
- [Bun 1.4.4](https://github.com/oven-sh/bun/releases/tag/bun-v1.4.4)
- [Go stable metadata](https://go.dev/dl/?mode=json)
- [govulncheck module metadata](https://proxy.golang.org/golang.org/x/vuln/@latest)
- [PyYAML metadata](https://pypi.org/pypi/PyYAML/json)
- [Cargo registry](https://crates.io/)
