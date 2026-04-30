#!/bin/bash
set -euo pipefail

ENTRY="192.168.20.190  vidcall3.internal"

if grep -q "vidcall3.internal" /etc/hosts; then
  echo "Host entry already exists, skipping."
else
  echo "$ENTRY" | sudo tee -a /etc/hosts
  echo "Added: $ENTRY"
fi

echo ""
echo "=== Also add this line to /etc/hosts on any client machine ==="
echo "$ENTRY"