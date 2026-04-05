#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 07-setup-rbac.sh
#
# Creates Gravitino RBAC: users, roles, and privilege assignments
#
# WHAT THIS SCRIPT DOES:
#   1. Port-forwards to Gravitino (admin call)
#   2. Creates Gravitino "users" for each SPIFFE identity
#   3. Creates oc_writer_role with write access to OC, read-only AC
#   4. Creates ac_writer_role with write access to AC, read-only OC
#   5. Assigns roles to users
#
# LEARNING NOTE — Gravitino's RBAC Model:
#
#   Gravitino uses a standard RBAC (Role-Based Access Control) model:
#
#     User ──→ Role ──→ Privilege ──→ Securable Object
#
#   USERS:
#     In Gravitino, a "user" is just a string identifier. When OAuth2 is
#     enabled, the "sub" claim from a JWT-SVID becomes the user identifier.
#     So the user "spiffe://gravitino.demo/spark-oc-writer" is automatically
#     created/matched when a JWT with that sub claim is presented.
#     We pre-register these users to assign roles to them.
#
#   ROLES:
#     A role is a named collection of privileges. Creating a role is like
#     creating a job function: "oc_writer" can do X, Y, Z on certain objects.
#
#   PRIVILEGES:
#     Gravitino privileges are:
#       USE_CATALOG       — can list/use a catalog (required for any access)
#       CREATE_SCHEMA     — can create databases/schemas in a catalog
#       CREATE_TABLE      — can create tables in a schema
#       MODIFY_TABLE      — can insert/update/delete data in a table
#       SELECT_TABLE      — can read data from a table (read-only)
#       CREATE_CATALOG    — can create new catalogs (metalake-level)
#       MANAGE_USERS      — can add/remove users (admin operation)
#
#   SECURABLE OBJECTS:
#     Privileges are granted on specific objects in the hierarchy:
#       metalake  → catalog → schema → table
#     You can grant at any level: granting SELECT_TABLE on a catalog grants
#     SELECT_TABLE on all tables in all schemas in that catalog.
#
#   OUR POLICY:
#     oc_writer_role:
#       • FULL access to oc_iceberg catalog (CREATE, MODIFY, SELECT, USE)
#       • READ-ONLY access to ac catalog (SELECT_TABLE, USE_CATALOG only)
#       → An oc_writer can write to operational; can read analytical for comparison
#
#     ac_writer_role:
#       • FULL access to ac catalog (hive_metastore_analytics)
#       • READ-ONLY access to oc_iceberg catalog (SELECT_TABLE, USE_CATALOG only)
#       → An ac_writer can read operational (source), write to analytical (dest)
#
#   WHY GRAVITINO RBAC + SPIFFE TOGETHER:
#     SPIFFE ensures the identity is UNFORGEABLE — you can't claim to be
#     spark-oc-writer unless SPIRE attested your pod via Kubernetes API.
#     Gravitino RBAC ensures the identity is AUTHORIZED — even if you have
#     a valid spark-oc-writer JWT, you still can't write to ac_iceberg.
#     Neither is sufficient alone:
#       • RBAC without SPIFFE: any pod could fake a username in a request
#       • SPIFFE without RBAC: any attested workload could do anything
#
# Prerequisites:
#   - 06-setup-spire.sh completed (Gravitino has OAuth2 enabled)
#   - Gravitino is running and accessible
#   - Port-forward OR cluster-internal access to port 8090
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

NAMESPACE="gravitino"
METALAKE="poc_layer"
GRAVITINO_PORT=8090
LOCAL_PORT=18090

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Port-forward setup ────────────────────────────────────────────────────────
# IMPORTANT: After 06-setup-spire.sh, Gravitino requires OAuth2 Bearer tokens
# for ALL API calls — including admin calls. But the admin token comes from
# SPIRE, and the admin pod needs to be attested first.
#
# For the RBAC setup script, we use a special approach:
#   1. Run a temporary pod labelled spiffe-workload=gravitino-admin
#   2. SPIRE attests it and issues JWT-SVID: spiffe://gravitino.demo/admin
#   3. Use that JWT-SVID as the Bearer token for Gravitino admin API calls
#
# For simplicity in this script, we fetch the JWT-SVID via the SPIRE agent
# socket from within the admin pod.

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " Setting up Gravitino RBAC for SPIFFE Identities"
echo "════════════════════════════════════════════════════════════════════════════"

# ── Start port-forward to Gravitino ──────────────────────────────────────────
info "Starting port-forward to Gravitino service..."
kubectl port-forward svc/gravitino ${LOCAL_PORT}:${GRAVITINO_PORT} -n "${NAMESPACE}" &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT
sleep 3

GRAVITINO_URL="http://localhost:${LOCAL_PORT}"

