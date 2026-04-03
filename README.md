# Gravitino Iceberg Federation Demo

A self-contained Kubernetes demo showing Apache Gravitino federating two Hive
Metastore clusters (Operational and Analytical) with Iceberg table format and
SeaweedFS as the S3-compatible object store.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes (gravitino namespace)          │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Apache Gravitino  (port 8090)                │   │
│  │   Metalake: poc_layer                                     │   │
│  │   Catalogs: OC-HMS (hive) │ oc_iceberg (lakehouse-iceberg)│   │
│  │             AC-HMS (hive)                                 │   │
│  │                                                           │   │
│  │   Iceberg REST Service (port 9001) ──────────────────┐   │   │
│  └──────────────────────────┬────────────────────────────┼───┘   │
│                             │                            │       │
│              ┌──────────────┴──────────────┐            │       │
│              │                             │            │       │
│  ┌───────────▼──────────┐  ┌──────────────▼──────┐     │       │
│  │  OC-HMS (port 9083)  │  │ AC-HMS (port 9083)  │     │       │
│  │  Operational         │  │ Analytical           │     │       │
│  │  hive-metastore      │  │ hive-metastore-      │     │       │
│  │                      │  │ analytics            │     │       │
│  └──────────┬───────────┘  └───────────┬──────────┘     │       │
│             │                          │                 │       │
│  ┌──────────▼──────────────────────────▼─────────────────▼───┐  │
│  │                SeaweedFS S3 (port 8333)                    │  │
│  │   Buckets:  operational/   │   analytical/                 │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

Demo flow:
  Demo 1 (03-iceberg-write-demo.sh):
    Spark ──► Gravitino Iceberg REST (:9001) ──► OC-HMS ──► s3://operational/

  Demo 2 (04-ac-write-demo.sh):
    Spark ──► oc_iceberg (read, via Gravitino)    ──► s3://operational/
    Spark ──► ac_iceberg (write, direct to AC-HMS) ──► s3://analytical/
```

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | Latest | [docs.docker.com](https://docs.docker.com/desktop/) |
| Kubernetes | 1.28+ | Enable in Docker Desktop → Settings → Kubernetes |
| kubectl | Latest | `brew install kubectl` |
| Helm | 3.x | `brew install helm` |
| aws CLI | v2 | `brew install awscli` |
| curl | Any | Pre-installed on macOS/Linux |

> **Note:** The demo uses `hostpath` storage class which is available by default
> in Docker Desktop's Kubernetes. If you use a different distribution (kind,
> minikube, k3s), ensure a dynamic provisioner for `hostpath` is available or
> change `storageClassName` in the `deploy/` YAML files accordingly.

## Repository Structure

```
.
├── gravitino/                Apache Gravitino server Helm chart
├── hive-metastore/           Hive Metastore Helm chart (used for OC-HMS and AC-HMS)
├── deploy/                   Deployment manifests and Helm values
│   ├── 00-namespace.yaml     Kubernetes namespace
│   ├── 01-seaweedfs.yaml     SeaweedFS all-in-one manifest
│   ├── 02-gravitino-pvc.yaml Gravitino persistence volume claim
│   ├── 03-gravitino-values.yaml  Gravitino Helm values
│   ├── 04-oc-hms-values.yaml     Operational HMS Helm values
│   └── 05-ac-hms-values.yaml     Analytical HMS Helm values
├── scripts/                  Ordered demo scripts
│   ├── 00-download-jars.sh   Download required JARs
│   ├── 01-deploy-all.sh      Full infrastructure deployment
│   ├── 02-register-catalogs.sh  Register Gravitino metalake + catalogs
│   ├── 03-iceberg-write-demo.sh Demo 1: write Iceberg table via Gravitino
│   ├── 04-ac-write-demo.sh   Demo 2: cross-catalog ETL with ranking
│   └── 05-cleanup.sh         Reset demo data
├── jars/                     JAR cache (git-ignored, see 00-download-jars.sh)
│   └── .gitkeep
└── README.md                 This file
```

---

## Quick Start

```bash
# 1. Clone the repo
git clone <your-repo-url>
cd <repo-directory>

