#!/bin/bash
set -euo pipefail

NAMESPACE="jitsi"
VALUES_FILE="$(dirname "$0")/../values/jitsi-values.yaml"

echo "=== [1/5] Creating namespace ==="
kubectl apply -f ../manifests/namespace.yaml

echo "=== [2/5] Adding Helm repos ==="
helm repo add jitsi https://jitsi-contrib.github.io/jitsi-helm/ 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

echo "=== [3/5] Installing ingress-nginx ==="
if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
  echo "ingress-nginx already installed, skipping."
else
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.service.loadBalancerIP=192.168.20.190 \
    --set controller.service.annotations."metallb\\.io/allow-shared-ip"=jitsi-shared
  kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=90s
fi

kubectl annotate service ingress-nginx-controller \
  -n ingress-nginx \
  metallb.io/allow-shared-ip=jitsi-shared \
  --overwrite

echo "=== [4/5] Installing Jitsi Meet ==="
if helm status jitsi -n $NAMESPACE &>/dev/null; then
  echo "Jitsi already installed, upgrading."
  helm upgrade jitsi jitsi/jitsi-meet -n $NAMESPACE -f $VALUES_FILE
else
  helm install jitsi jitsi/jitsi-meet -n $NAMESPACE -f $VALUES_FILE
fi

echo "=== [5/5] Applying supporting manifests ==="
kubectl apply -f ../manifests/jitsi-colibri-ws.yaml
kubectl apply -f ../manifests/jvb-2.yaml

echo "=== Waiting for pods ==="
kubectl rollout status deployment/jitsi-jitsi-meet-web -n $NAMESPACE --timeout=120s
kubectl rollout status deployment/jitsi-jitsi-meet-jicofo -n $NAMESPACE --timeout=120s
kubectl rollout status deployment/jitsi-jitsi-meet-jvb -n $NAMESPACE --timeout=120s

echo ""
echo "=== Done! Jitsi is available at https://vidcall3-prod.transmedika.co.id ==="
echo "=== TLS certificate will be issued automatically by cert-manager. ==="
echo "=== Monitor with: kubectl describe certificate jitsi-tls -n jitsi ==="
echo "=== Run 03-create-user.sh to add moderator accounts (if enableAuth: true) ==="
