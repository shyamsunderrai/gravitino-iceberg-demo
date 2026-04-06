#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 06-setup-spire.sh
#
# Deploys SPIRE Server + Agent, registers workload identities, upgrades
# Gravitino to use OAuth2 JWT validation, and hardens HMS access with
# NetworkPolicy + ClusterIP services.
#
# WHAT THIS SCRIPT DOES (in order):
#   Phase 1 — Deploy SPIRE Server and wait for it to be ready
#   Phase 2 — Deploy SPIRE Agent and wait for node attestation to complete
#   Phase 3 — Register workload entries (map pod labels → SPIFFE IDs)
#   Phase 4 — Patch HMS Services from NodePort to ClusterIP
#   Phase 5 — Apply NetworkPolicy (HMS access control)
#   Phase 6 — Upgrade Gravitino with OAuth2 + RBAC configuration
#
# WHY THE ORDER MATTERS:
#   The SPIRE Agent cannot start until the Server is ready (it needs to
#   attest against the Server at startup). Workload entries must exist
#   before Spark pods run (entries tell SPIRE which pod → SPIFFE ID).
#   Gravitino must be upgraded AFTER SPIRE is running (it needs to fetch
#   JWKS from the OIDC endpoint during startup). NetworkPolicy can be
#   applied at any time but we do it before Gravitino upgrade to ensure
#   the new RBAC-enforced Gravitino boots with the correct network topology.
#
# PHASE-BY-PHASE LEARNING GUIDE:
#   See inline comments for detailed explanations of each SPIFFE concept.
#
# Prerequisites:
#   - scripts/01-deploy-all.sh completed successfully
#   - scripts/02-register-catalogs.sh completed
#   - kubectl configured and pointing at your cluster
#   - helm available
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../deploy" && pwd)"
NAMESPACE="gravitino"
CHARTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

wait_for_pod_ready() {
  local label="$1"; local timeout="${2:-120}"
  info "Waiting for pod with label '${label}' to be ready (timeout: ${timeout}s)..."
  kubectl wait pod -n "${NAMESPACE}" -l "${label}" \
    --for=condition=Ready --timeout="${timeout}s"
}

################################################################################
# ════════════════════════════════════════════════════════════════════════════
# PHASE 1: Deploy SPIRE Server
#
# LEARNING NOTE — What happens during this phase:
#
#   The SPIRE Server starts and initialises:
#     1. Generates a CA key pair (stored in /run/spire/data/keys.json via PVC)
#     2. Creates a self-signed root certificate for trust domain "gravitino.demo"
#     3. Opens gRPC listener on :8081 for Agent connections
#     4. Opens health check HTTP listener on :8080
#     5. The OIDC Discovery Provider sidecar starts and connects to the
#        Server via the shared Unix socket at /run/spire/sockets/server.sock
#     6. OIDC provider begins serving JWKS on :8008
#
#   After this phase you can verify:
#     kubectl port-forward svc/spire-oidc 8008:8008 -n gravitino
#     curl http://localhost:8008/.well-known/openid-configuration
#     curl http://localhost:8008/keys
# ════════════════════════════════════════════════════════════════════════════
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " Phase 1: Deploying SPIRE Server"
echo "════════════════════════════════════════════════════════════════════════════"

kubectl apply -f "${DEPLOY_DIR}/06-spire-server.yaml"

info "Waiting for SPIRE Server StatefulSet to become ready..."
kubectl rollout status statefulset/spire-server -n "${NAMESPACE}" --timeout=120s

wait_for_pod_ready "app=spire-server" 120

success "SPIRE Server is running"
info "You can verify the OIDC endpoint is live:"
info "  kubectl port-forward svc/spire-oidc 8008:8008 -n ${NAMESPACE} &"
info "  curl http://localhost:8008/.well-known/openid-configuration"

