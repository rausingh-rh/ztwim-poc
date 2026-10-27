# Nested SPIRE: Attestor Comparison: Deploy & Test Manifests

This directory contains the manifests needed to deploy and test nested SPIRE using three different node attestation methods. Each attestor was deployed on two fresh GCP OpenShift clusters, verified end-to-end, and the resulting manifests were recorded.

## Architecture

All three scenarios use the **sidecar + unix** deployment pattern:

- **Parent cluster**: Runs a standard SPIRE server with the appropriate NodeAttestor configured
- **Child cluster**: Runs a SPIRE server with an **upstream agent sidecar** (3rd container in the `spire-server` StatefulSet)
- The sidecar connects to the upstream parent server (via a gRPC passthrough Route) for node attestation
- The downstream child server connects to the sidecar's unix socket (`/run/spire/upstream-agent/spire-agent.sock`) via the UpstreamAuthority "spire" plugin
- The child server's CA is signed by the parent, forming a CA hierarchy within a single trust domain

## Prerequisites

- Two OpenShift 4.x clusters on GCP (or adjust for your cloud)
- `oc` CLI authenticated to both clusters
- ZTWIM operator available in `redhat-operators` catalog

## Variables

All manifests use `${VAR}` placeholders. Set your values in `env.sh` and source it:

```bash
# Edit env.sh with your cluster values, then:
source env.sh
```

| Variable | Description | Example |
|----------|-------------|---------|
| `PARENT_CLUSTER_DOMAIN` | Parent cluster's OpenShift base domain | `gcp1793008166.gcp.devcluster.openshift.com` |
| `CHILD_CLUSTER_DOMAIN` | Child cluster's OpenShift base domain | `gcp1793009109.gcp.devcluster.openshift.com` |
| `TRUST_DOMAIN` | Shared SPIRE trust domain (derived: `apps.${PARENT_CLUSTER_DOMAIN}`) | `apps.gcp1793008166.gcp.devcluster.openshift.com` |
| `GCP_PROJECT` | GCP project ID (gcp_iit only) | `openshift-gce-devel` |
| `PARENT_KUBECONFIG` | Path to parent cluster kubeconfig | `/path/to/parent/kubeconfig` |
| `CHILD_KUBECONFIG` | Path to child cluster kubeconfig | `/path/to/child/kubeconfig` |

Apply manifests using `envsubst`:

```bash
KUBECONFIG=$PARENT_KUBECONFIG envsubst < common/03-parent-grpc-route.yaml | oc apply -f -
```

## Common Setup (All Attestors)

1. Install the operator on both clusters:

```bash
oc apply -f common/01-subscription.yaml  # on both clusters
```

2. Create the operand CR and sub-CRs on both clusters (see `common/02-operand-cr.yaml`).
3. Wait for all pods to be healthy, then enable `CREATE_ONLY_MODE` on both clusters to prevent the operator from reconciling manual patches:

```bash
oc patch subscription openshift-zero-trust-workload-identity-manager \
  -n zero-trust-workload-identity-manager \
  --type merge \
  -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'
```

Wait for the operator pod to restart before proceeding:

```bash
sleep 20
oc get pod -n zero-trust-workload-identity-manager -l name=zero-trust-workload-identity-manager
```

4. Create a gRPC passthrough Route on the parent cluster (see `common/03-parent-grpc-route.yaml` or the per-attestor equivalent).

## Per-Attestor Instructions

### k8s_psat (Recommended)

**Directory**: `k8s-psat/`

**Summary**: Parent validates child's projected SA token via TokenReview. Reattestable.

**Steps** (after common setup):