# 2. Download required JARs (~150 MB total)
bash scripts/00-download-jars.sh

# 3. Deploy all infrastructure (~3-5 minutes first time)
bash scripts/01-deploy-all.sh

# 4. Register Gravitino catalogs
bash scripts/02-register-catalogs.sh

# 5. Run Demo 1 — write Iceberg table via Gravitino
bash scripts/03-iceberg-write-demo.sh

# 6. Run Demo 2 — cross-catalog ETL with ranking column
bash scripts/04-ac-write-demo.sh
```

---

## Detailed Setup

### Step 1 — Enable Kubernetes in Docker Desktop

1. Open **Docker Desktop** → click the gear icon (Settings)
2. Navigate to **Kubernetes**
3. Check **Enable Kubernetes** and click **Apply & Restart**
4. Wait until the Kubernetes indicator in the bottom-left turns green
5. Verify: `kubectl cluster-info`

### Step 2 — Download JARs

The Spark demo jobs need these JARs mounted as a `hostPath` volume:

```bash
bash scripts/00-download-jars.sh
```

Downloads to `jars/` (git-ignored):
- `iceberg-spark-runtime-3.5_2.12-1.6.1.jar` — Iceberg Spark integration
- `hadoop-aws-3.3.4.jar` — S3A filesystem for Hadoop
- `aws-java-sdk-bundle-1.12.262.jar` — AWS SDK v1 (used by S3A)

### Step 3 — Deploy Infrastructure

```bash
bash scripts/01-deploy-all.sh
```

This script:
1. Creates the `gravitino` namespace
2. Deploys SeaweedFS (master + volume + filer with S3 gateway)
3. Creates S3 buckets: `operational` and `analytical`
4. Installs Gravitino via Helm with persistence and Iceberg REST enabled
5. Installs OC-HMS (Operational Hive Metastore) via Helm
6. Installs AC-HMS (Analytical Hive Metastore) via Helm

Expected final pod state:

```
NAME                                         READY   STATUS
gravitino-xxx                                1/1     Running
hive-metastore-xxx                           1/1     Running
hive-metastore-analytics-xxx                 1/1     Running
hive-metastore-analytics-mysql-xxx           1/1     Running
hive-metastore-mysql-xxx                     1/1     Running
seaweedfs-filer-xxx                          1/1     Running
seaweedfs-master-xxx                         1/1     Running
seaweedfs-volume-xxx                         1/1     Running
```

> **Tip:** MySQL pods may take 60-90 seconds to be ready on first start due to
> database initialization. The script waits automatically.

### Step 4 — Register Catalogs

```bash
bash scripts/02-register-catalogs.sh
```

Registers these resources in Gravitino under metalake `poc_layer`:

| Catalog | Provider | Backend |
|---------|----------|---------|
| `OC-HMS` | hive | `hive-metastore:9083` |
| `oc_iceberg` | lakehouse-iceberg | OC-HMS + `s3a://operational/iceberg-warehouse` |
| `AC-HMS` | hive | `hive-metastore-analytics:9083` |

The script is **idempotent** — safe to re-run after restarts.

---

## Port-Forwarding Guide

All services use `ClusterIP` by default. Use `kubectl port-forward` to access
them from your laptop. SeaweedFS S3 and both HMS Thrift ports are also exposed
as `NodePort` services for convenience.

### Gravitino UI & API (port 8090)

```bash
kubectl port-forward -n gravitino svc/gravitino 8090:8090
```

- **Web UI:** http://localhost:8090
- **REST API:** http://localhost:8090/api/metalakes

### Gravitino Iceberg REST (port 9001)

```bash
kubectl port-forward -n gravitino svc/gravitino 9001:9001
```

Test: `curl http://localhost:9001/iceberg/v1/config`

### SeaweedFS Master UI (NodePort — no port-forward needed)

Already exposed at `localhost:30333` via NodePort:

- **Master UI:** http://localhost:30333

You can browse the cluster status, volumes, and file topology here.

### SeaweedFS S3 API (NodePort — no port-forward needed)

Already exposed at `localhost:30334` via NodePort:

