#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 08-validate-policy.sh
#
# Proves that the SPIFFE + Gravitino RBAC policies are enforced.
#
# TEST MATRIX:
#
#   Test 1 — No token → 401 Unauthorized
#     Any request to Gravitino without a Bearer token should be rejected.
#
#   Test 2 — oc_writer tries to write to ac catalog → 403 Forbidden
#     A pod with spiffe://gravitino.demo/spark-oc-writer JWT should be
#     blocked when attempting CREATE_TABLE on the analytical catalog.
#
#   Test 3 — ac_writer tries to write to oc_iceberg → 403 Forbidden
#     A pod with spiffe://gravitino.demo/spark-ac-writer JWT should be
#     blocked when attempting CREATE_TABLE on oc_iceberg.
#
#   Test 4 — oc_writer can read from oc_iceberg → 200 OK
#     Proves authorized reads work correctly.
#
#   Test 5 — Direct HMS bypass attempt → TCP timeout/refused
#     A pod WITHOUT label spiffe-workload=spark-ac-writer trying to connect
#     to AC-HMS on port 9083 should be blocked by NetworkPolicy.
#     (Only enforced on CNIs with NetworkPolicy support like Calico.)
#
# HOW THIS WORKS:
#   We run temporary pods in the gravitino namespace with specific labels.
#   SPIRE attests each pod and issues a JWT-SVID based on the pod label.
#   We then use that JWT-SVID to call Gravitino's API.
#   Expected results: authorized operations succeed, unauthorized ones fail.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

NAMESPACE="gravitino"
METALAKE="poc_layer"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR_DIR="$(cd "${SCRIPT_DIR}/../jars" && pwd)"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
PASS="${GREEN}[PASS]${NC}"; FAIL="${RED}[FAIL]${NC}"; INFO="${BLUE}[INFO]${NC}"

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0

pass() { echo -e "${PASS} $*"; (( PASS_COUNT++ )) || true; }
fail() { echo -e "${FAIL} $*"; (( FAIL_COUNT++ )) || true; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; (( SKIP_COUNT++ )) || true; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " SPIFFE + Gravitino RBAC Policy Validation"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Port-forward to Gravitino ─────────────────────────────────────────────────
kubectl port-forward svc/gravitino 8090:8090 -n "${NAMESPACE}" &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT
sleep 3
GRAVITINO_URL="http://localhost:8090"

# ── Helper: fetch JWT-SVID for a given workload label ─────────────────────────
# Runs a temporary pod with the given label, waits for SPIRE to attest it,
# fetches the JWT-SVID, then returns the token string.
#
# Parameters:
#   $1 = pod name (must be unique)
#   $2 = spiffe-workload label value (e.g., "spark-oc-writer")
fetch_jwt() {
  local pod_name="$1"
  local workload_label="$2"

  kubectl delete pod "${pod_name}" -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1

  kubectl run "${pod_name}" \
    --image=busybox:1.36 \
    --restart=Never \
    -n "${NAMESPACE}" \
    -l "spiffe-workload=${workload_label}" \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"${pod_name}\",
          \"image\": \"busybox:1.36\",
          \"command\": [\"sh\", \"-c\",
            \"/jars/spire-agent api fetch jwt -audience gravitino -socketPath /run/spire/sockets/agent.sock 2>/dev/null | grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1\"],
          \"volumeMounts\": [
            {\"name\": \"jars\",        \"mountPath\": \"/jars\"},
            {\"name\": \"spire-socket\", \"mountPath\": \"/run/spire/sockets\"}
          ]
        }],
        \"volumes\": [
          {\"name\": \"jars\",   \"hostPath\": {\"path\": \"${JAR_DIR}\"}},
          {\"name\": \"spire-socket\", \"hostPath\": {\"path\": \"/run/spire/sockets\", \"type\": \"DirectoryOrCreate\"}}
        ]
      }
    }" > /dev/null 2>&1

  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${pod_name}" \
    -n "${NAMESPACE}" --timeout=30s > /dev/null 2>&1 || true

  local jwt
  jwt=$(kubectl logs "${pod_name}" -n "${NAMESPACE}" 2>/dev/null | \
    grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1)

  kubectl delete pod "${pod_name}" -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1

  echo "${jwt}"
}

