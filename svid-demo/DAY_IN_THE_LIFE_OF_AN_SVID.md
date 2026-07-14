# A Day in the Life of an SVID - Live Demo Walkthrough

> This document traces the complete lifecycle of how SPIRE issues an identity (SVID) to a workload,
> demonstrated on a live OpenShift 4.20 cluster running the Zero Trust Workload Identity Manager (ZTWIM) operator.

---

## Cluster Overview

| Property | Value |
|---|---|
| **Platform** | OpenShift 4.20 on GCP |
| **Kubernetes Version** | v1.33.6 |
| **Trust Domain** | `apps.gcp25mar.gcp.devcluster.openshift.com` |
| **SPIRE Version** | 1.13.3 |
| **Operator Namespace** | `zero-trust-workload-identity-manager` |

### Nodes

| Node | Role | IP |
|---|---|---|
| `gcp25mar-sbkbw-master-0` | control-plane | 10.0.0.6 |
| `gcp25mar-sbkbw-master-1` | control-plane | 10.0.0.5 |
| `gcp25mar-sbkbw-master-2` | control-plane | 10.0.0.3 |
| `gcp25mar-sbkbw-worker-a-wcgg4` | worker | 10.0.128.2 |
| `gcp25mar-sbkbw-worker-b-56pzx` | worker | 10.0.128.4 |
| `gcp25mar-sbkbw-worker-c-rfwsj` | worker | 10.0.128.3 |

### SPIRE Components Deployed

| Component | Kind | Purpose |
|---|---|---|
| `spire-server-0` | StatefulSet (2 containers) | Central SPIRE Server + SPIRE Controller Manager sidecar |
| `spire-agent-*` | DaemonSet (3 pods) | One agent per worker node — handles workload attestation |
| `spire-spiffe-csi-driver-*` | DaemonSet (3 pods) | CSI driver to inject Workload API socket into pods |
| `spire-spiffe-oidc-discovery-provider` | Deployment | Serves OIDC discovery endpoint for JWT-SVIDs |
| `controller-manager` | Deployment | The ZTWIM operator itself |

---

## PHASE 1: The SPIRE Server Starts Up (Steps 1–4)

### Step 1 — Self-Signed Certificate Generation

When `spire-server-0` starts, the first thing it does is generate a **self-signed X.509 CA certificate**.
Since no `UpstreamAuthority` plugin is configured, the SPIRE Server acts as its own root Certificate Authority.
It generates an RSA-2048 key pair and signs its own certificate with it.

**Server logs:**

```
time="2026-03-25T18:34:56Z" level=info msg="X509 CA prepared"
    expiration="2026-03-26 18:34:56 +0000 UTC"
    self_signed=true
    slot=A

time="2026-03-25T18:34:56Z" level=info msg="X509 CA activated"
    expiration="2026-03-26 18:34:56 +0000 UTC"
    slot=A
```

**Decoded CA certificate** (from the `spire-bundle` ConfigMap):

```
Issuer:  C=US, O=RH, CN=apps.gcp25mar.gcp.devcluster.openshift.com
Subject: C=US, O=RH, CN=apps.gcp25mar.gcp.devcluster.openshift.com   ← SAME! Self-signed.

Validity:
    Not Before: Mar 25 18:34:46 2026 GMT
    Not After : Mar 26 18:34:56 2026 GMT          ← 24-hour TTL (ca_ttl: "24h0m0s")

X509v3 Key Usage: Certificate Sign, CRL Sign      ← It's a CA certificate
X509v3 Basic Constraints: CA:TRUE
X509v3 Subject Alternative Name:
    URI:spiffe://apps.gcp25mar.gcp.devcluster.openshift.com   ← The trust domain URI
```

**Key insight:** `Issuer == Subject` means the server signed this cert with its own private key.
The SAN contains the trust domain URI. Every entity in this SPIRE deployment trusts this root.

**Where is the config that controls this?** The `spire-server` ConfigMap (`server.conf`):

```json
"server": {
    "ca_key_type": "rsa-2048",
    "ca_ttl": "24h0m0s",
    "ca_subject": [{
        "common_name": "apps.gcp25mar.gcp.devcluster.openshift.com",
        "country": ["US"],
        "organization": ["RH"]
    }],
    "trust_domain": "apps.gcp25mar.gcp.devcluster.openshift.com"
}
```

