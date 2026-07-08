# Finaira Backstage

Internal developer portal for Finaira, built on [Spotify Backstage](https://backstage.io) v1.48.

- **Frontend** → http://localhost:3000
- **Backend API** → http://localhost:7007

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [First-time Setup](#first-time-setup)
- [Running in Development](#running-in-development)
- [Running Tests](#running-tests)
- [Linting & Type-checking](#linting--type-checking)
- [Building the Docker Image](#building-the-docker-image)
- [Kubernetes Integration](#kubernetes-integration)
- [Scripts Reference](#scripts-reference)
- [Configuration Reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Node.js | 22 or 24 | Use [nvm](https://github.com/nvm-sh/nvm) or [fnm](https://github.com/Schniz/fnm) |
| Yarn | 4.4.1 | Comes via `corepack enable` |
| Docker | any | Required for PostgreSQL and image builds |
| kubectl | any | Required for Kubernetes integration |
| minikube | any | Optional — for local K8s cluster auto-setup |
| Git | any | |

> **macOS:** Run `xcode-select --install` for the native build toolchain required by `isolated-vm` and `better-sqlite3`.
>
> **Ubuntu/Debian:** `sudo apt-get install -y python3 g++ build-essential libsqlite3-dev`

---

## First-time Setup

### 1. Install dependencies

```sh
yarn install
```

### 2. Configure credentials

Run the interactive setup script — it guides you through every credential and patches all the right files:

```sh
./scripts/setup-env.sh
```

The wizard covers three sections:

#### GitHub OAuth App (required — for sign-in)

Create an OAuth App at <https://github.com/settings/developers>:

| Field | Value |
|-------|-------|
| Homepage URL | `http://localhost:3000` |
| Authorization callback URL | `http://localhost:7007/api/auth/github/handler/frame` |

The script writes `clientId` and `clientSecret` directly into `app-config.yaml`.

#### GitHub PAT (required — for catalog & scaffolder)

Create a PAT at <https://github.com/settings/tokens> with scopes: `repo`, `read:org`, `read:user`.

The script writes it to `.env` as `GITHUB_TOKEN`. `app-config.yaml` references this automatically via `${GITHUB_TOKEN}`.

#### Kubernetes credentials (optional — for K8s plugin)

The script offers three options:

1. **Auto-generate using Minikube** *(recommended)* — starts Minikube if needed, creates a `backstage` service account, extracts the bearer token + CA certificate, and patches `app-config.yaml` cluster URL automatically.
2. **Manual entry** — paste an existing token, CA data, and cluster URL.
3. **Keep existing / skip** — leaves whatever is currently in `.env`.

---

> **Re-running is always safe.** The script shows your existing values (masked) and lets you press Enter to keep them. Only values you explicitly change are updated.

---

### 3. Start PostgreSQL

The start script handles this for you, but you can also start it manually:

```sh
docker compose up -d
```

This starts a PostgreSQL container on port `5432` (user: `postgres`, password: `postgres`).

---

## Running in Development

### Quick start (recommended)

```sh
./scripts/start-dev.sh
```

This single command:

1. Checks prerequisites (Node 22+, Yarn, Docker)
2. Loads `.env` and exports all variables into the environment
3. Starts PostgreSQL if it isn't already running and waits for it to be ready
4. Runs `yarn start` (launches both frontend and backend concurrently)

### Manual start

```sh
# Ensure .env is loaded
set -a && source .env && set +a

# Start both together
yarn start

# — OR — start them individually:
# Terminal 1 — backend (port 7007)
yarn workspace backend start

# Terminal 2 — frontend (port 3000)
yarn workspace app start
```

---

## Running Tests

```sh
# Changed files since origin/master (fast, default for CI)
yarn test

# All tests with coverage
yarn test:all

# Single package
yarn workspace app test
yarn workspace backend test

# Single test file
yarn workspace app test -- --testPathPattern="App.test"

# End-to-end (Playwright — starts servers automatically)
yarn test:e2e
```

---

## Linting & Type-checking

```sh
# Lint changed files since origin/master
yarn lint

# Lint everything
yarn lint:all

# TypeScript type-check (fast, incremental)
yarn tsc

# Full type-check
yarn tsc:full

# Check Prettier formatting
yarn prettier:check
```

---

## Building the Docker Image

### Quick build (recommended)

```sh
./scripts/build-image.sh
```

Runs the full host-build pipeline (`install → tsc → build:backend`) and produces a `backstage` Docker image.

Note: the built image expects a PostgreSQL database at runtime. Start the local Postgres service defined in `docker-compose.yml` before running the image:

```sh
docker compose up -d
```

Override the tag: `IMAGE_TAG=my-tag ./scripts/build-image.sh`

### Manual build

```sh
yarn install --immutable
yarn tsc
yarn build:backend

docker build . \
  -f packages/backend/Dockerfile \
  --tag backstage
```

### Run the image locally

```sh
docker run -it -p 7007:7007 \
  -e POSTGRES_HOST=host.docker.internal \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  backstage
```

---

## Kubernetes Integration

The app shows Kubernetes workloads (including Argo Rollouts) for catalog entities annotated with `backstage.io/kubernetes-id`.

### Automatic setup (via `setup-env.sh`)

The easiest way is to run the setup wizard and choose **option 1** when it asks about Kubernetes:

```sh
./scripts/setup-env.sh
# → Configure Kubernetes integration? y
# → Choice: 1 (Auto-generate using Minikube)
```

### Standalone setup

Run the K8s script directly if you want to (re-)provision credentials without going through the full wizard:

```sh
./setup-backstage-k8s.sh              # With Minikube auto-start
./setup-backstage-k8s.sh --no-minikube # Use current kubectl context as-is
```

The script:
1. Starts Minikube (unless `--no-minikube`) and waits for nodes to be Ready
2. Enables the `metrics-server` addon
3. Enables the `dashboard` addon — prompts for the dashboard URL so it can be patched into `app-config.yaml`
4. Installs [Argo Rollouts](https://argoproj.github.io/rollouts/) into the `argo-rollouts` namespace (required by the K8s plugin's `customResources` config)
5. Creates namespace `backstage` + service account + `ClusterRoleBinding`
6. Creates a long-lived token secret and extracts the bearer token
7. Extracts the base64-encoded CA certificate
8. Patches `app-config.yaml` — cluster URL (correct 8-space indentation) and `dashboardUrl`
9. Writes `K8S_MINIKUBE_TOKEN` and `K8S_CONFIG_CA_DATA` to `.env`

> **Dashboard URL note:** The dashboard URL is ephemeral — it changes each time you open a tunnel. When the script prompts for it, run this in a separate terminal first:
> ```sh
> minikube service kubernetes-dashboard -n kubernetes-dashboard --url
> ```
> Paste the printed URL back into the setup prompt. Re-run the script any time the URL changes.

### How it works at runtime

`start-dev.sh` exports all `.env` variables before launching Backstage. `app-config.yaml` references them:

```yaml
kubernetes:
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: https://<minikube-ip>:8443
          authProvider: serviceAccount
          serviceAccountToken: ${K8S_MINIKUBE_TOKEN}
          caData: ${K8S_CONFIG_CA_DATA}
```

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/setup-env.sh` | Interactive credentials wizard — GitHub OAuth, PAT, K8s |
| `scripts/start-dev.sh` | Start PostgreSQL + frontend + backend (loads `.env` automatically) |
| `scripts/build-image.sh` | Full host-build → Docker image pipeline |
| `setup-backstage-k8s.sh` | Provision Kubernetes service account and write credentials to `.env` |

All scripts are idempotent — re-running them is safe.

---

## Configuration Reference

| File | Purpose |
|------|---------|
| `app-config.yaml` | Local development config (committed) — uses `${VAR}` references for secrets |
| `app-config.production.yaml` | Production overrides; all DB + secret values via env vars |
| `.env` | Runtime secrets (gitignored) — sourced by `scripts/start-dev.sh` |
| `examples/` | Sample catalog entities loaded at startup |

### Environment variables

| Variable | Required | Used by |
|----------|----------|---------|
| `GITHUB_TOKEN` | Yes | GitHub integration (catalog reads, scaffolder) |
| `K8S_MINIKUBE_TOKEN` | Optional | Kubernetes plugin bearer token |
| `K8S_CONFIG_CA_DATA` | Optional | Kubernetes plugin CA certificate (base64) |
| `POSTGRES_HOST` | Production | Backend database |
| `POSTGRES_PORT` | Production | Backend database |
| `POSTGRES_USER` | Production | Backend database |
| `POSTGRES_PASSWORD` | Production | Backend database |

### Adding a new plugin

```sh
yarn new
```

See [`packages/backend/src/index.ts`](packages/backend/src/index.ts) for backend plugin wiring and [`packages/app/src/App.tsx`](packages/app/src/App.tsx) for frontend routes.

---

## Troubleshooting

### YAML parse error on startup

**Symptom:** `YAMLParseError: Nested mappings are not allowed in compact mappings`

**Cause:** The `token:` field under `integrations.github` in `app-config.yaml` has a duplicate or incorrectly indented entry.

**Fix:** Open `app-config.yaml` and ensure there is exactly one `token:` line under `- host: github.com`, using the env-var reference:

```yaml
integrations:
  github:
    - host: github.com
      token: ${GITHUB_TOKEN}
```

---

### Credentials not picked up after setup

`app-config.yaml` uses `${GITHUB_TOKEN}` syntax for secrets. These are resolved from the process environment **at startup**, not from `.env` directly. Always start the app via `./scripts/start-dev.sh` (which loads `.env`) or export your `.env` manually:

```sh
set -a && source .env && set +a
yarn start
```

---

### `sed: no input files` or silent failures on WSL

`sed -i` can fail silently on Windows NTFS paths mounted in WSL (`/mnt/c/...`). The scripts in this repo use Python for all in-place file edits to avoid this issue.

If you encounter unexpected config values after running setup scripts, re-run `./scripts/setup-env.sh` — it will read the current file state and let you update any field.

---

### Minikube node readiness timeout

If `setup-backstage-k8s.sh` hangs waiting for nodes, check that Minikube started correctly:

```sh
minikube status
kubectl get nodes
```

If nodes are stuck in `NotReady`, try:

```sh
minikube delete && minikube start
./setup-backstage-k8s.sh
```