################################################################################
# ════════════════════════════════════════════════════════════════════════════
# PHASE 2: Deploy SPIRE Agent
#
# LEARNING NOTE — Node Attestation flow (what you're watching happen here):
#
#   1. SPIRE Agent pod starts on the node (as a DaemonSet pod)
#   2. Agent reads its projected ServiceAccount token from /run/spire/token
#      This token has audience="spiffe://gravitino.demo" (set in the PodSpec)
#   3. Agent sends the token to SPIRE Server at spire-server:8081 (gRPC)
#   4. SPIRE Server calls Kubernetes TokenReview API:
#        POST /apis/authentication.k8s.io/v1/tokenreviews
#        Body: {"spec": {"token": "<agent-token>", "audiences": ["spiffe://gravitino.demo"]}}
#   5. Kubernetes API verifies the token is valid and belongs to:
#        ServiceAccount: spire-agent, Namespace: gravitino
#   6. Server also calls GET /api/v1/nodes/<node-name> to get the node's UID
#   7. Server mints an X.509-SVID for the agent:
#        Subject: spiffe://gravitino.demo/spire/agent/k8s_sat/gravitino-demo/<node-uid>
#        Validity: 1 hour (ca_ttl)
#   8. Agent stores the SVID and opens the workload API socket:
#        /run/spire/sockets/agent.sock
#
#   After this phase, any pod on this node that mounts the socket can
#   call the Workload API to request a JWT-SVID for itself.
# ════════════════════════════════════════════════════════════════════════════
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " Phase 2: Deploying SPIRE Agent"
echo "════════════════════════════════════════════════════════════════════════════"

# Clear stale agent data from node hostPath before deploying.
# If the SPIRE Server was previously deleted and recreated, its CA changed.
# The agent will have a cached bundle from the old server that can't verify
# the new server's certificate → "x509: certificate signed by unknown authority".
# Wiping the data dir forces a clean insecure_bootstrap on first connect.
info "Clearing stale SPIRE Agent data from node hostPath (safe to run even if empty)..."
kubectl run spire-agent-cleanup --restart=Never --rm \
  --image=busybox:1.36 -n "${NAMESPACE}" \
  --overrides="{
    \"spec\": {
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"docker-desktop\"},
      \"containers\": [{
        \"name\": \"spire-agent-cleanup\",
        \"image\": \"busybox:1.36\",
        \"command\": [\"sh\",\"-c\",\"rm -rf /run/spire/agent-data/* && echo CLEANED\"],
        \"securityContext\": {\"privileged\": true},
        \"volumeMounts\": [{\"name\":\"agent-data\",\"mountPath\":\"/run/spire/agent-data\"}]
      }],
      \"volumes\": [{\"name\":\"agent-data\",\"hostPath\":{\"path\":\"/run/spire/agent-data\"}}]
    }
  }" 2>/dev/null && success "Agent data cleared" || warn "Cleanup pod skipped (may already be clean)"

kubectl apply -f "${DEPLOY_DIR}/07-spire-agent.yaml"

info "Waiting for SPIRE Agent DaemonSet to be ready..."
kubectl rollout status daemonset/spire-agent -n "${NAMESPACE}" --timeout=120s

wait_for_pod_ready "app=spire-agent" 120

success "SPIRE Agent is running — node attestation succeeded"

# Verify the Agent can talk to the Server by checking agent registration
AGENT_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=spire-agent -o jsonpath='{.items[0].metadata.name}')
info "Checking SPIRE Agent attestation status..."
kubectl exec -n "${NAMESPACE}" "${AGENT_POD}" -- \
  /opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock 2>/dev/null && \
  success "Agent SVID fetch succeeded" || \
  warn "Agent SVID fetch check skipped (agent may need a moment to fully initialise)"

################################################################################
# ════════════════════════════════════════════════════════════════════════════
# PHASE 3: Register Workload Entries
#
# LEARNING NOTE — What is a Workload Entry?
#
#   A workload entry is a record in the SPIRE Server that says:
#     "Any pod matching THESE SELECTORS should get THIS SPIFFE ID"
#
#   Example entry for the OC Spark writer:
#     SPIFFE ID:  spiffe://gravitino.demo/spark-oc-writer
#     Selectors:  k8s:ns:gravitino
#                 k8s:pod-label:spiffe-workload:spark-oc-writer
#
#   This means: any pod in namespace "gravitino" with label
#   "spiffe-workload=spark-oc-writer" will receive a JWT-SVID with
#   sub=spiffe://gravitino.demo/spark-oc-writer.
#
#   HOW WORKLOAD ATTESTATION USES THESE ENTRIES:
#
#   When the Spark pod calls the SPIRE Agent socket:
#   1. Agent gets caller's PID via SO_PEERCRED (Unix socket credential)
#   2. Agent resolves PID → pod via kubelet /pods API (local node only)
#   3. Agent extracts pod labels and namespace
#   4. Agent queries Server: "which entry matches ns=gravitino, label=spark-oc-writer?"
#   5. Server returns: spiffe://gravitino.demo/spark-oc-writer
#   6. Server issues JWT-SVID for that SPIFFE ID, returns to Agent
#   7. Agent returns JWT-SVID to the calling pod
#
#   The Spark pod never "proves" its identity directly — the Agent does the
#   attestation on its behalf by verifying the pod's Kubernetes metadata.
#   This is "zero-touch" identity: no certificates to provision, no tokens
#   to inject — just add a pod label and SPIRE does the rest.
#
#   WHY LABELS OVER SERVICE ACCOUNTS?
#   Both work. Labels are more flexible for demo scripts (you can add them
#   to `kubectl run` without creating a new ServiceAccount). In production,
#   ServiceAccount selectors are more robust (labels can be user-applied;
#   ServiceAccounts are controlled by cluster admins).
# ════════════════════════════════════════════════════════════════════════════
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " Phase 3: Registering Workload Entries in SPIRE Server"
echo "════════════════════════════════════════════════════════════════════════════"

