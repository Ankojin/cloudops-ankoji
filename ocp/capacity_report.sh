#!/bin/bash
# 6. Node Recommendation Calculation
# Logic:
# 1. Calculate Average Node Size (CPU & Mem) from valid nodes
# 2. Apply System Overhead (Assume 10% of allocatable is reserved for OS/Kubelet if not explicitly known, 
#    but since we use 'allocatable', this is already reserved. 
#    However, the user's example implies we need to account for 'usable' capacity vs 'allocatable'.
#    Let's assume the 'allocatable' is the max available, and we apply the Utilization Factor (80%).
#    If the user wants to simulate "System Overhead" on top of allocatable, we subtract 10% from allocatable first.
#    Based on the example: "16 vCPUs -> 14.5 usable". This is ~90% of 16.
#    We will calculate the average node size and apply the 80% utilization factor.
OUTPUT_FILE="capacity_report_workloads.csv"

echo "🚀 Generating Capacity Report (Based on Workload Definitions)..."
echo "   - Excluding Tainted Nodes (app=sas, dedicated=uipath)"
echo "   - Excluding System Namespaces"
echo "   - Calculating based on Replicas * Requests"
echo "   - Including Node Recommendations"
echo "----------------------------------------"

# Namespaces whose ALL workloads run on dedicated/tainted nodes (no nodeSelector needed — excluded entirely)
# babamldev   → 3 nodes with app=sas:NoSchedule
# bab-dev-rpa-apps-01 → UIPath nodes with dedicated=uipath:NoSchedule
TAINTED_NS_REGEX="^babamldev$|^bab-dev-rpa-apps-01$"

