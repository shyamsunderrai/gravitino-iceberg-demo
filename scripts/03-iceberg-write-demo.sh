#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 03-iceberg-write-demo.sh
#
# Submits a Spark job that:
#   1. Creates an Iceberg table in oc_iceberg.poc_demo (if not exists)
#   2. Inserts 10 sensor records as a single Parquet file
#   3. Reads back the data + shows Iceberg snapshot history and file listing
#
# Write path: Spark → Gravitino Iceberg REST (:9001) → OC-HMS → SeaweedFS S3
#
# Prerequisites:
#   - Infrastructure deployed: bash scripts/01-deploy-all.sh
#   - Catalogs registered:     bash scripts/02-register-catalogs.sh
#   - JARs downloaded:         bash scripts/00-download-jars.sh
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR_DIR="$(cd "${SCRIPT_DIR}/../jars" && pwd)"
NAMESPACE="gravitino"
POD_NAME="gravitino-iceberg-spark-demo"
CONFIGMAP_NAME="gravitino-iceberg-spark-script"
SCRIPT_FILE="/tmp/gravitino-iceberg-spark-demo.py"

# Validate JARs
for JAR in iceberg-spark-runtime-3.5_2.12-1.6.1.jar hadoop-aws-3.3.4.jar aws-java-sdk-bundle-1.12.262.jar; do
  if [ ! -f "${JAR_DIR}/${JAR}" ]; then
    echo "ERROR: Missing JAR: ${JAR_DIR}/${JAR}"
    echo "       Run:  bash scripts/00-download-jars.sh"
    exit 1
  fi
done

# ── PySpark script ────────────────────────────────────────────────────────────
cat > "${SCRIPT_FILE}" << 'PYEOF'
from pyspark.sql import SparkSession, Row
from datetime import datetime

spark = SparkSession.builder.appName("gravitino-iceberg-write-demo").getOrCreate()
spark.sparkContext.setLogLevel("WARN")

catalog = "oc_iceberg"
db      = "poc_demo"
table   = "sensor_readings"
full    = f"`{catalog}`.{db}.{table}"

print(f"\n=== [0/3] Ensuring namespace {catalog}.{db} ===")
spark.sql(f"CREATE NAMESPACE IF NOT EXISTS `{catalog}`.{db}")
print(f"    Namespace ready.")

print(f"\n=== [1/3] Creating Iceberg table {full} (if not exists) ===")
spark.sql(f"""
    CREATE TABLE IF NOT EXISTS {full} (
        sensor_id   INT,
        location    STRING,
        metric      STRING,
        value       DOUBLE,
        recorded_at TIMESTAMP
    ) USING iceberg
    TBLPROPERTIES (
        'write.format.default'            = 'parquet',
        'write.parquet.compression-codec' = 'snappy'
    )
""")
print("    Table ready — format: iceberg / file-format: parquet/snappy")

print(f"=== [2/3] Inserting 10 records (coalesced to 1 Parquet file) ===")
rows = [
    Row(sensor_id=1,  location='warehouse-a', metric='temperature', value=22.5,  recorded_at=datetime(2024,1,15,8,0,0)),
    Row(sensor_id=2,  location='warehouse-a', metric='humidity',    value=55.3,  recorded_at=datetime(2024,1,15,8,0,0)),
    Row(sensor_id=3,  location='warehouse-b', metric='temperature', value=19.8,  recorded_at=datetime(2024,1,15,8,5,0)),
    Row(sensor_id=4,  location='warehouse-b', metric='humidity',    value=62.1,  recorded_at=datetime(2024,1,15,8,5,0)),
    Row(sensor_id=5,  location='server-room', metric='temperature', value=18.2,  recorded_at=datetime(2024,1,15,8,10,0)),
    Row(sensor_id=6,  location='server-room', metric='humidity',    value=40.0,  recorded_at=datetime(2024,1,15,8,10,0)),
    Row(sensor_id=7,  location='warehouse-a', metric='temperature', value=23.1,  recorded_at=datetime(2024,1,15,8,15,0)),
    Row(sensor_id=8,  location='warehouse-b', metric='temperature', value=20.4,  recorded_at=datetime(2024,1,15,8,15,0)),
    Row(sensor_id=9,  location='server-room', metric='temperature', value=17.9,  recorded_at=datetime(2024,1,15,8,20,0)),
    Row(sensor_id=10, location='server-room', metric='humidity',    value=41.5,  recorded_at=datetime(2024,1,15,8,20,0)),
]
spark.createDataFrame(rows).coalesce(1).writeTo(full).append()