### Step 2 — Trust Bundle Stored in Datastore

The server uses a **SQLite** database as its datastore:

```json
"DataStore": [{
    "sql": {
        "plugin_data": {
            "database_type": "sqlite3",
            "connection_string": "/run/spire/data/datastore.sqlite3"
        }
    }
}]
```

**Server logs:**

```
Opening SQL database  db_type=sqlite3
Initializing new database              ← First startup, brand new DB
Connected to SQL database  type=sqlite3 version=3.50.4
```

The trust bundle (containing the root CA cert and JWT public keys) is stored in the SQLite database.
It is also published to a **Kubernetes ConfigMap** called `spire-bundle` via the `k8sbundle` notifier plugin,
so that agents can bootstrap from it:

```json
"Notifier": [{
    "k8sbundle": {
        "plugin_data": {
            "config_map": "spire-bundle",
            "namespace": "zero-trust-workload-identity-manager"
        }
    }
}]
```

**To inspect it yourself:**

```bash
kubectl get configmap spire-bundle -n zero-trust-workload-identity-manager -o yaml
# Decode the certificate:
kubectl get configmap spire-bundle -n zero-trust-workload-identity-manager \
    -o jsonpath='{.data.bundle\.crt}' | openssl x509 -text -noout
```

### Step 3 — JWT Signing Key Prepared

Alongside the X.509 CA, the server also prepares a **JWT signing key** for issuing JWT-SVIDs:

```
JWT key prepared   local_authority_id=qGlEUlIAeMjh8fkRVlTY3AEVgKGJxygO
JWT key activated  local_authority_id=qGlEUlIAeMjh8fkRVlTY3AEVgKGJxygO
```

The trust bundle in SPIFFE format contains both keys:

```json
{
    "keys": [
        { "use": "x509-svid", "kty": "RSA", ... },
        { "use": "jwt-svid",  "kty": "RSA", "kid": "qGlEUlIAeMjh8fkRVlTY3AEVgKGJxygO", ... }
    ],
    "spiffe_sequence": 1
}
```

**To inspect:**

```bash
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 \
    -c spire-server -- /spire-server bundle show -format spiffe
```

### Step 4 — Registration API Turned On

The server starts listening on two API endpoints:

```
Starting Server APIs  address="[::]:8081"                              network=tcp    ← gRPC for agents
Starting Server APIs  address=/tmp/spire-server/private/api.sock       network=unix   ← For controller manager
Serving health checks  address="0.0.0.0:8080"
```

- The **TCP endpoint** (port 8081) is where SPIRE Agents connect over mTLS.
- The **Unix socket** (`api.sock`) is how the SPIRE Controller Manager sidecar (in the same pod) talks to the server to create/update registration entries.
- Health checks are exposed on port 8080 (`/live` and `/ready`).

**To verify the server is healthy:**

```bash
kubectl get pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-server
```

---

## PHASE 2: SPIRE Agent Starts Up & Node Attestation (Steps 5–12)

### Step 5 — Agent Starts on Each Worker Node

The SPIRE Agent runs as a **DaemonSet** with `hostNetwork: true` and `hostPID: true` (privileged).
One agent runs on each worker node:

| Agent Pod | Node | Node IP |
|---|---|---|
| `spire-agent-rdb68` | `gcp25mar-sbkbw-worker-a-wcgg4` | 10.0.128.2 |
| `spire-agent-gsmlk` | `gcp25mar-sbkbw-worker-b-56pzx` | 10.0.128.4 |
| `spire-agent-cfb9b` | `gcp25mar-sbkbw-worker-c-rfwsj` | 10.0.128.3 |

**Agent logs (worker-a):**

```
Starting agent  data_dir=/var/lib/spire  version=1.13.3-dev-unk
Plugin loaded  plugin_name=memory    plugin_type=KeyManager
Plugin loaded  plugin_name=k8s_psat  plugin_type=NodeAttestor
Plugin loaded  plugin_name=k8s       plugin_type=WorkloadAttestor
```

Three plugins are loaded:
- **KeyManager (memory):** Stores the agent's private keys in memory
- **NodeAttestor (k8s_psat):** Used to prove the agent's node identity to the server
- **WorkloadAttestor (k8s):** Used later to discover workload identity via kubelet

### Step 6 — Node Attestation via k8s_psat

