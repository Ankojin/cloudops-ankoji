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

Replica readiness analysis resolves Deployment pods through ReplicaSets and reports:

- Desired, current, ready, available, and missing-ready replicas per controller
- Pending and unscheduled Pending pods
- Active CrashLoopBackOff and cumulative restart evidence
- CPU and memory Requests represented by missing-ready replicas
- Conservative scheduling, startup, application, and readiness review classifications


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

Storage review uses evidence rather than treating a Bound PVC with no current
pod as unused. Evidence includes active pod mounts, Deployment/StatefulSet,
Job/CronJob templates, StatefulSet claim templates, VolumeAttachments, PV
state, and kubelet filesystem metrics when the storage driver exposes them.
Unreferenced claims are review signals only and require owner/retention checks.

## Monitoring and Snapshot Lifecycle

- OpenShift Prometheus scrapes and evaluates core monitoring data every 30
    seconds by default. Individual targets may override the scrape interval.
- The collector uses instant Prometheus queries. CPU and network rates use a
    five-minute PromQL window; memory, pod count, and PVC filesystem values are
    point-in-time gauges.
- The Azure Container Apps Job runs every 15 minutes by default (`*/15 * * * *`). Configure
    `COLLECTOR_CRON_EXPRESSION` to change the schedule.
- Every successful environment collection appends a new parent row to
    `capacity_snapshots` and linked pool, namespace, and PVC rows. Existing
    snapshots are not overwritten.
- Incomplete parent snapshots are deleted. Successful inserts purge snapshots
    after `SNAPSHOT_RETENTION_DAYS` (90 days by default, minimum 60); foreign-key
    cascades remove their child rows.
- Cluster history supports presets and custom ranges up to 60 days. Namespace
    utilization history supports a 24-hour snapshot view and a 30-day daily
    view, scoped to all namespaces, tenant projects, platform namespaces, or
    one namespace. Aggregate and export endpoints can use the longer configured
    database retention period.
- Prometheus retention is cluster configuration, separate from dashboard
    snapshot retention. Verify effective values from the running Prometheus pod
    arguments before relying on historical metric availability.

Verified on SIT on 2026-09-02:

- Core platform Prometheus: 30-second global scrape/evaluation interval and
    15-day TSDB retention. Some scrape jobs override the interval to 60 seconds.
- User-workload Prometheus: 24-hour TSDB retention.
- The dashboard CPU and network values are five-minute rates sampled when the
    15-minute collector runs; they are not 15-minute averages.
- Azure Container Apps execution logs are sent through the environment's Log
    Analytics configuration. Their retention is controlled by that workspace,
    not by PostgreSQL or Prometheus, and must be verified in Azure separately.

## CPU, Memory, and Capacity Calculations

### Units and Kubernetes sources

- CPU is normalized to cores: `1000m = 1 core`.
- Memory is normalized to GiB: `1 GiB = 1,073,741,824 bytes`.
- Capacity planning uses node `status.allocatable`, not hardware capacity,
    because allocatable already excludes resources reserved by Kubernetes and the
    operating system.
- Masters are inventory only. Shared-pool calculations exclude master, infra,
    and dedicated/tainted workers. Every dedicated pool is calculated separately.

### Pod Requests

Kubernetes schedules a pod using the larger of the total regular-container
Requests and the largest init-container Request. CPU and memory are calculated
independently:

```text
pod CPU request = max(sum(app-container CPU requests), max(init-container CPU requests))
pod memory request = max(sum(app-container memory requests), max(init-container memory requests))
```

Each replica is a separate pod, so summing effective pod Requests already
includes the running replica count. Succeeded pods and evicted Failed pods are
excluded from current scheduling demand.

### Pod Actual Usage

The Pod Metrics view uses worker-scoped Prometheus cAdvisor metrics:

```promql
sum by (namespace, pod) (
    rate(container_cpu_usage_seconds_total{container!="", pod!=""}[5m])
)
```

CPU actual is therefore the average cores consumed during the five minutes
before collection. It is not a 15-minute average. Pod memory actual is the
point-in-time sum of `container_memory_working_set_bytes`, converted to GiB.
`oc adm top pods` is retained as a fallback when Prometheus pod vectors are not
available.

### Namespace Requests and Actual Usage

```text
namespace CPU request = sum(effective CPU request of namespace pods)
namespace memory request = sum(effective memory request of namespace pods)
namespace CPU actual = sum(actual CPU of namespace containers/pods)
namespace memory actual = sum(actual working-set memory of namespace containers/pods)
```

Namespace actual usage comes from `metrics.k8s.io` when available, with the
worker-scoped Prometheus namespace vectors as fallback.

```text
namespace CPU utilization % = namespace CPU actual / namespace CPU request * 100
namespace memory utilization % = namespace memory actual / namespace memory request * 100
```

These percentages compare usage with Requests for rightsizing. They do not
represent the namespace's share of cluster capacity. Values above 100% are
possible because Requests are scheduler reservations, not CPU limits. When the
Request denominator is zero, the current report emits 0%; inspect the Requests
columns before interpreting that value.

For All, Tenant, or Platform groups, the dashboard first sums the selected
namespaces and then calculates the ratio:

```text
group CPU utilization % = sum(namespace CPU actual) / sum(namespace CPU requests) * 100
```

It does not average namespace percentages, which would over-weight small
namespaces.

### Cluster and Worker-Pool Capacity

```text
pool CPU request % = sum(pod CPU requests on pool nodes) / pool allocatable CPU * 100
pool memory request % = sum(pod memory requests on pool nodes) / pool allocatable memory * 100
pool CPU actual % = sum(node CPU actual for pool) / pool allocatable CPU * 100
pool memory actual % = sum(node memory actual for pool) / pool allocatable memory * 100
```

Shared and dedicated pools are never combined for scheduling decisions. A
namespace assigned to one dedicated pool cannot consume spare capacity from a
different dedicated pool.

The planning target is 80% of allocatable capacity:

```text
safe CPU headroom = pool allocatable CPU * 0.80 - current CPU requests
safe memory headroom = pool allocatable memory * 0.80 - current memory requests
net new-node capacity = new-node allocatable - average DaemonSet requests per node
```

Required nodes are calculated independently for CPU and memory. The larger
result is used:

```text
CPU nodes = ceil(max(0, demand / 0.80 - current CPU capacity) / net CPU per node)
memory nodes = ceil(max(0, demand / 0.80 - current memory capacity) / net memory per node)
nodes to add = max(CPU nodes, memory nodes)
```

### Historical Aggregation

- Each successful 15-minute collection appends one PostgreSQL snapshot.
- The 24-hour namespace view displays each successful snapshot.
- The 30-day namespace view groups snapshots by Saudi calendar day.
- Daily average utilization is the average of the selected group or namespace
    snapshot ratios for that day. Daily peak is the maximum snapshot ratio.
- Spike charts draw measured samples as vertical columns. The 60% and 80%
    horizontal lines are reference thresholds, not measured series.


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
