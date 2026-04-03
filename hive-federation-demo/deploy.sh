#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — One-command deployment of the Gravitino Hive Federation Demo
#
# Usage:
#   cd dev/charts/hive-federation-demo
#   bash deploy.sh [--namespace <ns>] [--storage-class <sc>]
#
# Options:
#   --namespace      Target namespace (default: gravitino-demo)
#   --storage-class  StorageClass for PVCs (default: cluster default)
#   --minio-user     MinIO root user     (default: admin)
#   --minio-password MinIO root password (default: password)
#   --dry-run        Print commands without executing
#
# Prerequisites:
#   kubectl  — configured against your target cluster
#   helm     — v3.x
#   Internet access from init containers (for JAR downloads from Maven Central)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
NAMESPACE="gravitino-demo"
STORAGE_CLASS=""
MINIO_USER="admin"
MINIO_PASSWORD="password"
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="$(dirname "$SCRIPT_DIR")"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)      NAMESPACE="$2";      shift 2 ;;
    --storage-class)  STORAGE_CLASS="$2";  shift 2 ;;
    --minio-user)     MINIO_USER="$2";     shift 2 ;;
    --minio-password) MINIO_PASSWORD="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true;        shift   ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
  else
    echo "+ $*"
    "$@"
  fi
}

banner() {
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════"
}

# ── Helm repo setup ───────────────────────────────────────────────────────────
banner "Step 0 — Helm repo + dependency setup"
run helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
run helm repo update bitnami

# Pull bitnami subchart dependencies for the gravitino chart
run helm dependency update "$CHARTS_DIR/gravitino"

# Pull local dependencies for the umbrella chart
run helm dependency update "$SCRIPT_DIR"

# ── Namespace ─────────────────────────────────────────────────────────────────
banner "Step 1 — Namespace"
run kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── MinIO ─────────────────────────────────────────────────────────────────────
banner "Step 2 — MinIO (object storage)"
MINIO_ARGS=(
  --namespace "$NAMESPACE"
  --set auth.rootUser="$MINIO_USER"
  --set auth.rootPassword="$MINIO_PASSWORD"
  --set defaultBuckets="hive-operational hive-analytical poc"
  --set persistence.size=10Gi
)
if [[ -n "$STORAGE_CLASS" ]]; then
  MINIO_ARGS+=(--set persistence.storageClass="$STORAGE_CLASS")
fi

if helm status demo-minio -n "$NAMESPACE" &>/dev/null; then
  echo "MinIO already installed, skipping."
else
  run helm install demo-minio bitnami/minio "${MINIO_ARGS[@]}" --wait --timeout=120s
fi

echo "==> Waiting for MinIO pod to be Ready..."
run kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=minio \
  -n "$NAMESPACE" --timeout=120s

# ── Gravitino PVC ─────────────────────────────────────────────────────────────
banner "Step 3 — Gravitino PVC"
PVC_SC_ARG=""
if [[ -n "$STORAGE_CLASS" ]]; then
  PVC_SC_ARG="--set gravitinoPvc.storageClass=$STORAGE_CLASS"
fi
# Apply just the PVC template before helm install (chart needs it pre-created)
run kubectl apply -f "$SCRIPT_DIR/templates/gravitino-pvc.yaml" -n "$NAMESPACE" $PVC_SC_ARG 2>/dev/null || \
  run helm template "$SCRIPT_DIR" --show-only templates/gravitino-pvc.yaml \
    ${PVC_SC_ARG:+--set gravitinoPvc.storageClass="$STORAGE_CLASS"} | \
    kubectl apply -n "$NAMESPACE" -f -

