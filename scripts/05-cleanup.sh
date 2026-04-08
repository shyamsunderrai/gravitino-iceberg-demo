#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 05-cleanup.sh
#
# Resets the demo data environment by:
#   1. Dropping Iceberg tables from both catalogs via a Spark pod
#      (clears HMS metadata for both OC-HMS and AC-HMS)
#   2. Wiping all objects from the operational and analytical S3 buckets
#      (removes all Parquet data files and Iceberg metadata files)
#   3. Deleting all SeaweedFS PVCs so the next deploy starts with clean
#      LevelDB state and fresh S3 credentials from the ConfigMap.
#
# Gravitino catalog registrations (metalake + catalogs) are preserved.
# Run 01-deploy-all.sh then 03-iceberg-write-demo.sh to start fresh.
#
# Prerequisites:
#   - kubectl configured and pointing to the right cluster
#   - aws CLI available (brew install awscli)
#   - JARs downloaded: bash scripts/00-download-jars.sh
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR_DIR="$(cd "${SCRIPT_DIR}/../jars" && pwd)"
NAMESPACE="gravitino"
POD_NAME="gravitino-cleanup-spark"
CONFIGMAP_NAME="gravitino-cleanup-spark-script"
SCRIPT_FILE="/tmp/gravitino-cleanup-spark.py"
S3_ENDPOINT="http://localhost:30334"

# ── PySpark DROP script ───────────────────────────────────────────────────────
cat > "${SCRIPT_FILE}" << 'PYEOF'
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("gravitino-cleanup").getOrCreate()
spark.sparkContext.setLogLevel("WARN")

drops = [
    ("oc_iceberg", "poc_demo", "sensor_readings"),
    ("ac_iceberg", "poc_demo", "sensor_readings_ac"),
]

for catalog, db, table in drops:
    full = f"`{catalog}`.{db}.{table}"
    try:
        spark.sql(f"DROP TABLE IF EXISTS {full}")
        print(f"    Dropped table {full}")
    except Exception as e:
        print(f"    WARNING: could not drop {full}: {e}")

print("=== HMS metadata cleanup done ===")
spark.stop()
PYEOF

# ── Step 1: Spark DROP job ────────────────────────────────────────────────────
echo "[1/3] Running Spark DROP job to remove HMS table metadata..."
kubectl delete configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl create configmap "${CONFIGMAP_NAME}" --from-file=cleanup.py="${SCRIPT_FILE}" -n "${NAMESPACE}"
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found

kubectl run "${POD_NAME}" \
  --image=apache/spark:3.5.3 \
  --restart=Never \
  -n "${NAMESPACE}" \
  --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"${POD_NAME}\",
        \"image\": \"apache/spark:3.5.3\",
        \"command\": [
          \"/opt/spark/bin/spark-submit\",
          \"--master\", \"local[*]\",
          \"--jars\", \"/jars/iceberg-spark-runtime-3.5_2.12-1.6.1.jar,/jars/hadoop-aws-3.3.4.jar,/jars/aws-sdk-java-bundle-2.26.20.jar\",
          \"--driver-class-path\", \"/jars/iceberg-spark-runtime-3.5_2.12-1.6.1.jar:/jars/hadoop-aws-3.3.4.jar:/jars/aws-sdk-java-bundle-2.26.20.jar\",
          \"--conf\", \"spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions\",
          \"--conf\", \"spark.sql.warehouse.dir=/tmp/spark-warehouse\",
          \"--conf\", \"spark.sql.catalog.oc_iceberg=org.apache.iceberg.spark.SparkCatalog\",
          \"--conf\", \"spark.sql.catalog.oc_iceberg.type=rest\",
          \"--conf\", \"spark.sql.catalog.oc_iceberg.uri=http://gravitino.gravitino.svc.cluster.local:9001/iceberg\",
          \"--conf\", \"spark.sql.catalog.oc_iceberg.io-impl=org.apache.iceberg.hadoop.HadoopFileIO\",
          \"--conf\", \"spark.sql.catalog.ac_iceberg=org.apache.iceberg.spark.SparkCatalog\",
          \"--conf\", \"spark.sql.catalog.ac_iceberg.type=hive\",
          \"--conf\", \"spark.sql.catalog.ac_iceberg.uri=thrift://hive-metastore-analytics.gravitino.svc.cluster.local:9083\",
          \"--conf\", \"spark.sql.catalog.ac_iceberg.warehouse=s3a://analytical/iceberg-warehouse\",
          \"--conf\", \"spark.sql.catalog.ac_iceberg.io-impl=org.apache.iceberg.hadoop.HadoopFileIO\",
          \"--conf\", \"spark.hadoop.fs.s3a.endpoint=http://seaweedfs-filer.gravitino.svc.cluster.local:8333\",
          \"--conf\", \"spark.hadoop.fs.s3a.access.key=admin\",
          \"--conf\", \"spark.hadoop.fs.s3a.secret.key=admin\",
          \"--conf\", \"spark.hadoop.fs.s3a.path.style.access=true\",
          \"--conf\", \"spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem\",
          \"--conf\", \"spark.hadoop.fs.s3a.connection.ssl.enabled=false\",
          \"/script/cleanup.py\"
        ],
        \"volumeMounts\": [
          {\"name\": \"jars\",   \"mountPath\": \"/jars\"},
          {\"name\": \"script\", \"mountPath\": \"/script\"}
        ]
      }],
      \"volumes\": [
        {\"name\": \"jars\",   \"hostPath\": {\"path\": \"${JAR_DIR}\"}},
        {\"name\": \"script\", \"configMap\": {\"name\": \"${CONFIGMAP_NAME}\"}}
      ]
    }
  }"

