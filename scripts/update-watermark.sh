#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVG="${SCRIPT_DIR}/../assets/watermark.svg"

if [[ ! -f "$SVG" ]]; then
  echo "ERROR: $SVG not found"
  exit 1
fi

kubectl create configmap jitsi-watermark \
  -n jitsi \
  --from-file=watermark.svg="$SVG" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/jitsi-jitsi-meet-web -n jitsi
kubectl rollout status deployment/jitsi-jitsi-meet-web -n jitsi