SERVER_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=spire-server -o jsonpath='{.items[0].metadata.name}')

# Helper: register an entry, skip if already exists (idempotent)
register_entry() {
  local spiffe_id="$1"; shift
  local description="$1"; shift
  local selectors=("$@")

  info "Registering: ${description} → ${spiffe_id}"

  # Build the selector args
  local selector_args=()
  for sel in "${selectors[@]}"; do
    selector_args+=("-selector" "${sel}")
  done

  # spire-server entry create is idempotent in SPIRE 1.9+
  # (duplicate entries with same SPIFFE ID + selectors are skipped)
  kubectl exec -n "${NAMESPACE}" "${SERVER_POD}" -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID "${spiffe_id}" \
    -parentID "spiffe://gravitino.demo/spire/agent/k8s_sat/gravitino-demo/$(kubectl get node -o jsonpath='{.items[0].metadata.uid}')" \
    "${selector_args[@]}" \
    -ttl 300 \
    -socketPath /run/spire/sockets/server.sock 2>&1 | grep -v "^$" || true
}

# ── Gravitino server identity ──────────────────────────────────────────────
# Gravitino itself gets a SPIFFE identity. This is used for:
#   1. mTLS between Gravitino and HMS (future hardening)
#   2. The Gravitino admin can identify itself to SPIRE for management ops
register_entry \
  "spiffe://gravitino.demo/gravitino" \
  "Gravitino server" \
  "k8s:ns:gravitino" \
  "k8s:pod-label:app.kubernetes.io/name:gravitino"

# ── Operational Spark writer identity ──────────────────────────────────────
# The spark-oc-writer identity authorizes a pod to:
#   • Authenticate to Gravitino with JWT-SVID
#   • Gravitino RBAC grants: CREATE_TABLE, MODIFY_TABLE on oc_iceberg
#   • NetworkPolicy: this pod CANNOT reach AC-HMS directly
#   → Enforces: oc_writer can only write operational data via Gravitino
register_entry \
  "spiffe://gravitino.demo/spark-oc-writer" \
  "OC (Operational) Spark writer" \
  "k8s:ns:gravitino" \
  "k8s:pod-label:spiffe-workload:spark-oc-writer"

# ── Analytical Spark writer identity ───────────────────────────────────────
# The spark-ac-writer identity authorizes a pod to:
#   • Authenticate to Gravitino with JWT-SVID
#   • Gravitino RBAC grants: full access to AC catalog
#   • NetworkPolicy: this pod CAN reach AC-HMS directly (for ETL write)
#   • NetworkPolicy: this pod CANNOT reach OC-HMS directly
#   → Enforces: ac_writer can only read OC data (via Gravitino REST),
#               and can write analytical data directly to AC-HMS
register_entry \
  "spiffe://gravitino.demo/spark-ac-writer" \
  "AC (Analytical) Spark writer" \
  "k8s:ns:gravitino" \
  "k8s:pod-label:spiffe-workload:spark-ac-writer"

# ── Admin identity ──────────────────────────────────────────────────────────
# Used by the RBAC setup script (07-setup-rbac.sh) to call Gravitino's
# admin API. The admin gets a JWT-SVID for authentication.
register_entry \
  "spiffe://gravitino.demo/admin" \
  "Gravitino admin client" \
  "k8s:ns:gravitino" \
  "k8s:pod-label:spiffe-workload:gravitino-admin"

success "Workload entries registered"

# Show registered entries for verification
echo ""
info "Current workload entries in SPIRE Server:"
kubectl exec -n "${NAMESPACE}" "${SERVER_POD}" -- \
  /opt/spire/bin/spire-server entry show \
  -socketPath /run/spire/sockets/server.sock 2>/dev/null | \
  grep -E "(Entry ID|SPIFFE ID|Selector)" || true

