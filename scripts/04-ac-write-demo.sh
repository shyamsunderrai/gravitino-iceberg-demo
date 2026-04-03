#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 04-ac-write-demo.sh
#
# Submits a Spark job that demonstrates cross-catalog federation:
#   1. Reads sensor_readings from oc_iceberg (operational catalog via Gravitino)
#   2. Deduplicates rows
#   3. Adds a "ranking" column:
#        value  0–20  → A
#        value 21–50  → B
#        value  > 50  → C
#   4. Writes sensor_readings_ac to ac_iceberg (analytical catalog, AC-HMS)
#
# Read path:  Spark → Gravitino Iceberg REST (:9001) → OC-HMS → SeaweedFS
# Write path: Spark → AC-HMS (direct Hive catalog)  → SeaweedFS analytical
#
# Prerequisites:
#   - Infrastructure deployed: bash scripts/01-deploy-all.sh
#   - Catalogs registered:     bash scripts/02-register-catalogs.sh
#   - Iceberg demo run first:  bash scripts/03-iceberg-write-demo.sh
#   - JARs downloaded:         bash scripts/00-download-jars.sh
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR_DIR="$(cd "${SCRIPT_DIR}/../jars" && pwd)"
NAMESPACE="gravitino"
POD_NAME="gravitino-ac-spark-demo"
CONFIGMAP_NAME="gravitino-ac-spark-script"
SCRIPT_FILE="/tmp/gravitino-ac-spark-demo.py"

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
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, when

spark = SparkSession.builder.appName("gravitino-ac-write-demo").getOrCreate()
spark.sparkContext.setLogLevel("WARN")

src_catalog = "oc_iceberg"
dst_catalog = "ac_iceberg"
db          = "poc_demo"
src_full    = f"`{src_catalog}`.{db}.sensor_readings"
dst_full    = f"`{dst_catalog}`.{db}.sensor_readings_ac"

print(f"\n=== [1/4] Reading and deduplicating from {src_full} ===")
df_raw = spark.sql(f"SELECT * FROM {src_full}")
df_dedup = df_raw.dropDuplicates()
print(f"    Raw rows: {df_raw.count()}  |  After dedup: {df_dedup.count()}")

print("=== [2/4] Adding ranking column (A: 0-20, B: 21-50, C: >50) ===")
df_ranked = df_dedup.withColumn(
    "ranking",
    when(col("value") <= 20, "A")
    .when((col("value") > 20) & (col("value") <= 50), "B")
    .otherwise("C")
)
df_ranked.createOrReplaceTempView("ranked_data")

print(f"=== [3/4] Creating destination table {dst_full} (if not exists) ===")
spark.sql(f"CREATE DATABASE IF NOT EXISTS `{dst_catalog}`.{db}")
spark.sql(f"""
    CREATE TABLE IF NOT EXISTS {dst_full} (
        sensor_id   INT,
        location    STRING,
        metric      STRING,
        value       DOUBLE,
        recorded_at TIMESTAMP,
        ranking     STRING
    ) USING iceberg
    TBLPROPERTIES (
        'write.format.default'            = 'parquet',
        'write.parquet.compression-codec' = 'snappy'
    )
""")
print("    Table ready.")

print(f"=== [4/4] Writing to {dst_full} ===")
spark.sql(f"""
    INSERT OVERWRITE {dst_full}
    SELECT sensor_id, location, metric, value, recorded_at, ranking
    FROM ranked_data ORDER BY sensor_id
""")

print(f"\n=== Results: {dst_full} ===")
spark.sql(f"SELECT * FROM {dst_full} ORDER BY sensor_id").show(truncate=False)

print("=== Iceberg snapshot history ===")
spark.sql(f"SELECT snapshot_id, committed_at, operation FROM {dst_full}.snapshots").show(truncate=False)

print("=== Iceberg files (confirms Parquet on analytical bucket) ===")
spark.sql(f"SELECT file_path, file_format, record_count FROM {dst_full}.files").show(truncate=False)

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
