# Manual Verification: Separate Upstream Agent Pod Approach (Nested SPIRE via CSI)

**Date:** 2026-07-18  
**Validated on:** SPIRE 1.14.7, OpenShift 4.18, GCP devcluster  
**Clusters needed:** 2 (Hub + Spoke)

---

## Overview

In nested SPIRE, a "spoke" SPIRE server obtains its CA (Certificate Authority) from a "hub" SPIRE server rather than self-signing. This creates a certificate chain:

```
Hub Root CA  →  Spoke Intermediate CA  →  Workload SVID
```

The **separate upstream-agent pod** approach uses a dedicated SPIRE agent pod on the spoke cluster that connects to the hub SPIRE server. This agent's Workload API socket is then mounted into the spoke's SPIRE server pod via a second CSI driver, allowing the UpstreamAuthority plugin to request an intermediate CA from the hub.

### Architecture

```
┌─── Hub Cluster ──────────────────────────────────┐
│                                                    │
│  SPIRE Server (with x509pop NodeAttestor)         │
│  ├── gRPC Route (passthrough TLS, port 443)       │
│  ├── Registration entry: downstream=true          │
│  └── x509pop CA bundle Secret                     │
│                                                    │
└────────────────────────────────────────────────────┘
           ▲
           │ x509pop attestation via Route
           │
┌─── Spoke Cluster ────────────────────────────────────────────┐
│                                                                │
│  upstream-agent (Deployment, 1 replica)                       │
│  ├── x509pop NodeAttestor (cert+key from Secret)              │
│  ├── k8s WorkloadAttestor (identifies spire-server pod)       │
│  ├── hostPID: true (required for k8s WorkloadAttestor)        │
│  └── Writes socket to hostPath: /run/spire/agent-sockets-     │
│                                 upstream/spire-agent.sock     │
│                   │                                            │
│                   │ (CSI bind mount by upstream CSI driver)    │
│                   ▼                                            │
│  SPIRE Server StatefulSet (spire-server-0)                    │
│  ├── CSI volume: upstream.csi.spiffe.io                       │
│  ├── UpstreamAuthority "spire" plugin reads socket            │
│  ├── Gets SVID from upstream-agent                            │
│  └── Requests intermediate CA from Hub via gRPC Route         │
│                   │                                            │
│  Spoke SPIRE Agents (DaemonSet)                               │
│  └── Attest workloads, issue SVIDs signed by intermediate CA  │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Two OpenShift clusters with `oc` CLI access
- `operator-sdk` installed (v1.39+)
- `openssl` for certificate generation
- The ZTWIM operator source code built and pushed to a registry
- Familiarity with SPIRE concepts (trust domains, attestation, SVIDs)

---

## Critical Design Constraint

**Both clusters MUST share the same trust domain.**

The UpstreamAuthority "spire" plugin uses its own server's trust domain to construct the expected upstream server SPIFFE ID (`spiffe://<trust_domain>/spire/server`). If the trust domains differ, the TLS handshake will fail with "unexpected ID".

This is by design: nested SPIRE creates a hierarchical CA within a single trust domain. For cross-domain scenarios, use SPIRE Federation instead.

---

## Step-by-Step Verification

### Phase 1: Deploy the Operator on Both Clusters

#### What this does

Installs the ZTWIM operator via OLM (Operator Lifecycle Manager) on both clusters. The operator manages SPIRE server, agent, and CSI driver lifecycle.

#### Steps

```bash
# Set variables
export IMG=quay.io/<your-registry>/ztwim-operator:latest
export BUNDLE_IMG=quay.io/<your-registry>/ztwim-operator-bundle:v1.0.0
export CONTAINER_TOOL=podman

# Build and push (only once)
cd zero-trust-workload-identity-manager
make docker-build docker-push IMG=$IMG
make bundle IMG=$IMG
make bundle-build bundle-push BUNDLE_IMG=$BUNDLE_IMG

# Deploy on Hub (Cluster 1)
export KUBECONFIG=<path-to-hub-kubeconfig>
oc new-project zero-trust-workload-identity-manager
operator-sdk run bundle $BUNDLE_IMG --namespace zero-trust-workload-identity-manager --timeout 5m

# Deploy on Spoke (Cluster 2)
export KUBECONFIG=<path-to-spoke-kubeconfig>
oc new-project zero-trust-workload-identity-manager
operator-sdk run bundle $BUNDLE_IMG --namespace zero-trust-workload-identity-manager --timeout 5m
```

---

### Phase 2: Deploy Operands on Both Clusters

#### What this does

Creates the Custom Resources (ZTWIM, SpireServer, SpireAgent, SpiffeCSIDriver, SpireOIDCDiscoveryProvider) that tell the operator what to deploy. Initially, both clusters operate independently with self-signed CAs.