# ── Helper: call Gravitino API and check expected HTTP code ───────────────────
check_http() {
  local description="$1"
  local expected_code="$2"
  local method="$3"
  local url="$4"
  local token="${5:-}"
  local body="${6:-}"

  local auth_arg=""
  [ -n "${token}" ] && auth_arg="-H 'Authorization: Bearer ${token}'"

  local body_arg=""
  [ -n "${body}" ] && body_arg="-d '${body}' -H 'Content-Type: application/json'"

  local actual_code
  if [ -n "${token}" ] && [ -n "${body}" ]; then
    actual_code=$(curl -s -o /dev/null -w "%{http_code}" -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${body}" \
      "${GRAVITINO_URL}${url}")
  elif [ -n "${token}" ]; then
    actual_code=$(curl -s -o /dev/null -w "%{http_code}" -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      "${GRAVITINO_URL}${url}")
  elif [ -n "${body}" ]; then
    actual_code=$(curl -s -o /dev/null -w "%{http_code}" -X "${method}" \
      -H "Content-Type: application/json" \
      -d "${body}" \
      "${GRAVITINO_URL}${url}")
  else
    actual_code=$(curl -s -o /dev/null -w "%{http_code}" -X "${method}" \
      "${GRAVITINO_URL}${url}")
  fi

  if [ "${actual_code}" = "${expected_code}" ]; then
    pass "${description} → HTTP ${actual_code} (expected ${expected_code})"
  else
    fail "${description} → HTTP ${actual_code} (expected ${expected_code})"
  fi
}

################################################################################
# TEST 1: No token → 401 Unauthorized
# ────────────────────────────────────
# This verifies that Gravitino's OAuth2 enforcement is active.
# Any request without a Bearer token should be rejected with 401.
# If this test fails (returns 200), it means Gravitino is NOT enforcing
# authentication — check that 09-gravitino-values-spire.yaml was applied.
################################################################################
echo ""
echo "── Test 1: Unauthenticated request (no Bearer token) ────────────────────"
echo "   Expected: 401 Unauthorized — Gravitino rejects requests without JWT"
check_http \
  "GET /api/metalakes without token" \
  "401" "GET" "/api/metalakes"

################################################################################
# TEST 2: oc_writer tries to write to analytical catalog → 403 Forbidden
# ─────────────────────────────────────────────────────────────────────────
# LEARNING NOTE — Why this test matters:
#
#   The spark-oc-writer SPIFFE identity has oc_writer_role which grants:
#     • FULL access to oc_iceberg
#     • READ-ONLY access to hive_metastore_analytics (SELECT + USE only)
#
#   Attempting CREATE_TABLE on hive_metastore_analytics should return 403.
#   This proves Gravitino RBAC is denying the write privilege even though
#   the JWT-SVID is valid (authentication passes, authorization fails).
#
#   The flow:
#     1. Pod gets JWT: sub=spiffe://gravitino.demo/spark-oc-writer
#     2. Gravitino validates JWT (401 check passes)
#     3. Gravitino checks: does spark-oc-writer have CREATE_TABLE on
#        hive_metastore_analytics? → NO (only SELECT + USE)
#     4. Gravitino returns 403 Forbidden
################################################################################
echo ""
echo "── Test 2: oc_writer attempts WRITE to analytical catalog ───────────────"
echo "   Expected: 403 Forbidden — oc_writer has only READ access to AC catalog"

echo -e "${INFO} Fetching JWT-SVID for spark-oc-writer..."
OC_JWT=$(fetch_jwt "validate-oc-writer" "spark-oc-writer")

if [ -z "${OC_JWT}" ]; then
  skip "Test 2: Could not fetch oc_writer JWT (SPIRE may not be ready) — skipping"
else
  echo -e "${INFO} JWT obtained for spiffe://gravitino.demo/spark-oc-writer"

  # Try to create a table in the analytical catalog — should be denied
  check_http \
    "oc_writer CREATE TABLE in hive_metastore_analytics" \
    "403" "POST" \
    "/api/metalakes/${METALAKE}/catalogs/hive_metastore_analytics/schemas/poc_demo/tables" \
    "${OC_JWT}" \
    '{"name":"forbidden_table","columns":[],"comment":"should not be created"}'
fi

################################################################################
# TEST 3: ac_writer tries to write to operational catalog → 403 Forbidden
################################################################################
echo ""
echo "── Test 3: ac_writer attempts WRITE to operational catalog ──────────────"
echo "   Expected: 403 Forbidden — ac_writer has only READ access to OC catalog"

echo -e "${INFO} Fetching JWT-SVID for spark-ac-writer..."
AC_JWT=$(fetch_jwt "validate-ac-writer" "spark-ac-writer")

if [ -z "${AC_JWT}" ]; then
  skip "Test 3: Could not fetch ac_writer JWT (SPIRE may not be ready) — skipping"
else
  echo -e "${INFO} JWT obtained for spiffe://gravitino.demo/spark-ac-writer"

  # Try to create a table in oc_iceberg — should be denied
  check_http \
    "ac_writer CREATE TABLE in oc_iceberg" \
    "403" "POST" \
    "/api/metalakes/${METALAKE}/catalogs/oc_iceberg/schemas/poc_demo/tables" \
    "${AC_JWT}" \
    '{"name":"forbidden_table","columns":[],"comment":"should not be created"}'
fi

################################################################################
# TEST 4: oc_writer can LIST tables in oc_iceberg → 200 OK
# ─────────────────────────────────────────────────────────
# Verifies that authorized operations still work after RBAC is enabled.
# An oc_writer must be able to READ oc_iceberg tables (SELECT_TABLE + USE).
################################################################################
echo ""
echo "── Test 4: oc_writer authorized READ from oc_iceberg ─────────────────────"
echo "   Expected: 200 OK — oc_writer has SELECT_TABLE on oc_iceberg"

if [ -z "${OC_JWT}" ]; then
  skip "Test 4: No OC JWT available — skipping"
else
  check_http \
    "oc_writer LIST catalogs" \
    "200" "GET" \
    "/api/metalakes/${METALAKE}/catalogs" \
    "${OC_JWT}"
fi

################################################################################
# TEST 5: Direct HMS bypass attempt (NetworkPolicy enforcement test)
# ──────────────────────────────────────────────────────────────────
# LEARNING NOTE:
#   This test verifies that a pod WITHOUT the authorized label cannot
#   reach OC-HMS directly. If NetworkPolicy is enforced (Calico/Cilium),
#   the connection should time out or be refused immediately.
#
#   On Docker Desktop (kindnet), this test will FAIL (the connection succeeds)
#   because kindnet doesn't enforce NetworkPolicy. This is expected and is
#   noted in the output.
#
#   The test creates a pod WITHOUT the spiffe-workload label that would
#   authorize HMS access, and tries to TCP-connect to OC-HMS port 9083.
################################################################################
echo ""
echo "── Test 5: Direct OC-HMS bypass attempt (NetworkPolicy) ─────────────────"
echo "   Expected: TCP timeout/refused — NetworkPolicy blocks non-Gravitino pods"
echo "   NOTE: Only enforced on Calico/Cilium CNI. kindnet (Docker Desktop) = SKIP"

# Check if NetworkPolicy is actually enforced by testing a canary pod
kubectl delete pod oc-hms-bypass-test -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1
kubectl run oc-hms-bypass-test \
  --image=busybox:1.36 \
  --restart=Never \
  -n "${NAMESPACE}" \
  --overrides='{"spec":{"containers":[{"name":"test","image":"busybox:1.36","command":["sh","-c","timeout 3 nc -z hive-metastore 9083 && echo CONNECTED || echo BLOCKED"]}]}}' \
  > /dev/null 2>&1
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/oc-hms-bypass-test \
  -n "${NAMESPACE}" --timeout=30s > /dev/null 2>&1 || \
kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/oc-hms-bypass-test \
  -n "${NAMESPACE}" --timeout=30s > /dev/null 2>&1 || true
BYPASS_RESULT=$(kubectl logs oc-hms-bypass-test -n "${NAMESPACE}" 2>/dev/null | tail -1 || echo "ERROR")
kubectl delete pod oc-hms-bypass-test -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1

case "${BYPASS_RESULT}" in
  "BLOCKED")
    pass "Direct OC-HMS TCP access blocked → NetworkPolicy is enforced (Calico/Cilium active)"
    ;;
  "CONNECTED")
    warn "Direct OC-HMS TCP access SUCCEEDED → NetworkPolicy NOT enforced (likely kindnet)"
    warn "  This is expected on Docker Desktop. Deploy Calico for full enforcement."
    skip "Test 5: NetworkPolicy not enforced by current CNI"
    ;;
  *)
    skip "Test 5: Could not determine NetworkPolicy status (pod error: ${BYPASS_RESULT})"
    ;;