The agent performs **node attestation** to prove its identity to the server. In Kubernetes, this uses
**Projected Service Account Tokens (PSAT)**.

**What is a PSAT?** It's a short-lived, audience-bound JWT token that Kubernetes automatically projects
into the pod. The agent's DaemonSet mounts one:

```yaml
volumes:
- name: spire-token
  projected:
    sources:
    - serviceAccountToken:
        audience: spire-server        # Bound to this specific audience
        expirationSeconds: 7200       # 2-hour lifetime
        path: spire-agent
```

**Agent config** (`agent.conf`):

```json
"NodeAttestor": [{
    "k8s_psat": {
        "plugin_data": {
            "cluster": "test01"        ← Must match server config
        }
    }
}]
```

### Step 7 — TLS Connection with Bootstrap Bundle

The agent connects to the server using TLS, authenticating the server with the **bootstrap bundle**:

```json
"agent": {
    "server_address": "spire-server.zero-trust-workload-identity-manager",
    "server_port": "443",
    "trust_bundle_path": "/run/spire/bundle/bundle.crt",
    "trust_domain": "apps.gcp25mar.gcp.devcluster.openshift.com"
}
```

The `trust_bundle_path` points to the `spire-bundle` ConfigMap (mounted as a volume), which contains
the self-signed CA certificate from Step 1. This is how the agent knows it's talking to the real server.

**Agent logs:**

```
Bundle loaded  trust_domain_id="spiffe://apps.gcp25mar.gcp.devcluster.openshift.com"
SVID is not found. Starting node attestation
```

### Steps 8–9 — Server Validates the PSAT Token

On the server side, the `k8s_psat` node attestor validates the token:

**Server config** (`server.conf`):

```json
"NodeAttestor": [{
    "k8s_psat": {
        "plugin_data": {
            "clusters": [{
                "test01": {
                    "audience": ["spire-server"],
                    "service_account_allow_list": [
                        "zero-trust-workload-identity-manager:spire-agent"
                    ]
                }
            }]
        }
    }
}]
```

The server:
1. Receives the projected service account token from the agent
2. Calls the Kubernetes `TokenReview` API to validate it for cluster `test01`
3. Checks the audience is `spire-server`
4. Verifies the service account (`zero-trust-workload-identity-manager:spire-agent`) is in the allowlist

> **Note:** In the original "day in the life" doc, this step describes AWS IID validation. On Kubernetes/OpenShift,
> the equivalent is `k8s_psat` token validation via the Kubernetes API. The principle is the same:
> the server calls a platform API to verify the agent's proof of identity.

### Step 10 — Server Issues Agent SVID

After validation, the server assigns the agent a SPIFFE ID and issues it an SVID.

**Server logs:**

```
Agent attestation request completed
    agent_id="spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/spire/agent/k8s_psat/test01/ca52e226-e882-4d34-aed3-d94227affabc"
    node_attestor_type=k8s_psat
```

The SPIFFE ID format is defined by the `parentIDTemplate` in the controller-manager config:

```yaml
parentIDTemplate: spiffe://{{ .TrustDomain }}/spire/agent/k8s_psat/{{ .ClusterName }}/{{ .NodeMeta.UID }}
```

All 3 attested agents:

```
spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/spire/agent/k8s_psat/test01/d6465b60-2dfe-4b95-b034-4a4d4a6aafdf
    Attestation type: k8s_psat  |  Can re-attest: true

spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/spire/agent/k8s_psat/test01/9dfc70c9-7c7c-458c-97a8-c2c6b1327021
    Attestation type: k8s_psat  |  Can re-attest: true

spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/spire/agent/k8s_psat/test01/ca52e226-e882-4d34-aed3-d94227affabc
    Attestation type: k8s_psat  |  Can re-attest: true
```

**To inspect yourself:**

```bash
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 \
    -c spire-server -- /spire-server agent list
```

### Steps 11–12 — Agent Gets Registration Entries and Caches SVIDs

Using its newly minted SVID as a TLS client certificate, the agent contacts the server to fetch
authorized registration entries. The server authenticates the agent's SVID, completing mTLS.

The agent then pre-creates SVIDs for workloads already running on its node:

```
Creating X509-SVID  entry_id=test01.a0af6d4f-36f2-4b98-8823-f6560c58b362
    spiffe_id="spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/ns/zero-trust-workload-identity-manager/sa/spire-spiffe-oidc-discovery-provider"
```