```bash
# Set credentials once (or export before each command)
export AWS_ACCESS_KEY_ID=admin
export AWS_SECRET_ACCESS_KEY=admin
export AWS_DEFAULT_REGION=us-east-1

# List buckets
aws --endpoint-url http://localhost:30334 s3 ls

# List all objects in operational bucket
aws --endpoint-url http://localhost:30334 s3 ls s3://operational/ --recursive

# List all objects in analytical bucket
aws --endpoint-url http://localhost:30334 s3 ls s3://analytical/ --recursive
```

### Hive Metastore Thrift (NodePort — no port-forward needed)

| Instance | NodePort | Use |
|----------|----------|-----|
| OC-HMS | 30983 | `thrift://localhost:30983` |
| AC-HMS | 30984 | `thrift://localhost:30984` |

---

## Validation

### Validate Gravitino UI

1. Start port-forward: `kubectl port-forward -n gravitino svc/gravitino 8090:8090`
2. Open http://localhost:8090
3. You should see the metalake `poc_layer` listed
4. Click `poc_layer` → you should see catalogs: `OC-HMS`, `oc_iceberg`, `AC-HMS`

Alternatively, use the REST API:

```bash
# List metalakes
curl -s http://localhost:8090/api/metalakes | jq '.metalakes[].name'

# List catalogs under poc_layer
curl -s http://localhost:8090/api/metalakes/poc_layer/catalogs | jq '.catalogs[].name'

# Verify Iceberg REST is serving
curl -s http://localhost:9001/iceberg/v1/config | jq .
```

### Validate SeaweedFS

```bash
export AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=admin AWS_DEFAULT_REGION=us-east-1

# Should show operational and analytical buckets
aws --endpoint-url http://localhost:30334 s3 ls

# After running demo 1, show Iceberg data files
aws --endpoint-url http://localhost:30334 s3 ls s3://operational/ --recursive \
  | grep -E "\.parquet|metadata"

# After running demo 2, show analytical Iceberg data files
aws --endpoint-url http://localhost:30334 s3 ls s3://analytical/ --recursive \
  | grep -E "\.parquet|metadata"
```

**SeaweedFS Master UI** at http://localhost:30333 shows:
- Volume server count and free space
- File count per volume
- Cluster topology

### Validate Kubernetes Resources

```bash
# All pods running
kubectl get pods -n gravitino

# Check Gravitino logs (look for "Gravitino server started" and "IcebergRESTService")
kubectl logs -n gravitino deployment/gravitino --tail=30

# Check OC-HMS is connected to its MySQL
kubectl logs -n gravitino deployment/hive-metastore --tail=20

# Check HMS endpoints are reachable from within the cluster
kubectl run -it --rm debug --image=busybox --restart=Never -n gravitino -- \
  sh -c "nc -zv hive-metastore 9083 && echo OC-HMS OK; nc -zv hive-metastore-analytics 9083 && echo AC-HMS OK"
```

---

## Running the Demos

### Demo 1 — Iceberg Write via Gravitino (03-iceberg-write-demo.sh)

```bash
bash scripts/03-iceberg-write-demo.sh
```

**What it does:**
1. Creates `oc_iceberg.poc_demo.sensor_readings` (Iceberg, Parquet/Snappy)
2. Inserts 10 sensor readings coalesced into **1 Parquet file**
3. Reads the data back, shows snapshot history and file listing

**Write path:**
```
Spark ──► Gravitino Iceberg REST (9001/iceberg) ──► OC-HMS ──► s3://operational/warehouse/
```

**Expected output:**
```
=== [3/3] Reading back records ===
+---------+-----------+-----------+-----+-------------------+
|sensor_id|location   |metric     |value|recorded_at        |
+---------+-----------+-----------+-----+-------------------+
|1        |warehouse-a|temperature|22.5 |2024-01-15 08:00:00|
...
=== Iceberg files (confirms single Parquet file) ===
|s3a://operational/warehouse/.../data/00000-0-....parquet|PARQUET|10|
```

**Safe to re-run** — each run adds 1 new snapshot with 10 more rows.

