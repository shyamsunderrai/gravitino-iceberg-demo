#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 01-deploy-all.sh
#
# End-to-end deployment of the Gravitino Iceberg Federation Demo on a local
# Kubernetes cluster (Docker Desktop, Rancher Desktop, kind, etc.).
#
# Deploys:
#   1. gravitino namespace
#   2. SeaweedFS (S3-compatible object store)
#   3. S3 buckets: operational, analytical
#   4. Gravitino (metadata lake + Iceberg REST)
#   5. OC-HMS  (Operational Hive Metastore)
#   6. AC-HMS  (Analytical Hive Metastore)
#
# Prerequisites:
#   - kubectl pointing at your cluster
#   - helm 3
#   - aws CLI  (brew install awscli)
#   - JARs downloaded: bash scripts/00-download-jars.sh
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
DEPLOY_DIR="${REPO_DIR}/deploy"
CHARTS_DIR="${REPO_DIR}"   # gravitino/ and hive-metastore/ live at the repo root
NAMESPACE="gravitino"

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_deploy() {
  local name="$1"
  echo "  Waiting for deployment/${name}..."
  kubectl rollout status deployment/"${name}" -n "${NAMESPACE}" --timeout=180s
}

wait_helm() {
  local release="$1"
  echo "  Waiting for helm release '${release}'..."
  kubectl rollout status deployment/"${release}" -n "${NAMESPACE}" --timeout=300s 2>/dev/null || \
  kubectl wait pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${release}" \
    --for=condition=Ready --timeout=300s
}

# ── Step 0: Helm repositories ─────────────────────────────────────────────────
echo "[0/6] Ensuring Helm repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update bitnami
echo "  Helm repositories ready."

# ── Step 1: Namespace ─────────────────────────────────────────────────────────
echo "[1/6] Creating namespace '${NAMESPACE}'..."
kubectl apply -f "${DEPLOY_DIR}/00-namespace.yaml"

# ── Step 2: SeaweedFS ─────────────────────────────────────────────────────────
echo "[2/6] Deploying SeaweedFS..."
# Scale filer to 0 before applying to release the LevelDB lock.
# Without this, re-runs leave the old filer pod running while the new one starts,
# causing "resource temporarily unavailable" on /data/filerldb2/.
if kubectl get deployment/seaweedfs-filer -n "${NAMESPACE}" &>/dev/null; then
  echo "  Scaling seaweedfs-filer to 0 to release LevelDB lock..."
  kubectl scale deployment/seaweedfs-filer -n "${NAMESPACE}" --replicas=0
  kubectl wait --for=delete pod -l app=seaweedfs-filer -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true
fi
kubectl apply -f "${DEPLOY_DIR}/01-seaweedfs.yaml"
wait_deploy seaweedfs-master
wait_deploy seaweedfs-volume
wait_deploy seaweedfs-filer

# ── SeaweedFS S3 health check ─────────────────────────────────────────────────
# Validate S3 is fully operational before proceeding. Catches config issues
# (missing ConfigMap mount, stale LevelDB) before they silently break later steps.
echo ""
echo "  ── SeaweedFS S3 health check ──"

# 1. Confirm the credentials config file is actually mounted in the pod.
echo "  [1/4] Checking s3.json is mounted in filer pod..."
if ! kubectl exec -n "${NAMESPACE}" deployment/seaweedfs-filer -- \
     cat /etc/seaweedfs/s3.json &>/dev/null 2>&1; then
  echo ""
  echo "  ERROR: /etc/seaweedfs/s3.json is NOT mounted in the seaweedfs-filer pod."
  echo "  The ConfigMap 'seaweedfs-s3-config' is missing or the volume mount is wrong."
  echo "  Run: kubectl get configmap seaweedfs-s3-config -n ${NAMESPACE}"
  echo "  Then: kubectl describe pod -n ${NAMESPACE} -l app=seaweedfs-filer"
  exit 1
fi
echo "  [1/4] OK — s3.json is mounted."

export AWS_ACCESS_KEY_ID=admin
export AWS_SECRET_ACCESS_KEY=admin
export AWS_DEFAULT_REGION=us-east-1
S3_ENDPOINT="http://localhost:30334"

# 2. Poll until ListBuckets authenticates successfully (confirms IAM is loaded).
echo "  [2/4] Waiting for S3 authentication (up to 60s)..."
S3_READY=false
for i in $(seq 1 30); do
  ERR=$(aws --endpoint-url "${S3_ENDPOINT}" s3 ls 2>&1)
  if [ $? -eq 0 ]; then
    S3_READY=true
    break
  fi
  # Surface the actual error on the last attempt
  if [ "${i}" -eq 30 ]; then
    echo ""
    echo "  ERROR: S3 authentication failed after 60s. Last error:"
    echo "  ${ERR}"
    echo ""
    echo "  Diagnostics:"
    echo "    kubectl logs -n ${NAMESPACE} deployment/seaweedfs-filer | tail -20"
    exit 1
  fi
  sleep 2