The agent also handles **periodic re-attestation** as SVIDs expire:

```
Successfully reattested node
    spiffe_id="spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/spire/agent/k8s_psat/test01/ca52e226-..."

Renewing X509-SVID  entry_id=test01.a0af6d4f-...
    expires_at="2026-03-25T19:35:29Z"
    spiffe_id=".../sa/spire-spiffe-oidc-discovery-provider"
```

---

## PHASE 3: Agent Fully Bootstrapped — Workload API Ready (Steps 13–16)

```
Starting Workload and SDS APIs  address=/tmp/spire-agent/public/spire-agent.sock  network=unix
Serving health checks  address="0.0.0.0:9982"
```

The agent is now listening on a **Unix domain socket** — this is the **SPIFFE Workload API** endpoint.

The **SPIFFE CSI Driver** (`csi.spiffe.io`) makes this socket available to any pod that requests it
via a CSI ephemeral volume. On each node, the CSI driver maps the agent's socket directory
(`/run/spire/agent-sockets` on the host) into requesting pods.

**To verify agents are healthy:**

```bash
kubectl get pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent -o wide
```

---

## Deep Dive: The SPIFFE CSI Driver — The Bridge Between Agent and Workload

### The Problem It Solves

The SPIRE Agent exposes the **Workload API** on a Unix domain socket on each node:

```
/run/spire/agent-sockets/spire-agent.sock   (on the host)
```

But workload pods run in their own mount namespace — they can't see host paths by default.
The question is: **how does the agent's socket get inside the workload pod?**

That's exactly what the **SPIFFE CSI Driver** does. It's the bridge that connects workload pods
to the SPIRE Agent's Workload API socket, without requiring `hostPath` mounts (which would need
elevated privileges in the pod's security policy).

### When It Comes Into the Picture

The CSI driver comes into play **twice**:

1. **At cluster setup time** — The ZTWIM operator deploys it as a DaemonSet (one per worker node),
   and registers it with the kubelet as a CSI plugin.
2. **At pod creation time** — When a pod requests a CSI ephemeral volume with `driver: csi.spiffe.io`,
   the kubelet calls the CSI driver to "publish" the volume into the pod.

### How It's Deployed

The CSI driver runs as a **DaemonSet** with **3 containers**:

| Container | Image | Role |
|---|---|---|
| `set-context` (init) | `ubi9` | Runs `chcon` to set the SELinux context (`container_file_t`) on the agent socket directory so containers can access it |
| `spiffe-csi-driver` | `spiffe-csi-driver-rhel9` | The actual CSI plugin that handles volume publish/unpublish |
| `node-driver-registrar` | `ose-csi-node-driver-registrar` | Registers the CSI driver with the kubelet |

On your cluster, there's one CSI driver pod per worker:

```
spire-spiffe-csi-driver-lglc7   2/2  Running   worker-a-wcgg4
spire-spiffe-csi-driver-4xq8r   2/2  Running   worker-b-56pzx
spire-spiffe-csi-driver-xcdb4   2/2  Running   worker-c-rfwsj
```

### The Key Volume Mounts

The CSI driver pod mounts several critical host paths:

```yaml
volumes:
# 1. The SPIRE agent's socket directory on the host
- name: spire-agent-socket-dir
  hostPath:
    path: /run/spire/agent-sockets      # Where the agent writes spire-agent.sock
    type: DirectoryOrCreate

# 2. The CSI plugin socket — kubelet talks to the driver here
- name: spiffe-csi-socket-dir
  hostPath:
    path: /var/lib/kubelet/plugins/csi.spiffe.io
    type: DirectoryOrCreate

# 3. The kubelet pod volume directory — where the driver publishes volumes into pods
- name: mountpoint-dir
  hostPath:
    path: /var/lib/kubelet/pods          # Bidirectional mount propagation!
    mountPropagation: Bidirectional

# 4. Kubelet plugin registration directory
- name: kubelet-plugin-registration-dir
  hostPath:
    path: /var/lib/kubelet/plugins_registry
```

The **critical detail** is `mountPropagation: Bidirectional` on `/var/lib/kubelet/pods`.
This allows the CSI driver to create bind mounts inside pod volume directories that
become visible to the pod containers.

