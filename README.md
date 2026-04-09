# Gravitino Iceberg Federation Demo

A self-contained Kubernetes demo showing Apache Gravitino federating two Hive
Metastore clusters (Operational and Analytical) with Iceberg table format and
SeaweedFS as the S3-compatible object store.

## Demo Tracks

This repository contains two demo tracks on separate branches:

| Track | Branch | Description |
|-------|--------|-------------|
| **Track 1 — Core Federation** | `main` | No authentication. Simplest path to see Gravitino federation + Iceberg + SeaweedFS working end-to-end. |
| **Track 2 — SPIFFE/SPIRE + RBAC** | `feature/spiffe-spire-integration` | Adds SPIFFE workload identity (SPIRE), OAuth2 JWT authentication, and Gravitino RBAC on top of Track 1. |

Start with Track 1 to validate the core setup, then move to Track 2 if you want
to explore identity-aware federation.

---

## Track 1 — Core Federation Demo (main branch)

### Architecture

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

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | Latest | [docs.docker.com](https://docs.docker.com/desktop/) |
| Kubernetes | 1.28+ | Enable in Docker Desktop → Settings → Kubernetes |
| kubectl | Latest | `brew install kubectl` |
| Helm | 3.x | `brew install helm` |
| aws CLI | v2 | `brew install awscli` |
| curl | Any | Pre-installed on macOS/Linux |

> **Note:** The demo uses the `hostpath` storage class available by default in
> Docker Desktop's Kubernetes. For other distributions (kind, minikube, k3s),
> ensure a dynamic provisioner for `hostpath` is available or change
> `storageClassName` in the `deploy/` YAML files accordingly.

### Repository Structure

```
.
├── gravitino/                Apache Gravitino server Helm chart
├── hive-metastore/           Hive Metastore Helm chart (OC-HMS and AC-HMS)
├── deploy/                   Deployment manifests and Helm values
│   ├── 00-namespace.yaml     Kubernetes namespace
│   ├── 01-seaweedfs.yaml     SeaweedFS all-in-one manifest
│   ├── 02-gravitino-pvc.yaml Gravitino persistent volume claim
│   ├── 03-gravitino-values.yaml  Gravitino Helm values
│   ├── 04-oc-hms-values.yaml     Operational HMS Helm values
│   └── 05-ac-hms-values.yaml     Analytical HMS Helm values
├── scripts/                  Ordered demo scripts
│   ├── 00-download-jars.sh   Download required JARs
│   ├── 01-deploy-all.sh      Full infrastructure deployment
│   ├── 02-register-catalogs.sh  Register Gravitino metalake + catalogs
│   ├── 03-iceberg-write-demo.sh Demo 1: write Iceberg table via Gravitino
│   ├── 04-ac-write-demo.sh   Demo 2: cross-catalog ETL with ranking
│   └── 05-cleanup.sh         Full teardown (data + namespace)
├── jars/                     JAR cache (git-ignored, see 00-download-jars.sh)
│   └── .gitkeep
└── README.md                 This file
```

### Quick Start

```bash
# 0. Make sure you are on the main branch
git checkout main

# 1. Download required JARs (~150 MB total)
bash scripts/00-download-jars.sh

# 2. Deploy all infrastructure (~3-5 minutes first time)
bash scripts/01-deploy-all.sh

# 3. Register Gravitino catalogs
bash scripts/02-register-catalogs.sh

# 4. Run Demo 1 — write Iceberg table via Gravitino
bash scripts/03-iceberg-write-demo.sh

# 5. Run Demo 2 — cross-catalog ETL with ranking column
bash scripts/04-ac-write-demo.sh
```

### Detailed Setup

#### Step 1 — Enable Kubernetes in Docker Desktop

1. Open **Docker Desktop** → click the gear icon (Settings)
2. Navigate to **Kubernetes**
3. Check **Enable Kubernetes** and click **Apply & Restart**
4. Wait until the Kubernetes indicator in the bottom-left turns green
5. Verify: `kubectl cluster-info`

#### Step 2 — Download JARs

The Spark demo jobs need these JARs mounted as a `hostPath` volume:

```bash
bash scripts/00-download-jars.sh
```

Downloads to `jars/` (git-ignored):
- `iceberg-spark-runtime-3.5_2.12-1.6.1.jar` — Iceberg Spark integration
- `hadoop-aws-3.3.4.jar` — S3A filesystem for Hadoop
- `aws-java-sdk-bundle-1.12.262.jar` — AWS SDK v1 (used by S3A)

#### Step 3 — Deploy Infrastructure

```bash
bash scripts/01-deploy-all.sh
```

This script:
1. Creates the `gravitino` namespace
2. Deploys SeaweedFS (master + volume + filer with S3 gateway)
3. Runs a 4-step S3 health check (credential load, list, read/write, cleanup)
4. Creates S3 buckets: `operational` and `analytical`
5. Installs Gravitino via Helm with persistence and Iceberg REST enabled
6. Installs OC-HMS (Operational Hive Metastore) via Helm
7. Installs AC-HMS (Analytical Hive Metastore) via Helm

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

#### Step 4 — Register Catalogs

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

### Port-Forwarding Guide

#### Gravitino UI & API (port 8090)

```bash
kubectl port-forward -n gravitino svc/gravitino 8090:8090
```

- **Web UI:** http://localhost:8090
- **REST API:** http://localhost:8090/api/metalakes

#### Gravitino Iceberg REST (port 9001)

```bash
kubectl port-forward -n gravitino svc/gravitino 9001:9001
```

Test: `curl http://localhost:9001/iceberg/v1/config`

#### SeaweedFS Master UI (NodePort — no port-forward needed)

Already exposed at `localhost:30333` via NodePort:
- **Master UI:** http://localhost:30333

#### SeaweedFS S3 API (NodePort — no port-forward needed)

Already exposed at `localhost:30334` via NodePort:

```bash
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

#### Hive Metastore Thrift (NodePort — no port-forward needed)

| Instance | NodePort | Use |
|----------|----------|-----|
| OC-HMS | 30983 | `thrift://localhost:30983` |
| AC-HMS | 30984 | `thrift://localhost:30984` |

### Validation

#### Validate Gravitino UI

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

#### Validate SeaweedFS

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

### Running the Demos

#### Demo 1 — Iceberg Write via Gravitino

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

**Safe to re-run** — each run appends 1 new snapshot with 10 more rows.

#### Demo 2 — Cross-Catalog ETL with Ranking

```bash
bash scripts/04-ac-write-demo.sh
```

**What it does:**
1. Reads `oc_iceberg.poc_demo.sensor_readings` (via Gravitino Iceberg REST)
2. Deduplicates to 10 unique rows
3. Adds a `ranking` column based on `value`:
   - `A` — value ≤ 20
   - `B` — value 21–50
   - `C` — value > 50
4. Overwrites `ac_iceberg.poc_demo.sensor_readings_ac` (direct to AC-HMS)

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

### Cleanup

```bash
bash scripts/05-cleanup.sh
```

This performs a **full teardown**:
1. Runs a Spark job to drop `sensor_readings` and `sensor_readings_ac` from both HMS instances
2. Deletes all objects from `s3://operational/` and `s3://analytical/`
3. Scales all SeaweedFS deployments to 0 (releases LevelDB locks)
4. Deletes SeaweedFS PVCs (ensures clean IAM state on next deploy)
5. Deletes the entire `gravitino` namespace

After cleanup, run from `01-deploy-all.sh` again for a fresh environment.

### Troubleshooting

#### Spark pod stuck in `Pending`

```bash
kubectl describe pod gravitino-iceberg-spark-demo -n gravitino
```

Common cause: JARs not found because the `hostPath` volume path doesn't exist.
Verify `jars/` contains all three JAR files and run `00-download-jars.sh` if needed.

#### `NoSuchMetalakeException` when running demos

The Gravitino pod was restarted and lost its H2 database. Re-register:

```bash
bash scripts/02-register-catalogs.sh
```

#### Gravitino pod in `CrashLoopBackOff`

```bash
kubectl logs -n gravitino deployment/gravitino --previous
```

If you see `classpath: /jars not exists`, re-apply the Helm values:

```bash
helm upgrade gravitino ./gravitino -n gravitino -f deploy/03-gravitino-values.yaml
```

#### SeaweedFS `InvalidAccessKeyId` errors

This means SeaweedFS started without loading the S3 credentials config. The most
common cause is a stale LevelDB from a previous deployment that ignored the
`-s3.config` file. Run `05-cleanup.sh` for a full teardown, then re-deploy with
`01-deploy-all.sh`. The deploy script runs a 4-step S3 health check before
proceeding — if it fails, check the filer pod logs:

```bash
kubectl logs -n gravitino deployment/seaweedfs-filer | tail -30
```

#### SeaweedFS S3 `NoSuchBucket` errors

```bash
export AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=admin AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://localhost:30334 s3 mb s3://operational
aws --endpoint-url http://localhost:30334 s3 mb s3://analytical
```

#### `deployment exceeded its progress deadline`

The Hive Metastore MySQL init takes 90-120 seconds on first start. Retry with a longer timeout:

```bash
kubectl rollout status deployment/hive-metastore -n gravitino --timeout=300s
```

#### Docker Desktop node IP

All NodePort services bind to `localhost` in Docker Desktop. For other
distributions (minikube, kind), replace `localhost` with the node IP:

```bash
kubectl get nodes -o wide   # use the INTERNAL-IP column
# or for minikube:
minikube ip
```

---

## Track 2 — SPIFFE/SPIRE + OAuth2 + RBAC (feature/spiffe-spire-integration branch)

This track extends Track 1 with workload identity and access control:

- **SPIRE** issues X.509 SVIDs (SPIFFE Verifiable Identity Documents) to each pod
- **Gravitino** is configured with OAuth2/JWT authentication, validating SVIDs as bearer tokens
- **Gravitino RBAC** restricts which identities can access which catalogs

### Additional Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes (gravitino namespace)          │
│                                                                   │
│  ┌────────────────────┐   ┌──────────────────────────────────┐  │
│  │   SPIRE Server     │   │       Apache Gravitino            │  │
│  │   (port 8081)      │──►│   auth: OAuth2 / SPIFFE JWT      │  │
│  └────────────────────┘   │   RBAC: metalake-level policies  │  │
│                            └──────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  SPIRE Agent DaemonSet                                  │    │
│  │  Attestation: k8s_psat (projected service account token)│    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                   │
│  (all Track 1 components remain unchanged)                       │
└─────────────────────────────────────────────────────────────────┘

Identity flow:
  Spark pod ──► SPIRE Agent ──► SVID (JWT) ──► Gravitino (validates JWT)
  Gravitino ──► RBAC check ──► OC-HMS / AC-HMS
```

### Prerequisites

All Track 1 prerequisites, plus:

| Tool | Notes |
|------|-------|
| `spire-server` CLI | Optional — for manual bundle inspection |

> **Docker Desktop CNI note:** Network policies are applied but Docker Desktop's
> built-in CNI does not enforce them. The RBAC demo still works — policies are
> visible in `kubectl get networkpolicy` and would be enforced on a CNI that
> supports NetworkPolicy (Calico, Cilium, etc.).

### Repository Structure (additional files)

```
deploy/
├── 06-spire-server.yaml      SPIRE Server deployment + ClusterRole
├── 07-spire-agent.yaml       SPIRE Agent DaemonSet + attestor config
└── 08-gravitino-rbac.yaml    NetworkPolicy + Gravitino RBAC roles

scripts/
├── 06-setup-spire.sh         Deploy SPIRE + bootstrap Gravitino auth + RBAC
├── 07-setup-rbac.sh          Create Gravitino roles and role bindings
└── 08-validate-policy.sh     End-to-end SPIFFE identity + access validation
```

### Quick Start

```bash
# 0. Switch to the SPIRE feature branch
git checkout feature/spiffe-spire-integration

# 1. Complete Track 1 steps 00 through 02 first
bash scripts/00-download-jars.sh
bash scripts/01-deploy-all.sh
bash scripts/02-register-catalogs.sh

# 2. Deploy SPIRE and bootstrap Gravitino auth + RBAC
bash scripts/06-setup-spire.sh

# 3. Create Gravitino roles and role bindings
bash scripts/07-setup-rbac.sh

# 4. Validate SPIFFE identity end-to-end
bash scripts/08-validate-policy.sh

# 5. Run the demos (same as Track 1 — now identity-aware)
bash scripts/03-iceberg-write-demo.sh
bash scripts/04-ac-write-demo.sh
```

### SPIRE Setup Details

`06-setup-spire.sh` performs these steps:

1. Deploys SPIRE Server and creates ClusterRole for k8s_psat attestation
2. Deploys SPIRE Agent DaemonSet
3. Creates SPIRE registration entries for Gravitino and Spark workloads
4. Configures Gravitino with OAuth2 JWT authentication (SPIFFE trust domain)
5. Bootstraps the Gravitino admin user in H2 (required before RBAC can be configured)
6. Applies NetworkPolicy resources

#### Troubleshooting SPIRE

**`x509: certificate signed by unknown authority` on agent startup**

This happens when SPIRE Server is redeployed (new CA) but the agent has a stale
bootstrap bundle in its hostPath data directory. Fix:

```bash
# Delete old agent pods to force re-attestation
kubectl delete pod -n gravitino -l app=spire-agent

# Clear the stale agent data directory from inside a debug pod
kubectl run -it --rm spire-wipe --image=busybox --restart=Never \
  -n gravitino \
  --overrides='{"spec":{"volumes":[{"name":"data","hostPath":{"path":"/run/spire/agent-data"}}],"containers":[{"name":"spire-wipe","image":"busybox","command":["sh","-c","rm -rf /data/* && echo done"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}]}}' \
  -- sh

# Redeploy the agent
kubectl apply -f deploy/07-spire-agent.yaml
```

**Gravitino `403 — user doesn't exist in metalake`**

RBAC is enabled but the admin user was not bootstrapped. Re-run the setup script:

```bash
bash scripts/06-setup-spire.sh
```

The script inserts the admin user directly into the Gravitino H2 database from
inside the running pod using `AUTO_SERVER=TRUE`. It must run while Gravitino is
up (Flyway wipes tables on startup if the pod is scaled down first).

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
| SPIRE Server / Agent | 1.9.x (Track 2 only) |
