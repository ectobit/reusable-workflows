# reusable-workflows

[![pipeline](https://github.com/ectobit/reusable-workflows/actions/workflows/pipeline.yaml/badge.svg)](https://github.com/ectobit/reusable-workflows/actions/workflows/pipeline.yaml)
[![License](https://img.shields.io/badge/license-BSD--2--Clause--Patent-orange.svg)](https://github.com/ectobit/reusable-workflows/blob/main/LICENSE)

Reusable GitHub Actions Workflows

Please check the [.github/workflows](.github/workflows) directory

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

Breaking change: `hadolint-dockerfile` has been removed. Callers that used it must switch to `dockerfile`, which is now shared by hadolint and Docker Buildx:

```yaml
with:
  image: example/image
  dockerfile: backend/Dockerfile
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