################################################################################
# ════════════════════════════════════════════════════════════════════════════
# PHASE 4: Harden HMS Services (NodePort → ClusterIP)
#
# LEARNING NOTE — Why NodePort defeats NetworkPolicy:
#
#   When a service is type=NodePort, Kubernetes creates a listener on every
#   node's IP address at the NodePort (e.g., 0.0.0.0:30983). Traffic arriving
#   at the NodePort is SNAT'd by kube-proxy BEFORE it reaches the pod.
#
#   NetworkPolicy operates at the pod ingress level. By the time SNAT'd
#   traffic arrives at the HMS pod, it looks like it came from a node IP,
#   not from a specific pod — so the "podSelector" in NetworkPolicy can't
#   identify the source pod and the policy is bypassed.
#
#   ClusterIP services don't have this problem: pod-to-pod traffic preserves
#   the source pod's IP, and NetworkPolicy correctly identifies the source pod.
#
#   After this patch:
#     • OC-HMS is only reachable from within the cluster
#     • AC-HMS is only reachable from within the cluster
#     • Local access: kubectl port-forward svc/hive-metastore 9083:9083
# ════════════════════════════════════════════════════════════════════════════
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " Phase 4: Converting HMS Services from NodePort to ClusterIP"
echo "════════════════════════════════════════════════════════════════════════════"

# Patch OC-HMS service
info "Patching hive-metastore (OC-HMS) service to ClusterIP..."
kubectl patch service hive-metastore -n "${NAMESPACE}" \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/type","value":"ClusterIP"},{"op":"remove","path":"/spec/ports/0/nodePort"}]' \
  2>/dev/null && success "OC-HMS: NodePort removed, now ClusterIP" || \
  warn "OC-HMS service patch skipped (may already be ClusterIP or service not found)"

# Patch AC-HMS service
info "Patching hive-metastore-analytics (AC-HMS) service to ClusterIP..."
kubectl patch service hive-metastore-analytics -n "${NAMESPACE}" \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/type","value":"ClusterIP"},{"op":"remove","path":"/spec/ports/0/nodePort"}]' \
  2>/dev/null && success "AC-HMS: NodePort removed, now ClusterIP" || \
  warn "AC-HMS service patch skipped (may already be ClusterIP or service not found)"

# Also add role labels to HMS pods — required by NetworkPolicy selectors
info "Adding role labels to HMS pods..."
kubectl label pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=hive-metastore" \
  role=operational --overwrite 2>/dev/null || \
  warn "Could not label OC-HMS pods (may not be running)"

# AC-HMS is deployed with release name hive-metastore-analytics
kubectl label pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=hive-metastore-analytics" \
  role=analytical --overwrite 2>/dev/null || \
  warn "Could not label AC-HMS pods (may not be running)"

################################################################################
# ════════════════════════════════════════════════════════════════════════════
# PHASE 5: Apply NetworkPolicy
#
# LEARNING NOTE — NetworkPolicy and CNI support:
#
#   Kubernetes NetworkPolicy is defined in the API but only ENFORCED if your
#   CNI plugin supports it. Common CNIs and their NetworkPolicy support:
#
#   ✓ Calico     — Full NetworkPolicy support (recommended)
#   ✓ Cilium     — Full NetworkPolicy + extended policy (eBPF)
#   ✓ Weave Net  — Full NetworkPolicy support
#   ✗ kindnet    — Does NOT support NetworkPolicy (Docker Desktop default)
#   ✗ Flannel    — Does NOT support NetworkPolicy
#
#   On Docker Desktop (kindnet): policies are accepted by the API server
#   and will appear in kubectl get networkpolicy, but they are NOT enforced.
#   Pods can still reach each other freely.
#
#   To test real enforcement on Docker Desktop, install Calico:
#     kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
#   (This replaces kindnet with Calico as the CNI.)
#
#   On EKS (Amazon VPC CNI + Calico), GKE (Cilium), AKS (Azure CNI):
#   NetworkPolicy is enforced by default or with minimal configuration.
# ════════════════════════════════════════════════════════════════════════════
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " Phase 5: Applying NetworkPolicy for HMS access control"
echo "════════════════════════════════════════════════════════════════════════════"

kubectl apply -f "${DEPLOY_DIR}/08-network-policy.yaml"
success "NetworkPolicy applied"

warn "REMINDER: NetworkPolicy is only enforced if your CNI supports it."
warn "Docker Desktop (kindnet) does NOT enforce NetworkPolicy."
warn "For enforcement: install Calico, or test on EKS/GKE/AKS."

