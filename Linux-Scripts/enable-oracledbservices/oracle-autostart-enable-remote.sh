#!/bin/bash

# ============================================================
# oracle-autostart-enable-remote.sh
#
# Runs as ROOT on target RHEL server.
#
# Result is written to:
#   /tmp/oracle-autostart-enable-result.txt
#
# Debug log:
#   /tmp/oracle-autostart-enable-debug.log
#
# Purpose:
#   - Validate Oracle user and /etc/oratab
#   - Discover Oracle SIDs and Oracle Homes
#   - Validate dbstart/dbshut
#   - Change existing /etc/oratab startup flags N/n -> Y
#   - PRESERVE original /etc/oratab owner/group/permissions
#   - Create oracle-db.service
#   - Validate systemd service
#   - daemon-reload
#   - Enable oracle-db.service
#
# IMPORTANT:
#   - Must run as root
#   - If oracle user does not exist -> REVIEW
#   - If /etc/oratab does not exist -> REVIEW
#   - If no SID exists -> REVIEW
#   - No SID is invented
#   - Existing enabled oracle-db.service is NOT modified
#   - Service is NOT started
#   - No database restart
#   - No server reboot
#   - Existing /etc/oratab owner/group/permissions are preserved
#
# ============================================================

set -u

RESULT_FILE="/tmp/oracle-autostart-enable-result.txt"
DEBUG_FILE="/tmp/oracle-autostart-enable-debug.log"

ORATAB="/etc/oratab"

SERVICE_NAME="oracle-db.service"
SERVICE_FILE="/etc/systemd/system/oracle-db.service"

ORACLE_USER="oracle"

# ============================================================
# Cleanup
# ============================================================

rm -f "$RESULT_FILE"
rm -f "$DEBUG_FILE"

# Send all normal output and errors to debug file
exec >> "$DEBUG_FILE" 2>&1

echo "============================================================"
echo "START $(date)"
echo "============================================================"

echo "Running as:"
id

# ============================================================
# Helper
# ============================================================

write_result()
{
    RESULT_CODE="$1"
    REASON="$2"
    SIDS="$3"
    HOMES="$4"
    ENABLED="$5"
    ACTIVE="$6"

    {
        echo "RESULT_CODE=$RESULT_CODE"
        echo "REASON=$REASON"
        echo "ORACLE_SIDS=$SIDS"
        echo "ORACLE_HOMES=$HOMES"
        echo "SERVICE_ENABLED=$ENABLED"
        echo "SERVICE_ACTIVE=$ACTIVE"
    } > "$RESULT_FILE"

    chmod 644 "$RESULT_FILE"
}

# ============================================================
# 1. Root check
# ============================================================

if [ "$(id -u)" -ne 0 ]; then

    write_result \
        "FAILED" \
        "NOT_RUNNING_AS_ROOT" \
        "N/A" \
        "N/A" \
        "N/A" \
        "N/A"

    exit 10
fi

# ============================================================
# 2. Oracle user
# ============================================================

if ! id "$ORACLE_USER" >/dev/null 2>&1; then

    echo "Oracle user does not exist."

    write_result \
        "REVIEW" \
        "ORACLE_USER_MISSING" \
        "N/A" \
        "N/A" \
        "N/A" \
        "N/A"

    exit 0
fi

ORACLE_GROUP=$(id -gn "$ORACLE_USER")

echo "Oracle user : $ORACLE_USER"
echo "Oracle group: $ORACLE_GROUP"

# ============================================================
# 3. /etc/oratab
# ============================================================

if [ ! -f "$ORATAB" ]; then

    echo "/etc/oratab does not exist."

    write_result \
        "REVIEW" \
        "ORATAB_MISSING" \
        "N/A" \
        "N/A" \
        "N/A" \
        "N/A"

    exit 0
fi

# ============================================================
# 4. Discover Oracle SID entries
#
# We consider any non-comment SID:HOME entry valid.
# The startup flag can be Y or N.
# ============================================================

