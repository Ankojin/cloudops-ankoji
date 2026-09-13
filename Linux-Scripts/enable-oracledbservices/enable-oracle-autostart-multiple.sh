#!/bin/bash

# ============================================================
# Script : enable-oracle-autostart-multiple.sh
#
# Purpose:
# Enable Oracle DB/Listener automatic startup on multiple
# RHEL servers.
#
# Requirements:
#   sshpass
#
# Remote changes:
#   - Backup /etc/oratab
#   - Change existing Oracle entries N -> Y
#   - Create oracle-db.service
#   - daemon-reload
#   - enable oracle-db.service
#
# IMPORTANT:
#   - If oracle user does not exist -> REVIEW / SKIP
#   - If /etc/oratab has NO SID -> REVIEW / SKIP
#   - Existing N entries are changed to Y
#   - No SID is invented
#   - Existing enabled service is NOT modified
#   - Service is NOT started
#   - No database restart
#   - No server reboot
#
# ============================================================

set -u

USERNAME="azureadmin"
SERVER_FILE="server.txt"

REMOTE_SCRIPT="oracle-autostart-enable-remote.sh"
REMOTE_SCRIPT_PATH="/tmp/oracle-autostart-enable-remote.sh"
REMOTE_RESULT_PATH="/tmp/oracle-autostart-enable-result.txt"

LOG_FILE="oracle-autostart-execution.log"
RESULT_CSV="oracle-autostart-execution-results.csv"

# ============================================================
# Validation
# ============================================================

if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is not installed."
    exit 1
fi

if [ ! -f "$SERVER_FILE" ]; then
    echo "ERROR: $SERVER_FILE not found."
    exit 1
fi

if [ ! -f "$REMOTE_SCRIPT" ]; then
    echo "ERROR: $REMOTE_SCRIPT not found."
    exit 1
fi

# ============================================================
# Password
# ============================================================

read -s -p "Enter SSH password: " PASSWORD
echo
echo

# ============================================================
# Initialize
# ============================================================

: > "$LOG_FILE"

echo "Server,Result,Reason,Oracle_SIDs,Oracle_Homes,Service_Enabled,Service_Active" \
    > "$RESULT_CSV"

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ============================================================
# Process servers
# ============================================================

