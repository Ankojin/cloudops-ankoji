#!/bin/bash
# Standalone test script for Linux – collects TCP connections + listening ports.
# Run this directly on a Linux VM to verify output format before using the
# full Azure Run Command collector.
#
# Usage:
#   chmod +x Test-Collect-Linux.sh
#   ./Test-Collect-Linux.sh
#   ./Test-Collect-Linux.sh /tmp/linux-test.csv

OUTPUT_FILE="${1:-./Linux-Connections-Test.csv}"
HOSTNAME=$(hostname)
COLLECTED=$(date +"%Y-%m-%d %H:%M:%S")

echo "Collecting on $HOSTNAME ..."
echo "Output will be written to: $OUTPUT_FILE"

# Header (same columns as main script + enrichment)
echo "ComputerName,OSType,RecordType,Direction,LocalAddress,LocalPort,RemoteAddress,RemotePort,State,ProcessId,ProcessName,ProcessPath,ProcessCompany,DetectedApp,WellKnownApp,CollectedAt" > "$OUTPUT_FILE"

# Helper: map well-known ports
lookup_app() {
    case "$1" in
        22)   echo "SSH" ;;
        80)   echo "HTTP" ;;
        443)  echo "HTTPS" ;;
        445)  echo "SMB / CIFS" ;;
        1433) echo "Microsoft SQL Server" ;;
        1521) echo "Oracle" ;;
        3306) echo "MySQL / MariaDB" ;;
        3389) echo "RDP" ;;
        5432) echo "PostgreSQL" ;;
        5672) echo "RabbitMQ / AMQP" ;;
        6379) echo "Redis" ;;
        8080) echo "HTTP-Alt / App Server" ;;
        8443) echo "HTTPS-Alt" ;;
        9200) echo "Elasticsearch" ;;
        27017) echo "MongoDB" ;;
        11211) echo "Memcached" ;;
        *)    echo "" ;;
    esac
}

# ---- Established connections ----
ss -tnp state established 2>/dev/null | awk -v host="$HOSTNAME" -v ts="$COLLECTED" '
NR > 1 {
    split($4, local, ":")
    split($5, remote, ":")
    local_ip = local[1]; local_port = local[2]
    remote_ip = remote[1]; remote_port = remote[2]
    if (local_ip ~ /^127\.|^::1/ || remote_ip ~ /^127\.|^::1/) next

    proc = ""; pid = ""
    if ($6 ~ /users:\(\("/) {
        match($6, /users:\(\("([^"]+)",pid=([0-9]+)/, a)
        proc = a[1]; pid = a[2]
    }
    # Output raw fields – enrichment done below via bash
    print host "|Linux|Connection|Outbound|" local_ip "|" local_port "|" remote_ip "|" remote_port "|Established|" pid "|" proc "|||" ts
}' | while IFS='|' read -r host os rtype dir lip lport rip rport state pid proc path company ts; do
    wellknown=$(lookup_app "$rport")
    if [ -n "$proc" ] && [ "$proc" != "Unknown" ]; then
        detected="$proc"
    else
        detected="$wellknown"
    fi
    echo "$host,$os,$rtype,$dir,$lip,$lport,$rip,$rport,$state,$pid,$proc,$path,$company,$detected,$wellknown,$ts" >> "$OUTPUT_FILE"
done

# ---- Listening ports ----
ss -tlnp 2>/dev/null | awk -v host="$HOSTNAME" -v ts="$COLLECTED" '
NR > 1 {
    split($4, local, ":")
    local_ip = local[1]; local_port = local[2]
    if (local_ip ~ /^127\.|^::1/) next

    proc = ""; pid = ""
    if ($6 ~ /users:\(\("/) {
        match($6, /users:\(\("([^"]+)",pid=([0-9]+)/, a)
        proc = a[1]; pid = a[2]
    }
    print host "|Linux|Listen|Listen|" local_ip "|" local_port "|||Listen|" pid "|" proc "|||" ts
}' | while IFS='|' read -r host os rtype dir lip lport rip rport state pid proc path company ts; do
    wellknown=$(lookup_app "$lport")
    if [ -n "$proc" ] && [ "$proc" != "Unknown" ]; then
        detected="$proc"
    else
        detected="$wellknown"
    fi
    echo "$host,$os,$rtype,$dir,$lip,$lport,$rip,$rport,$state,$pid,$proc,$path,$company,$detected,$wellknown,$ts" >> "$OUTPUT_FILE"
done

TOTAL=$(tail -n +2 "$OUTPUT_FILE" | wc -l)
CONNS=$(grep -c ",Connection," "$OUTPUT_FILE" || true)
LISTEN=$(grep -c ",Listen," "$OUTPUT_FILE" || true)

echo ""
echo "========================================"
echo "Linux test collection complete"
echo "Total records : $TOTAL"
echo "Connections   : $CONNS"
echo "Listening     : $LISTEN"
echo "Output file   : $(readlink -f "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")"
echo "========================================"
echo ""
echo "Sample (first 8 data rows):"
head -n 9 "$OUTPUT_FILE" | column -t -s ',' 2>/dev/null || head -n 9 "$OUTPUT_FILE"