**Important:** Use the SAME trust domain (the Hub's `apps.<hub-domain>`) on BOTH clusters from the start, OR plan to change the spoke's trust domain later (which requires clearing PVC data).

#### Steps (Hub cluster)

```bash
export KUBECONFIG=<path-to-hub-kubeconfig>
export APP_DOMAIN=apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
export CLUSTER_NAME=hub01

oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: $APP_DOMAIN
  clusterName: $CLUSTER_NAME
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  caSubject:
    commonName: $APP_DOMAIN
    country: "US"
    organization: "RH"
  persistence:
    size: "2Gi"
    accessMode: ReadWriteOnce
  datastore:
    databaseType: sqlite3
    connectionString: "/run/spire/data/datastore.sqlite3"
  jwtIssuer: https://oidc-discovery.$APP_DOMAIN
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: "auto"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec: {}
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  jwtIssuer: https://oidc-discovery.$APP_DOMAIN
EOF
```

#### Steps (Spoke cluster)

Same as above but with:

- `CLUSTER_NAME=spoke01`
- `trustDomain` = **Hub's APP_DOMAIN** (the same trust domain as Hub)

#### Verification

```bash
# On each cluster:
oc exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server healthcheck
# Expected: "Server is healthy."

oc exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server agent list
# Expected: Attested agents with k8s_psat attestation type
```

---

### Phase 3: Generate x509pop Certificates

#### What this does

Creates a CA keypair and an agent certificate signed by that CA. The Hub server will trust this CA (via its NodeAttestor config), and the Spoke's upstream agent will present the agent certificate during attestation.

x509pop (X.509 Proof of Possession) is a node attestation method where the agent proves its identity by presenting a pre-provisioned X.509 certificate and proving it holds the corresponding private key.

#### Steps

```bash
mkdir -p /tmp/nested-spire-certs && cd /tmp/nested-spire-certs

# Generate CA (the Hub will trust this)
openssl req -x509 -newkey rsa:2048 -keyout agent-ca.key -out agent-ca.crt \
  -days 365 -nodes -subj "/C=US/O=SPIRE Test/CN=Agent CA"

# Generate agent certificate (the upstream-agent will use this)
openssl req -newkey rsa:2048 -keyout agent.key -out agent.csr \
  -nodes -subj "/C=US/O=SPIRE Test/CN=Downstream Agent"

# Create extensions file with REQUIRED key usage
# CRITICAL: digitalSignature is mandatory — SPIRE 1.14's x509pop attestor
# rejects certificates without it ("certificate not intended for digital signature use")
cat > agent-ext.cnf << 'EOF'
subjectAltName = URI:spiffe://example.org/agent
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth, serverAuth
basicConstraints = critical, CA:FALSE
EOF

# Sign the agent cert with the CA
openssl x509 -req -in agent.csr -CA agent-ca.crt -CAkey agent-ca.key \
  -CAcreateserial -out agent.crt -days 365 -extfile agent-ext.cnf

# Verify the cert has the required key usage
openssl x509 -in agent.crt -noout -text | grep -A2 "Key Usage"
# Expected: "Digital Signature"
```

**What the CN means:** The `CN=Downstream Agent` in the agent certificate is used by the Hub's SPIRE server as a selector (`x509pop:subject:cn:Downstream Agent`) to match registration entries. You can use any CN you want, but it must match the selector in the registration entry.

**Why `keyUsage = digitalSignature` is required:** The x509pop attestor performs a challenge-response protocol where the agent proves possession of the private key by signing a challenge. SPIRE 1.14+ explicitly checks that the certificate permits digital signature operations before issuing the challenge.

---

### Phase 4: Configure the Hub for Nested SPIRE

#### 4a. Create gRPC Passthrough Route

**What this does:** Exposes the Hub SPIRE server's gRPC port (8081) externally via an OpenShift Route with TLS passthrough. The Spoke's upstream agent connects to this Route for attestation, and the UpstreamAuthority plugin connects to it for CA signing requests.

"Passthrough" means the Route does NOT terminate TLS — the raw TCP/TLS connection passes through to the SPIRE server pod, which handles its own mTLS.

```bash
export KUBECONFIG=<path-to-hub-kubeconfig>
HUB_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
GRPC_HOST="spire-server-grpc-zero-trust-workload-identity-manager.apps.${HUB_DOMAIN}"

oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-grpc
  namespace: zero-trust-workload-identity-manager
spec:
  host: ${GRPC_HOST}
  to:
    kind: Service
    name: spire-server
    weight: 100
  port:
    targetPort: grpc
  tls:
    termination: passthrough
    insecureEdgeTerminationPolicy: Redirect
EOF
```

#### 4b. Enable CREATE_ONLY_MODE on Hub

**What this does:** Tells the operator to stop reconciling (updating) existing resources. This lets you manually patch the ConfigMap and StatefulSet without the operator reverting your changes.

```bash
oc patch subscription zero-trust-workload-identity-manager-v1-1-0-sub \
  -n zero-trust-workload-identity-manager \
  --type merge \
  -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'

# Wait for operator pod to restart (~15-20s)
```

#### 4c. Create x509pop CA Bundle Secret

**What this does:** Makes the x509pop CA certificate available to the Hub's SPIRE server pod. The server uses this CA to verify the upstream agent's certificate during attestation.

```bash
oc create secret generic x509pop-ca-bundle \
  -n zero-trust-workload-identity-manager \
  --from-file=ca-bundle.crt=/tmp/nested-spire-certs/agent-ca.crt
```

#### 4d. Add x509pop NodeAttestor to Hub Server Config

**What this does:** Adds a second node attestation method to the Hub's SPIRE server. Alongside k8s_psat (for local agents), it now also accepts x509pop attestation (for the remote upstream agent from the Spoke).

```bash
# Get current config, add x509pop to NodeAttestor array
oc get configmap spire-server -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.server\.conf}' > /tmp/hub-config.json

# Add to the "NodeAttestor" array in plugins:
#   {
#     "x509pop": {
#       "plugin_data": {
#         "ca_bundle_path": "/run/spire/x509pop/ca-bundle.crt"
#       }
#     }
#   }

# Then apply:
oc patch configmap spire-server ... --type merge -p '{"data":{"server.conf":"<new-config>"}}'
```

#### 4e. Mount x509pop Secret in Hub StatefulSet

**What this does:** Adds a volume mount so the SPIRE server container can read the CA bundle at `/run/spire/x509pop/ca-bundle.crt`.

```bash
oc patch statefulset spire-server -n zero-trust-workload-identity-manager --type json -p '[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"x509pop-ca-bundle","secret":{"secretName":"x509pop-ca-bundle"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"x509pop-ca-bundle","mountPath":"/run/spire/x509pop","readOnly":true}}
]'
# StatefulSet will rolling-restart the pod
```

#### Verification

```bash
# Check x509pop plugin loaded:
oc logs spire-server-0 -c spire-server | grep x509pop
# Expected: "Plugin loaded" external=false plugin_name=x509pop plugin_type=NodeAttestor
```

---

### Phase 5: Deploy Upstream Agent on Spoke

#### 5a. Enable CREATE_ONLY_MODE on Spoke

```bash
export KUBECONFIG=<path-to-spoke-kubeconfig>
oc patch subscription zero-trust-workload-identity-manager-v1-1-0-sub \
  -n zero-trust-workload-identity-manager \
  --type merge \
  -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'
```

#### 5b. Create Secrets on Spoke

**What this does:** Provides the upstream agent with:

1. Its x509pop certificate and key (for authenticating to the Hub)
2. The Hub's trust bundle (for verifying the Hub server's TLS certificate during initial connection)