while IFS= read -r HOST || [[ -n "$HOST" ]]
do

    HOST=$(echo "$HOST" | tr -d '\r' | xargs)

    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue

    echo

    log "============================================================"
    log "Processing server: $HOST"
    log "============================================================"

    # ========================================================
    # 1. Copy remote script
    # ========================================================

    log "Copying remote enable script..."

    sshpass -p "$PASSWORD" scp \
        -q \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "$REMOTE_SCRIPT" \
        "$USERNAME@$HOST:$REMOTE_SCRIPT_PATH"

    SCP_RC=$?

    if [ "$SCP_RC" -ne 0 ]; then

        log "$HOST : SCP FAILED"

        echo "\"$HOST\",\"FAILED\",\"SCP_FAILED\",\"N/A\",\"N/A\",\"N/A\",\"N/A\"" \
            >> "$RESULT_CSV"

        continue
    fi

    # ========================================================
    # 2. Execute remote script
    #
    # sudo password is supplied separately.
    # Remote script is already copied to the server.
    # ========================================================

    log "Executing remote enable script..."

    sshpass -p "$PASSWORD" ssh \
        -n \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "$USERNAME@$HOST" \
        "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash '$REMOTE_SCRIPT_PATH'"

    REMOTE_RC=$?

    if [ "$REMOTE_RC" -ne 0 ]; then

        log "$HOST : REMOTE SCRIPT FAILED (RC=$REMOTE_RC)"

        echo "\"$HOST\",\"FAILED\",\"REMOTE_SCRIPT_FAILED_RC_$REMOTE_RC\",\"N/A\",\"N/A\",\"N/A\",\"N/A\"" \
            >> "$RESULT_CSV"

        # Try to retrieve debug information if available
        sshpass -p "$PASSWORD" ssh \
            -n \
            -o StrictHostKeyChecking=no \
            "$USERNAME@$HOST" \
            "sudo -n cat /tmp/oracle-autostart-enable-debug.log 2>/dev/null" \
            >> "$LOG_FILE" 2>&1 || true

        continue
    fi

    # ========================================================
    # 3. Retrieve result file
    # ========================================================

    LOCAL_RESULT="/tmp/oracle-autostart-enable-result-$HOST.txt"

    rm -f "$LOCAL_RESULT"

    log "Retrieving result..."

    sshpass -p "$PASSWORD" scp \
        -q \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "$USERNAME@$HOST:$REMOTE_RESULT_PATH" \
        "$LOCAL_RESULT"

    RESULT_RC=$?

    if [ "$RESULT_RC" -ne 0 ]; then

        log "$HOST : RESULT RETRIEVAL FAILED"

        echo "\"$HOST\",\"FAILED\",\"RESULT_RETRIEVAL_FAILED\",\"N/A\",\"N/A\",\"N/A\",\"N/A\"" \
            >> "$RESULT_CSV"

        continue
    fi

    # ========================================================
    # 4. Validate result file
    # ========================================================

    if [ ! -s "$LOCAL_RESULT" ]; then

        log "$HOST : EMPTY RESULT FILE"

        echo "\"$HOST\",\"FAILED\",\"EMPTY_REMOTE_RESULT\",\"N/A\",\"N/A\",\"N/A\",\"N/A\"" \
            >> "$RESULT_CSV"

        rm -f "$LOCAL_RESULT"

        continue
    fi

    log "Remote result received:"
    cat "$LOCAL_RESULT"

    # ========================================================
    # 5. Read result values
    # ========================================================

    RESULT_CODE=$(grep '^RESULT_CODE=' "$LOCAL_RESULT" | cut -d= -f2-)
    REASON=$(grep '^REASON=' "$LOCAL_RESULT" | cut -d= -f2-)
    ORACLE_SIDS=$(grep '^ORACLE_SIDS=' "$LOCAL_RESULT" | cut -d= -f2-)
    ORACLE_HOMES=$(grep '^ORACLE_HOMES=' "$LOCAL_RESULT" | cut -d= -f2-)
    SERVICE_ENABLED=$(grep '^SERVICE_ENABLED=' "$LOCAL_RESULT" | cut -d= -f2-)
    SERVICE_ACTIVE=$(grep '^SERVICE_ACTIVE=' "$LOCAL_RESULT" | cut -d= -f2-)

    # ========================================================
    # 6. Validate result
    # ========================================================

    if [ -z "$RESULT_CODE" ]; then

        log "$HOST : INVALID REMOTE RESULT"

        echo "\"$HOST\",\"FAILED\",\"INVALID_REMOTE_RESULT\",\"N/A\",\"N/A\",\"N/A\",\"N/A\"" \
            >> "$RESULT_CSV"

        rm -f "$LOCAL_RESULT"

        continue
    fi

    [ -z "$REASON" ] && REASON="N/A"
    [ -z "$ORACLE_SIDS" ] && ORACLE_SIDS="N/A"
    [ -z "$ORACLE_HOMES" ] && ORACLE_HOMES="N/A"
    [ -z "$SERVICE_ENABLED" ] && SERVICE_ENABLED="N/A"
    [ -z "$SERVICE_ACTIVE" ] && SERVICE_ACTIVE="N/A"

    # ========================================================
    # 7. Display result
    # ========================================================

    echo
    echo "Server          : $HOST"
    echo "Result          : $RESULT_CODE"
    echo "Reason          : $REASON"
    echo "Oracle SID(s)   : $ORACLE_SIDS"
    echo "Oracle Home(s)  : $ORACLE_HOMES"
    echo "Service Enabled : $SERVICE_ENABLED"
    echo "Service Active  : $SERVICE_ACTIVE"
    echo

    log "$HOST : $RESULT_CODE - $REASON"

    # ========================================================
    # 8. CSV
    # ========================================================

    echo "\"$HOST\",\"$RESULT_CODE\",\"$REASON\",\"$ORACLE_SIDS\",\"$ORACLE_HOMES\",\"$SERVICE_ENABLED\",\"$SERVICE_ACTIVE\"" \
        >> "$RESULT_CSV"

    # ========================================================
    # 9. Cleanup
    # ========================================================

    rm -f "$LOCAL_RESULT"

    sshpass -p "$PASSWORD" ssh \
        -n \
        -o StrictHostKeyChecking=no \
        "$USERNAME@$HOST" \
        "rm -f '$REMOTE_SCRIPT_PATH' '$REMOTE_RESULT_PATH' /tmp/oracle-autostart-enable-debug.log" \
        >/dev/null 2>&1 || true

done < "$SERVER_FILE"

# ============================================================
# Summary
# ============================================================

echo

log "============================================================"
log "Execution completed"
log "============================================================"

echo
echo "Results:"
cat "$RESULT_CSV"

echo
echo "Result summary:"

awk -F',' '
NR > 1 {
    value=$2
    gsub(/"/, "", value)
    count[value]++
}
END {
    for (x in count)
        print "  " x ": " count[x]
}
' "$RESULT_CSV"

echo
echo "CSV Result : $RESULT_CSV"
echo "Log File   : $LOG_FILE"
echo

log "No server reboot was performed."
log "No Oracle service was started by this script."
log "Existing enabled oracle-db.service was not modified."