print(f"\n=== [3/3] Reading back records ===")
spark.sql(f"SELECT * FROM {full} ORDER BY sensor_id").show(truncate=False)

print("=== Iceberg snapshot history ===")
spark.sql(f"SELECT snapshot_id, committed_at, operation FROM {full}.snapshots").show(truncate=False)

print("=== Iceberg files (confirms single Parquet file) ===")
spark.sql(f"SELECT file_path, file_format, record_count FROM {full}.files").show(truncate=False)

print("=== Done ===")
spark.stop()
PYEOF

# ── Deploy and run ────────────────────────────────────────────────────────────
echo "[1/4] Updating ConfigMap '${CONFIGMAP_NAME}'..."
kubectl delete configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl create configmap "${CONFIGMAP_NAME}" --from-file=spark-demo.py="${SCRIPT_FILE}" -n "${NAMESPACE}"

echo "[2/4] Cleaning up previous pod..."
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found

echo "[3/4] Submitting Spark job..."
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
          \"--conf\", \"spark.sql.catalog.oc_iceberg=org.apache.iceberg.spark.SparkCatalog\",
          \"--conf\", \"spark.sql.catalog.oc_iceberg.type=rest\",
          \"--conf\", \"spark.sql.catalog.oc_iceberg.uri=http://gravitino.gravitino.svc.cluster.local:9001/iceberg\",
          \"--conf\", \"spark.sql.catalog.oc_iceberg.io-impl=org.apache.iceberg.hadoop.HadoopFileIO\",
          \"--conf\", \"spark.sql.warehouse.dir=/tmp/spark-warehouse\",
          \"--conf\", \"spark.hadoop.fs.s3a.endpoint=http://seaweedfs-filer.gravitino.svc.cluster.local:8333\",
          \"--conf\", \"spark.hadoop.fs.s3a.access.key=admin\",
          \"--conf\", \"spark.hadoop.fs.s3a.secret.key=admin\",
          \"--conf\", \"spark.hadoop.fs.s3a.path.style.access=true\",
          \"--conf\", \"spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem\",
          \"--conf\", \"spark.hadoop.fs.s3a.connection.ssl.enabled=false\",
          \"--conf\", \"spark.hadoop.fs.s3a.fast.upload=true\",
          \"/script/spark-demo.py\"
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

echo "[4/4] Waiting for pod to complete..."
TIMEOUT=300; ELAPSED=0
while true; do
  PHASE=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  case "${PHASE}" in
    Succeeded) break ;;
    Failed)
      echo "ERROR: Pod failed. Logs:"
      kubectl logs "${POD_NAME}" -n "${NAMESPACE}" || true
      exit 1 ;;
    *)
      [ "${ELAPSED}" -ge "${TIMEOUT}" ] && { echo "ERROR: Timeout"; exit 1; }
      sleep 5; ELAPSED=$(( ELAPSED + 5 )) ;;
  esac
done

echo ""
echo "════════════════════════════════════════════════════════════"
echo " Spark Job Output"
echo "════════════════════════════════════════════════════════════"
kubectl logs "${POD_NAME}" -n "${NAMESPACE}" \
  | grep -vE "^[0-9]{2}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (INFO|WARN)"
echo "════════════════════════════════════════════════════════════"