ORATAB_TMP="/tmp/oracle-oratab-entries-$$.tmp"

rm -f "$ORATAB_TMP"

while IFS=: read -r SID HOME FLAG REST
do

    SID=$(printf '%s' "$SID" | tr -d '\r')
    HOME=$(printf '%s' "$HOME" | tr -d '\r')
    FLAG=$(printf '%s' "$FLAG" | tr -d '\r')

    [ -z "$SID" ] && continue

    case "$SID" in
        \#*)
            continue
            ;;
    esac

    [ -z "$HOME" ] && continue

    case "$SID" in
        *[[:space:]]*)
            continue
            ;;
    esac

    printf '%s|%s|%s\n' "$SID" "$HOME" "$FLAG" >> "$ORATAB_TMP"

done < "$ORATAB"

# ============================================================
# 5. No SID found
# ============================================================

if [ ! -s "$ORATAB_TMP" ]; then

    echo "NO SID FOUND IN /etc/oratab"

    rm -f "$ORATAB_TMP"

    write_result \
        "REVIEW" \
        "NO_SID_IN_ORATAB" \
        "N/A" \
        "N/A" \
        "N/A" \
        "N/A"

    exit 0
fi

# ============================================================
# 6. Collect SIDs / Homes
# ============================================================

ORACLE_SIDS=""
ORACLE_HOMES=""

VALIDATION_FAILED=0

while IFS='|' read -r SID HOME FLAG
do

    echo "SID=$SID"
    echo "HOME=$HOME"
    echo "FLAG=$FLAG"

    if [ -z "$ORACLE_SIDS" ]; then
        ORACLE_SIDS="$SID"
    else
        ORACLE_SIDS="${ORACLE_SIDS};${SID}"
    fi

    if [ -z "$ORACLE_HOMES" ]; then

        ORACLE_HOMES="$HOME"

    elif ! printf '%s\n' "$ORACLE_HOMES" |
        tr ';' '\n' |
        grep -Fxq "$HOME"; then

        ORACLE_HOMES="${ORACLE_HOMES};${HOME}"

    fi

    # ========================================================
    # Validate Oracle Home
    # ========================================================

    if [ ! -d "$HOME" ]; then

        echo "ERROR: Oracle Home does not exist: $HOME"

        VALIDATION_FAILED=1
        continue
    fi

    # ========================================================
    # Validate dbstart
    # ========================================================

    if [ ! -x "$HOME/bin/dbstart" ]; then

        echo "ERROR: dbstart missing: $HOME/bin/dbstart"

        VALIDATION_FAILED=1

    else

        echo "dbstart OK: $HOME/bin/dbstart"

    fi

    # ========================================================
    # Validate dbshut
    # ========================================================

    if [ ! -x "$HOME/bin/dbshut" ]; then

        echo "ERROR: dbshut missing: $HOME/bin/dbshut"

        VALIDATION_FAILED=1

    else

        echo "dbshut OK: $HOME/bin/dbshut"

    fi

done < "$ORATAB_TMP"

# ============================================================
# 7. Validation failure
# ============================================================

if [ "$VALIDATION_FAILED" -ne 0 ]; then

    rm -f "$ORATAB_TMP"

    write_result \
        "REVIEW" \
        "ORACLE_HOME_DBSTART_DBSHUT_VALIDATION_FAILED" \
        "$ORACLE_SIDS" \
        "$ORACLE_HOMES" \
        "N/A" \
        "N/A"

    exit 0
fi

# ============================================================
# 8. Check whether service is already enabled
#
# Do this BEFORE modifying anything.
#
# Existing enabled service is NOT modified.
# ============================================================

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then

    SERVICE_ACTIVE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)

    [ -z "$SERVICE_ACTIVE" ] && SERVICE_ACTIVE="unknown"

    echo "$SERVICE_NAME already enabled."

    rm -f "$ORATAB_TMP"

    write_result \
        "NO_ACTION" \
        "SERVICE_ALREADY_ENABLED" \
        "$ORACLE_SIDS" \
        "$ORACLE_HOMES" \
        "enabled" \
        "$SERVICE_ACTIVE"

    exit 0
