# reusable-workflows

[![pipeline](https://github.com/ectobit/reusable-workflows/actions/workflows/pipeline.yaml/badge.svg)](https://github.com/ectobit/reusable-workflows/actions/workflows/pipeline.yaml)
[![License](https://img.shields.io/badge/license-BSD--2--Clause--Patent-orange.svg)](https://github.com/ectobit/reusable-workflows/blob/main/LICENSE)

Reusable GitHub Actions Workflows

Please check the [.github/workflows](.github/workflows) directory

## Runner selection

The `buildx.yaml`, `go-check.yaml`, `chart.yaml`, and `frontend-check.yaml` workflows accept an
optional `runner` input containing a JSON runner label or label array. It
defaults to `"ubuntu-latest"`, preserving existing callers. A trusted caller
can target the Emaia laptop runner with:

```yaml
with:
  runner: '["self-hosted","linux","emaia"]'
```

## Caller-controlled execution

Reusable workflows in this repository do not decide which branches, tags, or events should deploy or publish artifacts. Caller workflows should express that policy with their own `on` and `if` conditions.

For example, `buildx.yaml` pushes an image whenever it runs. To publish only from `main`, call it only from a job that is allowed to publish:

```yaml
on:
  push:
    branches:
      - main
  pull_request:

jobs:
  build:
    if: ${{ github.ref == 'refs/heads/main' && github.event_name == 'push' }}
    uses: ectobit/reusable-workflows/.github/workflows/buildx.yaml@main
    with:
      image: example/image
    secrets:
      container-registry-username: ${{ secrets.CONTAINER_REGISTRY_USERNAME }}
      container-registry-password: ${{ secrets.CONTAINER_REGISTRY_PASSWORD }}
```

## Build container images

By default, `buildx.yaml` builds from the repository root with `Dockerfile`. Existing callers can keep using only the original inputs:

```yaml
jobs:
  build:
    uses: ectobit/reusable-workflows/.github/workflows/buildx.yaml@main
    with:
      image: example/image
    secrets:
      container-registry-username: ${{ secrets.CONTAINER_REGISTRY_USERNAME }}
      container-registry-password: ${{ secrets.CONTAINER_REGISTRY_PASSWORD }}
```

Callers with a Dockerfile in a subfolder can set the build context and Dockerfile path explicitly. Hadolint uses the selected `dockerfile`.

```yaml
jobs:
  build:
    uses: ectobit/reusable-workflows/.github/workflows/buildx.yaml@main
    with:
      image: acim/maia
      context: .
      dockerfile: backend/Dockerfile
    secrets:
      container-registry-username: ${{ secrets.CONTAINER_REGISTRY_USERNAME }}
      container-registry-password: ${{ secrets.CONTAINER_REGISTRY_PASSWORD }}
```

Hadolint runs by default. Callers that already lint the Dockerfile in an earlier CI gate can skip the internal Hadolint step:

```yaml
with:
  image: example/image
  hadolint: false
```

Callers that keep internal Hadolint enabled can set the Hadolint failure threshold. The default is `info`, matching the current Hadolint action behavior. Valid values are `error`, `warning`, `info`, `style`, and `ignore`.

```yaml
with:
  image: example/image
  hadolint-failure-threshold: warning
```

`buildx.yaml` can also scan the built image with Grype before pushing it. This mode builds the image once into the local Docker engine, scans that same image, and only pushes the scanned tags when the scan passes. Because the scanned image is loaded locally, this mode supports one platform at a time. Multi-platform callers should keep `grype: false` or split scans by platform.

```yaml
with:
  image: ghcr.io/example/app
  registry: ghcr.io
  platforms: linux/amd64
  grype: true
  grype-sarif-artifact-name: app-grype-sarif
```

Callers with reviewed VEX documents should pass them explicitly. This avoids
depending on Grype's implicit configuration-file discovery inside GitHub
Actions and keeps the exception visible at the reusable-workflow boundary.

```yaml
with:
  image: ghcr.io/example/app
  platforms: linux/amd64
  grype: true
  grype-vex: security/openvex.json
```

Set `grype-fail-build: false` only for an explicit temporary risk acceptance. The scan still runs and uploads SARIF when available, but findings do not fail the workflow.

```yaml
with:
  image: ghcr.io/example/app
  grype: true
  grype-fail-build: false
```

Breaking change: `hadolint-dockerfile` has been removed. Callers that used it must switch to `dockerfile`, which is now shared by hadolint and Docker Buildx:

```yaml
with:
  image: example/image
  dockerfile: backend/Dockerfile
```

## Check Go projects

`go-check.yaml` runs a Go lint command, optional extra checks, optional `govulncheck`, optional `go fix -diff`, and an optional test command. Use `working-directory` for repositories where Go code is not at the repository root.

```yaml
jobs:
  backend-check:
    uses: ectobit/reusable-workflows/.github/workflows/go-check.yaml@main
    with:
      working-directory: backend
      lint-command: make lint
      extra-check-command: make openapi-check
      govulncheck-version: v1.8.0
      go-toolchain: local
      go-fix-check: false
```

Go module and build caching is enabled by default for ephemeral and
GitHub-hosted runners. Persistent self-hosted runners can keep their local Go
caches between jobs and disable the remote cache transfer:

```yaml
with:
  runner: '["self-hosted","linux","example"]'
  cache: false
```

The separate Go tools cache remains enabled when the module and build cache is
disabled.

## Compare direct Go dependencies

`go-dependency-diff.yaml` compares direct requirements in a Go module file
between two Git commits. It writes a readable job summary and exposes the
`has_changes` and `report_json` workflow outputs. It does not compare indirect
requirements, `go.sum`, `replace` or `tool` directives, the Go version, or
compiled binary size.

On pull requests, the workflow compares the head commit with its merge base
against the selected base, including when `base-ref` is explicitly supplied.
The JSON report exposes the selected ref's resolved commit as
`base_ref_commit`, the actual comparison commit as `base_commit`, and sets
`base_is_merge_base` to `true`. Callers for other events must pass `base-ref`;
plain branch names fall back to their `origin/` remote-tracking branch. Callers
can optionally override `head-ref`, which otherwise defaults to `GITHUB_SHA`.
If the module file exists at only one commit, the missing side is treated as an
empty dependency set so module creation and deletion remain reportable changes.

The runner must provide `git` and `jq`; the selected Go version is installed by
`actions/setup-go`. The workflow checks these commands up front and reports a
clear error when a prerequisite is unavailable on a self-hosted runner.

For example, a repository such as Emaia with its Go module under `backend/`
can call it with:

```yaml
jobs:
  dependency-diff:
    uses: ectobit/reusable-workflows/.github/workflows/go-dependency-diff.yaml@main
    with:
      runner: '["self-hosted","linux","emaia"]'
      go-version: 1.27.1
      go-toolchain: local
      go-mod-file: backend/go.mod
      fail-on-changes: false
```

Set `fail-on-changes: true` only when any direct dependency change should be a
blocking policy violation. The default is report-only.

## Check and release Helm charts

`chart.yaml` can run Helm lint, a default `helm template`, caller-supplied render/check commands, and optional chart publishing. Existing ChartMuseum callers continue to work. OCI publishing is available with `release-target: oci`.

```yaml
jobs:
  chart-check:
    uses: ectobit/reusable-workflows/.github/workflows/chart.yaml@main
    with:
      chart: charts/example
      release: false
      render-release-name: example
      check-command: sh charts/example/tests/render-contract.sh

  chart-release:
    uses: ectobit/reusable-workflows/.github/workflows/chart.yaml@main
    with:
      chart: charts/example
      release: true
      lint: false
      package-version: 1.2.${{ github.run_number }}
      app-version: main
      release-target: oci
      registry: ghcr.io
      oci-repository: oci://ghcr.io/example/charts
      sign: false
    secrets:
      helm-repo-username: ${{ github.actor }}
      helm-repo-password: ${{ secrets.GITHUB_TOKEN }}
```

## Deploy Kubernetes images

`deploy.yaml` updates one Kubernetes Deployment container image with `kubectl set image`. It supports SSH tunneling, optional deployment concurrency, and rollout waiting. Callers with Helm-based releases or custom smoke tests should keep those workflows custom instead of using this simple deployment helper.

```yaml
with:
  image: ghcr.io/example/app
  tag: sha-1234567
  namespace: default
  deployment-name: app
  container-name: app
  concurrency-group: production-app-deploy
  verify-rollout: true
```

## Kubernetes deployment secrets

`deploy.yaml` requires these Kubernetes secrets from the caller:

```yaml
secrets:
  kubernetes-server: ${{ secrets.KUBERNETES_SERVER }}
  kubernetes-token: ${{ secrets.KUBERNETES_TOKEN }}
  kubernetes-cert: ${{ secrets.KUBERNETES_CERT }}
```

`KUBERNETES_SERVER` contains the Kubernetes API URL. For public or directly reachable clusters, use the public API URL including the Kubernetes API port. For tunneled deploys, use the local tunnel endpoint inside the GitHub Actions runner, for example:

```txt
https://127.0.0.1:6443
```

The private Kubernetes API address is used as the SSH tunnel target, through `SSH_TUNNEL_TARGET_HOST` and `SSH_TUNNEL_TARGET_PORT`.

`KUBERNETES_TOKEN` and `KUBERNETES_CERT` should come from a Kubernetes ServiceAccount token Secret belonging to a dedicated deployment ServiceAccount. For example, the ServiceAccount and RBAC can be created with `bedag/raw`:

```yaml
- name: deploy-role
  chart: bedag/raw
  version: 2.0.2
  namespace: default
  values:
    - resources:
        - apiVersion: v1
          kind: ServiceAccount
          metadata:
            name: deploy
            namespace: default
        - apiVersion: rbac.authorization.k8s.io/v1
          kind: Role
          metadata:
            name: deploy
            namespace: default
          rules:
            - apiGroups: ['apps']
              resources: ['deployments']
              verbs: ['get', 'list', 'patch', 'update']
        - apiVersion: rbac.authorization.k8s.io/v1
          kind: RoleBinding
          metadata:
            name: deploy
            namespace: default
          subjects:
            - kind: ServiceAccount
              name: deploy
              namespace: default
          roleRef:
            kind: Role
            name: deploy
            apiGroup: rbac.authorization.k8s.io
        - apiVersion: rbac.authorization.k8s.io/v1
          kind: Role
          metadata:
            name: deploy
            namespace: repo
          rules:
            - apiGroups: ['apps']
              resources: ['deployments']
              verbs: ['get', 'list', 'patch', 'update']
        - apiVersion: rbac.authorization.k8s.io/v1
          kind: RoleBinding
          metadata:
            name: deploy
            namespace: repo
          subjects:
            - kind: ServiceAccount
              name: deploy
              namespace: default
          roleRef:
            kind: Role
            name: deploy
            apiGroup: rbac.authorization.k8s.io
```

If your cluster does not create a ServiceAccount token Secret automatically, create one for the `deploy` ServiceAccount:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: deploy-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: deploy
type: kubernetes.io/service-account-token
```

Find the ServiceAccount token Secret:

```sh
kubectl -n default get secret
```

Then create the GitHub secret values from that Kubernetes Secret. `KUBERNETES_TOKEN` contains the decoded `token` field:

```sh
kubectl -n default get secret SECRET_NAME -o jsonpath='{.data.token}' | base64 -d
```

`KUBERNETES_CERT` contains the encoded `ca.crt` field. Copy and paste the Secret value as-is; do not decode it before storing it in GitHub secrets:

```sh
kubectl -n default get secret SECRET_NAME -o jsonpath='{.data.ca\.crt}'
```

Store the resulting values as GitHub Actions secrets. Do not print tokens, kubeconfig contents, private keys, or certificates in CI logs.

## Deploy through SSH tunnel

`deploy.yaml` can optionally deploy to a Kubernetes cluster through an SSH tunnel. Existing callers do not need to change anything unless they opt in.

```yaml
on:
  push:
    branches:
      - main

jobs:
  deploy:
    if: ${{ github.ref == 'refs/heads/main' && github.event_name == 'push' }}
    uses: ectobit/reusable-workflows/.github/workflows/deploy.yaml@main
    with:
      ssh-tunnel-enabled: true
    secrets:
      kubernetes-tls-server-name: ${{ secrets.KUBERNETES_TLS_SERVER_NAME }}
      ssh-private-key: ${{ secrets.SSH_TUNNEL_PRIVATE_KEY }}
      ssh-known-hosts: ${{ secrets.SSH_TUNNEL_KNOWN_HOSTS }}
      ssh-tunnel-host: ${{ secrets.SSH_TUNNEL_HOST }}
      ssh-tunnel-user: ${{ secrets.SSH_TUNNEL_USER }}
      ssh-tunnel-local-port: ${{ secrets.SSH_TUNNEL_LOCAL_PORT }}
      ssh-tunnel-target-host: ${{ secrets.SSH_TUNNEL_TARGET_HOST }}
      ssh-tunnel-target-port: ${{ secrets.SSH_TUNNEL_TARGET_PORT }}
```

The caller workflow decides when deployment runs. `deploy.yaml` does not restrict deployment to a specific branch or event.

When the tunnel is enabled, the caller's `kubernetes-server` secret must point to the local tunnel endpoint, and `kubernetes-tls-server-name` must contain the Kubernetes API certificate name. The `SSH_TUNNEL_*` secrets are only needed when `ssh-tunnel-enabled` is `true`.

Use a pinned `known_hosts` value from a secret for CI instead of discovering host keys at runtime.

### Dedicated SSH tunnel user

GitHub Actions does not need shell or admin access to the SSH host. It only needs to create a local port forward to the private Kubernetes API. Use a dedicated restricted user to reduce blast radius if the CI SSH key is exposed.

The examples below use `example.com`, `kube-tunnel`, and `192.168.169.4:6443` as placeholders. Replace them with values for your environment and store those values in GitHub secrets.

Create a dedicated SSH key on an admin laptop:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/example-github-actions-kube-tunnel -C "github-actions-kube-tunnel"
```

Create the restricted user on the SSH server:

```sh
sudo adduser --disabled-password --gecos "" kube-tunnel
sudo passwd -l kube-tunnel
sudo mkdir -p /home/kube-tunnel/.ssh
sudo chmod 700 /home/kube-tunnel/.ssh
```

Add the public key to `authorized_keys` with forwarding restrictions:

```sh
sudo nano /home/kube-tunnel/.ssh/authorized_keys
```

The line should look like this, with the real public key replacing the placeholder:

```txt
restrict,port-forwarding,permitopen="192.168.169.4:6443" ssh-ed25519 AAAA... github-actions-kube-tunnel
```

`restrict` disables most SSH features by default. `port-forwarding` re-enables TCP forwarding. `permitopen="192.168.169.4:6443"` allows forwarding only to that private Kubernetes API endpoint.

Fix ownership and permissions:

```sh
sudo chown -R kube-tunnel:kube-tunnel /home/kube-tunnel/.ssh
sudo chmod 600 /home/kube-tunnel/.ssh/authorized_keys
```

Test the tunnel from a local machine:

```sh
ssh -fN \
  -i ~/.ssh/example-github-actions-kube-tunnel \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6443:192.168.169.4:6443 \
  kube-tunnel@example.com
```

Create these GitHub Actions secrets only for callers that enable SSH tunneling:

```txt
SSH_TUNNEL_PRIVATE_KEY
SSH_TUNNEL_KNOWN_HOSTS
SSH_TUNNEL_HOST
SSH_TUNNEL_USER
SSH_TUNNEL_LOCAL_PORT
SSH_TUNNEL_TARGET_HOST
SSH_TUNNEL_TARGET_PORT
KUBERNETES_TLS_SERVER_NAME
```

`SSH_TUNNEL_PRIVATE_KEY` contains the private key from:

```sh
cat ~/.ssh/example-github-actions-kube-tunnel
```

`SSH_TUNNEL_KNOWN_HOSTS` contains the pinned SSH host key entry. Generate a candidate entry with:

```sh
ssh-keyscan -H example.com
```

Verify the host key out-of-band before storing it as a GitHub secret. Prefer pinned `known_hosts` over `ssh-keyscan` during CI.

The reusable deploy workflow starts the tunnel in the same job that runs `kubectl`:

```sh
ssh -fN \
  -i ~/.ssh/ssh_tunnel_deploy_key \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o StrictHostKeyChecking=yes \
  -L 127.0.0.1:6443:192.168.169.4:6443 \
  kube-tunnel@example.com
```

For tunneled deploys, the caller's Kubernetes connection secrets should represent:

```yaml
server: https://127.0.0.1:6443
tls-server-name: example.com
```

`server` points to the local tunnel endpoint inside the runner. `tls-server-name` must match a DNS name in the Kubernetes API server certificate. Existing Kubernetes CA and ServiceAccount token/cert auth stay unchanged.

Security notes:

- Do not use root SSH login.
- Do not use a personal or admin SSH account for CI.
- Do not grant sudo to the tunnel user.
- Do not print private keys, kube tokens, kubeconfig contents, or certificates.
- Keep the SSH private key in GitHub secrets and rotate it if it is exposed.
- Start the SSH tunnel in the same GitHub Actions job that runs `kubectl`, `helm`, or `helmfile`, because jobs run on isolated runners.


## Preinstalled runner tools

`preinstalled-tools` defaults to `false`: existing callers keep their setup
steps. Enable it only after rebuilding and recreating the self-hosted runner
image. `chart.yaml` then requires Helm 4.3.0; `buildx.yaml` uses native
Hadolint 2.15.1 when Dockerfile linting is enabled, retaining the selected
failure threshold, ignore list, and project configuration. Version mismatches
fail with an actionable error; they do not silently install another binary.

```yaml
with:
  runner: '["self-hosted","linux","example"]'
  preinstalled-tools: true
```

For `buildx.yaml`, independently enable `reuse-runner-builder: true` to use
the runner's `BUILDX_BUILDER`. The workflow bootstraps and inspects that existing
builder and requires all requested platforms before skipping QEMU and Buildx
setup. It supplies the verified builder explicitly to every build action and
does not remove it afterward. Provision platform emulation on the physical
container host before opting in; installing QEMU inside a runner filesystem
does not configure the host's binfmt handlers. Keep the existing setup when
platform support is unavailable. Use a distinct builder per runner.

```yaml
with:
  image: ghcr.io/example/app
  runner: '["self-hosted","linux","example"]'
  platforms: linux/amd64
  preinstalled-tools: true
  reuse-runner-builder: true
  grype: true
```

Grype, VEX, SARIF upload, tags, caching, and scan-before-push behavior are
unchanged. The Go workflows and their toolchain/cache policies are unchanged.

## Frontend checks with Bun and Playwright

`frontend-check.yaml` runs one job per call. Keep unit and browser checks as
separate caller jobs to preserve parallelism, job-specific conditions, and
required-check wiring. The workflow owns Bun **1.4.2** and Playwright **1.63.0**.
A declared `packageManager` must agree with Bun; browser jobs must resolve the
matching project-local `playwright-core` version from the frozen lockfile.

Inputs:

| Input | Default | Meaning |
| --- | --- | --- |
| `runner` | `"ubuntu-latest"` | JSON runner label or label array |
| `preinstalled-tools` | `false` | Require image-owned Bun/browsers; skip setup/downloads |
| `working-directory` | `.` | Directory containing package.json and the Bun lockfile |
| `fetch-depth` | `1` | Checkout depth; use `0` for history-dependent checks |
| `timeout-minutes` | `20` | Job timeout |
| `browser-tests` | `false` | Verify or install Chromium and WebKit |
| `prepare-command` | empty | Optional preparation after frozen dependency installation |
| `check-command` | required | Checks in working-directory |
| `root-check-command` | empty | Final checks from repository root |
| `artifact-path` | empty | Optional repository-relative paths uploaded even on failure |
| `artifact-name` | `frontend-results` | Unique artifact name per caller job |

The required `check-command` rejects empty or whitespace-only values.
Commands execute with failure propagation and pipefail. They are authored by
the trusted caller workflow; do not construct them from PR titles, commit
messages, or other untrusted event text. No test, coverage, Fallow, or browser
failure is suppressed. The optional artifact upload tolerates absent result
files, since tests can fail before creating a report.

Frontend runners must provide Node.js on `PATH` for the Bun and Playwright
compatibility checks, including when Bun is installed by the workflow.
Playwright is resolved through the project's installed dependency chain,
supporting isolated installs with only `@playwright/test` declared.

With `preinstalled-tools: true`, browser jobs require the image's Playwright
package at `/opt/runner-playwright/node_modules/playwright-core` (set the runner
environment variable `RUNNER_PLAYWRIGHT_HOME` to an absolute directory to override
`/opt/runner-playwright`) and
`PLAYWRIGHT_BROWSERS_PATH` pointing to installed executable Chromium/WebKit
builds. No browser installation runs in this mode. The runner smoke test
launches both engines; project tests exercise their own locked dependencies.
Without preinstalled tools, Bun is set up and browser jobs run the project's
resolved `playwright-core` CLI to install browsers with system dependencies.
This supports `@playwright/test`, `playwright`, and `playwright-core` entry
packages, including isolated dependency layouts. Custom commands such as Fallow
still require the caller's runner to provide those tools.

Example frontend unit/coverage checks:

```yaml
jobs:
  frontend-test:
    # Keep the caller's existing needs and event/path conditions here.
    uses: ectobit/reusable-workflows/.github/workflows/frontend-check.yaml@main
    with:
      runner: '["self-hosted","linux","emaia"]'
      preinstalled-tools: true
      working-directory: frontend
      fetch-depth: 0
      prepare-command: bun run generate-routes
      check-command: |
        bun run typecheck
        bun run check
        bun run test:coverage
      root-check-command: >-
        fallow audit --root frontend --config .fallowrc.json --gate all
        --coverage coverage/coverage-final.json --fail-on-issues
```

Example widget unit checks:

```yaml
jobs:
  widget-unit-test:
    uses: ectobit/reusable-workflows/.github/workflows/frontend-check.yaml@main
    with:
      runner: '["self-hosted","linux","vega"]'
      preinstalled-tools: true
      check-command: bun run check:widget
      root-check-command: make widget-sri-check
```

Browser jobs use the same workflow independently:

```yaml
jobs:
  frontend-browser-test:
    uses: ectobit/reusable-workflows/.github/workflows/frontend-check.yaml@main
    with:
      runner: '["self-hosted","linux","emaia"]'
      preinstalled-tools: true
      working-directory: frontend
      browser-tests: true
      check-command: |
        bun run e2e -- e2e/landing-motion.spec.ts e2e/landing-locales.spec.ts
        bun run e2e:accessibility
      artifact-path: |
        frontend/test-results
        frontend/playwright-report
      artifact-name: frontend-browser-results

  widget-browser-test:
    uses: ectobit/reusable-workflows/.github/workflows/frontend-check.yaml@main
    with:
      runner: '["self-hosted","linux","vega"]'
      preinstalled-tools: true
      browser-tests: true
      check-command: bun run test:widget:e2e
```

Update caller workflows only after the shared workflows are published and the
runner image is deployed. Preserve caller `needs`, `if`, permissions, and
required-check names; these examples omit repository-specific scheduling.
The shared workflow does not commit, publish, or deploy anything.

Validate changes with `actionlint`, the existing shell contracts, and
`python3 test/runner-tools-contract.py` (requires PyYAML and Node.js).