```bash
# x509pop credentials for the upstream agent
oc create secret generic upstream-agent-x509pop \
  -n zero-trust-workload-identity-manager \
  --from-file=agent.crt=/tmp/nested-spire-certs/agent.crt \
  --from-file=agent.key=/tmp/nested-spire-certs/agent.key

# Hub trust bundle (get from Hub's spire-bundle ConfigMap)
export KUBECONFIG=<path-to-hub-kubeconfig>
oc get configmap spire-bundle -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.bundle\.crt}' > /tmp/hub-bundle.crt

export KUBECONFIG=<path-to-spoke-kubeconfig>
oc create secret generic hub-trust-bundle \
  -n zero-trust-workload-identity-manager \
  --from-file=bundle.crt=/tmp/hub-bundle.crt
```

#### 5c. Create Upstream Agent ServiceAccount + SCC + RBAC

**What this does:** Creates a ServiceAccount for the upstream agent, a **separate SCC** with the same privileges as the downstream agent's SCC, and **RBAC permissions** to access the kubelet's pods API (required by the k8s WorkloadAttestor to resolve PIDs to pods).

> **Why a separate SCC instead of patching `spire-agent`?**  
> The operator's SpireAgent controller reconciles the `spire-agent` SCC on every loop and it is **not gated by CREATE_ONLY_MODE** (unlike other resources). The desired state hardcodes `.users` to only `[spire-agent]`, so any additional users added via `oc patch` will be reconciled away within seconds. Creating a separate `spire-agent-upstream` SCC avoids this problem entirely.

> **Why RBAC is needed:**  
> The k8s WorkloadAttestor queries the kubelet at `https://<node>:10250/pods` to resolve a caller's PID to its pod metadata. Without `get` permissions on `nodes/proxy`, the kubelet returns 403 Forbidden and the attestor yields empty selectors (causing "no identity issued").

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-agent-upstream
  namespace: zero-trust-workload-identity-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-agent-upstream
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "nodes/proxy"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-agent-upstream
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spire-agent-upstream
subjects:
- kind: ServiceAccount
  name: spire-agent-upstream
  namespace: zero-trust-workload-identity-manager
---
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: spire-agent-upstream
readOnlyRootFilesystem: true
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: MustRunAs
fsGroup:
  type: MustRunAs
users:
- system:serviceaccount:zero-trust-workload-identity-manager:spire-agent-upstream
volumes:
- configMap
- hostPath
- projected
- secret
- emptyDir
allowHostDirVolumePlugin: true
allowHostIPC: false
allowHostNetwork: false
allowHostPID: true
allowHostPorts: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities: []
defaultAddCapabilities: []
requiredDropCapabilities:
- ALL
groups: []
EOF
```

#### 5d. Create Upstream Agent ConfigMap

**What this does:** Defines the upstream agent's configuration. Key fields:

- `server_address` / `server_port`: Hub's gRPC Route (how the agent reaches the Hub)
- `socket_path`: Where the agent writes its Workload API socket (shared via hostPath → CSI)
- `trust_bundle_path`: Initial trust bundle to verify Hub's server cert during first connection
- `trust_domain`: Must match the Hub (same trust domain)
- `NodeAttestor: x509pop`: Uses the pre-provisioned certificate for attestation
- `WorkloadAttestor: k8s`: Identifies callers by their Kubernetes pod metadata
- `node_name_env: MY_NODE_NAME`: Tells the k8s attestor how to reach the kubelet API

```bash
HUB_GRPC_HOST="spire-server-grpc-zero-trust-workload-identity-manager.apps.<hub-domain>"
HUB_TRUST_DOMAIN="apps.<hub-domain>"

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-agent-upstream
  namespace: zero-trust-workload-identity-manager
data:
  agent.conf: |
    {
      "agent": {
        "data_dir": "/run/spire/data",
        "log_level": "debug",
        "server_address": "${HUB_GRPC_HOST}",
        "server_port": "443",
        "socket_path": "/run/spire/agent-sockets-upstream/spire-agent.sock",
        "trust_bundle_path": "/run/spire/bundle/bundle.crt",
        "trust_domain": "${HUB_TRUST_DOMAIN}"
      },
      "plugins": {
        "NodeAttestor": [{"x509pop": {"plugin_data": {
          "private_key_path": "/run/spire/x509pop/agent.key",
          "certificate_path": "/run/spire/x509pop/agent.crt"
        }}}],
        "KeyManager": [{"disk": {"plugin_data": {"directory": "/run/spire/data"}}}],
        "WorkloadAttestor": [{"k8s": {"plugin_data": {
          "node_name_env": "MY_NODE_NAME",
          "skip_kubelet_verification": true
        }}}]
      }
    }
