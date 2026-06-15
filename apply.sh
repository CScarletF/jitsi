#!/usr/bin/env bash
# ==============================================================================
# apply.sh — Jitsi Meet deployment orchestrator
# ==============================================================================
# Sources config.env, renders all .tpl templates via envsubst, and applies
# them to the cluster. Run this instead of calling helm/kubectl directly.
#
# Usage:
#   bash apply.sh [component]
#
# Components:
#   all         — full deploy/upgrade (default)
#   jitsi       — Helm upgrade for Jitsi only
#   manifests   — kubectl apply for all manifests only
#   jibri-pvc   — apply Longhorn PVC for Jibri recordings
#   colibri-ws  — apply Colibri WebSocket ingress
#   certissuer  — apply cert-manager ClusterIssuers
#
# Examples:
#   bash apply.sh             # full upgrade
#   bash apply.sh jitsi       # Helm upgrade only
#   bash apply.sh jibri-pvc   # apply Longhorn PVC only
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
CONFIG="$REPO_ROOT/config.env"
TPL_DIR="$REPO_ROOT/templates"
MANIFEST_DIR="$REPO_ROOT/manifests"
VALUES_DIR="$REPO_ROOT/values"
RENDER_DIR="$(mktemp -d)"

# Cleanup rendered temp files on exit
trap 'rm -rf "$RENDER_DIR"' EXIT

# ------------------------------------------------------------------------------
# Load config
# ------------------------------------------------------------------------------
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.env not found at $CONFIG"
  exit 1
fi
set -a
source "$CONFIG"
set +a
echo "=== Loaded config.env ==="

# ------------------------------------------------------------------------------
# Render a .tpl file via envsubst into RENDER_DIR
# render_tpl <template_path> <output_filename>
# ------------------------------------------------------------------------------
render_tpl() {
  local tpl="$1"
  local out="$RENDER_DIR/$2"
  envsubst "$(cat "$CONFIG" | grep -v '^#' | grep -v '^$' | cut -d= -f1 | sed 's/^/$/g' | tr '\n' ' ')" < "$tpl" > "$out"
  echo "    Rendered: $2" >&2
  echo "$out"
}

# ------------------------------------------------------------------------------
# Component: jibri-pvc
# ------------------------------------------------------------------------------
apply_jibri_pvc() {
  echo "=== Applying Jibri Longhorn PVC ==="
  local out
  out=$(render_tpl "$TPL_DIR/jibri-pvc.yaml.tpl" "jibri-pvc.yaml")
  kubectl apply -f "$out"
}

# ------------------------------------------------------------------------------
# Component: colibri-ws
# ------------------------------------------------------------------------------
apply_colibri_ws() {
  echo "=== Applying Colibri WebSocket ingress ==="
  local out
  out=$(render_tpl "$TPL_DIR/jitsi-colibri-ws.yaml.tpl" "jitsi-colibri-ws.yaml")
  kubectl apply -f "$out"
}

# ------------------------------------------------------------------------------
# Component: certissuer
# ------------------------------------------------------------------------------
apply_cert_issuer() {
  echo "=== Applying cert-manager ClusterIssuers ==="
  local out
  out=$(render_tpl "$TPL_DIR/cert-manager-issuer.yaml.tpl" "cert-manager-issuer.yaml")
  kubectl apply -f "$out"
}

# ------------------------------------------------------------------------------
# Component: metallb
# ------------------------------------------------------------------------------
apply_metallb() {
  echo "=== Applying MetalLB pool ==="
  local out
  out=$(render_tpl "$TPL_DIR/metallb-pool.yaml.tpl" "metallb-pool.yaml")
  kubectl apply -f "$out"
  kubectl apply -f "$MANIFEST_DIR/metallb-l2.yaml"
}

# ------------------------------------------------------------------------------
# Component: jitsi (Helm upgrade)
# ------------------------------------------------------------------------------
apply_jitsi() {
  echo "=== Rendering jitsi-values.yaml ==="
  local out
  out=$(render_tpl "$TPL_DIR/jitsi-values.yaml.tpl" "jitsi-values.yaml")
  echo "=== Running helm upgrade ==="
  helm upgrade jitsi jitsi/jitsi-meet \
    --version 2.16.0 \
    -n jitsi \
    --create-namespace \
    -f "$out"
  echo "=== Helm upgrade complete ==="
}

# ------------------------------------------------------------------------------
# Component: manifests (all non-Helm manifests)
# ------------------------------------------------------------------------------
apply_manifests() {
  apply_jibri_pvc
  apply_colibri_ws
  apply_cert_issuer
  apply_metallb
  kubectl apply -f "$MANIFEST_DIR/namespace.yaml"
  kubectl apply -f "$MANIFEST_DIR/jvb-2.yaml"
}

# ------------------------------------------------------------------------------
# Component: all
# ------------------------------------------------------------------------------
apply_all() {
  apply_manifests
  apply_jitsi
  echo ""
  echo "=== All components applied ==="
  echo "=== Jitsi available at https://${DOMAIN} ==="
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------
COMPONENT="${1:-all}"

case "$COMPONENT" in
  all)         apply_all ;;
  jitsi)       apply_jitsi ;;
  manifests)   apply_manifests ;;
  jibri-pvc)   apply_jibri_pvc ;;
  colibri-ws)  apply_colibri_ws ;;
  certissuer)  apply_cert_issuer ;;
  metallb)     apply_metallb ;;
  *)
    echo "ERROR: Unknown component '$COMPONENT'"
    echo "Valid: all, jitsi, manifests, jibri-pvc, colibri-ws, certissuer, metallb"
    exit 1
    ;;
esac