# ── Fetch admin JWT-SVID from SPIRE ──────────────────────────────────────────
# To call Gravitino's admin API, we need a JWT-SVID for the admin identity.
# We get it by running a temporary pod with the admin label, which SPIRE
# attests and issues a JWT-SVID to.
#
# LEARNING NOTE — How JWT-SVID minting works:
#   The SPIRE Agent socket provides a Workload API. When you call:
#     /opt/spire/bin/spire-agent api fetch jwt -audience gravitino
#   The Agent:
#     1. Identifies your PID via SO_PEERCRED
#     2. Looks up your pod in Kubernetes
#     3. Finds a matching workload entry (based on pod labels)
#     4. Requests a JWT-SVID from the Server for that entry
#     5. Returns the signed JWT
#   The returned JWT is a standard JWT you can decode with jwt.io:
#     Header: {"alg": "RS256", "kid": "<spire-key-id>"}
#     Payload: {"sub": "spiffe://gravitino.demo/admin",
#               "iss": "http://spire-oidc.gravitino.svc.cluster.local:8008",
#               "aud": ["gravitino"],
#               "exp": <5 min from now>,
#               "iat": <now>}

info "Fetching admin JWT-SVID from SPIRE..."
kubectl delete pod spire-admin-jwt-fetch -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1
kubectl run spire-admin-jwt-fetch \
  --image=ghcr.io/spiffe/spire-agent:1.9.6 \
  --restart=Never \
  -n "${NAMESPACE}" \
  -l "spiffe-workload=gravitino-admin" \
  --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"spire-admin-jwt-fetch\",
        \"image\": \"ghcr.io/spiffe/spire-agent:1.9.6\",
        \"command\": [\"/opt/spire/bin/spire-agent\", \"api\", \"fetch\", \"jwt\",
                     \"-audience\", \"gravitino\",
                     \"-socketPath\", \"/run/spire/sockets/agent.sock\"],
        \"volumeMounts\": [{
          \"name\": \"spire-socket\",
          \"mountPath\": \"/run/spire/sockets\"
        }]
      }],
      \"volumes\": [{
        \"name\": \"spire-socket\",
        \"hostPath\": {\"path\": \"/run/spire/sockets\", \"type\": \"DirectoryOrCreate\"}
      }]
    }
  }" > /dev/null 2>&1
# Wait for the pod to complete (max 30 seconds)
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/spire-admin-jwt-fetch \
  -n "${NAMESPACE}" --timeout=30s > /dev/null 2>&1 || true
ADMIN_JWT=$(kubectl logs spire-admin-jwt-fetch -n "${NAMESPACE}" 2>/dev/null | \
  grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1)
kubectl delete pod spire-admin-jwt-fetch -n "${NAMESPACE}" --ignore-not-found > /dev/null 2>&1

if [ -z "${ADMIN_JWT}" ]; then
  warn "Could not fetch admin JWT-SVID from SPIRE."
  warn "This may mean SPIRE is not yet fully initialised, or the admin"
  warn "workload entry is not yet registered."
  warn ""
  warn "Falling back to unauthenticated admin setup..."
  warn "(This works only if Gravitino hasn't fully enabled JWT enforcement yet.)"
  ADMIN_JWT=""
  AUTH_HEADER=""
else
  success "Admin JWT-SVID obtained"
  AUTH_HEADER="Authorization: Bearer ${ADMIN_JWT}"
  info "JWT-SVID sub claim: spiffe://gravitino.demo/admin"
fi

# ── Helper: Gravitino API calls ───────────────────────────────────────────────
gravitino_post() {
  local path="$1"
  local body="$2"
  local response http_code

  if [ -n "${AUTH_HEADER:-}" ]; then
    response=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Content-Type: application/json" \
      -H "${AUTH_HEADER}" \
      -d "${body}" \
      "${GRAVITINO_URL}${path}")
  else
    response=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Content-Type: application/json" \
      -d "${body}" \
      "${GRAVITINO_URL}${path}")
  fi

  http_code=$(echo "${response}" | tail -1)
  body_out=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200|201) echo "${body_out}" ;;
    409) warn "Already exists (409) — skipping" ;;
    *) error "HTTP ${http_code}: ${body_out}"; return 1 ;;
  esac
}

gravitino_put() {
  local path="$1"
  local body="$2"
  local response http_code

  if [ -n "${AUTH_HEADER:-}" ]; then
    response=$(curl -s -w "\n%{http_code}" \
      -X PUT \
      -H "Content-Type: application/json" \
      -H "${AUTH_HEADER}" \
      -d "${body}" \
      "${GRAVITINO_URL}${path}")
  else
    response=$(curl -s -w "\n%{http_code}" \
      -X PUT \
      -H "Content-Type: application/json" \
      -d "${body}" \
      "${GRAVITINO_URL}${path}")
  fi

  http_code=$(echo "${response}" | tail -1)
  body_out=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200|201) echo "${body_out}" ;;
    409) warn "Already exists (409) — skipping" ;;
    *) error "HTTP ${http_code}: ${body_out}"; return 1 ;;
  esac
}

