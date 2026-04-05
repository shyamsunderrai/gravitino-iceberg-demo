# SPIFFE/SPIRE + Apache Gravitino: Zero-Trust Identity for a Data Lakehouse

This document covers three areas:

1. [SPIFFE/SPIRE Fundamentals](#part-1-spiffespire-fundamentals) — what the standards are and how the machinery works
2. [This Implementation](#part-2-this-implementation) — exactly where SPIFFE/SPIRE integrates with Gravitino in this demo
3. [Demo Execution Guide](#part-3-demo-execution-guide) — step-by-step walkthrough with explanation of what every command proves

---

## Part 1: SPIFFE/SPIRE Fundamentals

### What Problem Are We Solving?

Traditional service-to-service authentication relies on static secrets: API keys,
passwords, long-lived certificates, or hardcoded credentials. These have two fundamental
problems:

- **Secret sprawl**: credentials must be distributed, rotated, and revoked manually.
  A credential stored in a ConfigMap, environment variable, or Vault secret is only as
  secure as the system managing it.
- **No workload identity**: a credential proves "someone who has this key", not "this
  specific microservice running on this specific node." An attacker who steals the key
  cannot be distinguished from the legitimate workload.

SPIFFE (Secure Production Identity Framework for Everyone) solves both problems by
giving each workload a **cryptographically verifiable identity** derived from its
Kubernetes metadata — no static secrets required.

---

### SPIFFE: The Standard

SPIFFE is a specification, not a product. It defines:

**SPIFFE ID** — a URI that uniquely identifies a workload:
```
spiffe://<trust-domain>/<workload-path>

Examples:
  spiffe://gravitino.demo/spark-oc-writer
  spiffe://gravitino.demo/admin
  spiffe://gravitino.demo/gravitino
```

**SVID (SPIFFE Verifiable Identity Document)** — the credential that proves a workload
holds a particular SPIFFE ID. Two formats:

| Format | Structure | Use Case |
|---|---|---|
| X.509-SVID | TLS certificate with SPIFFE URI in the SAN field | Mutual TLS between services |
| JWT-SVID | Signed JWT with SPIFFE URI in the `sub` claim | Bearer token in HTTP headers |

In this demo, Spark workloads obtain **JWT-SVIDs** and present them to Gravitino as
`Authorization: Bearer <token>`.

---

### SPIRE: The Implementation

SPIRE (SPIFFE Runtime Environment) is the reference implementation of SPIFFE. It has
two components:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                 Kubernetes Cluster                           │
│                                                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  SPIRE Server  (StatefulSet, 1 replica)                                │ │
│  │                                                                        │ │
│  │  • Root CA for trust domain "gravitino.demo"                          │ │
│  │  • Issues X.509 and JWT SVIDs to agents                               │ │
│  │  • Stores workload entries (pod label → SPIFFE ID mappings)           │ │
│  │  • Exposes gRPC API on :8081 for agent connections                    │ │
│  │                                                                        │ │
│  │  ┌───────────────────────────────────────────────────────────────┐    │ │
│  │  │  OIDC Discovery Provider  (sidecar container)                  │    │ │
│  │  │  • Serves /.well-known/openid-configuration on :8008           │    │ │
│  │  │  • Serves /keys (JWKS) on :8008                                │    │ │
│  │  │  • Reads SPIRE signing keys via shared Unix socket             │    │ │
│  │  └───────────────────────────────────────────────────────────────┘    │ │
│  └───────────────────────────────┬────────────────────────────────────────┘ │
│                                  │ gRPC :8081                                │
│                                  │ (node attestation + SVID issuance)        │
│  ┌───────────────────────────────▼────────────────────────────────────────┐ │
│  │  SPIRE Agent  (DaemonSet — one pod per node)                           │ │
│  │                                                                        │ │
│  │  • Attests itself to the Server at startup (k8s_psat)                 │ │
│  │  • Exposes Workload API on Unix socket: /run/spire/sockets/agent.sock  │ │
│  │  • When a workload calls the socket, attests the workload by looking   │ │
│  │    up the caller's pod labels in the Kubernetes API                    │ │
│  │  • Returns a JWT-SVID for the matching SPIFFE ID                      │ │
│  └───────────────────────────────┬────────────────────────────────────────┘ │
│                                  │ hostPath socket                            │
│                  ┌───────────────┴────────────────┐                          │
│                  │                                │                          │
│  ┌───────────────▼──────────┐  ┌─────────────────▼──────────┐               │
│  │  Spark Pod (oc-writer)   │  │  Spark Pod (ac-writer)     │               │
│  │  label: spark-oc-writer  │  │  label: spark-ac-writer    │               │
│  │                          │  │                            │               │
│  │  Requests JWT-SVID:      │  │  Requests JWT-SVID:        │               │
│  │  sub=.../spark-oc-writer │  │  sub=.../spark-ac-writer   │               │
│  └──────────────────────────┘  └────────────────────────────┘               │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Node Attestation: How SPIRE Agents Bootstrap Trust

Before the SPIRE Agent can issue SVIDs to workloads, it must prove to the SPIRE Server
that it is running on a legitimate Kubernetes node. This process is called **node
attestation**. We use the `k8s_psat` (Kubernetes Projected Service Account Token) plugin.

```
SPIRE Agent                                    SPIRE Server
    │                                               │
    │  1. Read projected ServiceAccount token       │
    │     from /run/spire/token                     │
    │     (audience="spire", TTL=2h)                │
    │                                               │
    │  2. Send token to Server (gRPC)               │
    │─────────────────────────────────────────────>│
    │                                               │
    │                         3. Call Kubernetes TokenReview API:
    │                            POST /apis/authentication.k8s.io/v1/tokenreviews
    │                            Verify token belongs to SA "spire-agent"
    │                                               │
    │                         4. Read node name from TokenReview response
    │                            Node ID = spiffe://gravitino.demo/spire/agent/
    │                                      k8s_psat/gravitino-demo/<node-name>
    │                            (node-name is stable; survives pod restarts)
    │                                               │
    │  5. Receive X.509-SVID from Server            │
    │<─────────────────────────────────────────────│
    │                                               │
    │  6. Open Workload API socket:                 │
    │     /run/spire/sockets/agent.sock             │
    │                                               │
```

**Why `k8s_psat` instead of `k8s_sat`:**
The older `k8s_sat` plugin derived the node ID from the agent pod's UID, which changes
every time the DaemonSet pod restarts. `k8s_psat` derives the ID from the stable
Kubernetes **node name** (e.g., `docker-desktop`), so workload entries stay valid
across pod restarts.

---

### Workload Attestation: How Spark Gets a JWT-SVID

Once the Agent is running, any pod on the same node can call the Workload API to request
a JWT-SVID. The Agent attests the workload by inspecting its Kubernetes metadata:

```
Spark Pod                    SPIRE Agent              SPIRE Server    Kubernetes API
    │                            │                         │                │
    │  1. Connect to Unix socket │                         │                │
    │     /run/spire/sockets/    │                         │                │
    │     agent.sock             │                         │                │
    │───────────────────────────>│                         │                │
    │                            │                         │                │
    │                            │  2. Get caller PID via  │                │
    │                            │     SO_PEERCRED         │                │
    │                            │                         │                │
    │                            │  3. GET /pods from      │                │
    │                            │     kubelet             │                │
    │                            │─────────────────────────────────────────>│
    │                            │<─────────────────────────────────────────│
    │                            │     (pod list for this node)              │
    │                            │                         │                │
    │                            │  4. Match PID → pod → extract labels:    │
    │                            │     spiffe-workload=spark-oc-writer       │
    │                            │     namespace=gravitino                   │
    │                            │                         │                │
    │                            │  5. Query Server for    │                │
    │                            │     matching workload   │                │
    │                            │     entry               │                │
    │                            │────────────────────────>│                │
    │                            │<────────────────────────│                │
    │                            │     SPIFFE ID:          │                │
    │                            │     .../spark-oc-writer │                │
    │                            │                         │                │
    │                            │  6. Request JWT-SVID    │                │
    │                            │     for that SPIFFE ID  │                │
    │                            │────────────────────────>│                │
    │                            │<────────────────────────│                │
    │                            │     JWT signed with     │                │
    │                            │     SPIRE's RS256 key   │                │
    │                            │                         │                │
    │  7. Return JWT-SVID        │                         │                │
    │<───────────────────────────│                         │                │
    │                            │                         │                │
    │  JWT payload:              │                         │                │
    │  {                         │                         │                │
    │    "sub": "spiffe://gravitino.demo/spark-oc-writer", │                │
    │    "iss": "https://spire-oidc.gravitino.svc.cluster.local",           │
    │    "aud": ["gravitino"],   │                         │                │
    │    "exp": <now + 5min>     │                         │                │
    │  }                         │                         │                │
```

**Zero-touch identity**: the Spark pod never "proves" its identity directly. It simply
calls a socket. The Agent handles all attestation by reading Kubernetes API metadata.
Adding the label `spiffe-workload=spark-oc-writer` to a pod is all that's needed to
give it that SPIFFE identity.

---

### JWT-SVID Validation: How Gravitino Verifies the Token

Gravitino uses standard OAuth2/OIDC JWT validation via its `JwksTokenValidator`:

```
Spark Pod                    Gravitino Server           SPIRE OIDC Provider
    │                            │                            │
    │  Authorization:            │                            │
    │  Bearer eyJhbGci...        │                            │
    │───────────────────────────>│                            │
    │                            │                            │
    │                            │  1. Decode JWT header      │
    │                            │     alg=ES256, kid=<key-id>│
    │                            │                            │
    │                            │  2. Fetch JWKS (if not     │
    │                            │     cached):               │
    │                            │  GET /keys                 │
    │                            │───────────────────────────>│
    │                            │<───────────────────────────│
    │                            │     {"keys": [{            │
    │                            │       "kty":"EC",          │
    │                            │       "kid":"<key-id>",    │
    │                            │       "x":"...", "y":"..."  │
    │                            │     }]}                    │
    │                            │                            │
    │                            │  3. Verify signature using │
    │                            │     the matching public key│
    │                            │                            │
    │                            │  4. Check claims:          │
    │                            │     aud contains           │
    │                            │     "gravitino" ✓          │
    │                            │     exp > now ✓            │
    │                            │                            │
    │                            │  5. Extract principal:     │
    │                            │     sub = "spiffe://       │
    │                            │     gravitino.demo/        │
    │                            │     spark-oc-writer"       │
    │                            │                            │
    │                            │  6. Check RBAC: does       │
    │                            │     spark-oc-writer have   │
    │                            │     privilege for this op? │
    │                            │                            │
    │  200 OK / 403 Forbidden    │                            │
    │<───────────────────────────│                            │
```

The JWKS endpoint handles key rotation automatically: when SPIRE rotates its signing
key, it publishes the new key to `/keys`. Gravitino fetches the updated JWKS on the
next validation (or when a key ID is not found in cache). No configuration changes
required.

---

### The Two Security Layers

```
┌────────────────────────────────────────────────────────────────────────┐
│  Layer 1: Kubernetes NetworkPolicy (kernel-level, CNI-enforced)         │
│                                                                          │
│  Controls WHICH pods can open TCP connections to which services.         │
│  Enforced by iptables/eBPF at the node kernel — cannot be bypassed      │
│  from within a pod.                                                      │
│                                                                          │
│  Rules in this demo:                                                     │
│  • OC-HMS port 9083: ONLY pods labelled app=gravitino may connect        │
│  • AC-HMS port 9083: pods labelled app=gravitino OR                      │
│                       spiffe-workload=spark-ac-writer may connect        │
│                                                                          │
│  What it prevents: a rogue pod cannot open a raw Thrift connection to    │
│  HMS to read/write metadata, even if it knows the hostname and port.     │
└────────────────────────────────────────────────────────────────────────┘
                              ↕  both layers needed
┌────────────────────────────────────────────────────────────────────────┐
│  Layer 2: SPIFFE/SPIRE + Gravitino RBAC (application-level)             │
│                                                                          │
│  Controls WHAT authenticated workloads are permitted to do.              │
│  Enforced by Gravitino: every API call requires a valid JWT-SVID, and   │
│  the SPIFFE ID extracted from the token is checked against RBAC rules.  │
│                                                                          │
│  Rules in this demo:                                                     │
│  • spark-oc-writer: CREATE/MODIFY/SELECT on oc_iceberg; SELECT on AC    │
│  • spark-ac-writer: CREATE/MODIFY/SELECT on ac catalog; SELECT on OC    │
│  • admin:           full privileges at metalake level                    │
│                                                                          │
│  What it prevents: even Gravitino itself cannot be impersonated —        │
│  a pod must present a cryptographically signed JWT issued by SPIRE to    │
│  identify itself. Static credentials are eliminated entirely.            │
└────────────────────────────────────────────────────────────────────────┘
```

Neither layer alone is sufficient:
- NetworkPolicy without SPIFFE: can prevent direct HMS bypass, but cannot distinguish
  _which_ Gravitino-authorized workload is calling — any pod in the cluster can
  impersonate any other if credentials are static.
- SPIFFE without NetworkPolicy: correctly authenticates the caller, but a compromised
  pod could still make raw Thrift calls to HMS, bypassing Gravitino's RBAC entirely.

---

## Part 2: This Implementation

### Full System Architecture

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                          Kubernetes: namespace "gravitino"                     │
│                                                                                │
│  ┌─────────────────────────────────────────────────────────────────────────┐  │
│  │  SPIRE Server (spire-server-0)                                           │  │
│  │  trust domain: gravitino.demo        ┌──────────────────────────────┐   │  │
│  │  CA key: /run/spire/data/keys.json   │  OIDC Discovery Provider     │   │  │
│  │  store: SQLite PVC                   │  :8008  /.well-known/...      │   │  │
│  │                    ──────────────────│  :8008  /keys  (JWKS)         │   │  │
│  │                    shared socket     └──────────────────────────────┘   │  │
│  └──────────────────────────────┬───────────────────┬────────────────────┘  │
│                                 │ gRPC :8081         │ HTTP :8008             │
│                        node attestation          JWKS fetch                  │
│                                 │                    │                        │
│  ┌──────────────────────────────▼──────────┐         │                        │
│  │  SPIRE Agent (DaemonSet)                 │         │                        │
│  │  hostPID: true  hostNetwork: true        │         │                        │
│  │  socket: /run/spire/sockets/agent.sock   │         │                        │
│  └──────────────────┬───────────────────────┘         │                        │
│          hostPath socket (all pods on node)           │                        │
│          ┌───────────────────────────────────────────────────────────────┐    │
│          │                                                               │    │
│  ┌───────▼────────────────┐  ┌──────────────────────────┐               │    │
│  │  Spark: oc-writer      │  │  Spark: ac-writer         │               │    │
│  │  label: spark-oc-writer│  │  label: spark-ac-writer   │               │    │
│  │                        │  │                           │               │    │
│  │  Init container:       │  │  Init container:          │               │    │
│  │  /jars/spire-agent     │  │  /jars/spire-agent        │               │    │
│  │  → fetch JWT-SVID      │  │  → fetch JWT-SVID         │               │    │
│  │  → write to /jwt/token │  │  → write to /jwt/token    │               │    │
│  └──────────┬─────────────┘  └──────────────┬────────────┘               │    │
│             │  Bearer JWT                    │  Bearer JWT                │    │
│             │                               │                             │    │
│  ┌──────────▼───────────────────────────────▼──────────────────────────┐ │    │
│  │                        Apache Gravitino :8090                        │ │    │
│  │                                                                      │ │    │
│  │  authenticators: oauth                                               │ │    │
│  │  JwksTokenValidator ──────────────────────────────────────────────────────>│
│  │  serverUri: https://spire-oidc.gravitino.svc.cluster.local           │ │    │
│  │  jwksUri:   http://spire-oidc.gravitino.svc.cluster.local:8008/keys  │ │    │
│  │  principalFields: sub  →  "spiffe://gravitino.demo/spark-oc-writer"  │ │    │
│  │                                                                      │ │    │
│  │  RBAC: poc_layer metalake                                            │ │    │
│  │    oc_writer_role → USE+CREATE+MODIFY on oc_iceberg                  │ │    │
│  │    ac_writer_role → USE+CREATE+MODIFY on ac catalog                  │ │    │
│  │                                                                      │ │    │
│  │  Iceberg REST :9001                                                  │ │    │
│  │  catalogConfigProvider: dynamic-config-provider                      │ │    │
│  └────────────────┬────────────────────────────────────────────────────┘ │    │
│                   │                                                       │    │
│         Thrift :9083 (only Gravitino pods; NetworkPolicy enforced)       │    │
│         ┌─────────┴───────────────────────────────────────────────────┐  │    │
│         │                                                             │  │    │
│  ┌──────▼───────────────┐              ┌──────────────────────────────▼──┐    │
│  │  OC-HMS (ClusterIP)  │              │  AC-HMS (ClusterIP)              │    │
│  │  hive-metastore:9083 │              │  hive-metastore-analytics:9083   │    │
│  │  bucket: operational │              │  bucket: analytical              │    │
│  │                      │              │  (also accessible directly from  │    │
│  │  NetworkPolicy:      │              │   spark-ac-writer pod)           │    │
│  │  → ONLY Gravitino    │              │  NetworkPolicy:                  │    │
│  └──────────────────────┘              │  → Gravitino + spark-ac-writer   │    │
│                                        └─────────────────────────────────┘    │
│                                                                                │
│  ┌─────────────────────────────────────────────────────────────────────────┐  │
│  │  SeaweedFS (S3-compatible object store)                                  │  │
│  │  filer: seaweedfs-filer:8333                                             │  │
│  │  buckets: operational  │  analytical                                     │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

### Integration Point 1: Gravitino OAuth2 Configuration

`deploy/09-gravitino-values-spire.yaml` configures Gravitino's authentication and
authorization subsystems via Helm values:

```yaml
# Switch from "simple" (accept any string username) to "oauth" (validate JWT)
authenticators: oauth

authenticator:
  oauth:
    # Audience claim Gravitino requires in every incoming JWT.
    # SPIRE issues tokens with aud=["gravitino"] (set in the fetch command).
    serviceAudience: gravitino

    # OIDC issuer URL. Must EXACTLY match the "iss" claim in SPIRE JWT-SVIDs.
    # SPIRE's OIDC provider always reports "https://" in its discovery doc
    # (no port), even though actual traffic uses HTTP on :8008.
    serverUri: "https://spire-oidc.gravitino.svc.cluster.local"

    # Direct JWKS URI using HTTP (bypasses the https:// discovery redirect).
    # Gravitino fetches RS256/ES256 public keys from here to verify signatures.
    jwksUri: "http://spire-oidc.gravitino.svc.cluster.local:8008/keys"

    # JwksTokenValidator: dynamically fetches public keys from jwksUri.
    # Required because SPIRE uses asymmetric signing (ES256). The default
    # StaticSignKeyValidator only works with HMAC (HS256) shared secrets.
    tokenValidatorClass: "org.apache.gravitino.server.authentication.JwksTokenValidator"

    # Use the "sub" claim as the principal identity in RBAC.
    # SPIRE puts the SPIFFE URI here: "spiffe://gravitino.demo/spark-oc-writer"
    principalFields: "sub"

authorization:
  enable: true
  # This SPIFFE ID bypasses RBAC for admin operations (user/role management).
  serviceAdmins: "spiffe://gravitino.demo/admin"

# Required when authorization.enable=true — propagates auth context through
# the Iceberg REST service to catalog backends.
icebergRest:
  catalogConfigProvider: "dynamic-config-provider"
  dynamicConfigProvider:
    uri: "http://localhost:8090"
    metalake: "poc_layer"
    defaultCatalogName: "oc_iceberg"
```

**Key implementation detail**: Gravitino 1.2.0's `dynamic-config-provider` does not
propagate S3 properties (`s3.endpoint`, `s3.region`, etc.) from the registered catalog
to the Iceberg S3FileIO instance. The workaround is AWS SDK v2 environment variables
that are set in the Gravitino deployment:

```yaml
env:
  - name: AWS_REGION
    value: "us-east-1"                                        # SDK v2 region requirement
  - name: AWS_ENDPOINT_URL_S3
    value: "http://seaweedfs-filer.gravitino.svc.cluster.local:8333"  # redirect to SeaweedFS
  - name: AWS_ACCESS_KEY_ID
    value: "admin"
  - name: AWS_SECRET_ACCESS_KEY
    value: "admin"
```

---

### Integration Point 2: Workload Entry Registration

`scripts/06-setup-spire.sh` Phase 3 registers four workload entries in the SPIRE Server.
These entries are the mapping from "pod with these labels" to "SPIFFE ID":

| SPIFFE ID | Selector: namespace | Selector: pod label | Used by |
|---|---|---|---|
| `spiffe://gravitino.demo/gravitino` | `gravitino` | `app.kubernetes.io/name=gravitino` | Gravitino server pod |
| `spiffe://gravitino.demo/spark-oc-writer` | `gravitino` | `spiffe-workload=spark-oc-writer` | OC write demo Spark pod |
| `spiffe://gravitino.demo/spark-ac-writer` | `gravitino` | `spiffe-workload=spark-ac-writer` | AC write demo Spark pod |
| `spiffe://gravitino.demo/admin` | `gravitino` | `spiffe-workload=gravitino-admin` | RBAC setup pod |

The parent ID for all entries is the Agent's SPIFFE ID:
```
spiffe://gravitino.demo/spire/agent/k8s_psat/gravitino-demo/<node-name>
```
This means only agents that have been properly node-attested can issue these SVIDs.

---

### Integration Point 3: JWT Fetch in Spark Init Containers

Both `scripts/03-iceberg-write-demo.sh` and `scripts/04-ac-write-demo.sh` launch Spark
pods with an **init container** that fetches a JWT-SVID before the main Spark process
starts.

**Why an init container?** The SPIRE Agent binary (`ghcr.io/spiffe/spire-agent:1.9.6`)
is a distroless image — no shell, no utilities, no `exec` capabilities. We extract the
binary during setup (`scripts/06-setup-spire.sh` or pre-provided in `jars/`) and mount
it into a `busybox:1.36` init container that _does_ have a shell:

```json
{
  "name": "fetch-spire-jwt",
  "image": "busybox:1.36",
  "command": ["sh", "-c",
    "/jars/spire-agent api fetch jwt -audience gravitino -socketPath /run/spire/sockets/agent.sock 2>/dev/null | grep -oE 'eyJ[A-Za-z0-9._-]+' | head -1 > /run/spire/jwt/token"
  ],
  "volumeMounts": [
    {"name": "jars",         "mountPath": "/jars"},
    {"name": "spire-socket", "mountPath": "/run/spire/sockets"},
    {"name": "jwt-dir",      "mountPath": "/run/spire/jwt"}
  ]
}
```

The JWT is written to a shared `emptyDir` volume at `/run/spire/jwt/token`. The main
Spark container then reads this file at startup and uses it as the Bearer token for all
Gravitino API calls.

**Workload attestation at this moment**: when the init container calls
`/run/spire/sockets/agent.sock`, the SPIRE Agent looks at the calling PID, resolves it
to the pod via kubelet API, checks the pod labels, and issues a JWT-SVID with the
matching SPIFFE ID. The label `spiffe-workload=spark-oc-writer` on the pod is what
triggers issuance of `spiffe://gravitino.demo/spark-oc-writer`.

---

### Integration Point 4: RBAC Users and Roles

`scripts/07-setup-rbac.sh` calls Gravitino's REST API (authenticated as the `admin`
SPIFFE identity) to create users, roles, and privilege grants:

```
Gravitino RBAC Model:

  Metalake: poc_layer
  │
  ├── Catalog: oc_iceberg  (Iceberg REST, operational bucket)
  │     ├── oc_writer_role → USE_CATALOG, USE_SCHEMA, CREATE_SCHEMA,
  │     │                     CREATE_TABLE, MODIFY_TABLE, SELECT_TABLE
  │     └── ac_writer_role → USE_CATALOG, USE_SCHEMA, SELECT_TABLE  (read-only)
  │
  └── Catalog: hive_metastore_analytics  (AC-HMS)
        ├── ac_writer_role → USE_CATALOG, USE_SCHEMA, CREATE_SCHEMA,
        │                     CREATE_TABLE, MODIFY_TABLE, SELECT_TABLE
        └── oc_writer_role → USE_CATALOG, USE_SCHEMA, SELECT_TABLE  (read-only)

  User assignments:
    spiffe://gravitino.demo/spark-oc-writer  →  oc_writer_role
    spiffe://gravitino.demo/spark-ac-writer  →  ac_writer_role
    spiffe://gravitino.demo/admin            →  admin_role (metalake level, all privs)
```

The admin itself authenticates using a JWT-SVID. `scripts/07-setup-rbac.sh` runs a
`kubectl run` pod with label `spiffe-workload=gravitino-admin`, fetches that pod's
JWT-SVID, and uses it as `Authorization: Bearer` in all Gravitino admin API calls. The
`serviceAdmins` config in Gravitino recognises `spiffe://gravitino.demo/admin` as a
service admin that bypasses RBAC for management operations.

**Why roles must be deleted and recreated (not updated):** Gravitino 1.2.0 does not
support modifying a role's securable object list after creation. The setup script uses a
`DELETE` + `POST` pattern for idempotency.

---

### Integration Point 5: NetworkPolicy + Service Type

`deploy/08-network-policy.yaml` adds kernel-level enforcement. Two key design decisions:

**1. HMS Services converted from NodePort to ClusterIP** (`scripts/06-setup-spire.sh`
Phase 4): NodePort traffic is SNAT'd by kube-proxy before it reaches the pod, so
NetworkPolicy pod selectors cannot identify the source. ClusterIP preserves source pod
IP, making NetworkPolicy effective.

**2. Four policies** (two per HMS):
- `deny-all-to-oc-hms`: default deny — empty ingress list
- `allow-gravitino-to-oc-hms`: allows only `app.kubernetes.io/name=gravitino` on :9083
- `deny-all-to-ac-hms`: default deny
- `allow-to-ac-hms`: allows `app.kubernetes.io/name=gravitino` AND `spiffe-workload=spark-ac-writer` on :9083

The `spark-ac-writer` is intentionally allowed direct AC-HMS access — the demo's ETL
flow writes directly from Spark to the analytical Hive Metastore without going through
Gravitino's REST layer.

> **Note**: NetworkPolicy is only enforced by CNI plugins that support it (Calico,
> Cilium, Weave). Docker Desktop uses `kindnet` which does **not** enforce NetworkPolicy.
> On Docker Desktop the policies exist in the API but are silently ignored. Test 5 in
> `scripts/08-validate-policy.sh` detects this and marks the test as SKIP rather than FAIL.

---

### Data Flow: End-to-End for `spark-oc-writer`

```
1. Init container calls SPIRE Agent socket
   → Agent attests pod via label "spiffe-workload=spark-oc-writer"
   → Agent returns JWT-SVID:
       {"sub":"spiffe://gravitino.demo/spark-oc-writer",
        "iss":"https://spire-oidc.gravitino.svc.cluster.local",
        "aud":["gravitino"], "exp":<now+5min>}
   → Token written to /run/spire/jwt/token

2. Spark container starts, reads /run/spire/jwt/token

3. Spark calls Gravitino Iceberg REST (:9001):
   GET /iceberg/v1/config
   Authorization: Bearer <jwt>

4. Gravitino JwksTokenValidator:
   a. Fetches JWKS from http://spire-oidc...:8008/keys
   b. Verifies ES256 signature
   c. Validates aud="gravitino", exp not passed
   d. Extracts principal: "spiffe://gravitino.demo/spark-oc-writer"

5. Gravitino RBAC:
   a. Looks up user "spiffe://gravitino.demo/spark-oc-writer"
   b. Finds assigned role: oc_writer_role
   c. Checks privilege: USE_CATALOG on oc_iceberg → ALLOW
      USE_SCHEMA on poc_demo → ALLOW
      CREATE_TABLE → ALLOW
      MODIFY_TABLE → ALLOW

6. Gravitino forwards Thrift call to OC-HMS:9083
   NetworkPolicy kernel rule: source pod has label app.kubernetes.io/name=gravitino → ALLOW

7. OC-HMS returns Iceberg table metadata

8. Gravitino returns catalog config to Spark

9. Spark writes Parquet file directly to SeaweedFS S3:
   s3a://operational/warehouse/poc_demo.db/sensor_readings/data/...
   (S3FileIO uses AWS_ENDPOINT_URL_S3=http://seaweedfs-filer:8333)
```

---

## Part 3: Demo Execution Guide

### Prerequisites

- Docker Desktop with Kubernetes enabled (or any k8s cluster with Helm)
- `kubectl` configured pointing to the cluster
- `helm` 3.x installed
- `jq` installed (used by demo scripts)

### File Layout

```
dev/charts/
├── deploy/
│   ├── 00-namespace.yaml          # gravitino namespace
│   ├── 01-seaweedfs.yaml          # S3-compatible object store
│   ├── 02-gravitino-pvc.yaml      # Persistent volume for Gravitino data
│   ├── 03-gravitino-values.yaml   # Base Gravitino Helm values (S3, HMS)
│   ├── 04-oc-hms-values.yaml      # Operational Hive Metastore values
│   ├── 05-ac-hms-values.yaml      # Analytical Hive Metastore values
│   ├── 06-spire-server.yaml       # SPIRE Server + OIDC provider
│   ├── 07-spire-agent.yaml        # SPIRE Agent DaemonSet
│   ├── 08-network-policy.yaml     # NetworkPolicy for HMS access control
│   └── 09-gravitino-values-spire.yaml  # Gravitino SPIRE/OAuth2 overlay
├── scripts/
│   ├── 00-download-jars.sh        # Downloads Spark JARs for demo pods
│   ├── 01-deploy-all.sh           # Deploys base infrastructure
│   ├── 02-register-catalogs.sh    # Registers metalake + catalogs in Gravitino
│   ├── 03-iceberg-write-demo.sh   # Demo 1: OC write with oc-writer identity
│   ├── 04-ac-write-demo.sh        # Demo 2: ETL read OC → write AC with ac-writer
│   ├── 05-cleanup.sh              # Tears down all resources
│   ├── 06-setup-spire.sh          # Deploys SPIRE and enables auth in Gravitino
│   ├── 07-setup-rbac.sh           # Creates users, roles, privilege grants
│   └── 08-validate-policy.sh      # Verifies RBAC enforcement (6 tests)
├── jars/
│   ├── spire-agent                # Linux binary extracted from distroless image
│   ├── iceberg-spark-runtime-3.5_2.12-1.6.1.jar
│   ├── gravitino-spark-connector-runtime-3.5_2.12-1.2.0.jar
│   └── ...
└── gravitino/                     # Gravitino Helm chart
```

---

### Step 0: Download JARs

```bash
bash scripts/00-download-jars.sh
```

**What this does:**
Downloads the Spark JARs required by the demo pods into `jars/`. These are mounted into
Spark pods via a `hostPath` volume so the pods can find the Iceberg and Gravitino
connector libraries without building a custom Docker image.

The `jars/spire-agent` binary should already be present in the repository. If missing,
extract it from the distroless SPIRE image:
```bash
CID=$(docker create ghcr.io/spiffe/spire-agent:1.9.6)
docker cp "${CID}:/opt/spire/bin/spire-agent" jars/spire-agent
docker rm "${CID}"
chmod +x jars/spire-agent
```

**What it validates:** that all required libraries are locally available. The demo will
fail at the Spark pod step if any JAR is missing.

---

### Step 1: Deploy Base Infrastructure

```bash
bash scripts/01-deploy-all.sh
```

**What this does (in order):**
1. Creates the `gravitino` namespace (`deploy/00-namespace.yaml`)
2. Deploys SeaweedFS with two S3 buckets: `operational` and `analytical` (`deploy/01-seaweedfs.yaml`)
3. Creates a PersistentVolumeClaim for Gravitino's H2 database (`deploy/02-gravitino-pvc.yaml`)
4. Deploys the Gravitino Helm chart with base configuration — S3 credentials, HMS URIs,
   Iceberg REST service enabled, **no authentication yet** (`deploy/03-gravitino-values.yaml`)
5. Deploys OC-HMS (Hive Metastore for the operational data tier) (`deploy/04-oc-hms-values.yaml`)
6. Deploys AC-HMS (Hive Metastore for the analytical data tier) (`deploy/05-ac-hms-values.yaml`)
7. Waits for all pods to become Ready

**What it validates:** the core data platform is running and all services can communicate.
At this point Gravitino has **no authentication** — any request is accepted.

---

### Step 2: Register Catalogs

```bash
bash scripts/02-register-catalogs.sh
```

**What this does:**
Port-forwards to the Gravitino service and calls the Gravitino REST API to register:

| Resource | Type | Backend |
|---|---|---|
| Metalake `poc_layer` | metalake | (Gravitino's own H2 database) |
| Catalog `OC-HMS` | RELATIONAL / hive | thrift://hive-metastore:9083 |
| Catalog `oc_iceberg` | RELATIONAL / lakehouse-iceberg | HMS + SeaweedFS `s3a://operational` |
| Catalog `AC-HMS` | RELATIONAL / hive | thrift://hive-metastore-analytics:9083 |

The `oc_iceberg` catalog registration is the critical one: it tells Gravitino's Iceberg
REST service to use `hive` as the metastore backend and SeaweedFS as the warehouse
storage location. The catalog also includes:
- `io-impl = org.apache.iceberg.aws.s3.S3FileIO` — use AWS SDK v2 S3FileIO (not Hadoop S3A)
- `s3.endpoint`, `s3.access-key-id`, `s3.secret-access-key`, `s3.path-style-access`

**What it validates:** Gravitino can reach both HMS instances. Running this script a
second time is safe — existing resources return HTTP 409 and are skipped.

---

### Step 3: Deploy SPIRE and Enable Authentication

```bash
bash scripts/06-setup-spire.sh
```

This is the central script of the SPIFFE/SPIRE integration. It runs six phases:

#### Phase 1 — Deploy SPIRE Server
```bash
kubectl apply -f deploy/06-spire-server.yaml
kubectl rollout status statefulset/spire-server -n gravitino --timeout=120s
```
**What it validates:** SPIRE Server is running and its CA is initialized. The OIDC
Discovery Provider sidecar is serving JWKS on `:8008`. You can verify:
```bash
kubectl port-forward svc/spire-oidc 8008:8008 -n gravitino &
curl http://localhost:8008/.well-known/openid-configuration | jq .
curl http://localhost:8008/keys | jq .
```

#### Phase 2 — Deploy SPIRE Agent
```bash
kubectl apply -f deploy/07-spire-agent.yaml
kubectl rollout status daemonset/spire-agent -n gravitino --timeout=120s
```
**What it validates:** the Agent DaemonSet starts on the node, presents its projected
ServiceAccount token to the Server, and completes node attestation. After this, the
Agent socket at `/run/spire/sockets/agent.sock` is available on the host.

The script also runs a sanity check:
```bash
kubectl exec -n gravitino <agent-pod> -- \
  /opt/spire/bin/spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock
```
A successful X.509 SVID fetch confirms the Agent is fully attested and can issue SVIDs.

#### Phase 3 — Register Workload Entries
```bash
kubectl exec -n gravitino <server-pod> -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID "spiffe://gravitino.demo/spark-oc-writer" \
  -parentID "spiffe://gravitino.demo/spire/agent/k8s_psat/gravitino-demo/<node-uid>" \
  -selector "k8s:ns:gravitino" \
  -selector "k8s:pod-label:spiffe-workload:spark-oc-writer" \
  -ttl 300
# (repeated for each of the 4 identities)
```
**What it validates:** the Server now has a mapping from `{namespace=gravitino,
label=spark-oc-writer}` → `spiffe://gravitino.demo/spark-oc-writer`. Any pod on this
node matching those selectors will receive a JWT-SVID with that SPIFFE ID when it calls
the Agent socket.

#### Phase 4 — Convert HMS Services to ClusterIP
```bash
kubectl patch service hive-metastore -n gravitino \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/type","value":"ClusterIP"},
       {"op":"remove","path":"/spec/ports/0/nodePort"}]'
# (same for hive-metastore-analytics)
```
**What it validates:** OC-HMS and AC-HMS are no longer reachable via external NodePort.
All traffic must flow through the cluster network where NetworkPolicy is enforced. Without
this step, external clients (or pods that route via the node's external IP) would bypass
pod-level NetworkPolicy.

#### Phase 5 — Apply NetworkPolicy
```bash
kubectl apply -f deploy/08-network-policy.yaml
```
**What it validates:** kernel-level ingress rules are now active on the HMS pods
(on CNIs that support NetworkPolicy). Only the designated pods can open TCP connections
to the HMS Thrift ports.

#### Phase 6 — Upgrade Gravitino with OAuth2 + RBAC
```bash
helm upgrade gravitino ./gravitino -n gravitino \
  --reuse-values \
  -f deploy/09-gravitino-values-spire.yaml
```
**What it validates:** Gravitino restarts with `authenticators: oauth`. From this moment:
- Every Gravitino API request that does **not** include a valid JWT-SVID returns HTTP 401
- Valid JWT-SVIDs are checked against RBAC rules
- The `dynamic-config-provider` is active for the Iceberg REST service

The `--reuse-values` flag preserves all existing Helm values (S3 endpoints, HMS URIs,
persistence config) — the SPIRE overlay file only adds/overrides authentication fields.

---

### Step 4: Set Up RBAC

```bash
bash scripts/07-setup-rbac.sh
```

**What this does:**

First, the script authenticates as the admin identity by running a temporary pod:
```bash
kubectl run spire-admin-fetch --image=busybox:1.36 \
  -l "spiffe-workload=gravitino-admin" \
  --overrides='{"spec":{"volumes":[{"name":"jars","hostPath":...},
                                    {"name":"spire-socket","hostPath":...}],
                          "containers":[{"command":["sh","-c",
                            "/jars/spire-agent api fetch jwt -audience gravitino ..."]
                          }]}}'
```
The pod label `spiffe-workload=gravitino-admin` matches the workload entry registered in
Phase 3 above, so SPIRE issues a JWT-SVID with `sub=spiffe://gravitino.demo/admin`. This
token is used as `Authorization: Bearer` for all subsequent Gravitino admin API calls.

Then, for each SPIFFE identity it:
1. Creates a Gravitino user (e.g., `spiffe://gravitino.demo/spark-oc-writer`)
2. Creates a role with specific privileges on specific catalogs
3. Grants the role to the user

**What it validates:** after this script, the RBAC matrix is fully configured. The
outputs show the exact HTTP responses from Gravitino confirming each user, role, and
grant was created. The final summary table shows which operations are ALLOWED vs DENIED
for each identity.

**Why delete-before-create for roles:** Gravitino 1.2.0 does not support updating a
role's securable object list. The script first calls `DELETE /api/metalakes/.../roles/<name>`
(which returns 200 or 404, both acceptable) before `POST` to create, making the script
idempotent.

---

### Step 5: Demo 1 — OC Iceberg Write

```bash
bash scripts/03-iceberg-write-demo.sh
```

**What this does:**

Launches a Kubernetes pod with:
- Label `spiffe-workload=spark-oc-writer`
- An init container that fetches a JWT-SVID from SPIRE
- A main container running PySpark 3.5

The Spark job:
1. **Reads the JWT** from `/run/spire/jwt/token` and decodes it to show the SPIFFE ID,
   issuer, audience, and expiry — confirming the workload identity
2. **Creates an Iceberg table** `oc_iceberg.poc_demo.sensor_readings` via Gravitino's
   Iceberg REST endpoint (:9001), with the JWT-SVID as the Bearer token
3. **Inserts 10 records** of sensor telemetry (sensor ID, location, metric, value,
   timestamp) coalesced into a single Parquet file
4. **Reads back the records** to confirm the write succeeded
5. **Shows Iceberg snapshot history** — confirms a single `append` snapshot was created
6. **Shows the Iceberg data files** — confirms the file is stored at
   `s3a://operational/warehouse/...` (SeaweedFS operational bucket)

**What it validates:**
- SPIRE correctly issues a JWT-SVID to a pod with the right label (workload attestation)
- Gravitino accepts the JWT-SVID as a valid Bearer token (OAuth2 + JWKS validation)
- Gravitino RBAC grants the `spark-oc-writer` identity CREATE_TABLE and MODIFY_TABLE on `oc_iceberg`
- The full Iceberg write path works end-to-end: Spark → Gravitino REST → OC-HMS → SeaweedFS
- S3FileIO correctly routes to SeaweedFS via `AWS_ENDPOINT_URL_S3`

---

### Step 6: Demo 2 — AC Write (ETL)

```bash
bash scripts/04-ac-write-demo.sh
```

**What this does:**

Launches a pod with label `spiffe-workload=spark-ac-writer`. The Spark job:

1. **Authenticates as `spark-ac-writer`** — demonstrates a _different_ SPIFFE identity
   than Demo 1
2. **Reads from `oc_iceberg.poc_demo.sensor_readings`** (READ-ONLY access) using the
   Gravitino Iceberg REST endpoint with its JWT-SVID as Bearer token
3. **Applies an ETL transformation** — adds a `ranking` column (A/B/C) based on the
   sensor value:
   - A: value ≤ 20
   - B: 21–50
   - C: > 50
4. **Writes to `ac_iceberg.poc_demo.sensor_readings_ac`** directly via the Hive Metastore
   Thrift protocol (not through Gravitino REST — the `spark-ac-writer` pod is allowed
   direct AC-HMS access by NetworkPolicy)
5. **Shows the resulting table** with the added ranking column
6. **Shows the Parquet file location** — confirms it is in `s3a://analytical/...`

**What it validates:**
- `spark-ac-writer` can READ from the OC catalog (authorized by `ac_writer_role`)
- `spark-ac-writer` can WRITE to the AC catalog (authorized by `ac_writer_role`)
- NetworkPolicy allows the `spark-ac-writer` pod to reach AC-HMS directly
- The two-tier architecture works: operational data is written through Gravitino REST;
  analytical ETL is written directly to the analytical Hive Metastore
- Data lineage: the ranked records in AC are derived from the raw records in OC

---

### Step 7: Validate Policy Enforcement

```bash
bash scripts/08-validate-policy.sh
```

This script runs six tests that prove the security boundaries hold.

#### Test 1: Unauthenticated request returns 401
```bash
curl http://localhost:8090/api/metalakes
# Expected: HTTP 401 Unauthorized
```
**What it validates:** Gravitino's OAuth2 authenticator is active. A request without any
`Authorization` header is rejected before it reaches any business logic. This confirms
that the `authenticators: oauth` configuration took effect — before this upgrade, the
same call would return HTTP 200.

#### Test 2: `oc_writer` cannot write to the AC catalog → 403
```bash
# Fetch JWT-SVID for spark-oc-writer identity
# Then:
curl -X POST http://localhost:8090/api/metalakes/poc_layer/catalogs/hive_metastore_analytics/schemas/poc_demo/tables \
  -H "Authorization: Bearer <oc_writer_jwt>" \
  -d '{"name":"unauthorized_table",...}'
# Expected: HTTP 403 Forbidden
```
**What it validates:** Gravitino RBAC correctly denies write operations to identities
that only have SELECT_TABLE on the target catalog. The `oc_writer_role` grants
MODIFY_TABLE on `oc_iceberg` but not on `hive_metastore_analytics`. The RBAC evaluation
happens after JWT validation — so the identity is known, but the privilege check fails.

#### Test 3: `ac_writer` cannot write to the OC catalog → 403
```bash
# Fetch JWT-SVID for spark-ac-writer identity
# Then:
curl -X POST http://localhost:8090/api/metalakes/poc_layer/catalogs/oc_iceberg/schemas/poc_demo/tables \
  -H "Authorization: Bearer <ac_writer_jwt>" \
  -d '{"name":"unauthorized_table",...}'
# Expected: HTTP 403 Forbidden
```
**What it validates:** the inverse of Test 2. `ac_writer_role` has SELECT_TABLE on
`oc_iceberg` but not CREATE_TABLE or MODIFY_TABLE. Confirms that least-privilege is
enforced in both directions.

#### Test 4: `oc_writer` can READ the OC catalog → 200
```bash
curl http://localhost:8090/api/metalakes \
  -H "Authorization: Bearer <oc_writer_jwt>"
# Expected: HTTP 200 OK with metalake list
```
**What it validates:** a valid JWT-SVID with an authorized identity is accepted. This
test confirms that Tests 2 and 3 above are failing due to RBAC (insufficient privilege),
not due to JWT validation failures. The identity is recognized and the request is
processed — it's only the specific operation that is denied.

#### Test 5: Direct OC-HMS bypass attempt (NetworkPolicy test) — SKIP on Docker Desktop
```bash
# Pod without Gravitino label tries to connect to OC-HMS:9083 directly
kubectl run test-bypass --image=busybox:1.36 -n gravitino \
  --overrides='{"spec":{"containers":[{"command":["nc","-z","-w3",
    "hive-metastore.gravitino.svc.cluster.local","9083"]}]}}'
# Expected on Calico/Cilium: TCP timeout/refused (NetworkPolicy enforced)
# On Docker Desktop (kindnet): connection succeeds — SKIP
```
**What it validates (on Calico/Cilium):** a pod without the `app.kubernetes.io/name=gravitino`
label cannot establish a TCP connection to OC-HMS port 9083. The NetworkPolicy
`deny-all-to-oc-hms` + `allow-gravitino-to-oc-hms` combination blocks the kernel-level
TCP handshake.

**Docker Desktop note:** `kindnet` does not enforce NetworkPolicy. The test detects this
and marks as SKIP (not FAIL). The policies are valid and will enforce correctly on EKS,
GKE, AKS, or any cluster with Calico/Cilium.

#### Test 6: `spark-ac-writer` can reach AC-HMS directly → TCP open
```bash
# Pod with spiffe-workload=spark-ac-writer tries to connect to AC-HMS:9083
# Expected: TCP connection succeeds
```
**What it validates:** the NetworkPolicy `allow-to-ac-hms` correctly permits pods with
label `spiffe-workload=spark-ac-writer` to reach AC-HMS. This is the authorized direct
write path used by Demo 2. Confirms that NetworkPolicy allows the right identity
through, not just blocks the wrong ones.

---

### Expected Final Output

After all steps complete successfully:

```
Script 03 output confirms:
  ✓ JWT-SVID issued:   sub=spiffe://gravitino.demo/spark-oc-writer
  ✓ Table created:     oc_iceberg.poc_demo.sensor_readings
  ✓ 10 records written
  ✓ Parquet file at:   s3a://operational/warehouse/poc_demo.db/sensor_readings/data/...

Script 04 output confirms:
  ✓ JWT-SVID issued:   sub=spiffe://gravitino.demo/spark-ac-writer
  ✓ 10 records read from OC (authorized)
  ✓ Ranking column added (ETL transformation)
  ✓ 10 records written to:  ac_iceberg.poc_demo.sensor_readings_ac
  ✓ Parquet file at:   s3a://analytical/warehouse/poc_demo.db/sensor_readings_ac/data/...

Script 08 output confirms:
  PASS: 5  |  FAIL: 0  |  SKIP: 1  (NetworkPolicy CNI limitation on Docker Desktop)
```

---

### Cleanup

```bash
bash scripts/05-cleanup.sh
```

Removes all Kubernetes resources in the `gravitino` namespace. Safe to run at any point.

---

### Troubleshooting Reference

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` from Gravitino after script 06 | Expected — auth is now enforced. Scripts 03/04 include JWT-SVIDs. | Run script 07 first, then 03/04 |
| Init container fails: `JWT fetch failed` | SPIRE Agent not running or workload entry not registered | Run `kubectl logs -n gravitino <agent-pod>`, check Phase 3 registration |
| `403 Forbidden` on table operation | RBAC privilege missing | Re-run script 07 to ensure roles have USE_SCHEMA and correct privileges |
| `SdkClientException: Unable to load region` | AWS SDK v2 needs region | Verify `AWS_REGION=us-east-1` in Gravitino env |
| `S3Exception: AWS Access Key Id ... does not exist` | S3FileIO hitting AWS instead of SeaweedFS | Verify `AWS_ENDPOINT_URL_S3` env var in Gravitino deployment |
| `ClassNotFoundException: S3AFileSystem` | Catalog using `s3a://` without Hadoop-AWS JAR | Ensure `oc_iceberg` catalog has `io-impl=org.apache.iceberg.aws.s3.S3FileIO` |
| `Authorization is enabled. Set catalog-config-provider` | `icebergRest.catalogConfigProvider` missing | Verify `09-gravitino-values-spire.yaml` has `catalogConfigProvider: dynamic-config-provider` |
| NetworkPolicy test passes (connection not blocked) | kindnet CNI does not enforce NetworkPolicy | Expected on Docker Desktop — test is marked SKIP |
| SPIRE Agent fails to attest | Parent ID uses node UID (k8s_sat) vs node name (k8s_psat) | Verify workload entry parent ID matches the Agent's actual SPIFFE ID |
