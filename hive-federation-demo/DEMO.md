# Gravitino Hive Federation Demo

This demo showcases **Apache Gravitino** as a unified metadata layer over two
independent Hive Metastore (HMS) clusters — operational and analytical — with
MinIO as the object store.

```
┌─────────────────────────────────────────────────────────┐
│                   Gravitino  :8090                       │
│          Unified metadata view across both HMS           │
└──────────────────────┬──────────────────────────────────┘
                       │  federates
         ┌─────────────┴──────────────┐
         ▼                            ▼
  HMS A (operational)          HMS B (analytical)
  thrift://:9083                thrift://:9083
  s3a://hive-operational/       s3a://hive-analytical/
         │                            │
         └───────────────┬────────────┘
                         ▼
                    MinIO  :9000
```

**Key demo point:** Data written to HMS A (operational) is immediately visible
to any consumer through Gravitino — no synchronisation with HMS B required.

---

## Prerequisites

- Kubernetes cluster with `kubectl` configured
- Helm 3.x
- The demo deployed via `deploy.sh` (see [README](#deployment))

---

## Deployment

```bash
cd dev/charts/hive-federation-demo
bash deploy.sh
```

For a cluster with a specific storage class (e.g. EKS with `gp2`):

```bash
bash deploy.sh --namespace gravitino-demo --storage-class gp2
```

The script takes ~10-15 minutes on first run (JAR download from Maven Central).
Subsequent runs complete in ~3 minutes (JARs already in MinIO).

---

## Demo Walkthrough

All commands assume you are in `dev/charts/` and the namespace is `gravitino-demo`.

---

### Step 1 — Verify cluster health

```bash
kubectl get pods -n gravitino-demo
```

**Expected:** 6 pods all in `Running` status.

```
NAME                                      READY   STATUS
gravitino-xxx                             1/1     Running
gravitino-mysql-0                         1/1     Running
hive-metastore-a-xxx                      1/1     Running
hive-metastore-a-mysql-xxx                1/1     Running
hive-metastore-b-xxx                      1/1     Running
hive-metastore-b-mysql-xxx                1/1     Running
```

---

### Step 2 — Open the Gravitino UI

```bash
kubectl port-forward svc/gravitino 8090:8090 -n gravitino-demo
```

Open **http://localhost:8090** in your browser.

**Show in UI:**
- Metalake `demo`
- Catalog `hive_operational` → HMS A (operational cluster)
- Catalog `hive_analytical` → HMS B (analytical cluster, currently empty)

---

### Step 3 — Validate via Gravitino REST API

```bash
# Both catalogs registered in one metalake
curl -s http://localhost:8090/api/metalakes/demo/catalogs | python3 -m json.tool

# Operational schemas visible via Gravitino
curl -s http://localhost:8090/api/metalakes/demo/catalogs/hive_operational/schemas | python3 -m json.tool

# Operational tables visible via Gravitino (after Step 4)
curl -s http://localhost:8090/api/metalakes/demo/catalogs/hive_operational/schemas/operational_db/tables | python3 -m json.tool

# Analytical tables visible via Gravitino (after Step 6)
curl -s http://localhost:8090/api/metalakes/demo/catalogs/hive_analytical/schemas/analytical_db/tables | python3 -m json.tool
```

---

### Step 4 — Write operational data to HMS A (batch 1)

Spark writes directly to HMS A. Gravitino federates the result immediately —
no export to HMS B required.

```bash
# Clean up any previous run
kubectl delete job spark-write-demo -n gravitino-demo 2>/dev/null || true
kubectl delete cm spark-write-demo-sql -n gravitino-demo 2>/dev/null || true

# Run
kubectl apply -f gravitino/resources/scenarios/hive-demo/spark-write-demo-job.yaml \
  -n gravitino-demo

# Watch logs
kubectl logs -f job/spark-write-demo -n gravitino-demo -c spark-sql
```

**Expected output (last few lines):**
```
customers    5
products     5
orders      10
raw_events   7
Write complete!  Data is now in MinIO.
```

**Validate in Gravitino UI:** `demo → hive_operational → operational_db` shows
4 tables. Refresh — no HMS B sync needed.

---

### Step 5 — Show Parquet files landed in MinIO

```bash
kubectl run minio-ls --restart=Never --image=minio/mc:latest \
  -n gravitino-demo --rm -i \
  --command -- /bin/sh -c \
  'mc alias set m http://demo-minio:9000 admin password 2>/dev/null
   echo "=== hive-operational (HMS A) ==="
   mc ls --recursive m/hive-operational/warehouse/operational_db.db/
   echo ""
   echo "=== hive-analytical (HMS B) — still empty ==="
   mc ls --recursive m/hive-analytical/ 2>/dev/null || echo "(empty)"'
```

**Show:** Parquet files in `hive-operational`. `hive-analytical` is empty —
proving Gravitino federates **without** copying data to HMS B.

---

### Step 6 — Insert more operational records (batch 2)

```bash
kubectl delete job spark-insert-more -n gravitino-demo 2>/dev/null || true
kubectl delete cm spark-insert-more-sql -n gravitino-demo 2>/dev/null || true

kubectl apply -f gravitino/resources/scenarios/hive-demo/spark-insert-more-data-job.yaml \
  -n gravitino-demo

kubectl logs -f job/spark-insert-more -n gravitino-demo -c spark-sql
```

**Expected output:**
```
BEFORE — customers   5      AFTER — customers  10
BEFORE — products    5      AFTER — products   10
BEFORE — orders     10      AFTER — orders     20
BEFORE — raw_events  7      AFTER — raw_events 15
```

---

### Step 7 — Cross-catalog analytics via Gravitino (the federation showcase)

This job runs in 3 phases:

| Phase | What it does |
|-------|-------------|
| 1 — Gravitino V2 | `SHOW CATALOGS` proves both HMS clusters visible. Registers 4 analytical table schemas in HMS B via Gravitino DDL. |
| 2 — Direct HMS A reads | Computes JOINs across operational tables. Writes Parquet to `hive-analytical` MinIO bucket. |
| 3 — Direct HMS B verify | Reads back the data — proves Gravitino metadata is durable and the tables are queryable by any Hive client. |

```bash
kubectl delete job spark-analytics-federated -n gravitino-demo 2>/dev/null || true
kubectl delete cm spark-analytics-federated-sql -n gravitino-demo 2>/dev/null || true

kubectl apply -f gravitino/resources/scenarios/hive-demo/spark-analytics-federated-job.yaml \
  -n gravitino-demo

kubectl logs -f job/spark-analytics-federated -n gravitino-demo -c spark-sql
```

**Phase 1 output to highlight:**
```
SHOW CATALOGS → hive_analytical   ← both HMS clusters in one session
               spark_catalog
SHOW TABLES  → customers          ← Gravitino shows HMS A tables
               products
               orders
               raw_events
SHOW TABLES  → regional_summary   ← 4 schemas registered in HMS B via Gravitino
               product_revenue
               customer_ltv
               event_funnel
```

**Phase 3 output to highlight:**
```
regional_summary    8 rows   — customers grouped by region + tier
product_revenue     9 rows   — revenue per product (orders JOIN products)
customer_ltv       10 rows   — lifetime value per customer
event_funnel       10 rows   — event counts by region + event type
```

---

### Step 8 — Verify both buckets now have data

```bash
kubectl run minio-final --restart=Never --image=minio/mc:latest \
  -n gravitino-demo --rm -i \
  --command -- /bin/sh -c \
  'mc alias set m http://demo-minio:9000 admin password 2>/dev/null
   echo "=== hive-operational (HMS A) ==="
   mc ls --recursive m/hive-operational/warehouse/operational_db.db/
   echo ""
   echo "=== hive-analytical (HMS B) — now populated ==="
   mc ls --recursive m/hive-analytical/warehouse/analytical_db.db/'
```

**Show:** Both buckets now contain Parquet files. HMS B was populated entirely
through Gravitino — **zero manual export from HMS A**.

---

### Step 9 — Final Gravitino UI walkthrough

In the browser at **http://localhost:8090**:

| Navigation path | What it proves |
|---|---|
| `demo → hive_operational → operational_db` | HMS A tables discovered via Gravitino |
| `demo → hive_analytical → analytical_db` | HMS B tables registered via Gravitino |
| Both catalogs under one metalake `demo` | Single control plane federates independent clusters |

**Closing statement:**
Any data written to HMS A appears immediately through Gravitino to all
consumers. Analytical tables written to HMS B via Gravitino are registered in
the same unified catalog — with **zero synchronisation overhead** and **no
changes to either HMS cluster's configuration**.

---

## Cleanup

```bash
# Remove all demo resources
helm uninstall hive-federation-demo -n gravitino-demo
helm uninstall demo-minio -n gravitino-demo
kubectl delete namespace gravitino-demo

# Remove local helm dependency cache
rm -rf dev/charts/hive-federation-demo/charts/
```