EOF
```

#### 5e. Create Upstream Agent Deployment

**What this does:** Deploys a single SPIRE agent pod that:

- Uses `hostPID: true` so the k8s WorkloadAttestor can map caller PIDs to pods
- Has `podAffinity` to run on the same node as spire-server-0 (so the hostPath socket is accessible)
- Writes its Workload API socket to a hostPath directory that the upstream CSI driver serves
- Uses `MY_NODE_NAME` env var (from downward API) to locate the kubelet

```bash
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spire-agent-upstream
  namespace: zero-trust-workload-identity-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: spire-agent-upstream
  template:
    metadata:
      labels:
        app.kubernetes.io/name: spire-agent-upstream
    spec:
      serviceAccountName: spire-agent-upstream
      hostPID: true
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/name: spire-server
            topologyKey: kubernetes.io/hostname
      containers:
      - name: spire-agent
        image: ghcr.io/spiffe/spire-agent:1.14.7
        args: ["-config", "/run/spire/config/agent.conf"]
        env:
        - name: MY_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: config
          mountPath: /run/spire/config
          readOnly: true
        - name: x509pop-certs
          mountPath: /run/spire/x509pop
          readOnly: true
        - name: hub-trust-bundle
          mountPath: /run/spire/bundle
          readOnly: true
        - name: agent-sockets-upstream
          mountPath: /run/spire/agent-sockets-upstream
        - name: agent-data
          mountPath: /run/spire/data
      volumes:
      - name: config
        configMap:
          name: spire-agent-upstream
      - name: x509pop-certs
        secret:
          secretName: upstream-agent-x509pop
      - name: hub-trust-bundle
        secret:
          secretName: hub-trust-bundle
      - name: agent-sockets-upstream
        hostPath:
          path: /run/spire/agent-sockets-upstream
          type: DirectoryOrCreate
      - name: agent-data
        emptyDir: {}
EOF
```

#### Verification

```bash
# Check upstream agent attested to Hub:
oc logs -l app.kubernetes.io/name=spire-agent-upstream | grep "Node attestation was successful"
# Expected: "Node attestation was successful" reattestable=true spiffe_id="spiffe://.../spire/agent/x509pop/..."

# On Hub, confirm agent appears:
export KUBECONFIG=<path-to-hub-kubeconfig>
oc exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server agent list | grep x509pop
```

---

### Phase 6: Create Registration Entry for Downstream (on Hub)

**What this does:** Now that the upstream agent has attested to the Hub, we create a registration entry that tells the Hub to issue a **downstream SVID** to any workload connecting through the upstream agent that matches the specified k8s selectors. The `downstream: true` flag grants the SVID holder permission to request intermediate CAs from the Hub.

This step MUST happen after Phase 5 because the entry's `parentID` is the upstream agent's SPIFFE ID, which is only known after attestation.

#### Step 1: Get the Upstream Agent's SPIFFE ID

```bash
export KUBECONFIG=<path-to-hub-kubeconfig>

# Find the x509pop agent and note its SPIFFE ID
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server agent list | grep -A5 x509pop

# The SPIFFE ID will look like:
# spiffe://<trust-domain>/spire/agent/x509pop/<sha1-fingerprint>
```

#### Step 2: Create the Entry

**Option A: Manual CLI (quick testing)**

```bash
AGENT_ID="spiffe://<hub-trust-domain>/spire/agent/x509pop/<sha1-fingerprint>"
HUB_TRUST_DOMAIN="apps.<hub-domain>"

oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID "spiffe://${HUB_TRUST_DOMAIN}/spoke/spire-server" \
    -selector "k8s:ns:zero-trust-workload-identity-manager" \
    -selector "k8s:sa:spire-server" \
    -downstream \
    -x509SVIDTTL 3600
```

**Option B: ClusterStaticEntry CRD (recommended for automation)**

The `ClusterStaticEntry` CRD lets you declare the entry as a Kubernetes resource. The spire-controller-manager reconciles it continuously — if the entry is ever deleted, it gets re-created automatically. This is the recommended approach for production.

```bash
AGENT_ID="spiffe://<hub-trust-domain>/spire/agent/x509pop/<sha1-fingerprint>"
HUB_TRUST_DOMAIN="apps.<hub-domain>"

oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterStaticEntry
metadata:
  name: downstream-spoke-spire-server
spec:
  className: zero-trust-workload-identity-manager-spire
  parentID: "${AGENT_ID}"
  spiffeID: "spiffe://${HUB_TRUST_DOMAIN}/spoke/spire-server"
  selectors:
  - "k8s:ns:zero-trust-workload-identity-manager"
  - "k8s:sa:spire-server"
  downstream: true
  x509SVIDTTL: "1h"
