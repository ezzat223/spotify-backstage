#!/bin/bash
set -e

echo "🚀 Backstage + Minikube Setup"
echo "================================"

# ── 1. Create namespace ──────────────────────────────────────────────
echo ""
echo "📦 Creating backstage namespace..."
kubectl create namespace backstage 2>/dev/null && \
  echo "✅ Namespace created" || \
  echo "⚠️  Namespace already exists, skipping"

# ── 2. Create Service Account ────────────────────────────────────────
echo ""
echo "👤 Creating service account..."
kubectl create serviceaccount backstage -n backstage 2>/dev/null && \
  echo "✅ Service account created" || \
  echo "⚠️  Service account already exists, skipping"

# ── 3. Bind ClusterAdmin Role ─────────────────────────────────────────
echo ""
echo "🔐 Binding cluster-admin role..."
cat <<EOF | kubectl apply -f - > /dev/null
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
echo "✅ ClusterRoleBinding applied"

# ── 4. Create long-lived token Secret ────────────────────────────────
echo ""
echo "🔑 Creating service account token secret..."
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: Secret
metadata:
  name: backstage-token
  namespace: backstage
  annotations:
    kubernetes.io/service-account.name: backstage
type: kubernetes.io/service-account-token
EOF

# Wait for the token to be populated by the controller
echo "⏳ Waiting for token to be issued..."
for i in {1..10}; do
  TOKEN=$(kubectl get secret backstage-token -n backstage \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode)
  if [ -n "$TOKEN" ]; then
    echo "✅ Token issued"
    break
  fi
  sleep 1
done

if [ -z "$TOKEN" ]; then
  echo "❌ Token was not issued after 10s. Check your cluster."
  exit 1
fi

# ── 5. Extract CA Data ────────────────────────────────────────────────
echo ""
echo "🔒 Extracting CA certificate data..."
CA_FILE=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="spotify-backstage")].cluster.certificate-authority}')
          kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="spotify-backstage")].cluster.certificate-authority}'
if [ -z "$CA_FILE" ]; then
  echo "❌ Could not find spotify-backstage CA file path in kubeconfig."
  exit 1
fi

CA_DATA=$(cat "$CA_FILE" | base64 -w 0)

if [ -z "$CA_DATA" ]; then
  echo "❌ CA file found at $CA_FILE but could not be read or encoded."
  exit 1
fi

echo "✅ CA data extracted from: $CA_FILE"

# ── 6. Write .env ─────────────────────────────────────────────────────
echo ""
echo "📝 Writing .env file..."
cat > .env <<EOF
K8S_MINIKUBE_TOKEN=${TOKEN}
K8S_CONFIG_CA_DATA=${CA_DATA}
EOF
echo "✅ .env written with token and CA data"

# ── 7. Get Cluster URL ────────────────────────────────────────────────
MINIKUBE_URL=$(kubectl config view --raw --minify \
  --output='jsonpath={.clusters[0].cluster.server}')

# ── 8. Final Instructions ─────────────────────────────────────────────
echo ""
echo "================================"
echo "✅ All done! One manual step left:"
echo ""
echo "   In your app-config.yaml, set:"
echo ""
echo "       url: ${MINIKUBE_URL}"
echo ""
echo "   Then start Backstage with:"
echo ""
echo "       yarn start"
echo "================================"
