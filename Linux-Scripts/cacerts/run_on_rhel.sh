#!/bin/bash
# Deploy CA certs to multiple RHEL servers (FINAL STABLE)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_FILE="$SCRIPT_DIR/server.txt"
CERT_DIR="$SCRIPT_DIR/ca-certs"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

# ---- Validate tools ----
for cmd in sshpass ssh scp; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    exit 1
  }
done

# ---- Validate inputs ----
[ -f "$SERVER_FILE" ] || { echo "ERROR: server.txt not found at $SERVER_FILE"; exit 1; }
[ -d "$CERT_DIR" ] || { echo "ERROR: ca-certs folder not found at $CERT_DIR"; exit 1; }

echo "Using server file: $SERVER_FILE"
echo "Using cert folder: $CERT_DIR"

# ---- Prompt ----
read -r -p "SSH Admin Username [azureadmin]: " USERNAME
USERNAME="${USERNAME:-azureadmin}"

read -s -p "SSH password for $USERNAME: " SSH_PASSWORD; echo
[[ -z "$SSH_PASSWORD" ]] && { echo "ERROR: Password cannot be empty"; exit 1; }

FAILED_HOSTS=()
SUCCESS_HOSTS=()

# ---- Main loop (FIXED) ----
while IFS= read -r HOST || [[ -n "$HOST" ]]; do

    HOST=$(echo "$HOST" | tr -d '\r' | xargs)

    # Skip empty/comment lines
    [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

    echo ""
    echo "====== Processing: $HOST ======"

    # ---- SSH check ----
    echo "  Testing SSH..."
    if ! sshpass -p "$SSH_PASSWORD" ssh -n $SSH_OPTS "$USERNAME@$HOST" "echo OK" 2>/dev/null | grep -q OK; then
        echo "  ERROR: Cannot connect"
        FAILED_HOSTS+=("$HOST")
        continue
    fi
    echo "  SSH OK"

    # ---- Prepare directory ----
    sshpass -p "$SSH_PASSWORD" ssh -n $SSH_OPTS "$USERNAME@$HOST" "mkdir -p /tmp/ca-certs"

    # ---- Try SCP ----
    echo "  Copying certs (SCP)..."
    if sshpass -p "$SSH_PASSWORD" scp $SSH_OPTS "$CERT_DIR"/*.crt "$USERNAME@$HOST:/tmp/ca-certs/"; then
        echo "  SCP success"
    else
        echo "  SCP failed → fallback to SSH streaming"

        for file in "$CERT_DIR"/*.crt; do
            fname=$(basename "$file")

            if ! sshpass -p "$SSH_PASSWORD" ssh -n $SSH_OPTS "$USERNAME@$HOST" \
                "cat > /tmp/ca-certs/$fname" < "$file"; then
                echo "  ERROR: Failed to copy $fname"
                FAILED_HOSTS+=("$HOST")
                continue 2
            fi
        done

        echo "  Fallback copy success"
    fi

    # ---- Create remote install script ----
    WRAPPER=$(mktemp)
    chmod 600 "$WRAPPER"

    cat << 'EOF' > "$WRAPPER"
#!/bin/bash
set -euo pipefail

CERT_SRC="/tmp/ca-certs"
ANCHOR_DIR="/etc/pki/ca-trust/source/anchors"

echo "Installing CA certs..."

cp "$CERT_SRC"/*.crt "$ANCHOR_DIR"/
chmod 644 "$ANCHOR_DIR"/*.crt

update-ca-trust extract

echo "Done."
EOF

    # ---- Copy installer ----
    if ! sshpass -p "$SSH_PASSWORD" scp $SSH_OPTS "$WRAPPER" "$USERNAME@$HOST:/tmp/install-ca.sh"; then
        echo "  ERROR: Failed to copy install script"
        rm -f "$WRAPPER"
        FAILED_HOSTS+=("$HOST")
        continue
    fi

    rm -f "$WRAPPER"

    # ---- Execute ----
    echo "  Installing certificates..."

    if sshpass -p "$SSH_PASSWORD" ssh -n $SSH_OPTS "$USERNAME@$HOST" \
      "echo '$SSH_PASSWORD' | sudo -S bash /tmp/install-ca.sh && rm -rf /tmp/install-ca.sh /tmp/ca-certs"; then

        echo "  SUCCESS"
        SUCCESS_HOSTS+=("$HOST")
    else
        echo "  ERROR: Installation failed"
        FAILED_HOSTS+=("$HOST")
    fi

done < "$SERVER_FILE"

# ---- Summary ----
echo ""
echo "=========== SUMMARY ==========="
echo "Success: ${#SUCCESS_HOSTS[@]}"
printf '%s\n' "${SUCCESS_HOSTS[@]}"

echo ""
echo "Failed: ${#FAILED_HOSTS[@]}"
printf '%s\n' "${FAILED_HOSTS[@]}"

[ ${#FAILED_HOSTS[@]} -gt 0 ] && exit 1

echo "All servers processed successfully."