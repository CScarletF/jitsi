#!/usr/bin/env bash
# ==============================================================================
# 02-install-jitsi.sh — Full Jitsi Meet install / upgrade
#
# Installs or upgrades: ingress-nginx, cert-manager, Jitsi Meet (Helm),
# Longhorn PVC, Colibri WebSocket ingress, JVB-2, KEDA, Prometheus
#
# All values are read from config.env at the repo root.
# Templates are rendered via envsubst before applying.
#
# Run from the scripts/ directory:
#   bash 02-install-jitsi.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/config.env"

NAMESPACE="jitsi"
TPL_DIR="$REPO_ROOT/templates"
MANIFEST_DIR="$REPO_ROOT/manifests"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

render() {
  local tpl="$TPL_DIR/$1"
  local out="$RENDER_DIR/$1"
  envsubst < "$tpl" > "$out"
  echo "$out"
}

echo "=== [1/8] Creating namespace ==="
kubectl apply -f "$MANIFEST_DIR/namespace.yaml"

echo "=== [2/8] Adding Helm repos ==="
helm repo add jitsi https://jitsi-contrib.github.io/jitsi-helm/ 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo update

echo "=== [3/8] Installing ingress-nginx ==="
if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
  echo "ingress-nginx already installed, skipping."
else
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.service.loadBalancerIP="$METALLB_VIP" \
    --set controller.service.annotations."metallb\\.io/allow-shared-ip"=jitsi-shared
  kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=90s
fi

kubectl annotate service ingress-nginx-controller \
  -n ingress-nginx \
  metallb.io/allow-shared-ip=jitsi-shared \
  --overwrite

echo "=== [4/8] Installing cert-manager ==="
if helm status cert-manager -n cert-manager &>/dev/null; then
  echo "cert-manager already installed, skipping."
else
  helm install cert-manager jetstack/cert-manager \
    -n cert-manager \
    --create-namespace \
    -f "$(render cert-manager-values.yaml.tpl)"
  kubectl rollout status deployment cert-manager -n cert-manager --timeout=90s
fi

echo "=== [5/8] Applying cert-manager ClusterIssuers ==="
kubectl apply -f "$(render cert-manager-issuer.yaml.tpl)"

echo "=== [6/8] Installing Longhorn ==="
if helm status longhorn -n longhorn-system &>/dev/null; then
  echo "Longhorn already installed, skipping."
else
  helm install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --version 1.7.0
  kubectl rollout status deployment longhorn-driver-deployer -n longhorn-system --timeout=120s
fi

echo "=== [7/8] Installing Prometheus + KEDA ==="
if helm status prometheus -n monitoring &>/dev/null; then
  echo "Prometheus already installed, skipping."
else
  helm install prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring \
    --create-namespace \
    -f "$(render prometheus-values.yaml.tpl)"
fi

if helm status keda -n keda &>/dev/null; then
  echo "KEDA already installed, skipping."
else
  helm install keda kedacore/keda \
    -n keda \
    --create-namespace \
    -f "$(render keda-values.yaml.tpl)"
fi

echo "=== [8/8] Installing Jitsi Meet ==="
JITSI_VALUES="$(render jitsi-values.yaml.tpl)"
if helm status jitsi -n "$NAMESPACE" &>/dev/null; then
  echo "Jitsi already installed, upgrading."
  helm upgrade jitsi jitsi/jitsi-meet -n "$NAMESPACE" -f "$JITSI_VALUES"
else
  helm install jitsi jitsi/jitsi-meet -n "$NAMESPACE" -f "$JITSI_VALUES"
fi

echo "=== Applying supporting manifests ==="
kubectl apply -f "$(render jibri-pvc.yaml.tpl)"
kubectl apply -f "$(render jitsi-colibri-ws.yaml.tpl)"
kubectl apply -f "$(render jvb-2.yaml.tpl)"

echo "=== Waiting for core pods ==="
kubectl rollout status deployment/jitsi-jitsi-meet-web -n "$NAMESPACE" --timeout=120s
kubectl rollout status deployment/jitsi-jitsi-meet-jicofo -n "$NAMESPACE" --timeout=120s
kubectl rollout status deployment/jitsi-jitsi-meet-jvb -n "$NAMESPACE" --timeout=120s

echo ""
echo "=== Done! Jitsi available at https://${DOMAIN} ==="
echo "=== TLS certificate issued automatically by cert-manager ==="
echo "=== Monitor: kubectl describe certificate jitsi-tls -n jitsi ==="
echo "=== Add moderator accounts (if enableAuth: true): bash 03-create-user.sh ==="
