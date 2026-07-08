#!/usr/bin/env bash
# setup-backstage-k8s.sh — Provision Kubernetes credentials for Backstage.
#
# What it does:
#   1. Checks prerequisites (kubectl, optional minikube)
#   2. Minikube pre-setup: starts cluster if not running, waits for nodes,
#      enables metrics-server, installs Argo Rollouts, enables Dashboard
#   3. Creates the 'backstage' namespace + service account + cluster-admin binding
#   4. Creates a long-lived service-account token Secret
#   5. Extracts CA data (handles both inline base64 and file-path formats)
#   6. Patches app-config.yaml with the live cluster URL (correct indentation)
#   7. Patches app-config.yaml dashboardUrl if provided
#   8. Merges K8S_MINIKUBE_TOKEN + K8S_CONFIG_CA_DATA into .env
#
# Usage:
#   ./setup-backstage-k8s.sh              # interactive (default)
#   ./setup-backstage-k8s.sh --no-minikube  # skip minikube pre-setup steps
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

SKIP_MINIKUBE=false
for arg in "$@"; do
  [[ "$arg" == "--no-minikube" ]] && SKIP_MINIKUBE=true
done

# ── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}✔${NC}  $*"; }
step()  { echo -e "${CYAN}➜${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
error() { echo -e "${RED}✗${NC}  $*" >&2; }
die()   { error "$*"; exit 1; }

# ── Merge a key=value into .env — WSL-safe (Python, not sed -i) ─────────────
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

# ── Patch a line in app-config.yaml — WSL-safe (Python, not sed -i) ─────────
# patch_yaml_line KEY VALUE
#   Finds the first non-comment line matching "  KEY:" (any indent) and
#   replaces everything after the colon, preserving the original indentation.
patch_yaml_line() {
  local key="$1" val="$2"
  python3 - "$key" "$val" app-config.yaml << 'PY'
import sys, re
key, val, fname = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fname, 'r') as f:
    content = f.read()
# Match the key with any leading whitespace (handles both "- url:" and "dashboardUrl:")
pattern = r'^(\s+' + re.escape(key) + r':).*$'
new_content = re.sub(pattern, lambda m: m.group(1) + ' ' + val, content, count=1, flags=re.MULTILINE)
with open(fname, 'w') as f:
    f.write(new_content)
PY
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Backstage — Kubernetes Credentials Setup   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Check prerequisites ──────────────────────────────────────────────────
step "Checking prerequisites…"

if ! command -v kubectl &>/dev/null; then
  die "kubectl not found. Install it: https://kubernetes.io/docs/tasks/tools/"
fi
info "kubectl found: $(kubectl version --client --short 2>/dev/null || kubectl version --client | head -1)"

HAS_MINIKUBE=false
if command -v minikube &>/dev/null; then
  HAS_MINIKUBE=true
  info "minikube found: $(minikube version --short 2>/dev/null || minikube version | head -1)"
else
  warn "minikube not found — skipping minikube pre-setup."
  warn "Make sure your cluster is reachable via kubectl before continuing."
  SKIP_MINIKUBE=true
fi

# ── 2. Minikube pre-setup ───────────────────────────────────────────────────
if [[ "$SKIP_MINIKUBE" == "false" && "$HAS_MINIKUBE" == "true" ]]; then
  echo ""
  echo -e "${BOLD}── Minikube Pre-setup ──────────────────────────────────────────────${NC}"
  echo ""

  MINIKUBE_STATUS=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "Stopped")

  if [[ "$MINIKUBE_STATUS" == "Running" ]]; then
    info "Minikube is already running"
  else
    step "Starting minikube…"
    minikube start --driver=docker 2>&1 | sed 's/^/   /'
    info "Minikube started"
  fi

  # Wait for all nodes to be Ready
  step "Waiting for cluster nodes to be Ready…"
  for i in $(seq 1 60); do
    NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null \
      | grep -cv " Ready" || true)
    NOT_READY="${NOT_READY//[[:space:]]/}"
    NOT_READY="${NOT_READY:-0}"
    if [[ "$NOT_READY" -eq 0 ]]; then
      info "All nodes are Ready"
      break
    fi
    if [[ "$i" -eq 60 ]]; then
      die "Nodes did not become Ready after 60s. Run: kubectl get nodes"
    fi
    sleep 2
  done

  # ── metrics-server ──────────────────────────────────────────────────────
  step "Checking metrics-server addon…"
  if minikube addons list | grep -q "metrics-server.*enabled"; then
    info "metrics-server already enabled"
  else
    minikube addons enable metrics-server 2>&1 | sed 's/^/   /'
    info "metrics-server enabled"
  fi

  # ── Kubernetes Dashboard ────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}── Kubernetes Dashboard ────────────────────────────────────────────${NC}"
  echo ""

  step "Checking kubernetes-dashboard addon…"
  if minikube addons list | grep -q "dashboard.*enabled"; then
    info "kubernetes-dashboard addon already enabled"
  else
    minikube addons enable dashboard 2>&1 | sed 's/^/   /'
    info "kubernetes-dashboard addon enabled"
  fi

  echo ""
  echo "  The dashboard URL is ephemeral — it changes each time you open a tunnel."
  echo "  To get the current URL, run in a separate terminal:"
  echo ""
  echo -e "  ${CYAN}minikube service kubernetes-dashboard -n kubernetes-dashboard --url${NC}"
  echo ""
  echo -n "  Paste the URL here (or press Enter to skip): "
  read -r DASHBOARD_URL_INPUT || true

  if [[ -n "$DASHBOARD_URL_INPUT" ]]; then
    patch_yaml_line "dashboardUrl" "${DASHBOARD_URL_INPUT}"
    info "app-config.yaml → dashboardUrl: ${DASHBOARD_URL_INPUT}"
  else
    warn "Skipping dashboardUrl update (existing value kept)"
  fi

  # ── Argo Rollouts ───────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}── Argo Rollouts ───────────────────────────────────────────────────${NC}"
  echo ""

  step "Checking Argo Rollouts installation…"
  if kubectl get deployment argo-rollouts -n argo-rollouts &>/dev/null 2>&1; then
    info "Argo Rollouts already installed"
  else
    step "Creating argo-rollouts namespace…"
    kubectl create namespace argo-rollouts 2>/dev/null \
      && info "Namespace 'argo-rollouts' created" \
      || info "Namespace 'argo-rollouts' already exists"

    step "Applying Argo Rollouts manifests (this may take a moment)…"
    kubectl apply -n argo-rollouts \
      -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml \
      2>&1 | sed 's/^/   /'
    info "Argo Rollouts installed"
  fi
