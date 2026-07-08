#!/usr/bin/env bash
# setup-env.sh — Interactive setup for the Finaira Backstage .env file.
# Configures GitHub OAuth credentials in app-config.yaml and writes
# GITHUB_TOKEN + Kubernetes credentials to .env.
# Re-running is safe: existing values are shown and can be kept as-is.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${GREEN}➜${NC}  $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }

# ── Safely add or update a single key in .env (never clobbers other keys) ───
# Uses Python instead of sed -i to work reliably on WSL /mnt/c/ paths.
set_env_var() {
  local key="$1" val="$2" file="${REPO_ROOT}/.env"
  if [[ -f "$file" ]] && grep -q "^${key}=" "$file" 2>/dev/null; then
    python3 - "$key" "$val" "$file" << 'PY'
import sys
key, val, fname = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fname, 'r') as f:
    lines = f.readlines()
with open(fname, 'w') as f:
    for line in lines:
        f.write((key + '=' + val + '\n') if line.startswith(key + '=') else line)
PY
  else
    echo "${key}=${val}" >> "$file"
  fi
}

# ── Patch a YAML key's value in app-config.yaml (WSL-safe via Python) ────────
patch_yaml() {
  local key="$1" val="$2"
  python3 - "$key" "$val" app-config.yaml << 'PY'
import sys, re
key, val, fname = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fname, 'r') as f:
    content = f.read()
pattern = r'^(\s+' + re.escape(key) + r':).*$'
new_content = re.sub(pattern, lambda m: m.group(1) + ' ' + val, content, count=1, flags=re.MULTILINE)
with open(fname, 'w') as f:
    f.write(new_content)
PY
}