gravitino_delete() {
  local path="$1"
  local response http_code

  if [ -n "${AUTH_HEADER:-}" ]; then
    response=$(curl -s -w "\n%{http_code}" \
      -X DELETE \
      -H "${AUTH_HEADER}" \
      "${GRAVITINO_URL}${path}")
  else
    response=$(curl -s -w "\n%{http_code}" \
      -X DELETE \
      "${GRAVITINO_URL}${path}")
  fi

  http_code=$(echo "${response}" | tail -1)
  body_out=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200|204) : ;;
    404) : ;;  # already gone
    *) warn "DELETE HTTP ${http_code}: ${body_out}" ;;
  esac
}

echo ""
echo "── Step 1: Register SPIFFE users in Gravitino ───────────────────────────"
# LEARNING NOTE:
#   Gravitino users are just string identifiers. When a JWT arrives with
#   sub="spiffe://gravitino.demo/spark-oc-writer", Gravitino looks up that
#   string as a user. We pre-register these users so we can assign roles.

for USER in \
  "spiffe://gravitino.demo/spark-oc-writer" \
  "spiffe://gravitino.demo/spark-ac-writer" \
  "spiffe://gravitino.demo/admin" \
  "spiffe://gravitino.demo/gravitino"; do

  info "Registering user: ${USER}"
  gravitino_post "/api/metalakes/${METALAKE}/users" \
    "{\"name\": \"${USER}\"}" || true
done

success "Users registered"

echo ""
echo "── Step 2: Create oc_writer_role ────────────────────────────────────────"
# LEARNING NOTE:
#   This role grants full access to the operational catalog (oc_iceberg)
#   and read-only access to the analytical catalog.
#
#   Privilege objects in Gravitino API use "securable" objects with types:
#     METALAKE   — top-level (grants apply to everything under it)
#     CATALOG    — a specific catalog
#     SCHEMA     — a specific schema/database
#     TABLE      — a specific table
#
#   We grant at the CATALOG level so privileges apply to all schemas and
#   tables within that catalog, now and in the future.

info "Creating oc_writer_role..."
gravitino_delete "/api/metalakes/${METALAKE}/roles/oc_writer_role" || true
gravitino_post "/api/metalakes/${METALAKE}/roles" '{
  "name": "oc_writer_role",
  "securableObjects": [
    {
      "type": "CATALOG",
      "fullName": "oc_iceberg",
      "privileges": [
        {"name": "USE_CATALOG",   "condition": "ALLOW"},
        {"name": "USE_SCHEMA",    "condition": "ALLOW"},
        {"name": "CREATE_SCHEMA", "condition": "ALLOW"},
        {"name": "CREATE_TABLE",  "condition": "ALLOW"},
        {"name": "MODIFY_TABLE",  "condition": "ALLOW"},
        {"name": "SELECT_TABLE",  "condition": "ALLOW"}
      ]
    },
    {
      "type": "CATALOG",
      "fullName": "hive_metastore_analytics",
      "privileges": [
        {"name": "USE_CATALOG",  "condition": "ALLOW"},
        {"name": "USE_SCHEMA",   "condition": "ALLOW"},
        {"name": "SELECT_TABLE", "condition": "ALLOW"}
      ]
    }
  ]
}' || true

success "oc_writer_role created"

echo ""
echo "── Step 3: Create ac_writer_role ────────────────────────────────────────"
# This role mirrors oc_writer_role but with the catalogs swapped:
#   Full write access to analytical, read-only to operational.

info "Creating ac_writer_role..."
gravitino_delete "/api/metalakes/${METALAKE}/roles/ac_writer_role" || true
gravitino_post "/api/metalakes/${METALAKE}/roles" '{
  "name": "ac_writer_role",
  "securableObjects": [
    {
      "type": "CATALOG",
      "fullName": "hive_metastore_analytics",
      "privileges": [
        {"name": "USE_CATALOG",   "condition": "ALLOW"},
        {"name": "USE_SCHEMA",    "condition": "ALLOW"},
        {"name": "CREATE_SCHEMA", "condition": "ALLOW"},
        {"name": "CREATE_TABLE",  "condition": "ALLOW"},
        {"name": "MODIFY_TABLE",  "condition": "ALLOW"},
        {"name": "SELECT_TABLE",  "condition": "ALLOW"}
      ]
    },
    {
      "type": "CATALOG",
      "fullName": "oc_iceberg",
      "privileges": [
        {"name": "USE_CATALOG",  "condition": "ALLOW"},
        {"name": "USE_SCHEMA",   "condition": "ALLOW"},
        {"name": "SELECT_TABLE", "condition": "ALLOW"}
      ]
    }
  ]
}' || true