fi

# ============================================================
# 9. Capture /etc/oratab attributes BEFORE modification
#
# IMPORTANT:
# We capture the actual UID/GID/mode rather than assuming
# root:root, oracle:oinstall, 0644, etc.
# ============================================================

echo "============================================================"
echo "Capturing /etc/oratab attributes"
echo "============================================================"

ORATAB_OWNER_UID=$(stat -c '%u' "$ORATAB")
ORATAB_GROUP_GID=$(stat -c '%g' "$ORATAB")
ORATAB_MODE=$(stat -c '%a' "$ORATAB")

ORATAB_OWNER_NAME=$(stat -c '%U' "$ORATAB")
ORATAB_GROUP_NAME=$(stat -c '%G' "$ORATAB")

echo "Original /etc/oratab:"
echo "  Owner : $ORATAB_OWNER_NAME (UID=$ORATAB_OWNER_UID)"
echo "  Group : $ORATAB_GROUP_NAME (GID=$ORATAB_GROUP_GID)"
echo "  Mode  : $ORATAB_MODE"

# ============================================================
# 10. Backup /etc/oratab
# ============================================================

ORATAB_BACKUP="${ORATAB}.bak.$(date '+%Y%m%d%H%M%S')"

echo "Backing up /etc/oratab:"
echo "$ORATAB_BACKUP"

if ! cp -p "$ORATAB" "$ORATAB_BACKUP"; then

    rm -f "$ORATAB_TMP"

    write_result \
        "FAILED" \
        "ORATAB_BACKUP_FAILED" \
        "$ORACLE_SIDS" \
        "$ORACLE_HOMES" \
        "N/A" \
        "N/A"

    exit 30
fi

echo "Backup completed successfully."

# ============================================================
# 11. Update /etc/oratab N -> Y
#
# The original owner/group/mode have already been captured.
# ============================================================

ORATAB_NEW="/tmp/oratab-new-$$"

rm -f "$ORATAB_NEW"

ORATAB_UPDATED=0

while IFS= read -r LINE || [ -n "$LINE" ]
do

    # --------------------------------------------------------
    # Preserve blank lines
    # --------------------------------------------------------

    if [ -z "$LINE" ]; then

        printf '%s\n' "$LINE" >> "$ORATAB_NEW"

        continue
    fi

    # --------------------------------------------------------
    # Preserve comments
    # --------------------------------------------------------

    case "$LINE" in

        \#*)

            printf '%s\n' "$LINE" >> "$ORATAB_NEW"

            continue

            ;;

    esac

    # --------------------------------------------------------
    # Parse the /etc/oratab line safely.
    #
    # Expected:
    #
    # SID:ORACLE_HOME:Y
    # SID:ORACLE_HOME:N
    #
    # REST is preserved.
    # --------------------------------------------------------

    OLD_IFS="$IFS"
    IFS=:
    read -r SID HOME FLAG REST <<EOF
$LINE
EOF
    IFS="$OLD_IFS"

    # Remove CR if file originated from Windows
    SID=$(printf '%s' "$SID" | tr -d '\r')
    HOME=$(printf '%s' "$HOME" | tr -d '\r')
    FLAG=$(printf '%s' "$FLAG" | tr -d '\r')

    # --------------------------------------------------------
    # Preserve malformed lines
    # --------------------------------------------------------

    if [ -z "$SID" ] || [ -z "$HOME" ]; then

        printf '%s\n' "$LINE" >> "$ORATAB_NEW"

        continue
    fi

    # --------------------------------------------------------
    # Update startup flag
    # --------------------------------------------------------

    case "$FLAG" in

        Y)

            printf '%s\n' "$LINE" >> "$ORATAB_NEW"

            ;;

        y)

            if [ -n "$REST" ]; then
                printf '%s:%s:Y:%s\n' "$SID" "$HOME" "$REST" >> "$ORATAB_NEW"
            else
                printf '%s:%s:Y\n' "$SID" "$HOME" >> "$ORATAB_NEW"
            fi

            ORATAB_UPDATED=1

            echo "Updated $SID: y -> Y"

            ;;

        N|n|"")

            if [ -n "$REST" ]; then
                printf '%s:%s:Y:%s\n' "$SID" "$HOME" "$REST" >> "$ORATAB_NEW"
            else
                printf '%s:%s:Y\n' "$SID" "$HOME" >> "$ORATAB_NEW"
            fi

            ORATAB_UPDATED=1

            echo "Updated $SID: $FLAG -> Y"

            ;;

        *)

            # Unknown flag - do not change it
            printf '%s\n' "$LINE" >> "$ORATAB_NEW"

            echo "WARNING: Unknown flag for SID=$SID: $FLAG"

            ;;

    esac

