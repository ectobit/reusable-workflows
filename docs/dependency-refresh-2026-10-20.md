# Dependency refresh — 2026-10-20

## Changes

- Go defaults in the check, update, and dependency-diff workflows, the repository
  pipeline, and current README examples: 1.27.2 → 1.27.3.
- govulncheck: v1.8.0 → v1.9.0. Its Go minimum is 1.26.0, below the selected
  toolchain. The update retains the existing checksum/module authentication
  mechanisms and all blocking checks.
- Playwright: 1.64.0 → 1.64.1. This fixes Emaia PR #237's browser-job failure:
  its project uses 1.64.1, but this workflow rejected it before running tests.
  The infrastructure runner source already pins 1.64.1. Keep the workflow,
  project lockfile, and deployed runner browsers aligned.
- Runner test fixtures now use Playwright 1.64.1, Buildx 0.38.0, and Helm
  4.3.1. The Playwright tests read the actual workflow environment instead of
  overriding it with an independent version, so a stale workflow default is
  exercised by the tests. The revised fixtures failed before the workflow fix
  and passed after it. Mismatched versions and missing/non-executable browser
  binaries still fail.

## Complete inventory

No open dependency PRs were present. Every Action reference and runtime/tool
pin in the workflows was compared with upstream stable release metadata.
There are no maintained Dockerfiles, application package manifests, Helm charts,
or lockfiles in this repository.

The existing Action releases are current: checkout 7.0.1, setup-go 7.0.0,
cache 6.1.0, upload-artifact 7.0.2, setup-bun 2.2.0, setup-helm 5.0.1,
actionlint action 2.2.0, create-pull-request 8.1.1, hadolint action 3.5.0,
setup-qemu 4.4.0, setup-buildx 4.4.1, metadata 6.2.0, login 4.6.0,
build-push 7.4.0, and scan-action 7.4.2. Existing major aliases retain their
intentional floating policy. Bun 1.4.3, golangci-lint 2.15.0, and PyYAML
6.0.3 are also current. Grype remains a blocking image scan in Buildx.

The Rust helper installations already resolve current stable crates through
`cargo install --locked`: cargo-deny 0.20.2, cargo-outdated 0.19.0,
cargo-udeps 0.1.61, cargo-audit 0.22.2, and cargo-pants 0.4.38. Their existing
floating update policy is unchanged. The existing Rust nightly default is
retained because cargo-udeps requires nightly at runtime; replacing it with
stable would break that check. No new prerelease dependency was adopted.

Ubuntu 26.04 is available upstream, but stable actionlint 1.7.12 does not
recognize its runner label. The attempted update failed the blocking lint gate
and was reverted. Keep Ubuntu 24.04 until a stable actionlint release supports
26.04; no label allowlist, lint suppression, or expression bypass was added.
Caller-selected runners and the existing ubuntu-latest defaults are unchanged.

## Validation and publication

Actionlint and all repository contracts pass: Buildx, Go check, Go dependency
diff, and 13 runner/frontend tool tests. Go 1.27.3 was verified directly.
The pipeline retains its early blocking raven-actions/actionlint@v2 job.
The selected govulncheck 1.9.0 was built with Go 1.27.3 in a temporary tooling
directory and passed a scan of the Emaia backend with zero reachable
vulnerabilities.

These changes are local on main. No commit, push, workflow dispatch, CI rerun,
runner restart, or runner image deployment has been performed. Emaia's browser
CI fix takes effect only after publishing the shared workflow and starting a
new run against it. A source image pin does not prove every active runner has
already been rebuilt; the compatibility check continues to enforce that.

## Primary sources

- [Go stable release metadata](https://go.dev/dl/?mode=json)
- [Playwright 1.64.1](https://github.com/microsoft/playwright/releases/tag/v1.64.1)
- [govulncheck module metadata](https://proxy.golang.org/golang.org/x/vuln/@v/v1.9.0.info)
- [GitHub runner images](https://github.com/actions/runner-images)
- [actionlint releases](https://github.com/rhysd/actionlint/releases)
- [cargo-udeps nightly requirement](https://github.com/est31/cargo-udeps#cargo-udeps)
