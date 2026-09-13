#!/bin/bash

RESULT_FILE="/tmp/oracle-autostart-result.txt"
DEBUG_FILE="/tmp/oracle-autostart-debug.log"

ORATAB="/etc/oratab"
SERVICE="oracle-db.service"

rm -f "$RESULT_FILE" "$DEBUG_FILE"

echo "===== START $(date) =====" > "$DEBUG_FILE"
echo "Running as: $(id)" >> "$DEBUG_FILE"

# ============================================================

# SERVER

# ============================================================

SERVER=$(hostname -s)

# ============================================================

# RHEL VERSION

# ============================================================

if [ -f /etc/redhat-release ]; then
RHEL_VERSION=$(cat /etc/redhat-release)
else
RHEL_VERSION="UNKNOWN"
fi

# ============================================================

# ORACLE USER / GROUP

# ============================================================

if id oracle >/dev/null 2>&1; then
ORACLE_USER="YES"
ORACLE_GROUP=$(id -gn oracle)
else
ORACLE_USER="NO"
ORACLE_GROUP="N/A"
fi

# ============================================================

# DEFAULT VALUES

# ============================================================

ORACLE_SIDS="N/A"
ORACLE_HOMES="N/A"
ORATAB_Y_COUNT=0

DBSTART_STATUS="N/A"
DBSHUT_STATUS="N/A"

# ============================================================

# READ /etc/oratab

# ============================================================

echo "Checking /etc/oratab..." >> "$DEBUG_FILE"

if [ -f "$ORATAB" ]; then

echo "/etc/oratab exists" >> "$DEBUG_FILE"

# Temporary files avoid command-substitution/heredoc problems
ORATAB_TMP="/tmp/oracle-oratab-y-$$.tmp"

rm -f "$ORATAB_TMP"

grep -v '^#' "$ORATAB" 2>/dev/null |
grep ':' 2>/dev/null |
while IFS=: read -r SID HOME FLAG REST
do
    [ -z "$SID" ] && continue

    case "$FLAG" in
        Y|y)
            printf '%s:%s:%s\n' "$SID" "$HOME" "$FLAG"
            ;;
    esac
done > "$ORATAB_TMP"

echo "Matching Y entries:" >> "$DEBUG_FILE"
cat "$ORATAB_TMP" >> "$DEBUG_FILE"

if [ -s "$ORATAB_TMP" ]; then

    ORATAB_Y_COUNT=$(grep -c '.' "$ORATAB_TMP")

    ORACLE_SIDS=$(cut -d: -f1 "$ORATAB_TMP" | paste -sd ';' -)

    ORACLE_HOMES=$(cut -d: -f2 "$ORATAB_TMP" | sort -u | paste -sd ';' -)

    DBSTART_STATUS="OK"
    DBSHUT_STATUS="OK"

    # ----------------------------------------------------
    # Validate each Oracle Home
    # ----------------------------------------------------

    while IFS=: read -r SID HOME FLAG
    do

        [ -z "$SID" ] && continue
        [ -z "$HOME" ] && continue

        echo "Checking SID=$SID" >> "$DEBUG_FILE"
        echo "Checking HOME=$HOME" >> "$DEBUG_FILE"

        if [ ! -x "$HOME/bin/dbstart" ]; then
            DBSTART_STATUS="MISSING"
            echo "MISSING: $HOME/bin/dbstart" >> "$DEBUG_FILE"
        else
            echo "OK: $HOME/bin/dbstart" >> "$DEBUG_FILE"
        fi

        if [ ! -x "$HOME/bin/dbshut" ]; then
            DBSHUT_STATUS="MISSING"
            echo "MISSING: $HOME/bin/dbshut" >> "$DEBUG_FILE"
        else
            echo "OK: $HOME/bin/dbshut" >> "$DEBUG_FILE"
        fi

    done < "$ORATAB_TMP"

else

    echo "NO Y entries found" >> "$DEBUG_FILE"

fi

rm -f "$ORATAB_TMP"

else

echo "/etc/oratab does not exist" >> "$DEBUG_FILE"

fi

# ============================================================

# SYSTEMD SERVICE

# ============================================================

SERVICE_STATUS="MISSING"
SERVICE_ENABLED="N/A"
SERVICE_ACTIVE="N/A"

echo "Checking systemd service..." >> "$DEBUG_FILE"

if [ -f "/etc/systemd/system/$SERVICE" ]; then

SERVICE_STATUS="EXISTS"

echo "Service exists" >> "$DEBUG_FILE"

if systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then
    SERVICE_ENABLED="enabled"
else
    SERVICE_ENABLED="disabled"
fi

if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
    SERVICE_ACTIVE="active"
else
    SERVICE_ACTIVE="inactive"
fi

else

echo "Service does not exist" >> "$DEBUG_FILE"

fi

echo "SERVICE_STATUS=$SERVICE_STATUS" >> "$DEBUG_FILE"
echo "SERVICE_ENABLED=$SERVICE_ENABLED" >> "$DEBUG_FILE"
echo "SERVICE_ACTIVE=$SERVICE_ACTIVE" >> "$DEBUG_FILE"

# ============================================================

# LISTENER

# ============================================================

if pgrep -f 'tnslsnr' >/dev/null 2>&1; then
LISTENER_STATUS="RUNNING"
else
LISTENER_STATUS="NOT_RUNNING"
fi

# ============================================================

# PMON

# ============================================================

if pgrep -f 'ora_pmon_' >/dev/null 2>&1; then
PMON_STATUS="RUNNING"
else
PMON_STATUS="NOT_RUNNING"
fi

# ============================================================

# RECOMMENDATION

# ============================================================

if [ "$SERVICE_ENABLED" = "enabled" ]; then


RECOMMENDATION="NO_ACTION"


elif [ "$ORATAB_Y_COUNT" -gt 0 ] &&
[ "$ORACLE_USER" = "YES" ] &&
[ "$DBSTART_STATUS" = "OK" ] &&
[ "$DBSHUT_STATUS" = "OK" ]; then

RECOMMENDATION="ENABLE_REQUIRED"

else


RECOMMENDATION="REVIEW"

fi

# ============================================================

# WRITE RESULT

# ============================================================

{
echo "SERVER=$SERVER"
echo "RHEL_VERSION=$RHEL_VERSION"
echo "ORACLE_USER=$ORACLE_USER"
echo "ORACLE_GROUP=$ORACLE_GROUP"
echo "ORACLE_SIDS=$ORACLE_SIDS"
echo "ORACLE_HOMES=$ORACLE_HOMES"
echo "ORATAB_Y_COUNT=$ORATAB_Y_COUNT"
echo "DBSTART_STATUS=$DBSTART_STATUS"
echo "DBSHUT_STATUS=$DBSHUT_STATUS"
echo "SERVICE_STATUS=$SERVICE_STATUS"
echo "SERVICE_ENABLED=$SERVICE_ENABLED"
echo "SERVICE_ACTIVE=$SERVICE_ACTIVE"
echo "LISTENER_STATUS=$LISTENER_STATUS"
echo "PMON_STATUS=$PMON_STATUS"
echo "RECOMMENDATION=$RECOMMENDATION"
} > "$RESULT_FILE"

chmod 644 "$RESULT_FILE"
chmod 644 "$DEBUG_FILE"

echo "===== END $(date) =====" >> "$DEBUG_FILE"

exit 0