done
echo "  [2/4] OK — S3 authentication working."

# 3. Create and verify a test bucket.
echo "  [3/4] Creating test bucket 's3://s3-health-check'..."
aws --endpoint-url "${S3_ENDPOINT}" s3 mb s3://s3-health-check --region us-east-1
if ! aws --endpoint-url "${S3_ENDPOINT}" s3 ls s3://s3-health-check &>/dev/null; then
  echo "  ERROR: Test bucket created but cannot be listed — S3 is not healthy."
  exit 1
fi
echo "  [3/4] OK — bucket create and list working."

# 4. Put and delete a test object to confirm write path works end to end.
echo "  [4/4] Testing object put/delete..."
echo "seaweedfs-ok" | aws --endpoint-url "${S3_ENDPOINT}" s3 cp - s3://s3-health-check/probe
aws --endpoint-url "${S3_ENDPOINT}" s3 rm s3://s3-health-check/probe
aws --endpoint-url "${S3_ENDPOINT}" s3 rb s3://s3-health-check
echo "  [4/4] OK — object write/delete working."
echo "  ── SeaweedFS S3 healthy ──"
echo ""

# ── Step 3: Create S3 buckets ─────────────────────────────────────────────────
echo "[3/6] Creating S3 buckets..."
for BUCKET in operational analytical; do
  if aws --endpoint-url "${S3_ENDPOINT}" s3 ls "s3://${BUCKET}" &>/dev/null; then
    echo "  Bucket '${BUCKET}' already exists — skipping."
  else
    aws --endpoint-url "${S3_ENDPOINT}" s3 mb "s3://${BUCKET}"
    echo "  Created bucket '${BUCKET}'."
  fi
done

# ── Step 4: Gravitino ─────────────────────────────────────────────────────────
echo "[4/6] Deploying Gravitino..."
kubectl apply -f "${DEPLOY_DIR}/02-gravitino-pvc.yaml"

if helm status gravitino -n "${NAMESPACE}" &>/dev/null; then
  echo "  Helm release 'gravitino' exists — upgrading..."
  helm upgrade gravitino "${CHARTS_DIR}/gravitino" \
    -n "${NAMESPACE}" \
    -f "${DEPLOY_DIR}/03-gravitino-values.yaml" \
    --dependency-update
else
  helm install gravitino "${CHARTS_DIR}/gravitino" \
    -n "${NAMESPACE}" \
    -f "${DEPLOY_DIR}/03-gravitino-values.yaml" \
    --dependency-update
fi
wait_deploy gravitino

# ── Step 5: OC-HMS (Operational Hive Metastore) ───────────────────────────────
echo "[5/6] Deploying OC-HMS (Operational Hive Metastore)..."
if helm status hive-metastore -n "${NAMESPACE}" &>/dev/null; then
  echo "  Helm release 'hive-metastore' exists — upgrading..."
  helm upgrade hive-metastore "${CHARTS_DIR}/hive-metastore" \
    -n "${NAMESPACE}" \
    -f "${DEPLOY_DIR}/04-oc-hms-values.yaml"
else
  helm install hive-metastore "${CHARTS_DIR}/hive-metastore" \
    -n "${NAMESPACE}" \
    -f "${DEPLOY_DIR}/04-oc-hms-values.yaml"
fi
kubectl rollout status deployment/hive-metastore -n "${NAMESPACE}" --timeout=300s

# ── Step 6: AC-HMS (Analytical Hive Metastore) ────────────────────────────────
echo "[6/6] Deploying AC-HMS (Analytical Hive Metastore)..."
if helm status hive-metastore-analytics -n "${NAMESPACE}" &>/dev/null; then
  echo "  Helm release 'hive-metastore-analytics' exists — upgrading..."
  helm upgrade hive-metastore-analytics "${CHARTS_DIR}/hive-metastore" \
    -n "${NAMESPACE}" \
    -f "${DEPLOY_DIR}/05-ac-hms-values.yaml"
else
  helm install hive-metastore-analytics "${CHARTS_DIR}/hive-metastore" \
    -n "${NAMESPACE}" \
    -f "${DEPLOY_DIR}/05-ac-hms-values.yaml"
fi
kubectl rollout status deployment/hive-metastore-analytics -n "${NAMESPACE}" --timeout=300s

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo " Deployment complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo " Next steps:"
echo "   1. Register Gravitino catalogs:"
echo "        bash scripts/02-register-catalogs.sh"
echo ""
echo "   2. Access Gravitino UI:"
echo "        kubectl port-forward -n gravitino svc/gravitino 8090:8090"
echo "        open http://localhost:8090"
echo ""
echo "   3. Access SeaweedFS S3 (aws CLI):"
echo "        AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=admin \\"
echo "        aws --endpoint-url http://localhost:30334 s3 ls"
echo ""
kubectl get pods -n "${NAMESPACE}"
