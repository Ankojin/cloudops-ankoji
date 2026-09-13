#!/bin/bash

# ============================================================

# collect-oracle-autostart.sh

#

# READ-ONLY Oracle auto-start inventory collector

# ============================================================

USERNAME="azureadmin"

SERVER_FILE="server.txt"
REMOTE_SCRIPT="oracle-autostart-check.sh"

REMOTE_SCRIPT_PATH="/tmp/oracle-autostart-check.sh"
REMOTE_RESULT_PATH="/tmp/oracle-autostart-result.txt"
current_date=$(date +"%Y-%m-%d")
OUTPUT_CSV="oracle-autostart-inventory-$current_date.csv"
RAW_LOG="oracle-autostart-raw.log"

# ============================================================

# VALIDATION

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

# PASSWORD

# ============================================================

read -s -p "Enter SSH/SUDO password: " PASSWORD
echo
echo

# ============================================================

# OUTPUT

# ============================================================

echo 'Server,RHEL_Version,Oracle_User,Oracle_Group,Oracle_SIDs,Oracle_Homes,Oratab_Y_Count,DBStart_Status,DBShut_Status,Service_Status,Service_Enabled,Service_Active,Listener_Status,PMON_Status,Recommendation' > "$OUTPUT_CSV"

: > "$RAW_LOG"

TOTAL=0
SUCCESS=0
FAILED=0

NO_ACTION=0
ENABLE_REQUIRED=0
REVIEW=0

# ============================================================

# PROCESS SERVERS

# ============================================================

while IFS= read -r HOST || [ -n "$HOST" ]
do

HOST=$(printf '%s' "$HOST" | tr -d '\r' | xargs)

[ -z "$HOST" ] && continue

case "$HOST" in
    \#*)
        continue
        ;;
esac

TOTAL=$((TOTAL + 1))

echo
echo "============================================================"
echo "SERVER: $HOST"
echo "============================================================"

# --------------------------------------------------------
# Copy remote script
# --------------------------------------------------------

echo "Copying collector..."

sshpass -p "$PASSWORD" scp \
    -q \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    "$REMOTE_SCRIPT" \
    "$USERNAME@$HOST:$REMOTE_SCRIPT_PATH"

if [ $? -ne 0 ]; then

    echo "SCP FAILED: $HOST"

    FAILED=$((FAILED + 1))

    echo "\"$HOST\",\"SSH_FAILED\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"N/A\",\"SSH_FAILED\"" >> "$OUTPUT_CSV"

    echo "$HOST : SCP FAILED" >> "$RAW_LOG"

    continue

fi

# --------------------------------------------------------
# Execute remote script as root
# --------------------------------------------------------

echo "Executing collector..."

sshpass -p "$PASSWORD" ssh \
    -n \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    "$USERNAME@$HOST" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash '$REMOTE_SCRIPT_PATH'"

if [ $? -ne 0 ]; then

    echo "REMOTE EXECUTION FAILED: $HOST"

    FAILED=$((FAILED + 1))

    echo "$HOST : REMOTE EXECUTION FAILED" >> "$RAW_LOG"

    continue

fi

# --------------------------------------------------------
# Retrieve result using sudo + base64
#
# This avoids requiring the remote result file to be
# readable by azureadmin.
# --------------------------------------------------------

LOCAL_RESULT="/tmp/oracle-autostart-result-$HOST.txt"

sshpass -p "$PASSWORD" ssh \
    -n \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    "$USERNAME@$HOST" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' base64 '$REMOTE_RESULT_PATH'" \
    | base64 -d > "$LOCAL_RESULT"

if [ $? -ne 0 ] || [ ! -s "$LOCAL_RESULT" ]; then

    echo "RESULT RETRIEVAL FAILED: $HOST"

    FAILED=$((FAILED + 1))

    echo "$HOST : RESULT RETRIEVAL FAILED" >> "$RAW_LOG"

    rm -f "$LOCAL_RESULT"

    continue

fi

# --------------------------------------------------------
# Validate result
# --------------------------------------------------------

if ! grep -q '^SERVER=' "$LOCAL_RESULT"; then

    echo "INVALID RESULT: $HOST"

    FAILED=$((FAILED + 1))

    echo "$HOST : INVALID RESULT" >> "$RAW_LOG"

    rm -f "$LOCAL_RESULT"

    continue

fi

SUCCESS=$((SUCCESS + 1))

# --------------------------------------------------------
# Read result
# --------------------------------------------------------

