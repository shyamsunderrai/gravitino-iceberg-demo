#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 02-register-catalogs.sh
#
# Bootstraps the Gravitino metalake and catalogs needed for the demo:
#   metalake : poc_layer
#   OC-HMS   : Operational Hive Metastore (hive provider)
#   oc_iceberg: Iceberg catalog backed by OC-HMS (lakehouse-iceberg provider)
#   AC-HMS   : Analytical Hive Metastore (hive provider)
#
# Re-running is safe — existing resources return HTTP 409 and are skipped.
#
# Prerequisites:
#   - kubectl configured and pointing to the right cluster
#   - Gravitino deployed and running in namespace gravitino
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

NAMESPACE="gravitino"
GRAVITINO_PORT=8090
LOCAL_PORT=18090
METALAKE="poc_layer"

echo "[1/5] Starting port-forward to Gravitino service on localhost:${LOCAL_PORT}..."
kubectl port-forward -n "${NAMESPACE}" svc/gravitino \
  "${LOCAL_PORT}:${GRAVITINO_PORT}" &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 3

# Helper: POST to Gravitino API
gravitino_post() {
  local path="$1"
  local body="$2"
  local label="$3"
  local code
  code=$(curl -s -o /tmp/gravitino_response.json -w "%{http_code}" \
    -X POST "http://localhost:${LOCAL_PORT}${path}" \
    -H "Content-Type: application/json" \
    -d "${body}")
  case "${code}" in
    200) echo "    ${label}: created." ;;
    409) echo "    ${label}: already exists — skipping." ;;
    *)
      echo "    ERROR ${label} (HTTP ${code}):"
      cat /tmp/gravitino_response.json
      exit 1
      ;;
  esac
}

# ── Step 2: Metalake ──────────────────────────────────────────────────────────
echo "[2/5] Ensuring metalake '${METALAKE}'..."
gravitino_post "/api/metalakes" \
  '{"name":"'"${METALAKE}"'","comment":"PoC layer metalake"}' \
  "Metalake '${METALAKE}'"

# ── Step 3: OC-HMS ────────────────────────────────────────────────────────────
echo "[3/5] Registering catalog 'OC-HMS'..."
gravitino_post "/api/metalakes/${METALAKE}/catalogs" \
  '{"name":"OC-HMS","type":"RELATIONAL","provider":"hive","comment":"Operational Hive Metastore","properties":{"metastore.uris":"thrift://hive-metastore.gravitino.svc.cluster.local:9083"}}' \
  "Catalog 'OC-HMS'"

# ── Step 4: oc_iceberg ────────────────────────────────────────────────────────
echo "[4/5] Registering catalog 'oc_iceberg'..."
gravitino_post "/api/metalakes/${METALAKE}/catalogs" \
  '{"name":"oc_iceberg","type":"RELATIONAL","provider":"lakehouse-iceberg","comment":"Iceberg catalog on OC-HMS + SeaweedFS operational bucket","properties":{"catalog-backend":"hive","uri":"thrift://hive-metastore.gravitino.svc.cluster.local:9083","warehouse":"s3a://operational/iceberg-warehouse"}}' \
  "Catalog 'oc_iceberg'"

# ── Step 5: AC-HMS ────────────────────────────────────────────────────────────
echo "[5/5] Registering catalog 'AC-HMS'..."
gravitino_post "/api/metalakes/${METALAKE}/catalogs" \
  '{"name":"AC-HMS","type":"RELATIONAL","provider":"hive","comment":"Analytical Hive Metastore","properties":{"metastore.uris":"thrift://hive-metastore-analytics.gravitino.svc.cluster.local:9083"}}' \
  "Catalog 'AC-HMS'"

echo ""
echo "✓  Setup complete: metalake '${METALAKE}' with catalogs OC-HMS, oc_iceberg, AC-HMS."
echo ""
echo "   Validate in Gravitino UI:"
echo "     kubectl port-forward -n gravitino svc/gravitino 8090:8090"
echo "     open http://localhost:8090"
