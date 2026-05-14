#!/bin/bash
# run_on_rhel.sh — Deploy CA certs to multiple RHEL servers (FIXED)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_FILE="$SCRIPT_DIR/server.txt"
CERT_DIR="$SCRIPT_DIR/ca-certs"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

# Validate tools
for cmd in sshpass ssh scp; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    exit 1
  }
done

# Validate inputs
[ -f "$SERVER_FILE" ] || { echo "ERROR: server.txt not found"; exit 1; }
[ -d "$CERT_DIR" ] || { echo "ERROR: ca-certs folder not found"; exit 1; }

# Prompt
read -r -p "SSH Admin Username [azureadmin]: " USERNAME
USERNAME="${USERNAME:-azureadmin}"

read -s -p "SSH password for $USERNAME: " SSH_PASSWORD; echo
[[ -z "$SSH_PASSWORD" ]] && { echo "ERROR: Password cannot be empty"; exit 1; }

FAILED_HOSTS=()
SUCCESS_HOSTS=()

# ---- IMPORTANT: Use dedicated file descriptor ----
exec 3< "$SERVER_FILE"

while IFS= read -r HOST <&3; do
    HOST=$(echo "$HOST" | tr -d '\r' | xargs)
    [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

    echo ""
    echo "====== Processing: $HOST ======"

    # ---- Connectivity ----
    echo "  Testing SSH..."
    if ! sshpass -p "$SSH_PASSWORD" ssh $SSH_OPTS "$USERNAME@$HOST" "echo OK" 2>/dev/null | grep -q OK; then
        echo "  ERROR: Cannot connect"
        FAILED_HOSTS+=("$HOST")
        continue
    fi
    echo "  SSH OK"

    # ---- Prepare dir ----
    sshpass -p "$SSH_PASSWORD" ssh $SSH_OPTS "$USERNAME@$HOST" "mkdir -p /tmp/ca-certs" >/dev/null 2>&1

    # ---- Copy certs ----
    echo "  Copying certs..."
    if ! sshpass -p "$SSH_PASSWORD" scp $SSH_OPTS "$CERT_DIR"/*.crt "$USERNAME@$HOST:/tmp/ca-certs/" >/dev/null 2>&1; then
        echo "  ERROR: SCP failed"
        FAILED_HOSTS+=("$HOST")
        continue
    fi
    echo "  Certs copied"

    # ---- Create remote script ----
    WRAPPER=$(mktemp /tmp/install-ca-XXXXXX.sh)
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

    # ---- Copy script ----
    if ! sshpass -p "$SSH_PASSWORD" scp $SSH_OPTS "$WRAPPER" "$USERNAME@$HOST:/tmp/install-ca.sh" >/dev/null 2>&1; then
        echo "  ERROR: Script copy failed"
        rm -f "$WRAPPER"
        FAILED_HOSTS+=("$HOST")
        continue
    fi

    rm -f "$WRAPPER"

    # ---- Execute ----
    echo "  Installing certs..."

    if sshpass -p "$SSH_PASSWORD" ssh $SSH_OPTS "$USERNAME@$HOST" \
      "echo '$SSH_PASSWORD' | sudo -S bash /tmp/install-ca.sh && rm -rf /tmp/install-ca.sh /tmp/ca-certs" >/dev/null 2>&1; then

        echo "  SUCCESS"
        SUCCESS_HOSTS+=("$HOST")
    else
        echo "  ERROR: Install failed"
        FAILED_HOSTS+=("$HOST")
    fi

done

exec 3<&-

# ---- Summary ----
echo ""
echo "=========== SUMMARY ==========="
echo "Success: ${#SUCCESS_HOSTS[@]}"
printf '%s\n' "${SUCCESS_HOSTS[@]}"

echo ""
echo "Failed: ${#FAILED_HOSTS[@]}"
printf '%s\n' "${FAILED_HOSTS[@]}"

[ ${#FAILED_HOSTS[@]} -gt 0 ] && exit 1

echo "All servers processed."