RHEL_VERSION=$(grep '^RHEL_VERSION=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
ORACLE_USER=$(grep '^ORACLE_USER=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
ORACLE_GROUP=$(grep '^ORACLE_GROUP=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
ORACLE_SIDS=$(grep '^ORACLE_SIDS=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
ORACLE_HOMES=$(grep '^ORACLE_HOMES=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
ORATAB_Y_COUNT=$(grep '^ORATAB_Y_COUNT=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
DBSTART_STATUS=$(grep '^DBSTART_STATUS=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
DBSHUT_STATUS=$(grep '^DBSHUT_STATUS=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
SERVICE_STATUS=$(grep '^SERVICE_STATUS=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
SERVICE_ENABLED=$(grep '^SERVICE_ENABLED=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
SERVICE_ACTIVE=$(grep '^SERVICE_ACTIVE=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
LISTENER_STATUS=$(grep '^LISTENER_STATUS=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
PMON_STATUS=$(grep '^PMON_STATUS=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)
RECOMMENDATION=$(grep '^RECOMMENDATION=' "$LOCAL_RESULT" | head -1 | cut -d= -f2-)

# --------------------------------------------------------
# Count recommendation
# --------------------------------------------------------

case "$RECOMMENDATION" in
    NO_ACTION)
        NO_ACTION=$((NO_ACTION + 1))
        ;;
    ENABLE_REQUIRED)
        ENABLE_REQUIRED=$((ENABLE_REQUIRED + 1))
        ;;
    REVIEW)
        REVIEW=$((REVIEW + 1))
        ;;
esac

# --------------------------------------------------------
# Display
# --------------------------------------------------------

echo
echo "RHEL Version    : $RHEL_VERSION"
echo "Oracle User     : $ORACLE_USER"
echo "Oracle Group    : $ORACLE_GROUP"
echo "Oracle SID(s)   : $ORACLE_SIDS"
echo "Oracle Home(s)  : $ORACLE_HOMES"
echo "oratab Y Count  : $ORATAB_Y_COUNT"
echo "dbstart         : $DBSTART_STATUS"
echo "dbshut          : $DBSHUT_STATUS"
echo "Service         : $SERVICE_STATUS"
echo "Service Enabled : $SERVICE_ENABLED"
echo "Service Active  : $SERVICE_ACTIVE"
echo "Listener        : $LISTENER_STATUS"
echo "PMON            : $PMON_STATUS"
echo "Recommendation  : $RECOMMENDATION"

# --------------------------------------------------------
# Raw log
# --------------------------------------------------------

{
    echo "SERVER: $HOST"
    cat "$LOCAL_RESULT"
    echo "------------------------------------------------------------"
} >> "$RAW_LOG"

# --------------------------------------------------------
# CSV
# --------------------------------------------------------

echo "\"$HOST\",\"$RHEL_VERSION\",\"$ORACLE_USER\",\"$ORACLE_GROUP\",\"$ORACLE_SIDS\",\"$ORACLE_HOMES\",\"$ORATAB_Y_COUNT\",\"$DBSTART_STATUS\",\"$DBSHUT_STATUS\",\"$SERVICE_STATUS\",\"$SERVICE_ENABLED\",\"$SERVICE_ACTIVE\",\"$LISTENER_STATUS\",\"$PMON_STATUS\",\"$RECOMMENDATION\"" >> "$OUTPUT_CSV"

rm -f "$LOCAL_RESULT"

# --------------------------------------------------------
# Cleanup remote files
# --------------------------------------------------------

sshpass -p "$PASSWORD" ssh \
    -n \
    -o StrictHostKeyChecking=no \
    "$USERNAME@$HOST" \
    "rm -f '$REMOTE_SCRIPT_PATH' '$REMOTE_RESULT_PATH'" \
    >/dev/null 2>&1

done < "$SERVER_FILE"

# ============================================================

# SUMMARY

# ============================================================

echo
echo "============================================================"
echo "COLLECTION COMPLETED"
echo "============================================================"

echo
echo "Total servers      : $TOTAL"
echo "Successful         : $SUCCESS"
echo "Failed             : $FAILED"

echo
echo "NO_ACTION          : $NO_ACTION"
echo "ENABLE_REQUIRED    : $ENABLE_REQUIRED"
echo "REVIEW             : $REVIEW"

echo
echo "Inventory CSV:"
echo "  $OUTPUT_CSV"

echo
echo "Raw log:"
echo "  $RAW_LOG"

echo
echo "============================================================"
echo "NO REMOTE CONFIGURATION CHANGES WERE MADE"
echo "============================================================"