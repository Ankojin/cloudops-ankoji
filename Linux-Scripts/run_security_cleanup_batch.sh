#!/bin/bash
# =================================================
# Remote batch runner for security-agent removal
#  - Runs remove_security_agents.sh on many hosts
#  - Skips cleanly if nothing installed (handled in script)
#  - Collects per-host logs locally
# =================================================

SCRIPT="./remove_security_agents.sh"
HOSTS="./hosts.txt"
LOGDIR="./logs"
SSH_USER="azureadmin"    # change if needed
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Prompt for password once
echo -n "Enter SSH password for $SSH_USER: "
read -s SSH_PASS
echo

mkdir -p "$LOGDIR"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: $SCRIPT not found in current directory"
  exit 1
fi

if [[ ! -f "$HOSTS" ]]; then
  echo "ERROR: $HOSTS not found"
  exit 1
fi

while read -r host; do
  [[ -z "$host" ]] && continue

  # Sanitize hostname for use in filenames (replace dots and special chars with underscores)
  safe_host=$(echo "$host" | tr '.:/' '_')

  echo "------------------------------------------"
  echo "Running cleanup on $host"
  echo "------------------------------------------"

  # Run remote script via SSH stdin using sshpass
  sshpass -p "$SSH_PASS" ssh $SSH_OPTS ${SSH_USER}@"$host" "sudo bash -s" < "$SCRIPT"
  RC=$?

  if [[ $RC -eq 0 ]]; then
    echo "Execution completed on $host (exit code 0)"
  else
    echo "Execution returned non-zero on $host (exit code $RC) – check log if present"
  fi

  # Try to fetch remote log
  sshpass -p "$SSH_PASS" scp $SSH_OPTS ${SSH_USER}@"$host":/var/log/security-agent-removal.log \
    "$LOGDIR/security-agent-removal-${safe_host}.log" 2>/dev/null

  if [[ $? -eq 0 ]]; then
    echo "Log collected for $host → $LOGDIR/security-agent-removal-${safe_host}.log"
  else
    echo "No log found or SCP failed for $host"
  fi

done < "$HOSTS"

echo "=========================================="
echo "Batch execution complete"
echo "Logs stored in: $LOGDIR"