1. On the **child cluster**, create the TokenReview SA and RBAC:
   - `01-child-sa-token-reviewer.yaml` — ServiceAccount
   - `02-child-clusterrole-nodes.yaml` — ClusterRole for `get nodes`
   - `03-child-clusterrolebinding-auth-delegator.yaml` — system:auth-delegator
   - `03b-child-clusterrolebinding-nodes.yaml` — bind nodes ClusterRole
   - `04-child-role-pod-access.yaml` — Role for `get pods` (namespace-scoped)
   - `05-child-rolebinding-pod-access.yaml` — RoleBinding for pod access
2. Generate a kubeconfig using the child SA's token, store as a Secret on the **parent cluster** (`08-parent-child-kubeconfig-secret.yaml`).
3. Patch the **parent** ConfigMap to add the child cluster in k8s_psat (`06-parent-server-configmap.yaml`), mount the kubeconfig Secret in the **parent** StatefulSet (`07-parent-server-statefulset.yaml`).
4. Copy the parent trust bundle to the **child** as a Secret (`10-child-parent-trust-bundle-secret.yaml`).
5. Patch the **child** ConfigMap to add UpstreamAuthority "spire" (`11-child-server-configmap.yaml`).
6. Create the upstream agent ConfigMap on the **child** (`12-child-upstream-agent-configmap.yaml`).
7. Patch the **child** StatefulSet to add the sidecar container + `shareProcessNamespace: true` (`13-child-server-statefulset.yaml`).
8. Create two ClusterStaticEntries on the **parent** (EP node-alias pattern):
   - `09a-parent-node-alias.yaml` — node alias: `parentID` = the SPIRE server, selectors match the attestor (e.g., `k8s_psat:cluster:child01`). Provides a **stable** intermediate SPIFFE ID.
   - `09b-parent-downstream.yaml` — downstream entry: `parentID` = the node alias SPIFFE ID (deterministic, no `agent list` needed), `downstream: true`.

     Both entries can be created **before** the agent attests — no need to look up the agent SPIFFE ID.

**Key facts**:

- `CanReattest: true` — survives pod restarts without data loss
- No `hostNetwork` needed
- No cloud-specific infrastructure
- Requires a kubeconfig (admin creates manually, operator mounts)

---

### gcp_iit

**Directory**: `gcp-iit/`

**Summary**: Agent presents a GCP instance identity token. Not reattestable.

**Steps** (after common setup):

1. Grant the `hostnetwork` SCC to the spire-server SA on the **child**:
   ```bash
        oc adm policy add-scc-to-user hostnetwork -z spire-server \
          -n zero-trust-workload-identity-manager
   ```
2. Patch the **parent** ConfigMap to add `gcp_iit` NodeAttestor with `projectid_allow_list` (`02-parent-server-configmap.yaml`).
3. Copy the parent trust bundle to the **child** (`05-child-parent-trust-bundle-secret.yaml`).
4. Patch the **child** ConfigMap to add UpstreamAuthority "spire" (`06-child-server-configmap.yaml`).
5. Create the upstream agent ConfigMap on the **child** (`07-child-upstream-agent-configmap.yaml`).
6. Patch the **child** StatefulSet: add sidecar, `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`, `shareProcessNamespace: true` (`08-child-server-statefulset.yaml`).
7. Create two ClusterStaticEntries on the **parent** (EP node-alias pattern):
   - `04a-parent-node-alias.yaml` — node alias: `parentID` = the SPIRE server, selector `gcp_iit:project-id:<GCP_PROJECT>`. Provides a **stable** intermediate SPIFFE ID.
   - `04b-parent-downstream.yaml` — downstream entry: `parentID` = the node alias SPIFFE ID (deterministic), `downstream: true`.

     Both entries can be created **before** the agent attests.

**Key facts**:

- `CanReattest: false` — agent eviction + re-registration required on pod restart (or use KeyManager disk + PVC workaround)
- Requires `hostNetwork: true` (GCP metadata server at 169.254.169.254)
- Requires elevated SCC (hostnetwork)
- GCP-specific; requires `projectid_allow_list`
- No kubeconfig needed

---

### http_challenge

**Directory**: `http-challenge/`