# ── Read a YAML scalar value; returns empty for placeholders / masked values ─
get_yaml_value() {
  local key="$1" raw
  raw=$(grep -m1 "^[[:space:]]*${key}:" app-config.yaml 2>/dev/null \
        | sed "s/.*${key}:[[:space:]]*//" | tr -d '\r\n' || true)
  # Treat all-asterisk strings, ${VAR} placeholders, or empty as "not set"
  if [[ -z "$raw" ]] || [[ "$raw" =~ ^\*+$ ]] || [[ "$raw" =~ ^\$\{ ]]; then
    echo ""
  else
    echo "$raw"
  fi
}

# ── Read a value from .env; returns empty for placeholders ──────────────────
get_env_value() {
  local key="$1" val
  val=$(grep "^${key}=" "${REPO_ROOT}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n' || true)
  # Treat all-asterisk or ${VAR} values as "not set"
  if [[ -z "$val" ]] || [[ "$val" =~ ^\*+$ ]] || [[ "$val" =~ ^\$\{ ]]; then
    echo ""
  else
    echo "$val"
  fi
}

# ── Mask a secret: first 4 chars + **** ─────────────────────────────────────
mask() {
  local val="$1" len="${#1}"
  if   [[ $len -eq 0 ]]; then echo ""
  elif [[ $len -le 6 ]]; then echo "****"
  else echo "${val:0:4}****"
  fi
}

# ── Interactive prompt with optional "keep existing" hint ───────────────────
# Sets global REPLY to the entered value or the existing value if Enter pressed.
REPLY=""
ask() {
  local label="$1" existing="$2" is_secret="${3:-false}"
  if [[ -n "$existing" ]]; then
    echo -e "${DIM}  Current: $(mask "$existing") (press Enter to keep)${NC}"
    echo -ne "${CYAN}?${NC}  ${label} [Enter to keep]: "
  else
    echo -ne "${CYAN}?${NC}  ${label}: "
  fi

  if [[ "$is_secret" == "true" ]]; then
    read -rs REPLY || true
    echo ""   # newline after silent input
  else
    read -r REPLY || true
  fi

  # Empty input → fall back to existing value
  if [[ -z "$REPLY" && -n "$existing" ]]; then
    REPLY="$existing"
  fi
}

# ── Banner ───────────────────────────────────────────────────────────────────
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
echo "Press Enter on any field to keep its existing value."
echo ""

# ── 1. GitHub OAuth App ──────────────────────────────────────────────────────
echo -e "${BOLD}── GitHub OAuth App ────────────────────────────────────────────────${NC}"
echo ""
echo "Create an OAuth App at: https://github.com/settings/developers"
echo "  Homepage URL              : http://localhost:3000"
echo "  Authorization callback URL: http://localhost:7007/api/auth/github/handler/frame"
echo ""

EXISTING_CLIENT_ID=$(get_yaml_value "clientId")
EXISTING_CLIENT_SECRET=$(get_yaml_value "clientSecret")

ask "GitHub OAuth Client ID" "$EXISTING_CLIENT_ID" false
GITHUB_CLIENT_ID="$REPLY"

ask "GitHub OAuth Client Secret" "$EXISTING_CLIENT_SECRET" true
GITHUB_CLIENT_SECRET="$REPLY"

if [[ -n "$GITHUB_CLIENT_ID" && -n "$GITHUB_CLIENT_SECRET" ]]; then
  # Store real credentials in .env (gitignored) and keep app-config.yaml using env-var references
  set_env_var "GITHUB_CLIENT_ID" "${GITHUB_CLIENT_ID}"
  set_env_var "GITHUB_CLIENT_SECRET" "${GITHUB_CLIENT_SECRET}"
  patch_yaml "clientId" "\${GITHUB_CLIENT_ID}"
  patch_yaml "clientSecret" "\${GITHUB_CLIENT_SECRET}"
  info ".env updated with GitHub OAuth credentials (app-config.yaml uses \\${GITHUB_CLIENT_ID} and \\${GITHUB_CLIENT_SECRET})"
else
  warn "Skipping GitHub OAuth config (no value provided and none existing)"
fi

echo ""

# ── 2. GitHub PAT ────────────────────────────────────────────────────────────
echo -e "${BOLD}── GitHub Personal Access Token (PAT) ─────────────────────────────${NC}"
echo ""
echo "Create a PAT at: https://github.com/settings/tokens"
echo "Required scopes: repo, read:org, read:user"
echo ""

# Prefer .env value; fall back to app-config.yaml token line
EXISTING_PAT=$(get_env_value "GITHUB_TOKEN")
if [[ -z "$EXISTING_PAT" ]]; then
  EXISTING_PAT=$(get_yaml_value "token")
fi

ask "GitHub PAT" "$EXISTING_PAT" true
GITHUB_TOKEN="$REPLY"

if [[ -n "$GITHUB_TOKEN" ]]; then
  # Keep app-config.yaml using ${GITHUB_TOKEN} env-var reference; write real value to .env
  patch_yaml "token" "\${GITHUB_TOKEN}"
  set_env_var "GITHUB_TOKEN" "${GITHUB_TOKEN}"
  info ".env updated with GitHub PAT (app-config.yaml uses \${GITHUB_TOKEN})"
else
  warn "Skipping GitHub PAT config (no value provided and none existing)"
fi

echo ""

# ── 3. Kubernetes (optional) ─────────────────────────────────────────────────
echo -e "${BOLD}── Kubernetes Integration (optional) ──────────────────────────────${NC}"
echo ""

EXISTING_K8S_TOKEN=$(get_env_value "K8S_MINIKUBE_TOKEN")
EXISTING_K8S_CA=$(get_env_value "K8S_CONFIG_CA_DATA")
if [[ -n "$EXISTING_K8S_TOKEN" && -n "$EXISTING_K8S_CA" ]]; then
  echo -e "${DIM}  Existing K8s credentials found in .env (token: $(mask "$EXISTING_K8S_TOKEN"), CA: set)${NC}"
  echo ""
fi

echo -ne "${CYAN}?${NC}  Configure Kubernetes integration? [y/N]: "
read -r CONFIGURE_K8S || true

if [[ "$CONFIGURE_K8S" =~ ^[Yy]$ ]]; then
  echo ""
  echo "How would you like to configure Kubernetes credentials?"
  echo ""
  echo "  1) Auto-generate using Minikube (recommended)"
  echo "     Starts Minikube if needed, creates service account, extracts"
  echo "     token + CA data, and patches app-config.yaml automatically."
  echo ""
  echo "  2) Enter token and CA data manually"
  echo "     Use this if you have an existing cluster or already ran"
  echo "     setup-backstage-k8s.sh."
  echo ""
  echo "  3) Keep existing / skip"
  echo ""
  echo -ne "${CYAN}?${NC}  Choice [1/2/3]: "
  read -r K8S_CHOICE || true

  case "$K8S_CHOICE" in
    1)
      echo ""
      echo -e "${BOLD}── Running Kubernetes auto-setup ───────────────────────────────────${NC}"
      echo ""

      if ! command -v minikube &>/dev/null; then
        warn "minikube not found."
        echo ""
        echo "  Install minikube: https://minikube.sigs.k8s.io/docs/start/"
        echo ""
        echo "  If you have another Kubernetes cluster already running and"
        echo "  configured in kubectl, the setup script can still work with"
        echo "  the --no-minikube flag."
        echo ""
        echo -ne "${CYAN}?${NC}  Continue without minikube (use current kubectl context)? [y/N]: "
        read -r CONTINUE_NO_MINIKUBE || true
        if [[ "$CONTINUE_NO_MINIKUBE" =~ ^[Yy]$ ]]; then
          bash "${REPO_ROOT}/setup-backstage-k8s.sh" --no-minikube
        else
          warn "Skipping Kubernetes setup"
        fi
      else
        bash "${REPO_ROOT}/setup-backstage-k8s.sh"
      fi
      ;;

    2)
      echo ""
      ask "K8S_MINIKUBE_TOKEN (bearer token)" "$EXISTING_K8S_TOKEN" true
      K8S_TOKEN="$REPLY"

      ask "K8S_CONFIG_CA_DATA (base64 CA cert)" "$EXISTING_K8S_CA" true
      K8S_CA="$REPLY"

      EXISTING_K8S_URL=$(grep -m1 "^[[:space:]]*- url:" app-config.yaml 2>/dev/null \
        | sed 's/.*- url:[[:space:]]*//' | tr -d '\r\n' || true)
      ask "Cluster API URL" "$EXISTING_K8S_URL" false
      K8S_URL="$REPLY"

      if [[ -n "$K8S_TOKEN" && -n "$K8S_CA" ]]; then
        set_env_var "K8S_MINIKUBE_TOKEN" "${K8S_TOKEN}"
        set_env_var "K8S_CONFIG_CA_DATA" "${K8S_CA}"
        info ".env updated with K8s credentials"
      else
        warn "Skipping K8s credentials (token or CA is empty)"
      fi

      if [[ -n "$K8S_URL" ]]; then
        patch_yaml "- url" "${K8S_URL}"
        info "app-config.yaml updated with cluster URL: ${K8S_URL}"
      fi
      ;;

    *)
      if [[ -n "$EXISTING_K8S_TOKEN" ]]; then
        info "Keeping existing K8s credentials"
      else
        warn "Skipping Kubernetes setup"
      fi
      ;;
  esac
fi

# ── 4. Next steps ─────────────────────────────────────────────────────────────
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

exit 0