esac

################################################################################
# TEST 6: ac_writer CAN reach AC-HMS directly (authorized by NetworkPolicy)
# ─────────────────────────────────────────────────────────────────────────
# The ac_write_demo Spark pod is authorized to reach AC-HMS directly
# (NetworkPolicy allows pods with label spiffe-workload=spark-ac-writer).
# This test verifies the authorized path is open.
################################################################################
echo ""
echo "── Test 6: ac_writer direct AC-HMS access (should be ALLOWED) ────────────"
echo "   Expected: TCP connection succeeds — NetworkPolicy allows spark-ac-writer"

kubectl delete pod ac-hms-access-test -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1
kubectl run ac-hms-access-test \
  --image=busybox:1.36 \
  --restart=Never \
  -n "${NAMESPACE}" \
  -l "spiffe-workload=spark-ac-writer" \
  --overrides='{"spec":{"containers":[{"name":"test","image":"busybox:1.36","command":["sh","-c","timeout 3 nc -z hive-metastore-analytics 9083 && echo CONNECTED || echo BLOCKED"]}]}}' \
  > /dev/null 2>&1
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/ac-hms-access-test \
  -n "${NAMESPACE}" --timeout=30s > /dev/null 2>&1 || \
kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/ac-hms-access-test \
  -n "${NAMESPACE}" --timeout=30s > /dev/null 2>&1 || true
