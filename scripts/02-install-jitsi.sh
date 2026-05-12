#!/bin/bash
set -euo pipefail

NAMESPACE="jitsi"
TLS_CERT="/home/srv-deploy-eng/jitsi-tls/tls.crt"
TLS_KEY="/home/srv-deploy-eng/jitsi-tls/tls.key"
VALUES_FILE="$(dirname "$0")/../values/jitsi-values.yaml"

echo "=== [1/6] Creating namespace ==="
kubectl apply -f ../manifests/namespace.yaml

echo "=== [2/6] Adding Helm repos ==="
helm repo add jitsi https://jitsi-contrib.github.io/jitsi-helm/ 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

echo "=== [3/6] Installing ingress-nginx ==="
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

echo "=== [4/6] Generating TLS certificate ==="
if kubectl get secret jitsi-tls -n $NAMESPACE &>/dev/null; then
  echo "TLS secret already exists, skipping."
else
  mkdir -p /home/srv-deploy-eng/jitsi-tls
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout $TLS_KEY \
    -out $TLS_CERT \
    -subj "/CN=vidcall3-prod.transmedika.co.id" \
    -addext "subjectAltName=DNS:vidcall3-prod.transmedika.co.id"
  kubectl create secret tls jitsi-tls \
    --cert=$TLS_CERT \
    --key=$TLS_KEY \
    -n $NAMESPACE
fi

echo "=== [5/6] Installing Jitsi Meet ==="
if helm status jitsi -n $NAMESPACE &>/dev/null; then
  echo "Jitsi already installed, upgrading."
  helm upgrade jitsi jitsi/jitsi-meet -n $NAMESPACE -f $VALUES_FILE
else
  helm install jitsi jitsi/jitsi-meet -n $NAMESPACE -f $VALUES_FILE
fi

echo "=== [6/6] Applying supporting manifests ==="
kubectl apply -f ../manifests/jitsi-colibri-ws.yaml
kubectl apply -f ../manifests/jitsi-hpa.yaml

echo "=== Waiting for pods ==="
kubectl rollout status deployment jitsi-jitsi-meet-web -n $NAMESPACE --timeout=120s
kubectl rollout status deployment jitsi-jitsi-meet-jicofo -n $NAMESPACE --timeout=120s
kubectl rollout status deployment jitsi-jitsi-meet-jvb-0 -n $NAMESPACE --timeout=120s

echo ""
echo "=== Done! Jitsi is available at https://vidcall3-prod.transmedika.co.id ==="
echo "=== Run 03-create-user.sh to add moderator accounts ==="
