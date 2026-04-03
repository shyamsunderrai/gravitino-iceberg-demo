#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 05-cleanup.sh
#
# Resets the demo data environment by:
#   1. Dropping Iceberg tables from both catalogs via a Spark pod
#      (clears HMS metadata for both OC-HMS and AC-HMS)
#   2. Wiping all objects from the operational and analytical S3 buckets
#      (removes all Parquet data files and Iceberg metadata files)
#
# Gravitino catalog registrations (metalake + catalogs) are preserved.
# Run 03-iceberg-write-demo.sh again after this to start fresh.
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
          \"--jars\", \"/jars/iceberg-spark-runtime-3.5_2.12-1.6.1.jar,/jars/hadoop-aws-3.3.4.jar,/jars/aws-java-sdk-bundle-1.12.262.jar\",
          \"--driver-class-path\", \"/jars/iceberg-spark-runtime-3.5_2.12-1.6.1.jar:/jars/hadoop-aws-3.3.4.jar:/jars/aws-java-sdk-bundle-1.12.262.jar\",
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

echo ""
echo "[3/3] Done."
echo "✓  Cleanup complete. Run scripts/03-iceberg-write-demo.sh to start fresh."