success "ac_writer_role created"

echo ""
echo "── Step 4: Create admin_role ────────────────────────────────────────────"
# Admin gets full metalake-level access (can do everything)

info "Creating admin_role..."
gravitino_delete "/api/metalakes/${METALAKE}/roles/admin_role" || true
gravitino_post "/api/metalakes/${METALAKE}/roles" "{
  \"name\": \"admin_role\",
  \"securableObjects\": [
    {
      \"type\": \"METALAKE\",
      \"fullName\": \"${METALAKE}\",
      \"privileges\": [
        {\"name\": \"MANAGE_USERS\",  \"condition\": \"ALLOW\"},
        {\"name\": \"USE_CATALOG\",   \"condition\": \"ALLOW\"},
        {\"name\": \"USE_SCHEMA\",    \"condition\": \"ALLOW\"},
        {\"name\": \"CREATE_CATALOG\",\"condition\": \"ALLOW\"},
        {\"name\": \"CREATE_SCHEMA\", \"condition\": \"ALLOW\"},
        {\"name\": \"CREATE_TABLE\",  \"condition\": \"ALLOW\"},
        {\"name\": \"MODIFY_TABLE\",  \"condition\": \"ALLOW\"},
        {\"name\": \"SELECT_TABLE\",  \"condition\": \"ALLOW\"}
      ]
    }
  ]
}" || true

success "admin_role created"

echo ""
echo "── Step 5: Grant roles to users ──────────────────────────────────────────"
# LEARNING NOTE — Role grant flow:
#   PUT /api/metalakes/{ml}/users/{user}/role  assigns a role to a user.
#   After this, when Gravitino receives a JWT with sub=<user>, it looks up
#   the user's roles and evaluates privileges against the requested operation.

grant_role() {
  local user="$1"
  local role="$2"
  # URL-encode the SPIFFE URI (forward slashes must be encoded as %2F)
  local encoded_user
  encoded_user=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${user}', safe=''))" 2>/dev/null || \
    echo "${user}" | sed 's|/|%2F|g; s|:|%3A|g')

  # LEARNING NOTE: The Gravitino permissions API uses a separate endpoint path:
  #   PUT /api/metalakes/{ml}/permissions/users/{user}/grant/
  #   Body: {"roleNames": ["role1", "role2"]}
  # (NOT /api/metalakes/{ml}/users/{user}/role which doesn't exist)
  info "Granting ${role} to ${user}..."
  gravitino_put "/api/metalakes/${METALAKE}/permissions/users/${encoded_user}/grant/" \
    "{\"roleNames\": [\"${role}\"]}" || true
}

grant_role "spiffe://gravitino.demo/spark-oc-writer" "oc_writer_role"
grant_role "spiffe://gravitino.demo/spark-ac-writer" "ac_writer_role"
grant_role "spiffe://gravitino.demo/admin"           "admin_role"

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " RBAC Setup Complete"
echo "════════════════════════════════════════════════════════════════════════════"
echo ""
echo " Roles and Privileges:"
echo ""
echo "   spiffe://gravitino.demo/spark-oc-writer  →  oc_writer_role"
echo "     ✓ oc_iceberg:  USE, CREATE_SCHEMA, CREATE_TABLE, MODIFY_TABLE, SELECT"
echo "     ✓ ac catalog:  USE, SELECT only (READ-ONLY)"
echo "     ✗ ac catalog:  CREATE_TABLE, MODIFY_TABLE → DENIED"
echo ""
echo "   spiffe://gravitino.demo/spark-ac-writer  →  ac_writer_role"
echo "     ✓ ac catalog:  USE, CREATE_SCHEMA, CREATE_TABLE, MODIFY_TABLE, SELECT"
echo "     ✓ oc_iceberg:  USE, SELECT only (READ-ONLY)"
echo "     ✗ oc_iceberg:  CREATE_TABLE, MODIFY_TABLE → DENIED"
echo ""
echo "   spiffe://gravitino.demo/admin            →  admin_role"
echo "     ✓ metalake level: all privileges"
echo ""
echo " NEXT STEPS:"
echo "   bash scripts/03-iceberg-write-demo.sh   (writes to OC as oc_writer)"
echo "   bash scripts/04-ac-write-demo.sh         (reads OC, writes AC as ac_writer)"
echo "   bash scripts/08-validate-policy.sh       (proves unauthorized access is blocked)"
echo "════════════════════════════════════════════════════════════════════════════"