# 1. Get Valid Nodes (Excluding Taints AND dedicated-pool labels)
# Covers: taint key=app/value=sas, taint key=dedicated/value=uipath|sas,
#         AND nodes labeled app=sas or dedicated=uipath (for cases where label is set without matching taint key)
VALID_NODES=$(oc get nodes -o json | jq -r '
  .items[] |
  select(
    # No taint matching SAS or UIPath pools
    ((.spec.taints // []) | map(select(
      (.key == "app"       and .value == "sas")    or
      (.key == "dedicated" and .value == "sas")    or
      (.key == "dedicated" and .value == "uipath")
    )) | length == 0)
    and
    # No node label marking it as a dedicated pool
    ((.metadata.labels // {}) | (.app != "sas" and .dedicated != "uipath"))
  ) |
  .metadata.name
')

if [ -z "$VALID_NODES" ]; then
  echo "❌ Error: No valid nodes found after filtering taints."
  exit 1
fi

CURRENT_NODES=$(echo "$VALID_NODES" | wc -l)

# 2. Calculate Total Cluster Capacity (Valid Nodes Only)
TOTAL_CPU=$(oc get nodes -o json | jq -r "
  [.items[] | select(.metadata.name as \$n | \"$VALID_NODES\" | split(\"\\n\") | map(select(. == \$n)) | length > 0) | 
   .status.allocatable.cpu |
   if test(\"m\$\") then (gsub(\"m\$\"; \"\") | tonumber / 1000)
   else tonumber
   end] | add
")

TOTAL_MEM_BYTES=$(oc get nodes -o json | jq -r "
  [.items[] | select(.metadata.name as \$n | \"$VALID_NODES\" | split(\"\\n\") | map(select(. == \$n)) | length > 0) | 
   .status.allocatable.memory | 
   if test(\"Gi\$\") then (gsub(\"Gi\$\"; \"\") | tonumber * 1073741824)
   elif test(\"Mi\$\") then (gsub(\"Mi\$\"; \"\") | tonumber * 1048576)
   elif test(\"Ki\$\") then (gsub(\"Ki\$\"; \"\") | tonumber * 1024)
   elif test(\"G\$\") then (gsub(\"G\$\"; \"\") | tonumber * 1000000000)
   elif test(\"M\$\") then (gsub(\"M\$\"; \"\") | tonumber * 1000000)
   else tonumber
   end] | add
")
TOTAL_MEM_GIB=$(echo "scale=2; $TOTAL_MEM_BYTES / 1073741824" | bc)

# Output files
OUTPUT_FILE="capacity_report_workloads.csv"          # Sheet 1: ALL namespaces usage
DEDICATED_FILE="capacity_report_dedicated_nodes.csv" # Sheet 2: Dedicated-node workloads only
SUMMARY_FILE="capacity_report_summary.csv"           # Summary & node recommendations

# jq helper functions (reused in multiple passes)
JQ_HELPERS='
  def parse_cpu:
    if . == null or . == "" then 0
    elif test("m$") then (gsub("m$"; "") | tonumber / 1000)
    else tonumber end;

  def parse_mem:
    if . == null or . == "" then 0
    elif test("Gi$") then (gsub("Gi$"; "") | tonumber * 1073741824)
    elif test("Mi$") then (gsub("Mi$"; "") | tonumber * 1048576)
    elif test("Ki$") then (gsub("Ki$"; "") | tonumber * 1024)
    elif test("G$")  then (gsub("G$";  "") | tonumber * 1000000000)
    elif test("M$")  then (gsub("M$";  "") | tonumber * 1000000)
    elif test("m$")  then (gsub("m$";  "") | tonumber / 1000)
    else tonumber end;

  def is_dedicated:
    # Dedicated namespace (all pods run on tainted nodes)
    (.metadata.namespace | test("^babamldev$|^bab-dev-rpa-apps-01$"))
    or
    # nodeSelector targets tainted pool
    ((.spec.template.spec.nodeSelector // {}) | (.app == "sas" or .dedicated == "uipath"))
    or
    # nodeAffinity required rules target tainted pool
    ((.spec.template.spec.affinity.nodeAffinity
        .requiredDuringSchedulingIgnoredDuringExecution
        .nodeSelectorTerms // []) |
      map(.matchExpressions // [] |
        map(select(
          (.key == "app"       and (.values // [] | contains(["sas"])))  or
          (.key == "dedicated" and (.values // [] | contains(["uipath"])))
        )) | length > 0
      ) | any);
'

# ─── 3. Single pass: collect ALL workloads with dedicated flag ─────────────────
TEMP_ALL=$(mktemp)
oc get deployments,statefulsets,daemonsets --all-namespaces -o json | jq -r "
  $JQ_HELPERS
  .items[] |
  (if .kind == \"DaemonSet\" then 1 else (.spec.replicas // 1) end) as \$replicas |
  {
    ns:        .metadata.namespace,
    name:      .metadata.name,
    kind:      .kind,
    replicas:  \$replicas,
    dedicated: is_dedicated,
    dedicated_reason: (
      if (.metadata.namespace | test(\"^babamldev\$\"))             then \"Dedicated ns: app=sas (3 nodes)\"
      elif (.metadata.namespace | test(\"^bab-dev-rpa-apps-01\$\")) then \"Dedicated ns: dedicated=uipath nodes\"
      elif ((.spec.template.spec.nodeSelector // {}) | .app == \"sas\")        then \"nodeSelector: app=sas\"
      elif ((.spec.template.spec.nodeSelector // {}) | .dedicated == \"uipath\") then \"nodeSelector: dedicated=uipath\"
      elif is_dedicated then \"nodeAffinity: app=sas or dedicated=uipath\"
      else \"\"
      end
    ),
    total_cpu: (
      if .spec.template.spec.containers then
        ([.spec.template.spec.containers[].resources.requests.cpu // null] | map(parse_cpu) | add // 0) * \$replicas
      else 0 end
    ),
    total_mem: (
      if .spec.template.spec.containers then
        ([.spec.template.spec.containers[].resources.requests.memory // null] | map(parse_mem) | add // 0) * \$replicas
      else 0 end
    )
  }
" > "$TEMP_ALL"

# ─── 4. Sheet 1: ALL namespaces — every namespace, every workload ──────────────
echo "Namespace,Workload_Count,CPU_Requests_Cores,Memory_Requests_GiB,Note" > "$OUTPUT_FILE"
jq -rs '
  group_by(.ns) |
  map({
    ns: .[0].ns,
    count: length,
    cpu:   (map(.total_cpu) | add),
    mem:   (map(.total_mem) | add),
    has_dedicated: (map(.dedicated) | any)
  }) |
  sort_by(-.cpu) |
  .[] |
  "\(.ns),\(.count),\(.cpu | . * 1000 | round / 1000),\(.mem / 1073741824 | . * 100 | floor / 100),\(if .has_dedicated then "contains dedicated-node workloads" else "" end)"
' "$TEMP_ALL" >> "$OUTPUT_FILE"

# ─── 5. Sheet 2: Dedicated-node workloads only ────────────────────────────────
echo "Namespace,Workload_Name,Kind,Replicas,CPU_Requests_Cores,Memory_Requests_GiB,Reason" > "$DEDICATED_FILE"
jq -rs '
  map(select(.dedicated)) |
  sort_by(.ns, .name) |
  .[] |
  "\(.ns),\(.name),\(.kind),\(.replicas),\(.total_cpu | . * 1000 | round / 1000),\(.total_mem / 1073741824 | . * 100 | floor / 100),\(.dedicated_reason)"
' "$TEMP_ALL" >> "$DEDICATED_FILE"

DEDICATED_COUNT=$(jq -s '[.[] | select(.dedicated)] | length' "$TEMP_ALL")
DEDICATED_CPU=$(jq -s '[.[] | select(.dedicated) | .total_cpu] | add // 0' "$TEMP_ALL")
DEDICATED_MEM_GIB=$(jq -s '[.[] | select(.dedicated) | .total_mem] | add // 0 | . / 1073741824 * 100 | floor / 100' "$TEMP_ALL")
echo "" >> "$DEDICATED_FILE"
echo "TOTALS" >> "$DEDICATED_FILE"
printf "Total Dedicated Workloads,%s,,,%.3f,%.2f,\n" "$DEDICATED_COUNT" "$DEDICATED_CPU" "$DEDICATED_MEM_GIB" >> "$DEDICATED_FILE"

# ─── 5b. Actual pod-to-node placement (running pods, not just specs) ──────────
echo "" >> "$DEDICATED_FILE"
echo "NODES USED BY DEDICATED NAMESPACES (actual running pod placement)" >> "$DEDICATED_FILE"
echo "Namespace,Node,Running_Pods,Node_Role" >> "$DEDICATED_FILE"

TEMP_POD_NODES=$(mktemp)
oc get pods --all-namespaces -o json | jq -r '
  [.items[] |
   select(.metadata.namespace | test("^babamldev$|^bab-dev-rpa-apps-01$")) |
   select(.spec.nodeName != null and .spec.nodeName != "") |
   select(.status.phase == "Running")] |
  group_by(.metadata.namespace + "|" + .spec.nodeName) |
  map({
    ns:    .[0].metadata.namespace,
    node:  .[0].spec.nodeName,
    count: length
  }) |
  sort_by(.ns, .node) |
  .[]' > "$TEMP_POD_NODES"

# Cross-reference with known dedicated node names
jq -rs '
  .[] |
  (.node | if test("rpa") then "UIPath dedicated" elif test("sas|aml") then "SAS dedicated" else "unknown" end) as $role |
  "\(.ns),\(.node),\(.count),\($role)"
' "$TEMP_POD_NODES" >> "$DEDICATED_FILE"

echo "" >> "$DEDICATED_FILE"
echo "POD-LEVEL PLACEMENT (all running pods in dedicated namespaces)" >> "$DEDICATED_FILE"
echo "Namespace,Pod_Name,Node,Status,Controller" >> "$DEDICATED_FILE"
oc get pods --all-namespaces -o json | jq -r '
  .items[] |
  select(.metadata.namespace | test("^babamldev$|^bab-dev-rpa-apps-01$")) |
  select(.spec.nodeName != null) |
  (.metadata.ownerReferences // [] | map(select(.controller == true)) | if length > 0 then ".[0].kind + \"/\" + .[0].name" else "standalone" end) as $ctrl |
  "\(.metadata.namespace),\(.metadata.name),\(.spec.nodeName // "pending"),\(.status.phase // "Unknown"),\((.metadata.ownerReferences // [] | map(select(.controller == true)) | if length > 0 then (.[0].kind + "/" + .[0].name) else "standalone" end))"
' >> "$DEDICATED_FILE"

# Print node placement to stdout for quick verification
echo ""
echo "----------------------------------------"
echo "🔍  DEDICATED NAMESPACE — ACTUAL NODE PLACEMENT"
echo "----------------------------------------"
printf "%-45s %-50s %s\n" "NAMESPACE" "NODE" "RUNNING_PODS"
printf "%-45s %-50s %s\n" "---------" "----" "------------"
jq -rs '.[] | [.ns, .node, (.count|tostring)] | @tsv' "$TEMP_POD_NODES" | \
  awk -F'\t' '{
    role = "?"
    if ($2 ~ /rpa/)      role = "UIPath dedicated"
    else if ($2 ~ /sas|aml/) role = "SAS dedicated"
    printf "%-45s %-50s %s  [%s]\n", $1, $2, $3, role
  }'

# Verify bab-dev-rpa-apps-01 against known UIPath nodes
echo ""
echo "  UIPath node check for bab-dev-rpa-apps-01:"
KNOWN_UIPATH_NODES="bab-dev-aro-01-zm4qv-worker-rpa-swec-01-979xq bab-dev-aro-01-zm4qv-worker-rpa-swec-02-s9mnt"
for NODE in $KNOWN_UIPATH_NODES; do
  COUNT=$(jq -rs "[.[] | select(.ns == \"bab-dev-rpa-apps-01\" and .node == \"$NODE\")] | if length > 0 then .[0].count else 0 end" "$TEMP_POD_NODES")
  if [ "$COUNT" -gt 0 ]; then
    printf "  ✅  %-55s %s running pods\n" "$NODE" "$COUNT"
  else
    printf "  ❌  %-55s no pods found\n" "$NODE"
  fi
done

rm -f "$TEMP_POD_NODES"

# ─── 6. Node calculations: general-purpose workloads only ─────────────────────
TOTAL_USED_CPU=$(jq -s '[.[] | select(.dedicated | not) | .total_cpu] | add // 0' "$TEMP_ALL")
TOTAL_USED_MEM_BYTES=$(jq -s '[.[] | select(.dedicated | not) | .total_mem] | add // 0' "$TEMP_ALL")
TOTAL_USED_MEM_GIB=$(echo "scale=2; $TOTAL_USED_MEM_BYTES / 1073741824" | bc)
TOTAL_INCLUDED_WORKLOADS=$(jq -s '[.[] | select(.dedicated | not)] | length' "$TEMP_ALL")
TOTAL_ALL_WORKLOADS=$(jq -s 'length' "$TEMP_ALL")

REMAINING_CPU=$(echo "scale=2; $TOTAL_CPU - $TOTAL_USED_CPU" | bc)
REMAINING_MEM_GIB=$(echo "scale=2; $TOTAL_MEM_GIB - $TOTAL_USED_MEM_GIB" | bc)

# ─── 7. Node Recommendation (general-purpose nodes × workloads only) ──────────
AVG_NODE_CPU=$(echo "scale=4; $TOTAL_CPU / $CURRENT_NODES" | bc)
AVG_NODE_MEM_GIB=$(echo "scale=2; $TOTAL_MEM_GIB / $CURRENT_NODES" | bc)

SYSTEM_OVERHEAD_FACTOR=0.90
UTILIZATION_FACTOR=0.80
EFFECTIVE_CPU_PER_NODE=$(echo "scale=4; $AVG_NODE_CPU * $SYSTEM_OVERHEAD_FACTOR * $UTILIZATION_FACTOR" | bc)

if (( $(echo "$TOTAL_USED_CPU <= 0" | bc -l) )); then
  NODES_NEEDED=0
else
  NODES_NEEDED=$(echo "scale=2; $TOTAL_USED_CPU / $EFFECTIVE_CPU_PER_NODE" | bc)
fi

NODES_NEEDED_ROUNDED=$(echo "scale=0; ($NODES_NEEDED + 0.99) / 1" | bc)
if (( $(echo "$NODES_NEEDED_ROUNDED < 1" | bc -l) )) && (( $(echo "$TOTAL_USED_CPU > 0" | bc -l) )); then
  NODES_NEEDED_ROUNDED=1
fi
ADDITIONAL_NODES=$(echo "$NODES_NEEDED_ROUNDED - $CURRENT_NODES" | bc)

TOTAL_CPU_R=$(printf "%.2f" "$TOTAL_CPU")
TOTAL_USED_CPU_R=$(printf "%.2f" "$TOTAL_USED_CPU")
CPU_UTIL_PCT=$(echo "scale=1; $TOTAL_USED_CPU * 100 / $TOTAL_CPU" | bc)
MEM_UTIL_PCT=$(echo "scale=1; $TOTAL_USED_MEM_GIB * 100 / $TOTAL_MEM_GIB" | bc)

# ─── 8. Summary CSV ───────────────────────────────────────────────────────────
{
echo "CLUSTER CAPACITY (General-Purpose Nodes Only: $CURRENT_NODES nodes)"
echo "Metric,Value,Unit"
echo "General-Purpose Nodes,$CURRENT_NODES,Nodes"
echo "Avg Node CPU,$AVG_NODE_CPU,Cores"
echo "Avg Node Memory,$AVG_NODE_MEM_GIB,GiB"
echo "Total Allocatable CPU,$TOTAL_CPU_R,Cores"
echo "Total Allocatable Memory,$TOTAL_MEM_GIB,GiB"
echo ""
echo "WORKLOAD REQUESTS (General-Purpose Workloads Only)"
echo "Metric,Value,Unit"
echo "General-Purpose Workloads,$TOTAL_INCLUDED_WORKLOADS,count"
echo "Dedicated-Node Workloads,$DEDICATED_COUNT,count (see $DEDICATED_FILE)"
echo "All Workloads,$TOTAL_ALL_WORKLOADS,count"
echo "CPU Requested,$TOTAL_USED_CPU_R,Cores"
echo "Memory Requested,$TOTAL_USED_MEM_GIB,GiB"
echo "CPU Utilization,$CPU_UTIL_PCT,%"
echo "Memory Utilization,$MEM_UTIL_PCT,%"
echo "Remaining CPU,$REMAINING_CPU,Cores"
echo "Remaining Memory,$REMAINING_MEM_GIB,GiB"
echo ""
echo "NODE RECOMMENDATIONS"
echo "Metric,Value,Unit"
echo "System Overhead Factor,$SYSTEM_OVERHEAD_FACTOR,(10% reserved)"
echo "Utilization Target,$UTILIZATION_FACTOR,(80% safe limit)"
echo "Effective CPU per Node,$EFFECTIVE_CPU_PER_NODE,Cores"
echo "Nodes Needed for Current Load,$NODES_NEEDED_ROUNDED,Nodes"
echo "Current General-Purpose Nodes,$CURRENT_NODES,Nodes"
echo "Additional Nodes Needed,$ADDITIONAL_NODES,Nodes"
} > "$SUMMARY_FILE"

# ─── 9. Stdout summary ────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "📊  CAPACITY REPORT COMPLETE"
echo "========================================"
printf "  %-42s %s\n" "Output files:"              ""
printf "  %-42s %s\n" "  All namespaces usage:"    "$OUTPUT_FILE"
printf "  %-42s %s\n" "  Dedicated-node workloads:" "$DEDICATED_FILE"
printf "  %-42s %s\n" "  Summary & recommendations:" "$SUMMARY_FILE"
echo "  ----------------------------------------"
printf "  %-42s %s\n" "General-purpose nodes (8):"  "${CURRENT_NODES} nodes"
printf "  %-42s %s\n" "Allocatable CPU:"            "${TOTAL_CPU_R} cores"
printf "  %-42s %s\n" "Allocatable Memory:"         "${TOTAL_MEM_GIB} GiB"
echo "  ----------------------------------------"
printf "  %-42s %s\n" "General-purpose workloads:"  "$TOTAL_INCLUDED_WORKLOADS"
printf "  %-42s %s\n" "Dedicated-node workloads:"   "$DEDICATED_COUNT  (babamldev=SAS, bab-dev-rpa-apps-01=UIPath)"
printf "  %-42s %s\n" "Total workloads:"            "$TOTAL_ALL_WORKLOADS"
echo "  ----------------------------------------"
printf "  %-42s %s\n" "CPU requested (general):"   "${TOTAL_USED_CPU_R} cores  (${CPU_UTIL_PCT}%)"
printf "  %-42s %s\n" "Memory requested (general):" "${TOTAL_USED_MEM_GIB} GiB  (${MEM_UTIL_PCT}%)"
printf "  %-42s %s\n" "Remaining CPU:"             "${REMAINING_CPU} cores"
printf "  %-42s %s\n" "Remaining Memory:"          "${REMAINING_MEM_GIB} GiB"
echo "  ----------------------------------------"
printf "  %-42s %s\n" "Nodes needed (recommended):" "$NODES_NEEDED_ROUNDED"
printf "  %-42s %s\n" "Additional nodes needed:"   "$ADDITIONAL_NODES"
echo "========================================"

rm -f "$TEMP_ALL"