done < "$ORATAB"

# ============================================================
# 12. Install updated /etc/oratab
#
# IMPORTANT:
# Restore original owner/group/mode explicitly.
# ============================================================

if [ "$ORATAB_UPDATED" -eq 1 ]; then

    echo "Installing updated /etc/oratab..."

    # --------------------------------------------------------
    # Copy updated contents into the existing file.
    #
    # Using cp instead of mv means we do not replace the
    # original inode unnecessarily.
    # --------------------------------------------------------

    if ! cp "$ORATAB_NEW" "$ORATAB"; then

        echo "ERROR: Failed to install updated /etc/oratab."

        # Rollback
        cp -p "$ORATAB_BACKUP" "$ORATAB" 2>/dev/null || true

        # Restore original attributes
        chown "$ORATAB_OWNER_UID:$ORATAB_GROUP_GID" "$ORATAB" 2>/dev/null || true
        chmod "$ORATAB_MODE" "$ORATAB" 2>/dev/null || true

        rm -f "$ORATAB_TMP" "$ORATAB_NEW"

        write_result \
            "FAILED" \
            "ORATAB_UPDATE_FAILED" \
            "$ORACLE_SIDS" \
            "$ORACLE_HOMES" \
            "N/A" \
            "N/A"

        exit 31
    fi

    # --------------------------------------------------------
    # Restore ORIGINAL owner/group
    # --------------------------------------------------------

    echo "Restoring original /etc/oratab owner/group..."

    if ! chown "$ORATAB_OWNER_UID:$ORATAB_GROUP_GID" "$ORATAB"; then

        echo "ERROR: Failed to restore /etc/oratab owner/group."

        # Rollback
        cp -p "$ORATAB_BACKUP" "$ORATAB" 2>/dev/null || true

        chown "$ORATAB_OWNER_UID:$ORATAB_GROUP_GID" "$ORATAB" 2>/dev/null || true
        chmod "$ORATAB_MODE" "$ORATAB" 2>/dev/null || true

        rm -f "$ORATAB_TMP" "$ORATAB_NEW"

        write_result \
            "FAILED" \
            "ORATAB_OWNER_GROUP_RESTORE_FAILED" \
            "$ORACLE_SIDS" \
            "$ORACLE_HOMES" \
            "N/A" \
            "N/A"

        exit 31
    fi

    # --------------------------------------------------------
    # Restore ORIGINAL permissions
    # --------------------------------------------------------

    echo "Restoring original /etc/oratab permissions..."

    if ! chmod "$ORATAB_MODE" "$ORATAB"; then

        echo "ERROR: Failed to restore /etc/oratab permissions."

        # Rollback
        cp -p "$ORATAB_BACKUP" "$ORATAB" 2>/dev/null || true

        chown "$ORATAB_OWNER_UID:$ORATAB_GROUP_GID" "$ORATAB" 2>/dev/null || true
        chmod "$ORATAB_MODE" "$ORATAB" 2>/dev/null || true

        rm -f "$ORATAB_TMP" "$ORATAB_NEW"

        write_result \
            "FAILED" \
            "ORATAB_PERMISSIONS_RESTORE_FAILED" \
            "$ORACLE_SIDS" \
            "$ORACLE_HOMES" \
            "N/A" \
            "N/A"

        exit 31
    fi

    # --------------------------------------------------------
    # Verify final attributes
    # --------------------------------------------------------

    FINAL_OWNER_UID=$(stat -c '%u' "$ORATAB")
    FINAL_GROUP_GID=$(stat -c '%g' "$ORATAB")
    FINAL_MODE=$(stat -c '%a' "$ORATAB")

    FINAL_OWNER_NAME=$(stat -c '%U' "$ORATAB")
    FINAL_GROUP_NAME=$(stat -c '%G' "$ORATAB")

    echo "Final /etc/oratab:"
    echo "  Owner : $FINAL_OWNER_NAME (UID=$FINAL_OWNER_UID)"
    echo "  Group : $FINAL_GROUP_NAME (GID=$FINAL_GROUP_GID)"
    echo "  Mode  : $FINAL_MODE"

    # --------------------------------------------------------
    # Verify owner/group/mode
    # --------------------------------------------------------

    if [ "$FINAL_OWNER_UID" != "$ORATAB_OWNER_UID" ] ||
       [ "$FINAL_GROUP_GID" != "$ORATAB_GROUP_GID" ] ||
       [ "$FINAL_MODE" != "$ORATAB_MODE" ]; then

        echo "ERROR: /etc/oratab attributes were not preserved."

        echo "Expected:"
        echo "  Owner UID : $ORATAB_OWNER_UID"
        echo "  Group GID : $ORATAB_GROUP_GID"
        echo "  Mode      : $ORATAB_MODE"

        echo "Actual:"
        echo "  Owner UID : $FINAL_OWNER_UID"
        echo "  Group GID : $FINAL_GROUP_GID"
        echo "  Mode      : $FINAL_MODE"

        # ----------------------------------------------------
        # Complete rollback
        # ----------------------------------------------------

        if cp -p "$ORATAB_BACKUP" "$ORATAB"; then

            chown "$ORATAB_OWNER_UID:$ORATAB_GROUP_GID" "$ORATAB" 2>/dev/null || true
            chmod "$ORATAB_MODE" "$ORATAB" 2>/dev/null || true

        fi

        rm -f "$ORATAB_TMP" "$ORATAB_NEW"

        write_result \
            "FAILED" \
            "ORATAB_ATTRIBUTES_NOT_PRESERVED" \
            "$ORACLE_SIDS" \
            "$ORACLE_HOMES" \
            "N/A" \
            "N/A"

        exit 31
    fi

    echo "/etc/oratab updated successfully."
    echo "Original owner/group/permissions preserved."