### The CSIDriver Object

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: csi.spiffe.io
spec:
  attachRequired: false           # No external attacher needed (node-local only)
  podInfoOnMount: true            # Kubelet passes pod name/namespace/UID to the driver
  volumeLifecycleModes:
  - Ephemeral                     # Only ephemeral inline volumes, no PV/PVC
  fsGroupPolicy: None             # No fsGroup ownership changes
  requiresRepublish: false        # Volume doesn't need periodic re-publishing
```

Key properties:
- **`attachRequired: false`** — This is a node-local driver. No "attach" to an external storage system is needed.
- **`podInfoOnMount: true`** — When the kubelet calls `NodePublishVolume`, it passes the pod's name, namespace, and UID. The driver uses this to create a per-pod volume directory.
- **`volumeLifecycleModes: [Ephemeral]`** — Only supports CSI ephemeral inline volumes (no PersistentVolumeClaim). The volume lives and dies with the pod.

### Exactly What Happens When a Pod Requests a SPIFFE Volume

Here's the step-by-step flow when our demo workload pod was created:

**1. Pod spec declares a CSI ephemeral volume:**

```yaml
spec:
  volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io     # Tells kubelet to use this CSI driver
      readOnly: true
  containers:
  - volumeMounts:
    - name: spiffe-workload-api
      mountPath: /spiffe-workload-api
      readOnly: true
```

**2. Kubelet sees the CSI volume and calls `NodePublishVolume` on the driver:**

The kubelet communicates with the CSI driver via its Unix socket at
`/var/lib/kubelet/plugins/csi.spiffe.io/csi.sock`. It tells the driver:
- Target path: `/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/spiffe-workload-api/mount`
- Pod UID: `61d10570-b891-42e0-82b3-3d7ae91d80e8`
- Volume is read-only

**3. The CSI driver creates a bind mount:**

The driver takes the SPIRE agent socket directory (`/run/spire/agent-sockets` on the host,
which it has mounted at `/spire-agent-socket`) and bind-mounts it to the target path under
`/var/lib/kubelet/pods/<pod-uid>/...`. Because of `Bidirectional` mount propagation,
this mount becomes visible to the pod.

The driver logged this for our demo workload:

```
Volume published
    volumeID: "csi-d4636561e27c1d99f49b9eb7134867325a456d3def134bd8f2691ae348b44b2e"
    targetPath: "/var/lib/kubelet/pods/61d10570-b891-42e0-82b3-3d7ae91d80e8/volumes/kubernetes.io~csi/spiffe-workload-api/mount"
    access_mode: "SINGLE_NODE_WRITER"
```

**4. The pod sees the agent socket at its mountPath:**

Inside the pod, the Workload API socket appears at `/spiffe-workload-api/spire-agent.sock`:

```
$ ls -la /spiffe-workload-api/
srwxrwxrwx. 1 1000730000 root  0 Mar 25 18:35 spire-agent.sock
```

**5. The CSI driver continuously health-checks the volume:**

After publishing, the driver periodically verifies the mount is still healthy:

```
Volume is healthy  volumeID="csi-d463..."
    volumePath="/var/lib/kubelet/pods/61d10570-.../volumes/kubernetes.io~csi/spiffe-workload-api/mount"
```

This runs every ~60–90 seconds on your cluster.

### The Complete Path: Host to Pod

```
┌─── Host (worker-a) ────────────────────────────────────────────────────┐
│                                                                        │
│  SPIRE Agent (DaemonSet, hostNetwork: true)                            │
│  └── Writes socket to: /run/spire/agent-sockets/spire-agent.sock      │
│                           │                                            │
│                           │ (hostPath mount)                           │
│                           ▼                                            │
│  SPIFFE CSI Driver (DaemonSet, privileged)                             │
│  └── Reads from:  /spire-agent-socket/spire-agent.sock                │
│  └── Bind-mounts to: /var/lib/kubelet/pods/<pod-uid>/volumes/         │
│                       kubernetes.io~csi/spiffe-workload-api/mount      │
│                           │                                            │
│                           │ (Bidirectional mount propagation)          │
│                           ▼                                            │
│  Workload Pod (demo-workload)                                          │
│  └── Sees it at: /spiffe-workload-api/spire-agent.sock                │
│  └── Connects via Unix socket to the SPIRE Agent Workload API         │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### Why CSI Instead of hostPath?

