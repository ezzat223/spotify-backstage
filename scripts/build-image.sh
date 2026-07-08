#!/usr/bin/env bash
# build-image.sh — Build the Backstage backend Docker image.
# Follows the official host-build approach:
#   yarn install --immutable → yarn tsc → yarn build:backend → docker build
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Colour helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}➜${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
error() { echo -e "${RED}✗${NC}  $*" >&2; }

IMAGE_TAG="${IMAGE_TAG:-backstage}"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Finaira Backstage — Docker Build    ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── 1. Check required tools ─────────────────────────────────────────────────
for cmd in node yarn docker; do
  if ! command -v "$cmd" &>/dev/null; then
    error "Required tool not found: $cmd"
    exit 1
  fi
done

# ── 1.1 Check for a running Postgres container (helpful when running the image)
# Note: building the image does not require Postgres, but running it locally does.
# If no Postgres container derived from the expected image is found, print guidance.
if ! docker ps --filter ancestor=postgres:18-trixie --format '{{.ID}}' | grep -q .; then
  warn "No running Postgres container detected. The built image needs a Postgres DB at runtime."
  warn "Start it with: docker compose up -d (uses docker-compose.yml service 'postgres')"
fi

# ── 2. Install dependencies ──────────────────────────────────────────────────
info "Installing dependencies (immutable)…"
yarn install --immutable

# ── 3. Type-check ────────────────────────────────────────────────────────────
info "Running TypeScript type-check…"
yarn tsc

# ── 4. Build backend bundle ──────────────────────────────────────────────────
info "Building backend bundle…"
yarn build:backend

# ── 5. Build Docker image ────────────────────────────────────────────────────
info "Building Docker image: ${IMAGE_TAG}"
docker build . \
  -f packages/backend/Dockerfile \
  --tag "$IMAGE_TAG"

echo ""
info "Image built: ${IMAGE_TAG}"
echo ""
echo "  Run locally with:"
echo "    docker run -it -p 7007:7007 \\"
echo "      --env POSTGRES_HOST=host.docker.internal \\"
echo "      --env POSTGRES_PORT=5432 \\"
echo "      --env POSTGRES_USER=postgres \\"
echo "      --env POSTGRES_PASSWORD=postgres \\"
echo "      ${IMAGE_TAG}"
echo ""
echo "  Or override the image tag:"
echo "    IMAGE_TAG=finaira/backstage:v1.0 $0"
echo ""
