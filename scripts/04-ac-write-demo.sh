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
# AUTHENTICATION + AUTHORIZATION FLOW (two paths, two mechanisms):
#
#   READ path  (Spark → Gravitino Iceberg REST → OC-HMS → SeaweedFS):
#   ─────────────────────────────────────────────────────────────────
#   The oc_iceberg Spark catalog uses type=rest, pointing at Gravitino's
#   Iceberg REST endpoint. With SPIFFE enabled:
#     1. Init container gets JWT-SVID: sub=spiffe://gravitino.demo/spark-ac-writer
#     2. JWT passed to spark-submit as spark.sql.catalog.oc_iceberg.token
#     3. Iceberg REST client sends: Authorization: Bearer <jwt>
#     4. Gravitino validates JWT, checks RBAC:
#          spark-ac-writer → ac_writer_role → SELECT_TABLE on oc_iceberg → ALLOWED
#     5. Data flows: Gravitino → OC-HMS thrift → HMS catalog lookup
#          → SeaweedFS S3 (Parquet read)
#
#   WRITE path (Spark → AC-HMS Thrift → SeaweedFS analytical):
#   ──────────────────────────────────────────────────────────
#   The ac_iceberg Spark catalog uses type=hive, connecting DIRECTLY to AC-HMS.
#   This bypasses Gravitino entirely for the write — which is intentional:
#   the analytical tier has its own metastore that Spark writes to directly.
#
#   How is this authorized?
#     • NetworkPolicy: allows pods labelled spiffe-workload=spark-ac-writer
#       to reach AC-HMS on port 9083 (the hive-metastore-analytics service)
#     • Pod label: this pod gets that exact label → TCP connection allowed
#     • If the pod had a different label (e.g., spark-oc-writer), the
#       NetworkPolicy would DROP the TCP SYN packet to AC-HMS → connection timeout
#
#   So for the write path, SPIFFE identity (the pod label) is what authorizes
#   the direct HMS connection via NetworkPolicy — no JWT validation at the
#   HMS layer (Thrift doesn't do JWT).
#
# POLICY SUMMARY:
#   oc_writer (spark-oc-writer identity):
#     → CAN write to oc_iceberg via Gravitino (RBAC: oc_writer_role)
#     → CANNOT write to ac_iceberg (NetworkPolicy blocks direct AC-HMS; RBAC blocks via Gravitino)
#
#   ac_writer (spark-ac-writer identity):
#     → CAN read from oc_iceberg via Gravitino (RBAC: SELECT_TABLE on oc_iceberg)
#     → CAN write to ac_iceberg directly (NetworkPolicy allows spark-ac-writer → AC-HMS)
#     → CANNOT write to oc_iceberg (RBAC denies MODIFY_TABLE on oc_iceberg)
#
# Prerequisites:
#   - 03-iceberg-write-demo.sh completed (sensor_readings table must exist)
#   - Infrastructure deployed:  bash scripts/01-deploy-all.sh
#   - Catalogs registered:      bash scripts/02-register-catalogs.sh
#   - SPIRE deployed:           bash scripts/06-setup-spire.sh
#   - RBAC configured:          bash scripts/07-setup-rbac.sh
#   - JARs downloaded:          bash scripts/00-download-jars.sh
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR_DIR="$(cd "${SCRIPT_DIR}/../jars" && pwd)"
NAMESPACE="gravitino"
POD_NAME="gravitino-ac-spark-demo"
CONFIGMAP_NAME="gravitino-ac-spark-script"
SCRIPT_FILE="/tmp/gravitino-ac-spark-demo.py"
WRAPPER_FILE="/tmp/gravitino-spark-ac-wrapper.sh"

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

# ── Show SPIFFE identity in use ────────────────────────────────────────────────
# The JWT-SVID sub claim tells us which SPIFFE identity this pod has.
# For this job it should be: spiffe://gravitino.demo/spark-ac-writer
# The ac_writer identity has:
#   READ access to oc_iceberg (this SELECT below will succeed)
#   WRITE access to ac catalog (the INSERT below will succeed)
jwt_token = spark.conf.get("spark.sql.catalog.oc_iceberg.token", "")
if jwt_token:
    import base64, json, time
    try:
        payload_b64 = jwt_token.split(".")[1]
        padding = 4 - len(payload_b64) % 4
        payload_b64 += "=" * (padding % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64).decode("utf-8"))
        print("\n" + "="*60)
        print(" SPIFFE Identity in use:")
        print(f"   sub (SPIFFE ID): {payload.get('sub', 'n/a')}")
        print(f"   iss (Issuer):    {payload.get('iss', 'n/a')}")
        print(f"   aud (Audience):  {payload.get('aud', 'n/a')}")
        exp_remaining = max(0, int(payload.get('exp', 0) - time.time()))
        print(f"   exp (Expires):   {exp_remaining}s from now")
        print("="*60 + "\n")
        print(" Authorization check (expected from Gravitino RBAC):")
        print("   oc_iceberg SELECT  → ALLOWED (ac_writer_role has SELECT_TABLE)")
        print("   ac catalog  WRITE  → ALLOWED (ac_writer_role has MODIFY_TABLE)")
        print("   oc_iceberg  WRITE  → DENIED  (ac_writer_role has SELECT_TABLE only)")
        print("="*60 + "\n")
    except Exception as e:
        print(f"\n[SPIFFE] Token present but could not decode: {e}\n")
