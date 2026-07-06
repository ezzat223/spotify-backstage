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

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Node.js | 22 or 24 | Use [nvm](https://github.com/nvm-sh/nvm) or [fnm](https://github.com/Schniz/fnm) |
| Yarn | 4.4.1 | Comes via `corepack enable` |
| Docker | any | Required for PostgreSQL and image builds |
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

Run the interactive setup script to configure GitHub OAuth and a GitHub PAT:

```sh
./scripts/setup-env.sh
```

This will:
- Patch `app-config.yaml` with your GitHub OAuth Client ID and Secret
- Write a `.env` file with your GitHub PAT and optional Kubernetes credentials

**Manual alternative — GitHub OAuth App**

Create an OAuth App at https://github.com/settings/developers with:

| Field | Value |
|-------|-------|
| Homepage URL | `http://localhost:3000` |
| Authorization callback URL | `http://localhost:7007/api/auth/github/handler/frame` |

Then set `clientId` and `clientSecret` under `auth.providers.github.development` in `app-config.yaml`.

**Manual alternative — GitHub PAT**

Create a PAT at https://github.com/settings/tokens with scopes: `repo`, `read:org`, `read:user`.  
Set it as the `token` under `integrations.github` in `app-config.yaml`.

### 3. Start PostgreSQL

```sh
docker compose up -d
```

This starts a PostgreSQL 18 container on port `5432` (user: `postgres`, password: `postgres`).

---

## Running in Development

### Quick start (recommended)

```sh
./scripts/start-dev.sh
```

This script checks prerequisites, starts PostgreSQL if it isn't running, and launches both the frontend and backend in one terminal.

### Manual start

```sh
# Terminal 1 — backend (port 7007)
yarn workspace backend start

# Terminal 2 — frontend (port 3000)
yarn workspace app start
```

Or run both together:

```sh
yarn start
```

The app uses `app-config.yaml` for local config. Environment variables from `.env` are **not** automatically sourced — the start-dev script handles this.  
To source manually: `set -a && source .env && set +a`.

---

## Running Tests

```sh
# Run tests for files changed since origin/master (fast, default workflow)
yarn test

# Run all tests with coverage
yarn test:all

# Run tests for a single package
yarn workspace app test
yarn workspace backend test

# Run a single test file
yarn workspace app test -- --testPathPattern="App.test"

# End-to-end tests (Playwright — starts servers automatically)
yarn test:e2e
```

---

## Linting & Type-checking

```sh
# Lint files changed since origin/master
yarn lint

# Lint everything
yarn lint:all

# TypeScript type-check (fast, incremental)
yarn tsc

# Full type-check (no skipLibCheck, no incremental)
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

The script runs the full host-build pipeline and produces a `backstage` Docker image.

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

Override the image tag with `IMAGE_TAG=my-tag ./scripts/build-image.sh`.

---

## Kubernetes Integration

The app displays Kubernetes workloads (including Argo Rollouts) for catalog entities.

To set up credentials for a local Minikube cluster:

```sh
./setup-backstage-k8s.sh
```

This creates a `backstage` service account with `cluster-admin`, generates a long-lived token, extracts the CA certificate, and writes `K8S_MINIKUBE_TOKEN` and `K8S_CONFIG_CA_DATA` to `.env`.

After running the script, update the cluster URL in `app-config.yaml`:

```yaml
kubernetes:
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: <minikube-url-printed-by-script>
```

---

## Scripts Reference

| Script | Description |
|--------|-------------|
| `scripts/setup-env.sh` | Interactive first-time credential setup |
| `scripts/start-dev.sh` | Start postgres + frontend + backend |
| `scripts/build-image.sh` | Full host-build → Docker image pipeline |
| `setup-backstage-k8s.sh` | Provision Kubernetes service account and write `.env` |

---

## Configuration Reference

| File | Purpose |
|------|---------|
| `app-config.yaml` | Local development config (committed) |
| `app-config.production.yaml` | Production overrides; DB uses env vars |
| `.env` | Runtime secrets (gitignored) — `K8S_MINIKUBE_TOKEN`, `K8S_CONFIG_CA_DATA` |
| `examples/` | Sample catalog entities loaded at startup |

### Key environment variables (production)

| Variable | Used by |
|----------|---------|
| `POSTGRES_HOST` | Backend database |
| `POSTGRES_PORT` | Backend database |
| `POSTGRES_USER` | Backend database |
| `POSTGRES_PASSWORD` | Backend database |
| `GITHUB_TOKEN` | GitHub integration (catalog, scaffolder) |
| `K8S_MINIKUBE_TOKEN` | Kubernetes plugin |
| `K8S_CONFIG_CA_DATA` | Kubernetes plugin |

### Adding a new plugin

```sh
# Scaffold a new frontend or backend plugin
yarn new
```

See [`packages/backend/src/index.ts`](packages/backend/src/index.ts) for how backend plugins are wired, and [`packages/app/src/App.tsx`](packages/app/src/App.tsx) for frontend routes.