You might wonder: "Why not just use a `hostPath` volume to mount `/run/spire/agent-sockets` into pods?"

The CSI approach is better for several reasons:

| Concern | hostPath | CSI Driver |
|---|---|---|
| **Security policy** | Requires `privileged` or relaxed SCC/PSA on the workload | Workload runs `restricted` — the CSI driver label `security.openshift.io/csi-ephemeral-volume-profile: restricted` tells OpenShift this volume is safe for restricted pods |
| **Pod modification** | Need to know the exact host path | Just declare `driver: csi.spiffe.io` — portable across nodes/clusters |
| **Health checking** | None | CSI driver periodically validates the mount is healthy |
| **Lifecycle** | Manual management | Automatically published on pod create, unpublished on pod delete |
| **SELinux** | Must handle relabeling yourself | The init container runs `chcon -Rvt container_file_t` to handle SELinux |

### Inspect Commands

```bash
# View CSIDriver object
kubectl get csidriver csi.spiffe.io -o yaml

# View CSI driver DaemonSet
kubectl get daemonset spire-spiffe-csi-driver -n zero-trust-workload-identity-manager -o yaml

# View CSI driver pods
kubectl get pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spiffe-csi-driver -o wide

# View CSI driver logs on a specific node (check volume publish/health events)
kubectl logs -n zero-trust-workload-identity-manager spire-spiffe-csi-driver-lglc7 -c spiffe-csi-driver --tail=20

# Verify the socket is visible inside a workload pod
kubectl exec -n svid-demo <pod-name> -- ls -la /spiffe-workload-api/
```

---

## PHASE 4: A Workload Requests an SVID (Steps 17–21) — LIVE DEMO

We deployed a demo workload to trace this end-to-end.

### Step 17 — Workload Pod Created

A pod `demo-workload-84f7bc5d77-pk47t` was created in namespace `svid-demo` with:

| Property | Value |
|---|---|
| **ServiceAccount** | `demo-workload` |
| **CSI Volume** | `csi.spiffe.io` → mounted at `/spiffe-workload-api` |
| **Scheduled on** | `gcp25mar-sbkbw-worker-a-wcgg4` |
| **Pod UID** | `61d10570-b891-42e0-82b3-3d7ae91d80e8` |
| **SPIRE Agent on same node** | `spire-agent-rdb68` |

The key part of the pod spec:

```yaml
volumes:
- name: spiffe-workload-api
  csi:
    driver: csi.spiffe.io
    readOnly: true
containers:
- volumeMounts:
  - name: spiffe-workload-api
    mountPath: /spiffe-workload-api
    readOnly: true
```

### Step 18 — SPIRE Controller Manager Auto-Creates Registration Entry

The **SPIRE Controller Manager** (sidecar in `spire-server-0`) watches for new pods. When it saw our
demo pod, it matched it against the `ClusterSPIFFEID` template:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: zero-trust-workload-identity-manager-spire-default
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values: ["zero-trust-workload-identity-manager"]
```

Since namespace `svid-demo` is NOT in the exclusion list, it matched. The controller manager
automatically created a SPIRE registration entry.

**Controller Manager logs:**

```
Created entry
    id:        "test01.303f9d05-81d3-4847-85a6-3812133add85"
    parentID:  "spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/spire/agent/k8s_psat/test01/ca52e226-..."
    spiffeID:  "spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/ns/svid-demo/sa/demo-workload"
    selectors: "[k8s:pod-uid:61d10570-b891-42e0-82b3-3d7ae91d80e8]"
```

Understanding the fields:
- **SPIFFE ID** = `spiffe://<trust_domain>/ns/<namespace>/sa/<service_account>` — the workload's identity
- **Parent ID** = the SPIRE agent on the node where the pod runs — only this agent can issue this SVID
- **Selector** = `k8s:pod-uid:<uid>` — ties the entry to the exact pod

**To verify registration entries:**

```bash
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 \
    -c spire-server -- /spire-server entry show
```

### Step 19 — Agent Creates the X509-SVID

The agent on `worker-a` picks up the new registration entry and creates the SVID:

```
Creating X509-SVID
    entry_id=test01.303f9d05-81d3-4847-85a6-3812133add85
    spiffe_id="spiffe://apps.gcp25mar.gcp.devcluster.openshift.com/ns/svid-demo/sa/demo-workload"
```