**Summary**: Agent proves DNS control by serving an HTTP challenge endpoint. Not reattestable (with tofu=true).

**Steps** (after common setup):

1. Patch the **parent** ConfigMap to add `http_challenge` NodeAttestor with `allowed_dns_patterns` (regex) and `tofu: true` (`02-parent-server-configmap.yaml`).
2. Copy the parent trust bundle to the **child** (`05-child-parent-trust-bundle-secret.yaml`).
3. Patch the **child** ConfigMap to add UpstreamAuthority "spire" (`06-child-server-configmap.yaml`).
4. Create the upstream agent ConfigMap on the **child** (`07-child-upstream-agent-configmap.yaml`). Note:
   - `port: 9080` — the local bind port for the challenge HTTP server
   - `advertised_port: 80` — the port the parent server connects to (via the Route)
5. Create the challenge Service on the **child** (`08-child-challenge-service.yaml`). Important:
   - `publishNotReadyAddresses: true` — required so the Route works during pod startup (before readiness probes pass)
   - `targetPort: 9080` — matches the agent's bind port
6. Create the challenge Route on the **child** (`09-child-challenge-route.yaml`):
   - `tls.termination: edge`
   - `tls.insecureEdgeTerminationPolicy: Allow` — SPIRE hardcodes `http://` and rejects redirects
7. Patch the **child** StatefulSet: add sidecar + `shareProcessNamespace: true` (`10-child-server-statefulset.yaml`).
8. Create two ClusterStaticEntries on the **parent** (EP node-alias pattern):
   - `04a-parent-node-alias.yaml` — node alias: `parentID` = the SPIRE server, selector `http_challenge:hostname:<agent_hostname>`. Provides a **stable** intermediate SPIFFE ID.
   - `04b-parent-downstream.yaml` — downstream entry: `parentID` = the node alias SPIFFE ID (deterministic), `downstream: true`.

     Both entries can be created **before** the agent attests.

**Key facts**:

- `CanReattest: false` (hardcoded for all cloud/challenge attestors)
- Plain HTTP only — SPIRE hardcodes `http://` scheme and disables HTTP redirects in its verification client
- `allowed_dns_patterns` uses **regex** syntax (e.g., `.*\\.apps\\.${CHILD_CLUSTER_DOMAIN}`)
- `publishNotReadyAddresses: true` is mandatory on the Service — otherwise the Route returns 503 during startup
- `advertised_port` decouples the bind port (high, e.g. 9080) from the externally accessible port (80, via Route)
- No `hostNetwork` needed, no kubeconfig needed
- Cloud/topology agnostic (any cluster with DNS-resolvable Routes)

## Verification

After deployment, verify end-to-end:

```bash
# Check upstream CA (self_signed should be false)
oc logs spire-server-0 -c spire-server -n zero-trust-workload-identity-manager \
  | grep "X509 CA activated"

# Mint a test SVID on the child
oc exec spire-server-0 -c spire-server -n zero-trust-workload-identity-manager -- \
  /spire-server x509 mint -spiffeID "spiffe://$TRUST_DOMAIN/test/verify"

# Should show 3 certificates: leaf → child intermediate → parent root
```

## Important Notes

1. **KeyManager disk**: For `gcp_iit` and `http_challenge` (both non-reattestable), use `KeyManager disk` with a PVC to persist agent keys across pod restarts, avoiding the need for agent eviction + re-registration.
2. **http_challenge regex escaping**: The `allowed_dns_patterns` value uses regex with escaped dots (e.g., `.*\\.apps\\.${CHILD_CLUSTER_DOMAIN}`). When applying via `envsubst | oc apply`, the double-backslashes in the YAML are preserved correctly. However, if applying via JSON patching or programmatic tools, ensure backslashes are not collapsed (SPIRE rejects `.*\.apps\.` as "illegal char escape" — it needs `.*\\.apps\\.` in the JSON string).
