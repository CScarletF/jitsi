#!/bin/bash
set -euo pipefail

echo "=== [1/5] Installing Flannel CNI ==="
if kubectl get daemonset kube-flannel-ds -n kube-flannel &>/dev/null; then
  echo "Flannel already installed, skipping."
else
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
fi

echo "=== [2/5] Removing control-plane taint ==="
kubectl taint nodes srv-deploy-eng node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || echo "Taint already removed."

echo "=== [3/5] Installing local-path-provisioner ==="
if kubectl get storageclass local-path &>/dev/null; then
  echo "local-path already installed, skipping."
else
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
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
kubectl apply -f ../manifests/metallb-pool.yaml
kubectl apply -f ../manifests/metallb-l2.yaml

echo "=== Done. Run 02-install-jitsi.sh next ==="