fi

# ── 3. Verify cluster reachability ──────────────────────────────────────────
echo ""
step "Verifying cluster connectivity…"
kubectl cluster-info --request-timeout=10s > /dev/null 2>&1 \
  || die "Cannot reach the Kubernetes cluster. Check your kubeconfig / minikube status."
info "Cluster is reachable"

# ── 4. Detect current cluster ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Cluster Info ────────────────────────────────────────────────────${NC}"
echo ""

CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null)
CONTEXT_NAME=$(kubectl config current-context 2>/dev/null)
CLUSTER_URL=$(kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.server}')

info "Context : ${CONTEXT_NAME}"
info "Cluster : ${CLUSTER_NAME}"
info "API URL : ${CLUSTER_URL}"

# ── 5. Create namespace + service account ───────────────────────────────────
echo ""
echo -e "${BOLD}── Service Account Setup ───────────────────────────────────────────${NC}"
echo ""

step "Creating backstage namespace…"
kubectl create namespace backstage 2>/dev/null \
  && info "Namespace 'backstage' created" \
  || info "Namespace 'backstage' already exists"

step "Creating backstage service account…"
kubectl create serviceaccount backstage -n backstage 2>/dev/null \
  && info "Service account 'backstage' created" \
  || info "Service account 'backstage' already exists"

