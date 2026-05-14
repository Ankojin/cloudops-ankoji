#!/bin/bash
set -euo pipefail

CERT_DIR="/tmp/ca-certs"

echo "Installing certificates from $CERT_DIR ..."

# Validate directory
[ -d "$CERT_DIR" ] || { echo "ERROR: $CERT_DIR not found"; exit 1; }

# Copy certs to anchors
cp "$CERT_DIR"/*.crt /etc/pki/ca-trust/source/anchors/

# Set proper permissions
chmod 644 /etc/pki/ca-trust/source/anchors/*.crt

# Update trust store
update-ca-trust extract

echo "Trust store updated successfully."

# Optional verification
echo "Verifying installed certs:"
trust list | grep -i "ca" || true