EOF
```

#### Why ClusterStaticEntry and not ClusterSPIFFEID?


|                 | ClusterSPIFFEID                                                            | ClusterStaticEntry                                           |
| --------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------ |
| parentID        | Templated globally from controller-manager config (always k8s_psat agents) | Explicit per-entry — supports any agent type                 |
| Pod matching    | Matches pods on the **local** cluster                                      | No pod matching — static selectors                           |
| Use case        | Workloads on this cluster that need SVIDs                                  | Cross-cluster entries, downstream entries, custom parent IDs |
| downstream flag | Supported                                                                  | Supported                                                    |


`ClusterSPIFFEID` cannot be used here because:

1. Its `parentIDTemplate` is hard-coded to k8s_psat agents (configured in controller-manager config)
2. The target workload (spoke's spire-server) is not a pod on the Hub cluster
3. The parent ID is an x509pop-attested agent, not a k8s_psat agent

#### Selector explanation

- `k8s:ns:zero-trust-workload-identity-manager` — the caller must be in this namespace
- `k8s:sa:spire-server` — the caller must use the `spire-server` ServiceAccount

These selectors are evaluated by the upstream agent's k8s WorkloadAttestor when the spoke's SPIRE server calls the Workload API.

#### Verification

```bash
# Confirm entry was created:
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server entry show -selector "k8s:ns:zero-trust-workload-identity-manager"
# Expected: Entry with Downstream=true, correct parentID and selectors
```

---

### Phase 7: Deploy Upstream CSI Driver on Spoke

#### What this does

Creates a second CSI driver (`upstream.csi.spiffe.io`) that serves the upstream agent's socket directory to any pod that requests it via a CSI ephemeral volume. This is how the spire-server pod gets access to the upstream agent's Workload API socket without needing elevated privileges itself.

The CSI driver:

1. Reads the socket from the hostPath (`/run/spire/agent-sockets-upstream`)
2. Bind-mounts it into requesting pods
3. Runs an init container with `chcon -Rvt container_file_t` to set the correct SELinux context

The `security.openshift.io/csi-ephemeral-volume-profile: restricted` label on the CSIDriver object tells OpenShift that pods using this CSI driver don't need elevated privileges (the CSI driver itself is privileged, but the consumer pods remain restricted).

```bash
export KUBECONFIG=<path-to-spoke-kubeconfig>

oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: upstream.csi.spiffe.io
  labels:
    security.openshift.io/csi-ephemeral-volume-profile: restricted
spec:
  attachRequired: false
  podInfoOnMount: true
  volumeLifecycleModes:
  - Ephemeral
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-spiffe-csi-driver-upstream
  namespace: zero-trust-workload-identity-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: spire-csi-upstream-use-privileged-scc
  namespace: zero-trust-workload-identity-manager
subjects:
- kind: ServiceAccount
  name: spire-spiffe-csi-driver-upstream
  namespace: zero-trust-workload-identity-manager
roleRef:
  kind: ClusterRole
  name: system:openshift:scc:privileged
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-spiffe-csi-driver-upstream
  namespace: zero-trust-workload-identity-manager
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: spire-spiffe-csi-driver-upstream
  template:
    metadata:
      labels:
        app.kubernetes.io/name: spire-spiffe-csi-driver-upstream
    spec:
      serviceAccountName: spire-spiffe-csi-driver-upstream
      initContainers:
      - name: set-context
        image: registry.access.redhat.com/ubi9:latest
        command: [chcon, -Rvt, container_file_t, spire-agent-socket/]
        volumeMounts:
        - name: spire-agent-socket-dir
          mountPath: /spire-agent-socket
        securityContext:
          privileged: true
      containers:
      - name: spiffe-csi-driver
        image: ghcr.io/spiffe/spiffe-csi-driver:0.2.8
        args:
        - "-workload-api-socket-dir"
        - "/spire-agent-socket"
        - "-plugin-name"
        - "upstream.csi.spiffe.io"
        - "-csi-socket-path"
        - "/spiffe-csi/csi.sock"
        env:
        - name: MY_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: spire-agent-socket-dir
          mountPath: /spire-agent-socket
        - name: spiffe-csi-socket-dir
          mountPath: /spiffe-csi
        - name: mountpoint-dir
          mountPath: /var/lib/kubelet/pods
          mountPropagation: Bidirectional
        securityContext:
          privileged: true
      - name: node-driver-registrar
        image: registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0
        args:
        - "-csi-address"
        - "/spiffe-csi/csi.sock"
        - "-kubelet-registration-path"
        - "/var/lib/kubelet/plugins/upstream.csi.spiffe.io/csi.sock"
        - "-health-port"
        - "9810"
        volumeMounts:
        - name: spiffe-csi-socket-dir
          mountPath: /spiffe-csi
        - name: kubelet-plugin-registration-dir
          mountPath: /registration
        securityContext:
          privileged: true
      volumes:
      - name: spire-agent-socket-dir
        hostPath:
          path: /run/spire/agent-sockets-upstream
          type: DirectoryOrCreate
      - name: spiffe-csi-socket-dir
        hostPath:
          path: /var/lib/kubelet/plugins/upstream.csi.spiffe.io
          type: DirectoryOrCreate
      - name: mountpoint-dir
        hostPath:
          path: /var/lib/kubelet/pods
          type: Directory
      - name: kubelet-plugin-registration-dir
        hostPath:
          path: /var/lib/kubelet/plugins_registry
          type: Directory
EOF
```

#### Verification

```bash
oc get pods -l app.kubernetes.io/name=spire-spiffe-csi-driver-upstream
# Expected: All pods 2/2 Running
```

---

### Phase 8: Patch Spoke SPIRE Server for UpstreamAuthority

#### 7a. Patch ConfigMap with UpstreamAuthority Plugin

**What this does:** Adds the `UpstreamAuthority "spire"` plugin to the spoke's SPIRE server configuration. This plugin:

1. Connects to the upstream agent's Workload API socket to get an SVID
2. Uses that SVID to authenticate to the Hub SPIRE server
3. Requests an intermediate CA from the Hub's MintX509CA API

```bash
# Add to the "plugins" section of server.conf:
#   "UpstreamAuthority": [{
#     "spire": {
#       "plugin_data": {
#         "server_address": "<hub-grpc-route-host>",
#         "server_port": "443",
#         "workload_api_socket": "/run/spire/upstream-agent/spire-agent.sock"
#       }
#     }
#   }]

# Apply via:
oc patch configmap spire-server -n zero-trust-workload-identity-manager \
  --type merge -p '{"data":{"server.conf":"<full-updated-config>"}}'