# ── 6. Bind cluster-admin role ──────────────────────────────────────────────
step "Binding cluster-admin role…"
kubectl apply -f - > /dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: backstage-cluster-admin
subjects:
  - kind: ServiceAccount
    name: backstage
    namespace: backstage
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
info "ClusterRoleBinding 'backstage-cluster-admin' applied"

# ── 7. Create long-lived token Secret ──────────────────────────────────────
step "Creating long-lived service-account token…"
kubectl apply -f - > /dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: backstage-token
  namespace: backstage
  annotations:
    kubernetes.io/service-account.name: backstage
type: kubernetes.io/service-account-token
EOF

step "Waiting for token to be issued…"
TOKEN=""
for i in $(seq 1 30); do
  TOKEN=$(kubectl get secret backstage-token -n backstage \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode 2>/dev/null || true)
  if [[ -n "$TOKEN" ]]; then
    info "Token issued"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    die "Token not issued after 30s. Check: kubectl describe secret backstage-token -n backstage"
  fi
  sleep 1
done

# ── 8. Extract CA data ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── CA Certificate ──────────────────────────────────────────────────${NC}"
echo ""

step "Extracting CA certificate data for cluster '${CLUSTER_NAME}'…"

CA_DATA=$(kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)

if [[ -z "$CA_DATA" ]]; then
  CA_FILE=$(kubectl config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)
  if [[ -n "$CA_FILE" && -f "$CA_FILE" ]]; then
    CA_DATA=$(base64 -w 0 < "$CA_FILE")
    info "CA data read from file: ${CA_FILE}"
  fi
fi

if [[ -z "$CA_DATA" ]]; then
  die "Could not extract CA certificate data for cluster '${CLUSTER_NAME}'.\n   Check: kubectl config view --raw --minify"
fi
info "CA data extracted (${#CA_DATA} chars)"

# ── 9. Patch app-config.yaml cluster URL (correct 8-space indentation) ──────
echo ""
echo -e "${BOLD}── app-config.yaml ─────────────────────────────────────────────────${NC}"
echo ""

step "Updating cluster URL in app-config.yaml…"
patch_yaml_line "- url" "${CLUSTER_URL}"
info "app-config.yaml → url: ${CLUSTER_URL}"

# ── 10. Write .env ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── .env ────────────────────────────────────────────────────────────${NC}"
echo ""

step "Writing K8s credentials to .env…"
set_env_var "K8S_MINIKUBE_TOKEN" "${TOKEN}"
set_env_var "K8S_CONFIG_CA_DATA" "${CA_DATA}"
info ".env updated with K8S_MINIKUBE_TOKEN and K8S_CONFIG_CA_DATA"

# ── 11. Done ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ✅  Kubernetes setup complete!              ║${NC}"
echo -e "${BOLD}║                                              ║${NC}"
echo -e "${BOLD}║  Cluster : ${CONTEXT_NAME}$(printf '%*s' $((34-${#CONTEXT_NAME})) '')║${NC}"
echo -e "${BOLD}║  Token   : written to .env                   ║${NC}"
echo -e "${BOLD}║  CA Data : written to .env                   ║${NC}"
echo -e "${BOLD}║                                              ║${NC}"
echo -e "${BOLD}║  Tip: to open the dashboard tunnel run:      ║${NC}"
echo -e "${BOLD}║  minikube service kubernetes-dashboard \\     ║${NC}"
echo -e "${BOLD}║    -n kubernetes-dashboard --url             ║${NC}"
echo -e "${BOLD}║                                              ║${NC}"
echo -e "${BOLD}║  Start Backstage:                            ║${NC}"
echo -e "${BOLD}║    ./scripts/start-dev.sh                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
