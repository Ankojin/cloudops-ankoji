#!/bin/bash
# Test script to check server reading

SERVER_FILE="servers.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing server file reading..."
echo "File: ${SCRIPT_DIR}/${SERVER_FILE}"
echo ""

total=0
while IFS=$'\n' read -r HOST || [[ -n "$HOST" ]]; do
    HOST=$(echo "$HOST" | tr -d '\r' | xargs)
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue
    
    ((total++))
    echo "Server $total: $HOST"
done < "${SCRIPT_DIR}/${SERVER_FILE}"

echo ""
echo "Total servers found: $total"