```

#### 7b. Mount CSI Volume in StatefulSet

**What this does:** Adds a CSI ephemeral volume to the spire-server StatefulSet. This volume is served by the `upstream.csi.spiffe.io` CSI driver and makes the upstream agent's Workload API socket available at `/run/spire/upstream-agent/spire-agent.sock` inside the spire-server container.

```bash
oc patch statefulset spire-server -n zero-trust-workload-identity-manager --type json -p '[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{
    "name":"upstream-agent-socket",
    "csi":{"driver":"upstream.csi.spiffe.io","readOnly":true}
  }},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{
    "name":"upstream-agent-socket",
    "mountPath":"/run/spire/upstream-agent",
    "readOnly":true
  }}
]'
```

#### 8c. Clear Old Data (required when adding UpstreamAuthority to existing server)

**What this does:** The PVC contains the server's existing self-signed CA in its journal. SPIRE only mints a new CA (via UpstreamAuthority) when the current one expires or no CA exists. Since the existing CA is still valid (24h TTL), the server will continue using the self-signed CA and ignore the UpstreamAuthority plugin until rotation time.

Clearing the PVC forces the server to start with no data, which triggers immediate CA minting via the UpstreamAuthority — giving you the intermediate CA from the Hub right away.

**How to tell if this step is needed:** Check the server logs. If you see `upstream_authority_id=` (empty), the server is using its old self-signed CA and this step is required.

```bash
# Scale down, delete PVC, scale up
oc scale statefulset spire-server --replicas=0
oc delete pvc spire-data-spire-server-0 -n zero-trust-workload-identity-manager
# Wait for PVC to terminate
oc scale statefulset spire-server --replicas=1
```

#### Verification

```bash
# Check server started with upstream CA:
oc logs spire-server-0 -c spire-server | grep "X509 CA"
# Expected: "X509 CA activated" ... self_signed=false ... upstream_authority_id=<non-empty>

oc exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server healthcheck
# Expected: "Server is healthy."
```

---

### Phase 9: Verify the Full Certificate Chain

#### What this does

Mints a test SVID on the spoke and examines its certificate chain. A correct nested SPIRE setup produces a 3-certificate chain:

1. **Root CA** (from Hub) — self-signed, trust anchor
2. **Intermediate CA** (Spoke's CA, signed by Hub) — has `OU=DOWNSTREAM-1`
3. **Workload SVID** (leaf, signed by Spoke's intermediate CA) — has the workload's SPIFFE ID

```bash
export KUBECONFIG=<path-to-spoke-kubeconfig>
TRUST_DOMAIN="apps.<hub-domain>"

# Mint a test SVID and save to a file
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server x509 mint \
  -spiffeID "spiffe://${TRUST_DOMAIN}/test-verify" > /tmp/minted-svid.txt

# Extract all certificates from the output into a PEM file
grep -A100 "BEGIN CERTIFICATE" /tmp/minted-svid.txt | \
  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > /tmp/svid-chain.pem

# Show each certificate in the chain
echo "=== Certificate Chain ==="
csplit -z -f /tmp/cert- /tmp/svid-chain.pem '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null
for cert in /tmp/cert-*; do
  [ -s "$cert" ] || continue
  echo ""
  echo "--- $(basename $cert) ---"
  openssl x509 -in "$cert" -noout -subject -issuer -ext subjectAltName
done

# Verify the chain: extract leaf and CA certs separately
# Leaf = first cert, CAs = everything else
awk '/-----BEGIN CERTIFICATE-----/{n++} n==1' /tmp/svid-chain.pem > /tmp/leaf.pem
awk '/-----BEGIN CERTIFICATE-----/{n++} n>1' /tmp/svid-chain.pem > /tmp/ca-chain.pem

echo ""
echo "=== Chain Verification ==="
openssl verify -CAfile /tmp/ca-chain.pem /tmp/leaf.pem
# Expected: /tmp/leaf.pem: OK

# Cleanup temp files
rm -f /tmp/cert-* /tmp/leaf.pem /tmp/ca-chain.pem /tmp/svid-chain.pem /tmp/minted-svid.txt
```

Expected output:
```
=== Certificate Chain ===

--- cert-00 ---
subject=C=US, O=SPIRE
issuer=C=US, O=RH, OU=DOWNSTREAM-1, CN=<trust-domain>, serialNumber=...
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>/test-verify

--- cert-01 ---
subject=C=US, O=RH, OU=DOWNSTREAM-1, CN=<trust-domain>, serialNumber=...
issuer=C=US, O=RH, CN=<trust-domain>, serialNumber=...
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>

--- cert-02 ---
subject=C=US, O=RH, CN=<trust-domain>, serialNumber=...
issuer=C=US, O=RH, CN=<trust-domain>, serialNumber=...
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>

=== Chain Verification ===
/tmp/leaf.pem: OK
```

The chain shows: **Hub Root CA** (self-signed) → **Spoke Intermediate CA** (`OU=DOWNSTREAM-1`, signed by Hub) → **Workload SVID** (leaf, signed by Spoke intermediate).

---

### Phase 10: Verify with a Live Demo Workload (spiffe-helper)

#### What this does

Deploys an actual workload pod that uses the standard SPIFFE CSI driver (`csi.spiffe.io`) to obtain an SVID from the spoke's SPIRE agent. This proves the full end-to-end flow:

1. Workload pod starts → CSI driver mounts the agent socket into the pod
2. spiffe-helper inside the pod calls the agent's Workload API
3. Agent checks with the spoke SPIRE server for a matching registration entry
4. Spoke server issues an SVID signed by the **intermediate CA** (which was obtained from the Hub)
5. We inspect the certificate chain to confirm: Hub Root → Spoke Intermediate → Workload SVID

This is the definitive proof that the nested SPIRE setup works for real workloads, not just server-side CLI commands.

#### Step 1: Create a Demo Namespace and ClusterSPIFFEID

The `ClusterSPIFFEID` tells the SPIRE controller-manager to automatically create registration entries for pods matching the selector. Without this, the agent will refuse to issue SVIDs ("no identity issued").

```bash
export KUBECONFIG=<path-to-spoke-kubeconfig>
TRUST_DOMAIN="apps.<hub-domain>"

