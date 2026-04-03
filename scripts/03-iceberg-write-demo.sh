#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 03-iceberg-write-demo.sh
#
# Submits a Spark job that:
#   1. Creates an Iceberg table in oc_iceberg.poc_demo (if not exists)
#   2. Inserts 10 sensor records as a single Parquet file
#   3. Reads back the data + shows Iceberg snapshot history and file listing
#
# AUTHENTICATION FLOW (with SPIFFE/SPIRE):
#
#   Before Spark starts, an init container runs and:
#     1. Connects to the SPIRE Agent socket (/run/spire/sockets/agent.sock)
#     2. SPIRE Agent attests this pod via Kubernetes API:
#          - Reads this pod's metadata (namespace + labels)
#          - Finds workload entry matching k8s:pod-label:spiffe-workload:spark-oc-writer
#          - Requests JWT-SVID from SPIRE Server
#     3. Receives JWT-SVID:
#          { "sub": "spiffe://gravitino.demo/spark-oc-writer",
#            "iss": "http://spire-oidc.gravitino.svc.cluster.local:8008",
#            "aud": ["gravitino"], "exp": <now+5min> }
#     4. Writes JWT to a shared emptyDir volume (/run/spire/jwt/token)
#
#   Spark then starts and:
#     5. Reads the JWT from /run/spire/jwt/token
#     6. Passes it to spark-submit as:
#          --conf spark.sql.catalog.oc_iceberg.token=<jwt>
#     7. Iceberg REST catalog client sends every request to Gravitino as:
#          Authorization: Bearer <jwt>
#     8. Gravitino validates JWT against SPIRE OIDC JWKS endpoint
#     9. Gravitino checks RBAC: spark-oc-writer → oc_writer_role
#          oc_writer_role has MODIFY_TABLE on oc_iceberg → ALLOWED
#
# Write path: Spark → Gravitino Iceberg REST (:9001) → OC-HMS → SeaweedFS S3
#
# Prerequisites:
#   - Infrastructure deployed: bash scripts/01-deploy-all.sh
#   - Catalogs registered:     bash scripts/02-register-catalogs.sh
#   - SPIRE deployed:          bash scripts/06-setup-spire.sh
#   - RBAC configured:         bash scripts/07-setup-rbac.sh
#   - JARs downloaded:         bash scripts/00-download-jars.sh
#
#   Without SPIRE (main branch / no OAuth2 on Gravitino):
#   The init container will fail to get a JWT. The script detects this and
#   falls back to running Spark without an auth token.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR_DIR="$(cd "${SCRIPT_DIR}/../jars" && pwd)"
NAMESPACE="gravitino"
POD_NAME="gravitino-iceberg-spark-demo"
CONFIGMAP_NAME="gravitino-iceberg-spark-script"
SCRIPT_FILE="/tmp/gravitino-iceberg-spark-demo.py"
WRAPPER_FILE="/tmp/gravitino-spark-oc-wrapper.sh"

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
import os

spark = SparkSession.builder.appName("gravitino-iceberg-write-demo").getOrCreate()
spark.sparkContext.setLogLevel("WARN")

# ── Show SPIFFE identity in use ────────────────────────────────────────────────
# The JWT-SVID was injected into the Spark catalog config before submission.
# Here we read it back from the SparkConf so we can decode and display the
# SPIFFE ID — proving which identity this Spark job is running as.
jwt_token = spark.conf.get("spark.sql.catalog.oc_iceberg.token", "")
if jwt_token:
    import base64, json
    try:
        # JWT structure: header.payload.signature  (all base64url encoded)
        # We only need the payload (middle part) to see the claims.
        payload_b64 = jwt_token.split(".")[1]
        # base64url padding: JWT omits '=' padding, add it back for Python decoder
        padding = 4 - len(payload_b64) % 4
        payload_b64 += "=" * (padding % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64).decode("utf-8"))
        print("\n" + "="*60)
        print(" SPIFFE Identity in use:")
        print(f"   sub (SPIFFE ID): {payload.get('sub', 'n/a')}")
        print(f"   iss (Issuer):    {payload.get('iss', 'n/a')}")
        print(f"   aud (Audience):  {payload.get('aud', 'n/a')}")
        import time
        exp_ts = payload.get('exp', 0)
        exp_remaining = max(0, int(exp_ts - time.time()))
        print(f"   exp (Expires):   {exp_remaining}s from now")
        print("="*60 + "\n")
    except Exception as e:
        print(f"\n[SPIFFE] Token present but could not decode: {e}\n")