else:
    print("\n[SPIFFE] No JWT-SVID found — running without authentication")
    print("         (SPIRE not deployed, or Gravitino OAuth2 not enabled)\n")

src_catalog = "oc_iceberg"
dst_catalog = "ac_iceberg"
db          = "poc_demo"
src_full    = f"`{src_catalog}`.{db}.sensor_readings"
dst_full    = f"`{dst_catalog}`.{db}.sensor_readings_ac"

print(f"\n=== [1/4] Reading and deduplicating from {src_full} ===")
print(f"    (READ path: Spark → Gravitino REST :9001 → OC-HMS)")
print(f"    (Auth: JWT-SVID with sub=spiffe://gravitino.demo/spark-ac-writer)")
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
print(f"    (WRITE path: Spark → AC-HMS Thrift directly)")
print(f"    (Auth: NetworkPolicy allows pod label spiffe-workload=spark-ac-writer)")
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

# ── Wrapper shell script ──────────────────────────────────────────────────────
cat > "${WRAPPER_FILE}" << WRAPEOF
#!/usr/bin/env sh
set -e

JWT_FILE="/run/spire/jwt/token"
JWT_SECRET_FILE="/run/spire/jwt-secret/token"
JWT_TOKEN=""

# Priority: pre-minted Secret (Docker Desktop workaround) → workload API
if [ -f "\${JWT_SECRET_FILE}" ] && [ -s "\${JWT_SECRET_FILE}" ]; then
    JWT_TOKEN=\$(cat "\${JWT_SECRET_FILE}")
    echo "[SPIFFE] JWT-SVID loaded from pre-minted Secret (server-side mint)"
    echo "[SPIFFE] First 60 chars of token: \$(echo \${JWT_TOKEN} | cut -c1-60)..."
elif [ -f "\${JWT_FILE}" ] && [ -s "\${JWT_FILE}" ]; then
    JWT_TOKEN=\$(cat "\${JWT_FILE}")
    echo "[SPIFFE] JWT-SVID loaded from workload API at \${JWT_FILE}"
    echo "[SPIFFE] First 60 chars of token: \$(echo \${JWT_TOKEN} | cut -c1-60)..."
else
    echo "[SPIFFE] WARNING: No JWT-SVID found at either source"
    echo "[SPIFFE] Running without authentication token."
fi

# Only pass token conf when non-empty — an empty Bearer token causes 401.
TOKEN_CONF=""
if [ -n "\${JWT_TOKEN}" ]; then
    TOKEN_CONF="--conf spark.sql.catalog.oc_iceberg.token=\${JWT_TOKEN}"
    echo "[SPIFFE] Running Spark with SPIFFE Bearer token."
else
    echo "[SPIFFE] Running Spark without auth token (no SPIRE or token empty)."
fi