oc create namespace spiffe-demo

oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: spiffe-demo
spec:
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: "spiffe://${TRUST_DOMAIN}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: spiffe-demo
  podSelector:
    matchLabels:
      app: spiffe-demo
EOF
```

#### Step 2: Deploy a Workload with spiffe-helper

The [spiffe-helper](https://github.com/spiffe/spiffe-helper) is a sidecar/init utility that watches the SPIRE Workload API for SVID updates and writes the certificates to disk. This simulates a real application consuming SPIFFE identities.

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: demo-workload
  namespace: spiffe-demo
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: spiffe-helper-config
  namespace: spiffe-demo
data:
  helper.conf: |
    agent_address = "/spiffe-workload-api/spire-agent.sock"
    cmd = ""
    cert_dir = "/certs"
    svid_file_name = "svid.pem"
    svid_key_file_name = "svid_key.pem"
    svid_bundle_file_name = "bundle.pem"
    renew_signal = ""
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spiffe-demo
  namespace: spiffe-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: spiffe-demo
  template:
    metadata:
      labels:
        app: spiffe-demo
    spec:
      serviceAccountName: demo-workload
      containers:
      - name: workload
        image: ghcr.io/spiffe/spiffe-helper:0.8.0
        args: ["-config", "/opt/spiffe-helper/helper.conf"]
        volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
        - name: helper-config
          mountPath: /opt/spiffe-helper
          readOnly: true
        - name: certs
          mountPath: /certs
      volumes:
      - name: spiffe-workload-api
        csi:
          driver: csi.spiffe.io
          readOnly: true
      - name: helper-config
        configMap:
          name: spiffe-helper-config
      - name: certs
        emptyDir: {}
EOF
```

#### Step 3: Deploy a Debug Pod to Inspect the Chain

The spiffe-helper image is minimal (no `cat`, `openssl`, or `tar`). Deploy a debug pod with the same CSI volume and standard tools to call the Workload API and inspect the certificates.

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: spiffe-chain-verify
  namespace: spiffe-demo
  labels:
    app: spiffe-demo
spec:
  serviceAccountName: demo-workload
  containers:
  - name: debug
    image: registry.access.redhat.com/ubi9:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: spiffe-workload-api
      mountPath: /spiffe-workload-api
      readOnly: true
  volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io
      readOnly: true
EOF
```

#### Step 4: Fetch and Verify the SVID Chain

From inside the debug pod, download the `spire-agent` binary and use it to call the Workload API. Then verify the certificate chain with `openssl`.

```bash
oc exec -n spiffe-demo spiffe-chain-verify -- bash -c '
  # Download spire-agent binary
  cd /tmp
  curl -sLO https://github.com/spiffe/spire/releases/download/v1.14.7/spire-1.14.7-linux-amd64-musl.tar.gz
  tar xzf spire-1.14.7-linux-amd64-musl.tar.gz

  # Fetch SVID via the Workload API socket (mounted by CSI driver)
  mkdir -p /tmp/fetched-certs
  ./spire-1.14.7/bin/spire-agent api fetch x509 \
    -socketPath /spiffe-workload-api/spire-agent.sock \
    -write /tmp/fetched-certs/
'
```

Expected output:

```
Received 1 svid after <N>ms

SPIFFE ID:              spiffe://<trust-domain>/ns/spiffe-demo/sa/demo-workload
SVID Valid After:       2026-07-19 04:53:28 +0000 UTC
SVID Valid Until:       2026-07-19 05:53:38 +0000 UTC
Intermediate #1 Valid After:    2026-07-18 12:12:36 +0000 UTC
Intermediate #1 Valid Until:    2026-07-19 11:48:55 +0000 UTC
CA #1 Valid After:      2026-07-18 11:48:45 +0000 UTC
CA #1 Valid Until:      2026-07-19 11:48:55 +0000 UTC
```

The key indicator: **"Intermediate #1"** — this is the Spoke's CA signed by the Hub.

#### Step 5: Verify the Certificate Chain with OpenSSL

```bash
oc exec -n spiffe-demo spiffe-chain-verify -- bash -c '
  # Extract the leaf certificate (first cert in svid.0.pem)
  awk "/BEGIN CERTIFICATE/{n++} n==1" /tmp/fetched-certs/svid.0.pem > /tmp/leaf.pem
  
  # Extract intermediate certificates (everything after the first cert)
  awk "/BEGIN CERTIFICATE/{n++} n>1" /tmp/fetched-certs/svid.0.pem > /tmp/intermediates.pem
  
  echo "=== Workload SVID (leaf) ==="
  openssl x509 -in /tmp/leaf.pem -noout -subject -issuer -ext subjectAltName
  
  echo ""
  echo "=== Intermediate CA (Spoke, signed by Hub) ==="
  openssl x509 -in /tmp/intermediates.pem -noout -subject -issuer -ext subjectAltName
  
  echo ""
  echo "=== Root CA (Hub, in trust bundle) ==="
  openssl x509 -in /tmp/fetched-certs/bundle.0.pem -noout -subject -issuer

  echo ""
  echo "=== Chain Verification ==="
  openssl verify \
    -CAfile /tmp/fetched-certs/bundle.0.pem \
    -untrusted /tmp/intermediates.pem \
    /tmp/leaf.pem