else

    echo "/etc/oratab already has appropriate startup flags."

fi

rm -f "$ORATAB_TMP" "$ORATAB_NEW"

# ============================================================
# 13. Backup existing systemd service
# ============================================================

if [ -f "$SERVICE_FILE" ]; then

    SERVICE_BACKUP="${SERVICE_FILE}.bak.$(date '+%Y%m%d%H%M%S')"

    echo "Backing up existing service:"
    echo "$SERVICE_BACKUP"

    if ! cp -p "$SERVICE_FILE" "$SERVICE_BACKUP"; then

        write_result \
            "FAILED" \
            "SERVICE_BACKUP_FAILED" \
            "$ORACLE_SIDS" \
            "$ORACLE_HOMES" \
            "N/A" \
            "N/A"

        exit 32
    fi
fi

# ============================================================
# 14. Create systemd service
#
# No database/service start is performed.
# ============================================================

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Universal Oracle Database and Listener Auto Start
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutSec=300

ExecStart=/bin/bash -c '\
    OH=$$(grep -v "^#" /etc/oratab | grep -i -E ":[yY]\r?[[:space:]]*$$" | cut -d: -f2 | head -n 1); \
    if [ -z "$$OH" ]; then echo "No auto-start databases found in /etc/oratab"; exit 0; fi; \
    OUSER=$$(ls -ld "$$OH" | tr -s " " | cut -d" " -f3); \
    echo "Starting Oracle as $$OUSER with ORACLE_HOME=$$OH"; \
    runuser -l "$$OUSER" -c "dbstart $$OH; lsnrctl status >/dev/null 2>&1 || lsnrctl start"'