# ── Two catalogs, two auth models ─────────────────────────────────────────────
#
# oc_iceberg (type=rest):
#   Token is passed via spark.sql.catalog.oc_iceberg.token
#   → Iceberg REST client sends Authorization: Bearer <jwt>
#   → Gravitino validates JWT and checks RBAC (SELECT allowed for ac_writer)
#
# ac_iceberg (type=hive):
#   No JWT needed — connects directly to AC-HMS via Thrift
#   → Authorization is via NetworkPolicy (pod label spiffe-workload=spark-ac-writer)
#   → NetworkPolicy rule: allow-to-ac-hms permits this pod to reach port 9083
#
exec /opt/spark/bin/spark-submit \\
  --master local[*] \\
  --jars /jars/iceberg-spark-runtime-3.5_2.12-1.6.1.jar,/jars/hadoop-aws-3.3.4.jar,/jars/aws-sdk-java-bundle-2.26.20.jar \\
  --driver-class-path /jars/iceberg-spark-runtime-3.5_2.12-1.6.1.jar:/jars/hadoop-aws-3.3.4.jar:/jars/aws-sdk-java-bundle-2.26.20.jar \\
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \\
  --conf spark.sql.warehouse.dir=/tmp/spark-warehouse \\
  --conf spark.sql.catalog.oc_iceberg=org.apache.iceberg.spark.SparkCatalog \\
  --conf spark.sql.catalog.oc_iceberg.type=rest \\
  --conf spark.sql.catalog.oc_iceberg.uri=http://gravitino.gravitino.svc.cluster.local:9001/iceberg \\
  --conf spark.sql.catalog.oc_iceberg.s3.access-key-id=admin \\
  --conf spark.sql.catalog.oc_iceberg.s3.secret-access-key=admin \\
  --conf spark.sql.catalog.oc_iceberg.s3.endpoint=http://seaweedfs-filer.gravitino.svc.cluster.local:8333 \\
  --conf spark.sql.catalog.oc_iceberg.s3.path-style-access=true \\
  \${TOKEN_CONF} \\
  --conf spark.sql.catalog.ac_iceberg=org.apache.iceberg.spark.SparkCatalog \\
  --conf spark.sql.catalog.ac_iceberg.type=hive \\
  --conf spark.sql.catalog.ac_iceberg.uri=thrift://hive-metastore-analytics.gravitino.svc.cluster.local:9083 \\
  --conf spark.sql.catalog.ac_iceberg.warehouse=s3://analytical/iceberg-warehouse \\
  --conf spark.sql.catalog.ac_iceberg.io-impl=org.apache.iceberg.aws.s3.S3FileIO \\
  --conf spark.sql.catalog.ac_iceberg.s3.access-key-id=admin \\
  --conf spark.sql.catalog.ac_iceberg.s3.secret-access-key=admin \\
  --conf spark.sql.catalog.ac_iceberg.s3.endpoint=http://seaweedfs-filer.gravitino.svc.cluster.local:8333 \\
  --conf spark.sql.catalog.ac_iceberg.s3.path-style-access=true \\
  --conf spark.sql.catalog.ac_iceberg.client.region=us-east-1 \\
  /script/spark-demo.py
WRAPEOF

# ── Pre-flight: clean stale AC-HMS entries + ensure schemas exist ─────────────
# NOTE: Do NOT clean OC-HMS here — sensor_readings was written by 03-iceberg-write-demo.sh
# and is needed for the READ step. Only clean AC-HMS to remove stale table entries.
echo "[0/4] Pre-flight: cleaning stale AC-HMS entries and ensuring schemas..."
kubectl exec -n "${NAMESPACE}" deployment/hive-metastore-analytics-mysql -- \
  mysql -uroot -phiveroot hive_metastore -e "
    SET FOREIGN_KEY_CHECKS=0;
    DELETE FROM TABLE_PARAMS WHERE TBL_ID IN (
      SELECT TBL_ID FROM TBLS WHERE DB_ID IN (
        SELECT DB_ID FROM DBS WHERE NAME='poc_demo'));
    DELETE FROM TBLS WHERE DB_ID IN (SELECT DB_ID FROM DBS WHERE NAME='poc_demo');
    DELETE FROM DBS WHERE NAME='poc_demo';
    SET FOREIGN_KEY_CHECKS=1;
  " 2>/dev/null || true

# Create poc_demo schema in AC-HMS via Gravitino management API
# Catalog name in Gravitino is "AC-HMS" (as registered in 02-register-catalogs.sh)
kubectl port-forward -n "${NAMESPACE}" svc/gravitino 18090:8090 &>/dev/null &
PF_PID=$!
sleep 3
curl -s -o /dev/null -X POST \
  "http://localhost:18090/api/metalakes/poc_layer/catalogs/AC-HMS/schemas" \
  -H "Content-Type: application/json" \
  -d '{"name":"poc_demo","comment":"Demo schema","properties":{}}' || true
kill "${PF_PID}" 2>/dev/null || true

# ── Deploy and run ────────────────────────────────────────────────────────────
echo "[1/4] Updating ConfigMap '${CONFIGMAP_NAME}'..."
kubectl delete configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl create configmap "${CONFIGMAP_NAME}" \
  --from-file=spark-demo.py="${SCRIPT_FILE}" \
  --from-file=run.sh="${WRAPPER_FILE}" \
  -n "${NAMESPACE}"

echo "[2/4] Cleaning up previous pod..."
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found

echo "[3/4] Submitting Spark job with SPIFFE identity: spark-ac-writer..."

# ── Pre-mint JWT via SPIRE Server (Docker Desktop workaround) ─────────────────
SPIRE_SERVER_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=spire-server \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
PRE_MINTED_JWT=""
if [ -n "${SPIRE_SERVER_POD}" ]; then
  PRE_MINTED_JWT=$(kubectl exec -n "${NAMESPACE}" "${SPIRE_SERVER_POD}" -c spire-server -- \
    /opt/spire/bin/spire-server jwt mint \
    -spiffeID spiffe://gravitino.demo/spark-ac-writer \
    -audience gravitino \
    -socketPath /run/spire/sockets/server.sock 2>/dev/null | tr -d '\n') || PRE_MINTED_JWT=""