# ── Main chart — Gravitino + HMS A + HMS B ────────────────────────────────────
banner "Step 4 — Install Gravitino + Hive Metastore A + B"
HELM_ARGS=(
  --namespace "$NAMESPACE"
  --set minio.endpoint="http://demo-minio:9000"
  --set minio.accessKey="$MINIO_USER"
  --set minio.secretKey="$MINIO_PASSWORD"
  --set "hive-metastore-a.minio.endpoint=http://demo-minio:9000"
  --set "hive-metastore-a.minio.accessKey=$MINIO_USER"
  --set "hive-metastore-a.minio.secretKey=$MINIO_PASSWORD"
  --set "hive-metastore-b.minio.endpoint=http://demo-minio:9000"
  --set "hive-metastore-b.minio.accessKey=$MINIO_USER"
  --set "hive-metastore-b.minio.secretKey=$MINIO_PASSWORD"
)
if [[ -n "$STORAGE_CLASS" ]]; then
  HELM_ARGS+=(
    --set "hive-metastore-a.mysql.persistence.storageClass=$STORAGE_CLASS"
    --set "hive-metastore-b.mysql.persistence.storageClass=$STORAGE_CLASS"
    --set "gravitinoPvc.storageClass=$STORAGE_CLASS"
  )
fi

if helm status hive-federation-demo -n "$NAMESPACE" &>/dev/null; then
  echo "Chart already installed, upgrading..."
  run helm upgrade hive-federation-demo "$SCRIPT_DIR" "${HELM_ARGS[@]}"
else
  run helm install hive-federation-demo "$SCRIPT_DIR" "${HELM_ARGS[@]}"
fi

# ── Wait for all pods ─────────────────────────────────────────────────────────
banner "Step 5 — Wait for all pods to be Ready"
echo "Waiting for Gravitino..."
run kubectl wait --for=condition=ready pod -l app=gravitino \
  -n "$NAMESPACE" --timeout=180s

echo "Waiting for HMS A..."
run kubectl wait --for=condition=ready pod -l app=hive-metastore-a \
  -n "$NAMESPACE" --timeout=180s

echo "Waiting for HMS B..."
run kubectl wait --for=condition=ready pod -l app=hive-metastore-b \
  -n "$NAMESPACE" --timeout=180s

# ── Setup jobs ────────────────────────────────────────────────────────────────
banner "Step 6 — Download Spark connector JARs to MinIO"
run helm template hive-federation-demo "$SCRIPT_DIR" "${HELM_ARGS[@]}" \
  --show-only templates/jobs/01-jar-download-job.yaml | \
  kubectl apply -n "$NAMESPACE" -f -
echo "==> JAR download job running (may take 5-10 min on first run)..."
run kubectl wait --for=condition=complete job/demo-jar-download \
  -n "$NAMESPACE" --timeout=600s

banner "Step 7 — Register catalogs in Gravitino"
run helm template hive-federation-demo "$SCRIPT_DIR" "${HELM_ARGS[@]}" \
  --show-only templates/jobs/02-setup-catalogs-job.yaml | \
  kubectl apply -n "$NAMESPACE" -f -
run kubectl wait --for=condition=complete job/demo-setup-catalogs \
  -n "$NAMESPACE" --timeout=120s

banner "Step 8 — Create HMS A tables (operational_db)"
run helm template hive-federation-demo "$SCRIPT_DIR" "${HELM_ARGS[@]}" \
  --show-only templates/jobs/03-create-dummy-data-job.yaml | \
  kubectl apply -n "$NAMESPACE" -f -
run kubectl wait --for=condition=complete job/demo-create-tables \
  -n "$NAMESPACE" --timeout=180s

# ── Done ──────────────────────────────────────────────────────────────────────
banner "Deployment complete!"
echo ""
echo "  Namespace : $NAMESPACE"
echo "  MinIO     : kubectl port-forward svc/demo-minio 9000:9000 -n $NAMESPACE"
echo "              → http://localhost:9000  (user: $MINIO_USER)"
echo ""
echo "  Gravitino : kubectl port-forward svc/gravitino 8090:8090 -n $NAMESPACE"
echo "              → http://localhost:8090"
echo ""
echo "  Demo jobs (run in order from DEMO.md):"
echo "    kubectl apply -f ../gravitino/resources/scenarios/hive-demo/spark-write-demo-job.yaml -n $NAMESPACE"
echo "    kubectl apply -f ../gravitino/resources/scenarios/hive-demo/spark-insert-more-data-job.yaml -n $NAMESPACE"
echo "    kubectl apply -f ../gravitino/resources/scenarios/hive-demo/spark-analytics-federated-job.yaml -n $NAMESPACE"
echo ""
