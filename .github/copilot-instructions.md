# Copilot Instructions — Finaira Backstage App

## Commands

```bash
# Development (preferred — handles postgres + .env automatically)
./scripts/start-dev.sh

# Or manually
yarn start                     # Start both frontend (port 3000) and backend (port 7007)
yarn workspace app start       # Frontend only
yarn workspace backend start   # Backend only

# Building
yarn build:backend             # Build backend only
yarn build:all                 # Build all packages
./scripts/build-image.sh       # Full Docker build pipeline (recommended)

# Testing
yarn test                      # Run tests for changed files (fast)
yarn test:all                  # Run all tests with coverage
yarn test:e2e                  # Playwright e2e tests (auto-starts servers)
yarn workspace app test        # Tests for a specific package
yarn workspace app test -- --testPathPattern="App.test"  # Single test file

# Linting & Types
yarn lint                      # Lint changed files since origin/master
yarn lint:all                  # Lint everything
yarn tsc                       # Type-check (incremental)
yarn tsc:full                  # Full type-check (no skipLibCheck, no incremental)
yarn prettier:check            # Check formatting

# Scaffolding
yarn new                       # Scaffold a new plugin or package
```

**Prerequisites:** PostgreSQL must be running before starting the backend. Use `docker compose up -d` to start it (postgres:18, port 5432, user/password: postgres).

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup-env.sh` | Interactive first-time credential setup (GitHub OAuth + PAT + K8s) |
| `scripts/start-dev.sh` | Start postgres + full app with prerequisite checks |
| `scripts/build-image.sh` | Full host-build → Docker image (accepts `IMAGE_TAG` env var) |
| `setup-backstage-k8s.sh` | Provision K8s service account and populate `.env` |

## Architecture

This is a **Backstage developer portal** for Finaira, using the standard Backstage monorepo layout:

```
packages/app/       Frontend React SPA (Backstage frontend role)
packages/backend/   Backend Node.js server (Backstage backend role)
plugins/            Custom plugins (currently empty — add new plugins here)
examples/           Sample catalog entity YAML files loaded at startup
```

### Frontend (`packages/app`)
- Entry point: `src/index.tsx` → `src/App.tsx`
- **Auth**: GitHub OAuth only (no guest fallback in the main app; `SignInPage` is pre-configured with GitHub provider)
- **Routing**: `FlatRoutes` from `@backstage/core-app-api`; each plugin gets its own `<Route>`
- **Entity pages**: Defined in `src/components/catalog/EntityPage.tsx` using `EntitySwitch` (kind-based) → `EntityLayout` (tab layout). Conditional tabs use `if={isXxxAvailable}` guards
- **Custom pages**: `src/components/home/HomePage.tsx` (placeholder), `src/components/search/SearchPage.tsx`, `src/components/Root/` (sidebar/nav)
- **API factories**: `src/apis.ts` — extend here to add custom API implementations
- **UI Library**: Material UI v4 (`@material-ui/core`) — not MUI v5

### Backend (`packages/backend`)
- Entry point: `src/index.ts` — uses the **new backend system** (`createBackend()` + `backend.add(import(...))`)
- All plugins are wired via `backend.add()` imports; no manual `Router` setup needed
- **Database**: PostgreSQL (primary, configured in `app-config.yaml`); `better-sqlite3` also installed as fallback
- **Search engine**: `plugin-search-backend-module-pg` (PostgreSQL-backed search, not in-memory Lunr)

### Configuration System
- `app-config.yaml` — local development config (committed, contains hardcoded local credentials)
- `app-config.production.yaml` — production overrides; database uses env vars (`${POSTGRES_HOST}`, etc.)
- Both files are passed to the Docker container at runtime via `CMD`

## Key Conventions

### Adding a new backend plugin
Use `backend.add(import('@backstage/plugin-xyz-backend'))` in `packages/backend/src/index.ts`. The new backend system handles wiring automatically.

### Adding a new frontend plugin
1. Add the package dependency to `packages/app/package.json`
2. Add the `<Route>` in `packages/app/src/App.tsx`
3. If it adds entity tabs, extend `EntityPage.tsx` with the appropriate `EntityLayout.Route` (use `if={isXxxAvailable}` for conditional tabs)

### Entity page pattern
Entity pages are structured as:
```
entityPage (EntitySwitch by kind)
  └── componentPage (EntitySwitch by type: service | website | default)
        └── XxxEntityPage (EntityLayout with tabs)
```
Add tabs to the right entity page variant; use community plugins from `@backstage-community/` for conditional content.

### Catalog entity files
Located in `examples/`. The catalog loads them via `type: file` locations in `app-config.yaml`. Production should replace these with `type: url` locations pointing to a GitHub repo.

### Credentials pattern
`app-config.yaml` contains hardcoded dev credentials (OAuth, DB). In production these are replaced by `${ENV_VAR}` references in `app-config.production.yaml`. **Never commit real secrets** — use `scripts/setup-env.sh` to configure locally. The `.env` file (gitignored) is sourced by `scripts/start-dev.sh`.

### GitHub OAuth callback URL
The exact callback URL registered in the GitHub OAuth App must be:
```
http://localhost:7007/api/auth/github/handler/frame
```

### Kubernetes integration
Configured with Argo Rollouts custom resources (`argoproj.io/v1alpha1/rollouts`). The cluster config uses `${K8S_MINIKUBE_TOKEN}` and `${K8S_CONFIG_CA_DATA}` env vars.

### Docker image build sequence
```bash
yarn install --immutable
yarn tsc
yarn build:backend
yarn build-image          # runs: docker build ../.. -f packages/backend/Dockerfile
```

### Installed community plugins
- `@backstage-community/plugin-adr` + `plugin-adr-backend` — Architecture Decision Records
- `@backstage-community/plugin-github-actions` — CI/CD tab on entity pages
- `@backstage-community/plugin-tech-radar` — Tech Radar page at `/tech-radar`