### Demo 2 — Cross-Catalog ETL with Ranking (04-ac-write-demo.sh)

```bash
bash scripts/04-ac-write-demo.sh
```

**What it does:**
1. Reads `oc_iceberg.poc_demo.sensor_readings` (all rows, may include duplicates from multiple demo 1 runs)
2. Deduplicates to 10 unique rows
3. Adds a `ranking` column based on `value`:
   - `A` — value ≤ 20
   - `B` — value 21–50
   - `C` — value > 50
4. Overwrites `ac_iceberg.poc_demo.sensor_readings_ac` with the ranked result

**Read path:** Spark → Gravitino Iceberg REST → OC-HMS → SeaweedFS `operational`
**Write path:** Spark → AC-HMS (Hive catalog, direct) → SeaweedFS `analytical`

**Expected output (10 rows, no duplicates):**
```
+---------+-----------+-----------+-----+-------------------+-------+
|sensor_id|location   |metric     |value|recorded_at        |ranking|
+---------+-----------+-----------+-----+-------------------+-------+
|1        |warehouse-a|temperature|22.5 |2024-01-15 08:00:00|B      |
|2        |warehouse-a|humidity   |55.3 |2024-01-15 08:00:00|C      |
|3        |warehouse-b|temperature|19.8 |2024-01-15 08:05:00|A      |
...
```

### Cleanup — Reset Demo Data (05-cleanup.sh)

```bash
bash scripts/05-cleanup.sh
```

- Drops `sensor_readings` and `sensor_readings_ac` from both HMS instances
- Deletes all objects from `s3://operational/` and `s3://analytical/`
- Gravitino metalake and catalog registrations are **preserved**
- After cleanup, run demos 3 and 4 again to start fresh

---

## Troubleshooting

### Spark pod stuck in `Pending`

```bash
kubectl describe pod gravitino-iceberg-spark-demo -n gravitino
```

Common cause: JARs not found because the `hostPath` volume path doesn't exist or
is wrong. Verify the `jars/` directory contains all three JAR files.

### `NoSuchMetalakeException` when running demos

The Gravitino pod was restarted and lost its H2 database. The PVC persists data
across restarts, but if the namespace was deleted or the PVC lost, re-register:

```bash
bash scripts/02-register-catalogs.sh
```

### Gravitino pod in `CrashLoopBackOff`

Check logs for classpath errors:

```bash
kubectl logs -n gravitino deployment/gravitino --previous
```

If you see `classpath: /jars not exists`, the Iceberg REST classpath is stale from
a previous upgrade. Re-apply the values:

```bash
helm upgrade gravitino ./charts/gravitino -n gravitino \
  -f deploy/03-gravitino-values.yaml
```

### `deployment exceeded its progress deadline`

The Hive Metastore MySQL init takes 90-120 seconds on first start. If you see
this, increase the timeout or wait and retry:

```bash
kubectl rollout status deployment/hive-metastore -n gravitino --timeout=300s
```

### SeaweedFS S3 `NoSuchBucket` errors

Buckets may not have been created. Run:

```bash
export AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=admin AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://localhost:30334 s3 mb s3://operational
aws --endpoint-url http://localhost:30334 s3 mb s3://analytical
```

### Docker Desktop node IP

All NodePort services bind to `localhost` (`127.0.0.1`) in Docker Desktop.
If you use a different Kubernetes distribution (minikube, kind), replace
`localhost` with the node IP returned by:

```bash
kubectl get nodes -o wide   # use the INTERNAL-IP column
# or for minikube:
minikube ip
```

---

## Component Versions

| Component | Version |
|-----------|---------|
| Apache Gravitino | 1.2.0 |
| Apache Hive Metastore | 3.1.3 |
| SeaweedFS | dev (chrislusf/seaweedfs:dev) |
| Apache Spark | 3.5.3 |
| Apache Iceberg | 1.6.1 |
| iceberg-spark-runtime | 3.5_2.12-1.6.1 |
| hadoop-aws | 3.3.4 |
| aws-java-sdk-bundle | 1.12.262 |
| MySQL | 8.4.8-oracle |