fi

kubectl delete secret ac-writer-jwt -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1
if [ -n "${PRE_MINTED_JWT}" ]; then
  kubectl create secret generic ac-writer-jwt \
    --from-literal=token="${PRE_MINTED_JWT}" \
    -n "${NAMESPACE}" > /dev/null 2>&1
  echo "    [SPIFFE] Pre-minted JWT injected via Secret (Docker Desktop workaround)"
  echo "    [SPIFFE] Identity: spiffe://gravitino.demo/spark-ac-writer"
else
  kubectl create secret generic ac-writer-jwt \
    --from-literal=token="" \
    -n "${NAMESPACE}" > /dev/null 2>&1
  echo "    [SPIFFE] No SPIRE Server found — Spark will run without auth token"
fi

# ── Pod label: spiffe-workload=spark-ac-writer ────────────────────────────────
# Two effects of this label:
#   1. SPIRE workload attestation → JWT-SVID: spiffe://gravitino.demo/spark-ac-writer
#   2. NetworkPolicy enforcement  → allow-to-ac-hms permits this pod to reach AC-HMS

kubectl run "${POD_NAME}" \
  --image=apache/spark:3.5.3 \
  --restart=Never \
  -n "${NAMESPACE}" \
  --overrides="{
    \"metadata\": {
      \"labels\": {
        \"spiffe-workload\": \"spark-ac-writer\"
      }
    },
    \"spec\": {
      \"initContainers\": [{
        \"name\": \"fetch-spire-jwt\",
        \"image\": \"busybox:1.36\",
        \"command\": [\"sh\", \"-c\",
          \"/jars/spire-agent api fetch jwt -audience gravitino -socketPath /run/spire/sockets/agent.sock 2>/dev/null | grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1 > /run/spire/jwt/token && echo '[SPIFFE] JWT-SVID written' && wc -c /run/spire/jwt/token || (echo '[SPIFFE] WARNING: JWT fetch failed' && touch /run/spire/jwt/token)\"],
        \"volumeMounts\": [
          {\"name\": \"jars\",        \"mountPath\": \"/jars\"},
          {\"name\": \"spire-socket\", \"mountPath\": \"/run/spire/sockets\"},
          {\"name\": \"jwt-dir\",      \"mountPath\": \"/run/spire/jwt\"}
        ]
      }],
      \"containers\": [{
        \"name\": \"${POD_NAME}\",
        \"image\": \"apache/spark:3.5.3\",
        \"command\": [\"sh\", \"/script/run.sh\"],
        \"volumeMounts\": [
          {\"name\": \"jars\",         \"mountPath\": \"/jars\"},
          {\"name\": \"script\",       \"mountPath\": \"/script\"},
          {\"name\": \"spire-socket\", \"mountPath\": \"/run/spire/sockets\"},
          {\"name\": \"jwt-dir\",      \"mountPath\": \"/run/spire/jwt\"},
          {\"name\": \"jwt-secret\",   \"mountPath\": \"/run/spire/jwt-secret\",
           \"readOnly\": true}
        ]
      }],
      \"volumes\": [
        {\"name\": \"jars\",   \"hostPath\": {\"path\": \"${JAR_DIR}\"}},
        {\"name\": \"script\", \"configMap\": {\"name\": \"${CONFIGMAP_NAME}\",
          \"defaultMode\": 493}},
        {\"name\": \"spire-socket\", \"hostPath\": {
          \"path\": \"/run/spire/sockets\", \"type\": \"DirectoryOrCreate\"}},
        {\"name\": \"jwt-dir\", \"emptyDir\": {}},
        {\"name\": \"jwt-secret\", \"secret\": {\"secretName\": \"ac-writer-jwt\"}}
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
      kubectl logs "${POD_NAME}" -n "${NAMESPACE}" --all-containers=true || true
      exit 1 ;;
    *)
      [ "${ELAPSED}" -ge "${TIMEOUT}" ] && { echo "ERROR: Timeout"; exit 1; }
      sleep 5; ELAPSED=$(( ELAPSED + 5 )) ;;
  esac
done

echo ""
echo "════════════════════════════════════════════════════════════"
echo " Init container (SPIFFE JWT fetch) logs:"
echo "════════════════════════════════════════════════════════════"
kubectl logs "${POD_NAME}" -n "${NAMESPACE}" -c fetch-spire-jwt 2>/dev/null || \
  echo "(init container logs not available)"

echo ""
echo "════════════════════════════════════════════════════════════"
echo " Spark Job Output"
echo "════════════════════════════════════════════════════════════"
kubectl logs "${POD_NAME}" -n "${NAMESPACE}" \
  | grep -vE "^[0-9]{2}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (INFO|WARN)"
echo "════════════════════════════════════════════════════════════"
