# OpenShift Capacity Planner

Enterprise capacity assessment tool for:

- Red Hat OpenShift 4.x
- Azure Red Hat OpenShift (ARO)

Generates:

- Interactive offline HTML dashboard
- CSV exports
- JSON reports
- Growth forecasting
- Capacity recommendations

Additional CSV exports provide an auditable scheduling inventory:

- `node_inventory_detailed.csv`
- `node_taints.csv`
- `pod_effective_requests.csv`
- `pod_tolerations.csv`
- `pool_capacity_detail.csv`

The live dashboard also provides a complete Node and Machine Inventory with:

- Node role, pool, MachineSet, zone, instance type, age, and kubelet version
- Ready/schedulable state, node pressure conditions, allocatable resources, and pod capacity
- Requested and actual CPU/memory per node
- Taints and conservative review candidates for unhealthy, unschedulable, or empty workers
- MachineSet desired, current, ready, and available replica inventory


---

# Features

## Cluster Inventory

Collects:

- Nodes
- Node roles
- Ready and schedulable state
- Node taints, worker-pool classification, VM type, and zone
- MachineSets
- VM sizes (ARO)
- Namespaces
- Pods
- Pod placement, effective requests, init-container reservations, and tolerations
- PVCs
- StorageClasses
- PersistentVolumes and reclaim policies
- Provisioned versus actual PVC usage when kubelet volume metrics are available
- Storage and stale-resource review candidates: unused/non-Bound PVCs,
  Released/Failed PVs, zero-replica controllers, and old terminal pods


## Capacity Analysis

Calculates:

- CPU allocatable capacity
- Memory allocatable capacity
- CPU requests
- Memory requests
- Utilization percentage
- Overcommit
- Growth scenarios


## Forecasting

Simulates:

- Current
- +25%
- +50%
- +75%
- +100%


## Dashboard

Offline HTML report:

- Executive summary
- Health score
- Capacity status
- CPU charts
- Memory charts
- Namespace consumption
- Top consumers
- Recommendations


---

# Requirements


## Client Machine


Required:
bash
jq
awk
oc

Verify:

```bash
oc version

jq --version