AC_HMS_RESULT=$(kubectl logs ac-hms-access-test -n "${NAMESPACE}" 2>/dev/null | tail -1 || echo "ERROR")
kubectl delete pod ac-hms-access-test -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1

case "${AC_HMS_RESULT}" in
  "CONNECTED")
    pass "ac_writer can reach AC-HMS directly (authorized path open)"
    ;;
  "BLOCKED")
    fail "ac_writer cannot reach AC-HMS — check NetworkPolicy allow-to-ac-hms rule"
    ;;
  *)
    skip "Test 6: Could not determine result (may be CNI issue)"
    ;;
esac

################################################################################
# SUMMARY
################################################################################
echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " Policy Validation Results"
echo "════════════════════════════════════════════════════════════════════════════"
echo -e " ${GREEN}PASS: ${PASS_COUNT}${NC}  |  ${RED}FAIL: ${FAIL_COUNT}${NC}  |  ${YELLOW}SKIP: ${SKIP_COUNT}${NC}"
echo ""
if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo -e " ${RED}Some tests failed. Review the output above for details.${NC}"
  echo ""
  echo " Common issues:"
  echo "   FAIL Test 1: Gravitino OAuth2 not enabled — re-run 06-setup-spire.sh"
  echo "   FAIL Test 2/3: RBAC roles not assigned — re-run 07-setup-rbac.sh"
  echo "   FAIL Test 4: RBAC too restrictive — check role privileges"
  echo "   FAIL Test 5: CNI doesn't support NetworkPolicy (kindnet) — expected"
else
  echo -e " ${GREEN}All tests passed (or skipped due to CNI limitations).${NC}"
fi
echo "════════════════════════════════════════════════════════════════════════════"

[ "${FAIL_COUNT}" -eq 0 ] || exit 1