else:
    print("\n[SPIFFE] No JWT-SVID found — running without authentication")
    print("         (SPIRE not deployed, or Gravitino OAuth2 not enabled)\n")

catalog = "oc_iceberg"
db      = "poc_demo"
table   = "sensor_readings"
full    = f"`{catalog}`.{db}.{table}"

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

# ── Wrapper shell script ──────────────────────────────────────────────────────
# This wrapper runs inside the Spark container. It:
#   1. Reads the JWT-SVID written by the init container
#   2. Logs the SPIFFE identity for visibility
#   3. Passes the JWT to spark-submit via --conf
#
# WHY A WRAPPER SCRIPT?
#   The JWT is dynamic (different every run, expires in 5 minutes). We can't
#   hard-code it into the kubectl run command. The init container writes it
#   to a shared volume, and this wrapper reads it at runtime before exec'ing
#   spark-submit.
#
#   Using "exec" replaces the shell process with spark-submit, so signals
#   (SIGTERM from kubectl) are properly forwarded to Spark.
cat > "${WRAPPER_FILE}" << WRAPEOF
#!/usr/bin/env sh
set -e

JWT_FILE="/run/spire/jwt/token"
JWT_TOKEN=""

# ── Read JWT-SVID from shared volume ─────────────────────────────────────────
if [ -f "\${JWT_FILE}" ] && [ -s "\${JWT_FILE}" ]; then
    JWT_TOKEN=\$(cat "\${JWT_FILE}")
    echo "[SPIFFE] JWT-SVID loaded from \${JWT_FILE}"
    echo "[SPIFFE] First 60 chars of token: \$(echo \${JWT_TOKEN} | cut -c1-60)..."
else
    echo "[SPIFFE] WARNING: No JWT-SVID found at \${JWT_FILE}"
    echo "[SPIFFE] Running without authentication token."
    echo "[SPIFFE] If SPIRE is deployed, check init container logs:"
    echo "[SPIFFE]   kubectl logs ${POD_NAME} -n ${NAMESPACE} -c fetch-spire-jwt"
fi

# ── Execute spark-submit with JWT token ──────────────────────────────────────
# The --conf spark.sql.catalog.oc_iceberg.token=\$JWT_TOKEN tells the Iceberg
# REST catalog client to include this JWT as a Bearer token in every HTTP
# request to Gravitino's Iceberg REST endpoint (port 9001).
#
# Gravitino then validates the JWT against SPIRE's OIDC JWKS endpoint and
# enforces RBAC: spark-oc-writer has MODIFY_TABLE on oc_iceberg → ALLOWED.
exec /opt/spark/bin/spark-submit \\
  --master local[*] \\
  --jars /jars/iceberg-spark-runtime-3.5_2.12-1.6.1.jar,/jars/hadoop-aws-3.3.4.jar,/jars/aws-java-sdk-bundle-1.12.262.jar \\
  --driver-class-path /jars/iceberg-spark-runtime-3.5_2.12-1.6.1.jar:/jars/hadoop-aws-3.3.4.jar:/jars/aws-java-sdk-bundle-1.12.262.jar \\
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \\
  --conf spark.sql.catalog.oc_iceberg=org.apache.iceberg.spark.SparkCatalog \\
  --conf spark.sql.catalog.oc_iceberg.type=rest \\
  --conf spark.sql.catalog.oc_iceberg.uri=http://gravitino.gravitino.svc.cluster.local:9001/iceberg \\
  --conf spark.sql.catalog.oc_iceberg.io-impl=org.apache.iceberg.hadoop.HadoopFileIO \\
  --conf "spark.sql.catalog.oc_iceberg.token=\${JWT_TOKEN}" \\
  --conf spark.sql.warehouse.dir=/tmp/spark-warehouse \\
  --conf spark.hadoop.fs.s3a.endpoint=http://seaweedfs-filer.gravitino.svc.cluster.local:8333 \\
  --conf spark.hadoop.fs.s3a.access.key=admin \\
  --conf spark.hadoop.fs.s3a.secret.key=admin \\
  --conf spark.hadoop.fs.s3a.path.style.access=true \\
  --conf spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem \\
  --conf spark.hadoop.fs.s3a.connection.ssl.enabled=false \\
  --conf spark.hadoop.fs.s3a.fast.upload=true \\
  /script/spark-demo.py