The agent:
1. Generates a private key and Certificate Signing Request (CSR)
2. Sends the CSR to the SPIRE Server
3. The server signs it with the self-signed CA from Step 1
4. Returns the signed X.509-SVID certificate
5. The agent caches the SVID (private key + cert + trust bundle)

### Steps 20–21 — Workload Attestation and SVID Delivery

When a workload process connects to the Workload API socket at `/spiffe-workload-api/spire-agent.sock`,
the agent performs **workload attestation**:

1. **Gets the process ID** of the connecting workload (via the Unix socket)
2. **Calls the `k8s` workload attestor** which queries the kubelet API to discover:
   - Pod UID
   - Namespace
   - Service account name
   - Container image, labels, etc.
3. **Matches selectors**: The discovered `k8s:pod-uid:61d10570-...` matches the registration entry
4. **Returns the cached SVID** (X.509 certificate + private key + trust bundle) to the workload

**Workload attestor config** (`agent.conf`):

```json
"WorkloadAttestor": [{
    "k8s": {
        "plugin_data": {
            "kubelet_ca_path": "/etc/kubernetes/kubelet-ca.crt",
            "node_name_env": "MY_NODE_NAME",
            "skip_kubelet_verification": false,
            "use_new_container_locator": true
        }
    }
}]
```

**Workload logs confirming the socket is accessible:**

```
=== SVID Demo Workload ===
--- Workload API socket found at /spiffe-workload-api/spire-agent.sock ---
srwxrwxrwx. 1 1000730000 root  0 Mar 25 18:35 spire-agent.sock
=== SVID Demo Workload Running ===
```

---

## Architecture Diagram

```
                    ┌─────────────────────────────────────────────────┐
                    │          SPIRE SERVER (spire-server-0)          │
                    │                                                 │
                    │  ┌─────────────────┐  ┌──────────────────────┐  │
                    │  │  spire-server   │  │  controller-manager  │  │
                    │  │                 │◄─│  (watches pods,      │  │
                    │  │  - Self-signed  │  │   creates entries    │  │
                    │  │    CA cert      │  │   via api.sock)      │  │
                    │  │  - SQLite DB    │  │                      │  │
                    │  │  - Signs SVIDs  │  │  ClusterSPIFFEID     │  │
                    │  │  - Trust bundle │  │  template matching   │  │
                    │  └────────┬────────┘  └──────────────────────┘  │
                    │           │ gRPC :8081 (mTLS)                   │
                    └───────────┼─────────────────────────────────────┘
                                │
              ┌─────────────────┼──────────────────────┐
              │                 │                      │
       ┌──────▼──────┐  ┌──────▼──────┐  ┌────────────▼──┐
       │ SPIRE Agent │  │ SPIRE Agent │  │  SPIRE Agent  │
       │ (worker-a)  │  │ (worker-b)  │  │  (worker-c)   │
       │             │  │             │  │               │
       │ - k8s_psat  │  │             │  │               │
       │   attestor  │  │             │  │               │
       │ - k8s work- │  │             │  │               │
       │   load      │  │             │  │               │
       │   attestor  │  │             │  │               │
       │ - SVID cache│  │             │  │               │
       │ - Workload  │  │             │  │               │
       │   API sock  │  │             │  │               │
       └──────┬──────┘  └─────────────┘  └───────────────┘
              │
              │  Unix Socket via SPIFFE CSI Driver (csi.spiffe.io)
              │  Host path: /run/spire/agent-sockets/spire-agent.sock
              │  Pod path:  /spiffe-workload-api/spire-agent.sock
              │
       ┌──────▼────────────────────────────────────────────┐
       │  demo-workload pod (svid-demo namespace)          │
       │  Node: worker-a                                   │
       │                                                   │
       │  SPIFFE ID:                                       │
       │  spiffe://apps.gcp25mar.gcp.devcluster            │
       │    .openshift.com/ns/svid-demo/sa/demo-workload   │
       │                                                   │
       │  Selector: k8s:pod-uid:61d10570-b891-42e0-...     │
       └───────────────────────────────────────────────────┘
```

---

## Key Configuration Resources

