#!/usr/bin/env bash
# setup-env.sh — Interactive setup for the Finaira Backstage .env file.
# Configures GitHub OAuth credentials in app-config.yaml and the
# Kubernetes service-account token / CA data in .env (for K8s plugin).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${GREEN}➜${NC}  $*"; }
prompt() { echo -e "${CYAN}?${NC}  $*"; }
warn()   { echo -e "${YELLOW}⚠${NC}  $*"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Finaira Backstage — Environment Setup   ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "This script guides you through setting up credentials for:"
echo "  1. GitHub OAuth App  (required — for sign-in)"
echo "  2. GitHub PAT        (required — for catalog/scaffolder integration)"
echo "  3. Kubernetes token  (optional — for K8s plugin)"
echo ""

# ── 1. GitHub OAuth App ──────────────────────────────────────────────────────
echo -e "${BOLD}── GitHub OAuth App ────────────────────────────────────────────────${NC}"
echo ""
echo "Create an OAuth App at: https://github.com/settings/developers"
echo "  Homepage URL              : http://localhost:3000"
echo "  Authorization callback URL: http://localhost:7007/api/auth/github/handler/frame"
echo ""

prompt "GitHub OAuth Client ID:"
read -r GITHUB_CLIENT_ID

prompt "GitHub OAuth Client Secret:"
read -rs GITHUB_CLIENT_SECRET
echo ""

# Patch app-config.yaml with the OAuth credentials
if [[ -n "$GITHUB_CLIENT_ID" && -n "$GITHUB_CLIENT_SECRET" ]]; then
  # Use sed to replace inline values (handles both literal and ${VAR} formats)
  sed -i \
    -e "s|clientId:.*|clientId: ${GITHUB_CLIENT_ID}|" \
    -e "s|clientSecret:.*|clientSecret: ${GITHUB_CLIENT_SECRET}|" \
    app-config.yaml
  info "app-config.yaml updated with GitHub OAuth credentials"
else
  warn "Skipping GitHub OAuth config (empty input)"
fi

echo ""

# ── 2. GitHub PAT ────────────────────────────────────────────────────────────
echo -e "${BOLD}── GitHub Personal Access Token (PAT) ─────────────────────────────${NC}"
echo ""
echo "Create a PAT at: https://github.com/settings/tokens"
echo "Required scopes: repo, read:org, read:user"
echo ""

prompt "GitHub PAT (leave blank to skip):"
read -rs GITHUB_TOKEN
echo ""

ENV_CONTENT=""

if [[ -n "$GITHUB_TOKEN" ]]; then
  # Replace the token line in app-config.yaml
  sed -i "s|token: \*\*\*\*\*\*|token: ${GITHUB_TOKEN}|g" app-config.yaml
  sed -i "s|#  token: \${GITHUB_TOKEN}|  token: \${GITHUB_TOKEN}|g" app-config.yaml
  ENV_CONTENT+="GITHUB_TOKEN=${GITHUB_TOKEN}\n"
  info "app-config.yaml updated with GitHub PAT"
else
  warn "Skipping GitHub PAT config"
fi

echo ""

# ── 3. Kubernetes (optional) ─────────────────────────────────────────────────
echo -e "${BOLD}── Kubernetes Integration (optional) ──────────────────────────────${NC}"
echo ""

prompt "Configure Kubernetes integration? [y/N]"
read -r CONFIGURE_K8S

if [[ "$CONFIGURE_K8S" =~ ^[Yy]$ ]]; then
  echo ""
  echo "To generate K8s credentials automatically, run:"
  echo "  ./setup-backstage-k8s.sh"
  echo ""
  echo "Or enter values manually:"
  echo ""
  prompt "K8S_MINIKUBE_TOKEN (base64 bearer token, leave blank to skip):"
  read -rs K8S_TOKEN
  echo ""
  prompt "K8S_CONFIG_CA_DATA (base64 CA cert, leave blank to skip):"
  read -rs K8S_CA
  echo ""

  if [[ -n "$K8S_TOKEN" && -n "$K8S_CA" ]]; then
    ENV_CONTENT+="K8S_MINIKUBE_TOKEN=${K8S_TOKEN}\nK8S_CONFIG_CA_DATA=${K8S_CA}\n"
    info "K8s credentials will be written to .env"
  else
    warn "Skipping K8s credentials"
  fi
fi

# ── 4. Write .env ─────────────────────────────────────────────────────────────
if [[ -n "$ENV_CONTENT" ]]; then
  echo ""
  if [[ -f ".env" ]]; then
    warn ".env already exists — backing up to .env.bak"
    cp .env .env.bak
  fi
  printf "%b" "$ENV_CONTENT" > .env
  info ".env written"
fi

# ── 5. Next steps ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Setup complete! Next steps:             ║"
echo "║                                          ║"
echo "║  1. Start development:                   ║"
echo "║     ./scripts/start-dev.sh               ║"
echo "║                                          ║"
echo "║  2. Open the app:                        ║"
echo "║     http://localhost:3000                ║"
echo "╚══════════════════════════════════════════╝"
echo ""