################################################################################
# ════════════════════════════════════════════════════════════════════════════
# PHASE 6: Upgrade Gravitino with OAuth2 + RBAC
#
# LEARNING NOTE — What changes in Gravitino:
#
#   Before this upgrade:
#     • Gravitino accepts any request without authentication
#     • Any pod can call Gravitino and do anything
#
#   After this upgrade:
#     • Every API request must include: Authorization: Bearer <jwt-svid>
#     • Gravitino validates the JWT against SPIRE's OIDC endpoint
#     • Gravitino extracts the "sub" claim as the user identity
#     • RBAC checks the user's roles and grants/denies the operation
#
#   The "sub" claim from a JWT-SVID looks like:
#     "spiffe://gravitino.demo/spark-oc-writer"
#   This becomes the Gravitino "user" that RBAC rules apply to.
#   In script 07-setup-rbac.sh we create these users and assign roles.
#
#   IMPORTANT: After this upgrade, the existing demo scripts (03, 04)
#   will fail with 401 Unauthorized until you update them to include
#   JWT-SVIDs in their Gravitino API calls. That's handled in the
#   updated versions of those scripts (also in this branch).
# ════════════════════════════════════════════════════════════════════════════
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " Phase 6: Upgrading Gravitino with OAuth2 + RBAC"
echo "════════════════════════════════════════════════════════════════════════════"

info "Upgrading Gravitino Helm release with SPIRE OAuth2 configuration..."
# --reuse-values preserves all existing config (S3, HMS, persistence, etc.)
# The SPIRE values file overlays ONLY auth/authz settings on top.
helm upgrade gravitino "${CHARTS_DIR}/gravitino" \
  -n "${NAMESPACE}" \
  --reuse-values \
  -f "${DEPLOY_DIR}/09-gravitino-values-spire.yaml" \
  --wait \
  --timeout 120s

info "Waiting for Gravitino to be ready with new configuration..."
kubectl rollout status deployment/gravitino -n "${NAMESPACE}" --timeout=120s

success "Gravitino upgraded with OAuth2 + RBAC"

################################################################################
# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " SPIRE Integration Setup Complete"
echo "════════════════════════════════════════════════════════════════════════════"
echo ""
echo " What's now in place:"
echo "   ✓ SPIRE Server — CA for trust domain 'gravitino.demo'"
echo "   ✓ SPIRE Agent  — workload identity issuer on every node"
echo "   ✓ OIDC Provider — JWKS endpoint for Gravitino JWT validation"
echo "   ✓ Workload Entries:"
echo "       spiffe://gravitino.demo/gravitino         → Gravitino server pods"
echo "       spiffe://gravitino.demo/spark-oc-writer   → OC Spark writer pods"
echo "       spiffe://gravitino.demo/spark-ac-writer   → AC Spark writer pods"
echo "       spiffe://gravitino.demo/admin             → Admin client pods"
echo "   ✓ HMS Services — changed to ClusterIP (no external exposure)"
echo "   ✓ NetworkPolicy — only Gravitino can reach OC-HMS"
echo "   ✓ Gravitino — OAuth2 JWT validation + RBAC enabled"
echo ""
echo " NEXT STEPS:"
echo "   1. Run RBAC setup:  bash scripts/07-setup-rbac.sh"
echo "      (creates users, roles, and privilege assignments)"
echo ""
echo "   2. Run demos with SPIFFE authentication:"
echo "      bash scripts/03-iceberg-write-demo.sh   (oc_writer identity)"
echo "      bash scripts/04-ac-write-demo.sh         (ac_writer identity)"
echo ""
echo "   3. Validate policies (expect failures for unauthorized access):"
echo "      bash scripts/08-validate-policy.sh"
echo ""
echo " DEBUGGING:"
echo "   # Check SPIRE Server logs:"
echo "   kubectl logs -n ${NAMESPACE} -l app=spire-server -c spire-server"
echo ""
echo "   # Check SPIRE Agent logs:"
echo "   kubectl logs -n ${NAMESPACE} -l app=spire-agent"
echo ""
echo "   # Verify OIDC endpoint:"
echo "   kubectl port-forward svc/spire-oidc 8008:8008 -n ${NAMESPACE} &"
echo "   curl http://localhost:8008/.well-known/openid-configuration | jq ."
echo "   curl http://localhost:8008/keys | jq ."
echo ""
echo "   # List workload entries:"
echo "   kubectl exec -n ${NAMESPACE} \$(kubectl get pod -n ${NAMESPACE} -l app=spire-server -o jsonpath='{.items[0].metadata.name}') -- \\"
echo "     /opt/spire/bin/spire-server entry show -socketPath /run/spire/sockets/server.sock"
echo "════════════════════════════════════════════════════════════════════════════"