| Resource | Purpose | Inspect Command |
|---|---|---|
| `ConfigMap/spire-server` | `server.conf` — trust domain, plugins, CA settings | `kubectl get cm spire-server -n zero-trust-workload-identity-manager -o yaml` |
| `ConfigMap/spire-agent` | `agent.conf` — server address, attestor config | `kubectl get cm spire-agent -n zero-trust-workload-identity-manager -o yaml` |
| `ConfigMap/spire-bundle` | The self-signed CA cert (trust bundle) | `kubectl get cm spire-bundle -n zero-trust-workload-identity-manager -o yaml` |
| `ConfigMap/spire-controller-manager` | Controller config — SPIFFE ID templates | `kubectl get cm spire-controller-manager -n zero-trust-workload-identity-manager -o yaml` |
| `ClusterSPIFFEID` | Template for auto-registering workloads | `kubectl get clusterspiffeids -o yaml` |
| `CSIDriver/csi.spiffe.io` | Injects Workload API socket into pods | `kubectl get csidriver csi.spiffe.io -o yaml` |
| `SpireServer/cluster` | Operator CR for SPIRE server | `kubectl get spireservers cluster -o yaml` |
| `SpireAgent/cluster` | Operator CR for SPIRE agent | `kubectl get spireagents cluster -o yaml` |

---

## Timeline of Events (from live cluster)

| Timestamp (UTC) | Event | Details |
|---|---|---|
| `18:34:56` | Server started | Self-signed CA created, SQLite DB initialized |
| `18:34:56` | JWT key prepared | Key ID: `qGlEUlIAeMjh8fkRVlTY3AEVgKGJxygO` |
| `18:34:56` | Server APIs started | gRPC on :8081, Unix socket, health on :8080 |
| `18:35:28` | Agent (worker-b) attested | k8s_psat token validated via TokenReview API |
| `18:35:28` | Agent (worker-a) attested | k8s_psat token validated via TokenReview API |
| `18:35:29` | Agent (worker-c) attested | k8s_psat token validated via TokenReview API |
| `18:35:29` | Workload API started | Agents listening on Unix domain sockets |
| `19:02:37` | Agent (worker-c) re-attested | SVID was expiring, agent re-attested automatically |
| `19:03:06` | Agent (worker-b) re-attested | Periodic SVID renewal |
| `19:03:40` | Agent (worker-a) re-attested | Periodic SVID renewal |
| `19:19:41` | Demo workload entry created | Controller manager detected new pod in `svid-demo` |
| `19:19:45` | X509-SVID created | Agent signed SVID for `ns/svid-demo/sa/demo-workload` |

---

## Glossary

| Term | Definition |
|---|---|
| **SVID** | SPIFFE Verifiable Identity Document — a cryptographic identity (X.509 cert or JWT) |
| **SPIFFE ID** | A URI like `spiffe://trust-domain/path` that uniquely identifies a workload |
| **Trust Domain** | The root of trust — all identities within share the same CA root |
| **Trust Bundle** | The set of root CA certificates for a trust domain |
| **Node Attestation** | Process where an agent proves its node identity to the server |
| **Workload Attestation** | Process where the agent verifies a workload's identity on its node |
| **Registration Entry** | A record mapping a SPIFFE ID to selectors and a parent agent |
| **PSAT** | Projected Service Account Token — Kubernetes-native token used for attestation |
| **CSI Driver** | Container Storage Interface driver that injects the Workload API socket |
| **ClusterSPIFFEID** | Kubernetes CRD that auto-creates registration entries for matching pods |

---

## Useful Commands

```bash
# Set kubeconfig
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/25Mar2026/auth/kubeconfig

# View SPIRE server logs
kubectl logs spire-server-0 -n zero-trust-workload-identity-manager -c spire-server --tail=50

# View SPIRE controller manager logs
kubectl logs spire-server-0 -n zero-trust-workload-identity-manager -c spire-controller-manager --tail=50

# View SPIRE agent logs (pick an agent pod)
kubectl logs spire-agent-rdb68 -n zero-trust-workload-identity-manager --tail=50

# List attested agents
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 \
    -c spire-server -- /spire-server agent list

# List registration entries
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 \
    -c spire-server -- /spire-server entry show

# Show trust bundle
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 \
    -c spire-server -- /spire-server bundle show -format spiffe

# Decode the CA certificate
kubectl get configmap spire-bundle -n zero-trust-workload-identity-manager \
    -o jsonpath='{.data.bundle\.crt}' | openssl x509 -text -noout

# Check ClusterSPIFFEID status
kubectl get clusterspiffeids -o yaml
```
