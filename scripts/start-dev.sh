#!/usr/bin/env bash
# start-dev.sh — Start the Finaira Backstage app in development mode.
# Ensures PostgreSQL is running via Docker Compose, loads .env, then starts
# both frontend (port 3000) and backend (port 7007).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}➜${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
error() { echo -e "${RED}✗${NC}  $*" >&2; }

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Finaira Backstage — Dev Startup    ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── 1. Check required tools ─────────────────────────────────────────────────
for cmd in node yarn docker; do
  if ! command -v "$cmd" &>/dev/null; then
    error "Required tool not found: $cmd"
    exit 1
  fi
done

NODE_VER=$(node -e "process.stdout.write(process.version.slice(1).split('.')[0])")
if [[ "$NODE_VER" -lt 22 ]]; then
  error "Node.js 22+ required (found v${NODE_VER}). Use nvm or fnm to switch."
  exit 1
fi

# ── 2. Load .env if present ──────────────────────────────────────────────────
if [[ -f ".env" ]]; then
  info "Loading .env"
  set -a; source .env; set +a
else
  warn ".env not found — Kubernetes integration will be disabled."
  warn "Run  scripts/setup-env.sh  to configure it."
fi

# ── 3. Start PostgreSQL via Docker Compose ───────────────────────────────────
if ! docker compose ps postgres 2>/dev/null | grep -q "running"; then
  info "Starting PostgreSQL (docker compose)…"
  docker compose up -d postgres
else
  info "PostgreSQL already running"
fi

# Wait for postgres to accept connections (max 30 s)
info "Waiting for PostgreSQL to be ready…"
for i in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U postgres -q 2>/dev/null; then
    info "PostgreSQL is ready"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    error "PostgreSQL did not become ready after 30 s. Check 'docker compose logs postgres'."
    exit 1
  fi
  sleep 1
done

# ── 4. Check node_modules ────────────────────────────────────────────────────
if [[ ! -d "node_modules" ]]; then
  warn "node_modules not found — running yarn install…"
  yarn install
fi

# ── 5. Start Backstage ───────────────────────────────────────────────────────
echo ""
info "Starting Backstage…"
info "  Frontend → http://localhost:3000"
info "  Backend  → http://localhost:7007"
echo ""

exec yarn start
