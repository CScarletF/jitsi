#!/usr/bin/env bash
# ==============================================================================
# 04-create-hosts.sh — Add local /etc/hosts entry for the Jitsi domain
#
# Maps the MetalLB VIP to the public domain so internal clients can reach
# Jitsi without going through the public DNS/NAT path.
#
# Run on any machine that needs direct internal access:
#   bash 04-create-hosts.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

ENTRY="${METALLB_VIP}  ${DOMAIN}"

if grep -q "$DOMAIN" /etc/hosts; then
  echo "Host entry already exists, skipping."
else
  echo "$ENTRY" | sudo tee -a /etc/hosts
  echo "Added: $ENTRY"
fi

echo ""
echo "=== Also add this line to /etc/hosts on any client machine ==="
echo "$ENTRY"
