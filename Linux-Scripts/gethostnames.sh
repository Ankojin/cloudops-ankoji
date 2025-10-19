#!/usr/bin/env bash
# get-hosts-from-rhel.sh
# Prompt once for SSH password and retrieve hostnames from servers listed in servers.txt
# Output: results.csv (IP,Hostname,Status)

SERVERS_FILE="${1:-ips.txt}"
OUTPUT="${2:-results.csv}"
USERNAME="${3:-azureadmin}"
CONNECT_TIMEOUT=5

SSH_OPTS="-o ConnectTimeout=${CONNECT_TIMEOUT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no"

# check sshpass
if ! command -v sshpass >/dev/null 2>&1; then
  echo "sshpass not found. Install it (e.g. sudo yum install -y sshpass) and try again."
  exit 1
fi

if [ ! -f "$SERVERS_FILE" ]; then
  echo "Servers file not found: $SERVERS_FILE"
  exit 2
fi

# prompt once
read -rsp "Enter SSH password for ${USERNAME}: " PASSWORD
echo
export SSHPASS="$PASSWORD"

# header
echo "IP,Hostname,Status" > "$OUTPUT"

# read file line-by-line, preserve whitespace handling, ignore empty/comment lines
while IFS= read -r raw || [ -n "$raw" ]; do
  # remove comments after '#' and trim
  line="${raw%%#*}"
  host="$(echo "$line" | xargs)"
  [ -z "$host" ] && continue

  printf "Connecting to %s ... " "$host"

  # Run hostname remotely. Use sshpass -e and force password auth.
  # Redirect ssh stdin from /dev/null so ssh doesn't read the servers file.
  out=$(sshpass -e ssh $SSH_OPTS -n "${USERNAME}@${host}" "hostname --fqdn 2>/dev/null || hostname 2>/dev/null" < /dev/null 2>/dev/null)
  rc=$?

  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    echo "Failed"
    echo "${host},,Failed" >> "$OUTPUT"
  else
    # clean host output (remove CR/LF, commas)
    host_clean=$(echo "$out" | tr -d '\r\n' | sed 's/,/_/g')
    echo "OK -> $host_clean"
    echo "${host},${host_clean},OK" >> "$OUTPUT"
  fi

done < "$SERVERS_FILE"

# unset SSHPASS for safety
unset SSHPASS

echo
echo "✅ Done. Results saved to: $OUTPUT"