WRAPEOF

# ── Deploy and run ────────────────────────────────────────────────────────────
echo "[1/4] Updating ConfigMap '${CONFIGMAP_NAME}'..."
kubectl delete configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl create configmap "${CONFIGMAP_NAME}" \
  --from-file=spark-demo.py="${SCRIPT_FILE}" \
  --from-file=run.sh="${WRAPPER_FILE}" \
  -n "${NAMESPACE}"

echo "[2/4] Cleaning up previous pod..."
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found

echo "[3/4] Submitting Spark job with SPIFFE identity: spark-oc-writer..."

# ── Pod label: spiffe-workload=spark-oc-writer ────────────────────────────────
# This label is the trigger for SPIRE workload attestation. When the init
# container calls the SPIRE Agent socket, the Agent:
#   1. Reads this pod's labels via Kubernetes API
#   2. Finds the workload entry: k8s:pod-label:spiffe-workload:spark-oc-writer
#   3. Issues JWT-SVID: sub=spiffe://gravitino.demo/spark-oc-writer
# Without this label, SPIRE won't issue a JWT (no matching entry).

kubectl run "${POD_NAME}" \
  --image=apache/spark:3.5.3 \
  --restart=Never \
  -n "${NAMESPACE}" \
  --overrides="{
    \"metadata\": {
      \"labels\": {
        \"spiffe-workload\": \"spark-oc-writer\"
      }
    },
    \"spec\": {
      \"initContainers\": [{
        \"name\": \"fetch-spire-jwt\",
        \"image\": \"ghcr.io/spiffe/spire-agent:1.9.6\",
        \"command\": [\"sh\", \"-c\",
          \"/opt/spire/bin/spire-agent api fetch jwt -audience gravitino -socketPath /run/spire/sockets/agent.sock 2>/dev/null | grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1 > /run/spire/jwt/token && echo '[SPIFFE] JWT-SVID written to /run/spire/jwt/token' && wc -c /run/spire/jwt/token || (echo '[SPIFFE] WARNING: Could not fetch JWT. SPIRE may not be deployed.' && touch /run/spire/jwt/token)\"],
        \"volumeMounts\": [
          {\"name\": \"spire-socket\", \"mountPath\": \"/run/spire/sockets\"},
          {\"name\": \"jwt-dir\",      \"mountPath\": \"/run/spire/jwt\"}
        ]
      }],
      \"containers\": [{
        \"name\": \"${POD_NAME}\",
        \"image\": \"apache/spark:3.5.3\",
        \"command\": [\"sh\", \"/script/run.sh\"],
        \"volumeMounts\": [
          {\"name\": \"jars\",        \"mountPath\": \"/jars\"},
          {\"name\": \"script\",      \"mountPath\": \"/script\"},
          {\"name\": \"spire-socket\",\"mountPath\": \"/run/spire/sockets\"},
          {\"name\": \"jwt-dir\",     \"mountPath\": \"/run/spire/jwt\"}
        ]
      }],
      \"volumes\": [
        {\"name\": \"jars\",   \"hostPath\": {\"path\": \"${JAR_DIR}\"}},
        {\"name\": \"script\", \"configMap\": {\"name\": \"${CONFIGMAP_NAME}\",
          \"defaultMode\": 493}},
        {\"name\": \"spire-socket\", \"hostPath\": {
          \"path\": \"/run/spire/sockets\", \"type\": \"DirectoryOrCreate\"}},
        {\"name\": \"jwt-dir\", \"emptyDir\": {}}
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
