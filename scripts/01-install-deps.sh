#!/usr/bin/env bash
# ==============================================================================
# 01-install-deps.sh — Cluster bootstrap (run once on fresh cluster)
#
# Installs: Flannel CNI, local-path-provisioner, MetalLB
# Removes:  control-plane NoSchedule taint so pods can run on both nodes
#
# Run from the scripts/ directory:
#   bash 01-install-deps.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

echo "=== [1/5] Installing Flannel CNI ==="
if kubectl get daemonset kube-flannel-ds -n kube-flannel &>/dev/null; then
  echo "Flannel already installed, skipping."
else
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
fi

echo "=== [2/5] Removing control-plane taint ==="
kubectl taint nodes "$CONTROL_PLANE_NODE" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null \
  || echo "Taint already removed."

echo "=== [3/5] Installing local-path-provisioner ==="
if kubectl get storageclass local-path &>/dev/null; then
  echo "local-path already installed, skipping."
else
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

echo "=== [4/5] Installing MetalLB ==="
if kubectl get namespace metallb-system &>/dev/null; then
  echo "MetalLB already installed, skipping."
else
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
  kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=90s
fi

echo "=== [5/5] Applying MetalLB pool config ==="
envsubst < "$SCRIPT_DIR/../templates/metallb-pool.yaml.tpl" > "$RENDER_DIR/metallb-pool.yaml"
kubectl apply -f "$RENDER_DIR/metallb-pool.yaml"
kubectl apply -f "$SCRIPT_DIR/../manifests/metallb-l2.yaml"

echo ""
echo "=== Done. Run 02-install-jitsi.sh next ==="