'
```

Expected output:

```
=== Workload SVID (leaf) ===
subject=C=US, O=SPIRE
issuer=C=US, O=RH, OU=DOWNSTREAM-1, CN=<trust-domain>, serialNumber=...
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>/ns/spiffe-demo/sa/demo-workload

=== Intermediate CA (Spoke, signed by Hub) ===
subject=C=US, O=RH, OU=DOWNSTREAM-1, CN=<trust-domain>, serialNumber=...
issuer=C=US, O=RH, CN=<trust-domain>, serialNumber=...
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>

=== Root CA (Hub, in trust bundle) ===
subject=C=US, O=RH, CN=<trust-domain>, serialNumber=...
issuer=C=US, O=RH, CN=<trust-domain>, serialNumber=...

=== Chain Verification ===
/tmp/leaf.pem: OK
```

`**/tmp/leaf.pem: OK**` confirms the full chain is cryptographically valid:

```
Hub Root CA  ──signs──►  Spoke Intermediate CA (OU=DOWNSTREAM-1)  ──signs──►  Workload SVID
                                                                              spiffe://.../ns/spiffe-demo/sa/demo-workload
```

#### Step 6: Confirm spiffe-helper is Receiving Live Updates

```bash
oc logs -n spiffe-demo -l app=spiffe-demo,pod-template-hash --tail=10
```

Expected output:

```
time="..." level=info msg="Received update" spiffe_id="spiffe://<trust-domain>/ns/spiffe-demo/sa/demo-workload"
time="..." level=info msg="X.509 certificates updated"
```

This confirms the workload is receiving automatic SVID rotations from the agent, exactly as a production workload would.

#### Cleanup

```bash
oc delete namespace spiffe-demo
oc delete clusterspiffeid spiffe-demo
```

---

## Troubleshooting


| Symptom                                                         | Likely Cause                                                     | Fix                                                                                                           |
| --------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| x509pop: "certificate not intended for digital signature use"   | Agent certificate missing `keyUsage: digitalSignature` extension | Regenerate cert with `keyUsage = critical, digitalSignature` in extensions file                               |
| Upstream agent: 403 Forbidden on kubelet pods API               | Missing RBAC for upstream agent ServiceAccount                   | Create ClusterRole+ClusterRoleBinding granting `get` on `pods`, `nodes`, `nodes/proxy`                        |
| Upstream agent: "connection refused" to kubelet                 | Missing `node_name_env` in k8s WorkloadAttestor config           | Add `"node_name_env": "MY_NODE_NAME"` and `MY_NODE_NAME` env var                                              |
| CSI driver: "node ID is required"                               | Missing `MY_NODE_NAME` env var on CSI driver container           | Add downward API env var to DaemonSet                                                                         |
| Pod Security Admission blocks CSI volume                        | Missing profile label on CSIDriver object                        | Add `security.openshift.io/csi-ephemeral-volume-profile: restricted` label                                    |
| "no identity issued" from upstream agent                        | No matching registration entry on Hub                            | Create entry with correct parentID (agent's SPIFFE ID) and k8s selectors                                      |
| "unexpected ID" during TLS handshake                            | Trust domains don't match between Hub and Spoke                  | Both MUST use the same trust domain                                                                           |
| "Agent SVID is not active" loop                                 | Stale agent record on Hub                                        | Evict the agent (`spire-server agent evict`), restart upstream agent pod                                      |
| Server crashes with "CSR URI SAN is invalid"                    | Controller-manager using old trust domain                        | Update `controller-manager-config.yaml` ConfigMap                                                             |
| Agent can't attest (bundle not found)                           | spire-bundle ConfigMap has wrong/empty data                      | Patch with Hub's trust bundle or restart agents after server populates it                                     |
| Upstream agent pod stuck in `CreateContainerError` / SCC denied | Patched `spire-agent` SCC but operator reconciled it back        | Create a separate `spire-agent-upstream` SCC (operator's SCC reconciliation is not gated by CREATE_ONLY_MODE) |


---

## SCC Summary


| Component                | SCC                                                                  | Why                                                                                                                                                                                                                      |
| ------------------------ | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| upstream-agent pod       | `spire-agent-upstream` (new, identical permissions to `spire-agent`) | Needs `hostPID` + `hostPath`. Cannot reuse `spire-agent` SCC because the operator reconciles its `.users` list and will remove any manually-added ServiceAccounts (SCC reconciliation is not gated by CREATE_ONLY_MODE). |
| upstream CSI driver      | `privileged` (existing)                                              | Needs bind mounts + bidirectional mount propagation                                                                                                                                                                      |
| spire-server StatefulSet | `restricted` (unchanged)                                             | CSI volume doesn't require elevated privileges                                                                                                                                                                           |


> **Note for operator-level implementation:** When this approach is implemented in the operator itself (not manual PoC), the operator should either extend the existing `spire-agent` SCC's `.users` list to include the upstream agent SA, or create a dedicated SCC as part of the upstream-agent controller's reconcile loop.

---

## Key Differences from Sidecar Approach


| Aspect                | Sidecar                        | Separate Pod                            |
| --------------------- | ------------------------------ | --------------------------------------- |
| WorkloadAttestor      | `unix` (matches UID)           | `k8s` (matches namespace + SA + labels) |
| Socket delivery       | Shared emptyDir volume         | CSI ephemeral volume                    |
| shareProcessNamespace | Required (for unix attestor)   | Not needed                              |
| Robustness            | UID changes across deployments | k8s selectors are stable                |
| Additional components | None                           | Second CSI driver DaemonSet             |
| Pod affinity          | N/A (same pod)                 | Required (same node as server)          |