ExecStop=/bin/bash -c '\
    OH=$$(grep -v "^#" /etc/oratab | grep -i -E ":[yY]\r?[[:space:]]*$$" | cut -d: -f2 | head -n 1); \
    if [ -z "$$OH" ]; then exit 0; fi; \
    OUSER=$$(ls -ld "$$OH" | tr -s " " | cut -d" " -f3); \
    echo "Stopping Oracle as $$OUSER with ORACLE_HOME=$$OH"; \
    runuser -l "$$OUSER" -c "lsnrctl stop; dbshut $$OH"'

[Install]
WantedBy=multi-user.target
EOF

# Standard permissions for systemd unit
chmod 644 "$SERVICE_FILE"

echo "Created:"
echo "$SERVICE_FILE"

# ============================================================
# 15. Validate systemd unit
# ============================================================

VERIFY_FILE="/tmp/oracle-systemd-verify-$$"

if ! systemd-analyze verify "$SERVICE_FILE" >"$VERIFY_FILE" 2>&1; then

    echo "SYSTEMD VALIDATION FAILED"

    cat "$VERIFY_FILE"

    rm -f "$VERIFY_FILE"

    write_result \
        "FAILED" \
        "SYSTEMD_VALIDATION_FAILED" \
        "$ORACLE_SIDS" \
        "$ORACLE_HOMES" \
        "N/A" \
        "N/A"

    exit 33
fi

rm -f "$VERIFY_FILE"

echo "systemd validation OK."

# ============================================================
# 16. daemon-reload
# ============================================================

if ! systemctl daemon-reload; then

    write_result \
        "FAILED" \
        "DAEMON_RELOAD_FAILED" \
        "$ORACLE_SIDS" \
        "$ORACLE_HOMES" \
        "N/A" \
        "N/A"

    exit 34
fi

echo "daemon-reload OK."

# ============================================================
# 17. Enable service
# ============================================================

if ! systemctl enable "$SERVICE_NAME"; then

    write_result \
        "FAILED" \
        "SERVICE_ENABLE_FAILED" \
        "$ORACLE_SIDS" \
        "$ORACLE_HOMES" \
        "N/A" \
        "N/A"

    exit 35
fi

echo "systemctl enable OK."

# ============================================================
# 18. Verify service enabled
# ============================================================

if ! systemctl is-enabled --quiet "$SERVICE_NAME"; then

    write_result \
        "FAILED" \
        "SERVICE_NOT_ENABLED_AFTER_ENABLE" \
        "$ORACLE_SIDS" \
        "$ORACLE_HOMES" \
        "N/A" \
        "N/A"

    exit 36
fi

# ============================================================
# 19. Check active state
#
# We DO NOT start the service.
# inactive is therefore acceptable.
# ============================================================

SERVICE_ACTIVE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)

[ -z "$SERVICE_ACTIVE" ] && SERVICE_ACTIVE="inactive"

# ============================================================
# 20. Final result
# ============================================================

if [ "$ORATAB_UPDATED" -eq 1 ]; then

    REASON="SERVICE_ENABLED_ORATAB_UPDATED"

else

    REASON="SERVICE_ENABLED_ORATAB_ALREADY_Y"

fi

echo "Final result:"
echo "Result       : SUCCESS"
echo "Reason       : $REASON"
echo "SIDs         : $ORACLE_SIDS"
echo "Homes        : $ORACLE_HOMES"
echo "Enabled      : enabled"
echo "Active       : $SERVICE_ACTIVE"

write_result \
    "SUCCESS" \
    "$REASON" \
    "$ORACLE_SIDS" \
    "$ORACLE_HOMES" \
    "enabled" \
    "$SERVICE_ACTIVE"

echo "============================================================"
echo "END $(date)"
echo "============================================================"

exit 0