TIMEOUT=180; ELAPSED=0
while true; do
  PHASE=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  case "${PHASE}" in
    Succeeded|Failed) break ;;
    *)
      [ "${ELAPSED}" -ge "${TIMEOUT}" ] && { echo "WARNING: Timeout on DROP job — continuing with S3 cleanup."; break; }
      sleep 5; ELAPSED=$(( ELAPSED + 5 )) ;;
  esac
done

kubectl logs "${POD_NAME}" -n "${NAMESPACE}" \
  | grep -vE "^[0-9]{2}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (INFO|WARN)" || true

# ── Step 2: Wipe S3 buckets ───────────────────────────────────────────────────
echo ""
echo "[2/3] Wiping S3 data from operational and analytical buckets..."
export AWS_ACCESS_KEY_ID=admin
export AWS_SECRET_ACCESS_KEY=admin
export AWS_DEFAULT_REGION=us-east-1

for BUCKET in operational analytical; do
  COUNT=$(aws --endpoint-url "${S3_ENDPOINT}" s3 ls "s3://${BUCKET}/" --recursive 2>/dev/null | wc -l | tr -d ' ')
  if [ "${COUNT}" -gt 0 ]; then
    echo "    Deleting ${COUNT} objects from s3://${BUCKET}/..."
    aws --endpoint-url "${S3_ENDPOINT}" s3 rm "s3://${BUCKET}/" --recursive --quiet
    echo "    s3://${BUCKET}/ cleared."
  else
    echo "    s3://${BUCKET}/ is already empty."
  fi
done

# ── Step 3: Delete SeaweedFS PVCs ────────────────────────────────────────────
echo ""
echo "[3/4] Deleting SeaweedFS PVCs..."
# Scale ALL SeaweedFS deployments to 0 and wait for every pod to terminate
# before deleting PVCs. If any deployment is still running it will hold the
# PVC and block deletion — or immediately spin up a new pod that grabs it.
for DEPLOY in seaweedfs-filer seaweedfs-volume seaweedfs-master; do
  if kubectl get deployment/"${DEPLOY}" -n "${NAMESPACE}" &>/dev/null; then
    echo "  Scaling ${DEPLOY} to 0..."
    kubectl scale deployment/"${DEPLOY}" -n "${NAMESPACE}" --replicas=0
  fi
done
echo "  Waiting for all SeaweedFS pods to terminate..."
kubectl wait --for=delete pod -l "app in (seaweedfs-filer,seaweedfs-volume,seaweedfs-master)" \
  -n "${NAMESPACE}" --timeout=90s 2>/dev/null || true

for PVC in seaweedfs-filer-pvc seaweedfs-master-pvc seaweedfs-volume-pvc; do
  kubectl delete pvc "${PVC}" -n "${NAMESPACE}" --ignore-not-found \
    && echo "  Deleted ${PVC}." || true
done

# ── Step 4: Delete namespace ──────────────────────────────────────────────────
echo ""
echo "[4/4] Deleting namespace '${NAMESPACE}'..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found
echo "  Waiting for namespace to be fully removed..."
kubectl wait --for=delete namespace/"${NAMESPACE}" --timeout=120s 2>/dev/null || true
echo "  Namespace '${NAMESPACE}' removed."

echo ""
echo "════════════════════════════════════════════════════════════"
echo " Cleanup complete."
echo " Run scripts/01-deploy-all.sh to redeploy from scratch."
echo "════════════════════════════════════════════════════════════"
