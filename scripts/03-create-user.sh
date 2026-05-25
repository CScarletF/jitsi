#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <username> <password>"
  echo "Example: $0 admin secretpassword"
  exit 1
fi

USERNAME=$1
PASSWORD=$2
NAMESPACE="jitsi"

echo "=== Creating Prosody user: $USERNAME ==="
kubectl exec -n $NAMESPACE jitsi-jitsi-meet-prosody-0 -- \
  prosodyctl --config /config/prosody.cfg.lua \
  register "$USERNAME" meet.jitsi "$PASSWORD"

echo "=== User $USERNAME created successfully ==="