# SPIRE Federation Setup Between Two OpenShift Clusters

## Overview

This document describes the complete setup of SPIRE-to-SPIRE federation between two OpenShift clusters running the zero-trust-workload-identity-manager operator. The federation enables workloads in different trust domains to establish mutual TLS connections and verify each other's identities.

## Cluster Information

### Cluster 1
- **Trust Domain**: `apps.cluster-1.devcluster.openshift.com`
- **Kubeconfig**: `/home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig`
- **OIDC Discovery**: `https://oidc-discovery.apps.cluster-1.devcluster.openshift.com`
- **Federation Bundle Endpoint**: `https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-1.devcluster.openshift.com`

### Cluster 2
- **Trust Domain**: `apps.cluster-2.devcluster.openshift.com`
- **Kubeconfig**: `/home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig`
- **OIDC Discovery**: `https://oidc-discovery.apps.cluster-2.devcluster.openshift.com`
- **Federation Bundle Endpoint**: `https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-2.devcluster.openshift.com`

## Prerequisites

- Two OpenShift clusters with zero-trust-workload-identity-manager operator installed
- SPIRE components (server, agent, CSI driver, controller-manager) running in both clusters
- kubectl access to both clusters
- Network connectivity between clusters (for federation bundle endpoint access)

## Federation Setup Steps

### Step 1: Configure Federation Bundle Endpoints

The SPIRE servers need to expose their federation bundle endpoints to allow other trust domains to fetch their trust bundles.

#### 1.1 Update SPIRE Server Configuration

For each cluster, update the SPIRE server ConfigMap to add the federation bundle endpoint configuration:

**Cluster 1 (`spire-server` ConfigMap):**
```json
{
  "server": {
    ...
    "federation": {
      "bundle_endpoint": {
        "address": "0.0.0.0",
        "port": 8443
      },
      "federates_with": {
        "apps.cluster-2.devcluster.openshift.com": {
          "bundle_endpoint_url": "https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-2.devcluster.openshift.com",
          "bundle_endpoint_profile": {
            "https_spiffe": {
              "endpoint_spiffe_id": "spiffe://apps.cluster-2.devcluster.openshift.com/spire/server"
            }
          }
        }
      }
    }
  }
}
```

Applied via:
```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig apply -f federation-setup/cluster1-current-cm.yaml
```

**Cluster 2 (`spire-server` ConfigMap):**
```json
{
  "server": {
    ...
    "federation": {
      "bundle_endpoint": {
        "address": "0.0.0.0",
        "port": 8443
      },
      "federates_with": {
        "apps.cluster-1.devcluster.openshift.com": {
          "bundle_endpoint_url": "https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-1.devcluster.openshift.com",
          "bundle_endpoint_profile": {
            "https_spiffe": {
              "endpoint_spiffe_id": "spiffe://apps.cluster-1.devcluster.openshift.com/spire/server"
            }
          }
        }
      }
    }
  }
}
```

Applied via:
```bash
kubectl --kubeconfig /path/to/cluster2/kubeconfig apply -f federation-setup/cluster2-current-cm.yaml
```

#### 1.2 Expose Port 8443 in SPIRE Server StatefulSet

The SPIRE server pods need to expose port 8443:

```bash
# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig patch statefulset spire-server \
  -n zero-trust-workload-identity-manager --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/ports/-", "value": {"name": "federation", "containerPort": 8443, "protocol": "TCP"}}]'

# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig patch statefulset spire-server \
  -n zero-trust-workload-identity-manager --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/ports/-", "value": {"name": "federation", "containerPort": 8443, "protocol": "TCP"}}]'
```

#### 1.3 Create Federation Services and Routes

Create Kubernetes Services and OpenShift Routes to expose the federation endpoints:

**Federation Service (both clusters):**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: spire-server-federation
  namespace: zero-trust-workload-identity-manager
spec:
  type: ClusterIP
  ports:
  - name: federation
    port: 8443
    protocol: TCP
    targetPort: 8443
  selector:
    app.kubernetes.io/name: spire-server
```

**Federation Route (both clusters):**
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-federation
  namespace: zero-trust-workload-identity-manager
spec:
  to:
    kind: Service
    name: spire-server-federation
  port:
    targetPort: federation
  tls:
    termination: passthrough
    insecureEdgeTerminationPolicy: Redirect
```

Applied via:
```bash
# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig apply -f federation-setup/cluster1-federation-service.yaml
kubectl --kubeconfig /path/to/cluster1/kubeconfig apply -f federation-setup/cluster1-federation-route.yaml

# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig apply -f federation-setup/cluster2-federation-service.yaml
kubectl --kubeconfig /path/to/cluster2/kubeconfig apply -f federation-setup/cluster2-federation-route.yaml
```

#### 1.4 Restart SPIRE Servers

Restart the SPIRE servers to apply the configuration changes:

```bash
# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig rollout restart statefulset spire-server -n zero-trust-workload-identity-manager

# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig rollout restart statefulset spire-server -n zero-trust-workload-identity-manager
```

### Step 2: Bootstrap Federation

Exchange trust bundles between the two SPIRE servers using the ClusterFederatedTrustDomain CRD.

#### 2.1 Extract Trust Bundles

Extract the trust bundle from each SPIRE server:

```bash
# Cluster 1 bundle
kubectl --kubeconfig /path/to/cluster1/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle show -format spiffe > federation-setup/cluster1-bundle.json

# Cluster 2 bundle
kubectl --kubeconfig /path/to/cluster2/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle show -format spiffe > federation-setup/cluster2-bundle.json
```

#### 2.2 Create ClusterFederatedTrustDomain Resources

**Cluster 1 - Federating with Cluster 2:**
```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster-2-federation
spec:
  trustDomain: apps.cluster-2.devcluster.openshift.com
  bundleEndpointURL: https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-2.devcluster.openshift.com
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://apps.cluster-2.devcluster.openshift.com/spire/server
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |-
    {
      "keys": [
        ... (trust bundle from cluster 2)
      ],
      "spiffe_sequence": 1
    }
```

**Cluster 2 - Federating with Cluster 1:**
```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster-1-federation
spec:
  trustDomain: apps.cluster-1.devcluster.openshift.com
  bundleEndpointURL: https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-1.devcluster.openshift.com
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://apps.cluster-1.devcluster.openshift.com/spire/server
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |-
    {
      "keys": [
        ... (trust bundle from cluster 1)
      ],
      "spiffe_sequence": 1
    }
```

Applied via:
```bash
# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig apply -f federation-setup/cluster1-federated-trust-domain.yaml

# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig apply -f federation-setup/cluster2-federated-trust-domain.yaml
```

### Step 3: Create Test Workloads with Federation

#### 3.1 Create Namespaces and ServiceAccounts

**Both clusters:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: federation-demo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-server  # In Cluster 2
  namespace: federation-demo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-client  # In Cluster 1
  namespace: federation-demo
```

#### 3.2 Create ClusterSPIFFEID Resources with Federation

**Cluster 2 - Backend Server:**
```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: backend-server
spec:
  spiffeIDTemplate: "spiffe://apps.cluster-2.devcluster.openshift.com/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: backend-server
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: federation-demo
  federatesWith:
  - "apps.cluster-1.devcluster.openshift.com"
  className: zero-trust-workload-identity-manager-spire
```

**Cluster 1 - Frontend Client:**
```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: frontend-client
spec:
  spiffeIDTemplate: "spiffe://apps.cluster-1.devcluster.openshift.com/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: frontend-client
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: federation-demo
  federatesWith:
  - "apps.cluster-2.devcluster.openshift.com"
  className: zero-trust-workload-identity-manager-spire
```

Applied via:
```bash
# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig apply -f federation-setup/workloads/backend-server-spiffeid.yaml

# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig apply -f federation-setup/workloads/frontend-client-spiffeid.yaml
```

### Step 4: Verify Federation

#### 4.1 Verify Trust Bundles

Check that each SPIRE server has the other's trust bundle:

```bash
# Cluster 1 - Should show cluster-2 bundle
kubectl --kubeconfig /path/to/cluster1/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list

# Cluster 2 - Should show cluster-1 bundle
kubectl --kubeconfig /path/to/cluster2/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list
```

**Expected Output:**
Each cluster should list the federated trust domain's bundle certificate.

#### 4.2 Verify Registration Entries

Check that registration entries are created with federation enabled:

```bash
# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show

# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show
```

**Expected Output:**
Entries should show `FederatesWith` field pointing to the other trust domain.

#### 4.3 Verify ClusterFederatedTrustDomain Resources

```bash
# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig get clusterfederatedtrustdomain -o wide

# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig get clusterfederatedtrustdomain -o wide
```

## Configuration Files

All configuration files are located in the `federation-setup/` directory:

```
federation-setup/
├── cluster1-current-cm.yaml                  # Updated SPIRE server ConfigMap for Cluster 1
├── cluster2-current-cm.yaml                  # Updated SPIRE server ConfigMap for Cluster 2
├── cluster1-federation-service.yaml          # Federation service for Cluster 1
├── cluster2-federation-service.yaml          # Federation service for Cluster 2
├── cluster1-federation-route.yaml            # Federation route for Cluster 1
├── cluster2-federation-route.yaml            # Federation route for Cluster 2
├── cluster1-federated-trust-domain.yaml      # ClusterFederatedTrustDomain for Cluster 1
├── cluster2-federated-trust-domain.yaml      # ClusterFederatedTrustDomain for Cluster 2
├── cluster1-bundle.json                      # Trust bundle from Cluster 1
├── cluster2-bundle.json                      # Trust bundle from Cluster 2
└── workloads/
    ├── backend-server.yaml                   # Backend workload deployment
    ├── frontend-client.yaml                  # Frontend workload deployment
    ├── backend-server-spiffeid.yaml          # ClusterSPIFFEID for backend
    └── frontend-client-spiffeid.yaml         # ClusterSPIFFEID for frontend
```

## Federation Architecture

### Authentication Method

This setup uses **SPIFFE Authentication (https_spiffe)** profile for the federation bundle endpoints:
- Each SPIRE server's bundle endpoint is authenticated using SPIFFE credentials
- The `endpointSPIFFEID` specifies the expected SPIFFE ID of the bundle endpoint server
- Initial trust is bootstrapped using the `trustDomainBundle` field in the ClusterFederatedTrustDomain resource

### Trust Bundle Exchange Flow

1. **Initial Bootstrap**: 
   - Trust bundles are manually extracted from each SPIRE server
   - ClusterFederatedTrustDomain resources are created with the initial bundles
   - The `federates_with` block in SPIRE server config tells the server WHERE to fetch federated bundles

2. **Automatic Updates (Bundle Rotation)**:
   - The `federates_with` configuration enables automatic bundle rotation
   - Each SPIRE server polls the federated endpoint periodically (default: every 5 minutes as indicated by `refresh_hint`)
   - When certificates are rotated in either trust domain, the changes propagate automatically
   - The SPIRE controller-manager watches ClusterFederatedTrustDomain resources for management
   - Bundle updates are propagated to all workloads automatically

3. **SVID Issuance with Federation**:
   - Workloads with `federatesWith` in their ClusterSPIFFEID receive their own trust domain's SVID
   - They also receive the federated trust domain's bundle
   - This enables mutual TLS authentication across trust domains

### Why `federates_with` Block is Critical

The `federates_with` configuration block in the SPIRE server config is **essential for automatic bundle rotation**:

**Without `federates_with`:**
- The SPIRE server only has the initial trust bundle provided via ClusterFederatedTrustDomain
- No automatic updates occur when certificates rotate
- Manual intervention is required to update bundles
- Federation breaks when certificates expire

**With `federates_with`:**
- The SPIRE server automatically polls the federated endpoint
- Bundle updates are fetched and applied automatically
- Certificate rotation is seamless with zero downtime
- The system is self-healing and maintenance-free

**Configuration Breakdown:**
```json
"federates_with": {
  "apps.cluster-2.devcluster.openshift.com": {              // Federated trust domain
    "bundle_endpoint_url": "https://...",                    // Where to fetch the bundle
    "bundle_endpoint_profile": {                             // How to authenticate
      "https_spiffe": {                                      // Use SPIFFE auth
        "endpoint_spiffe_id": "spiffe://.../spire/server"   // Expected server identity
      }
    }
  }
}
```

**Verification of Automatic Rotation:**
```bash
# Check SPIRE server logs for bundle refresh activity
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep "Bundle refresh"

# Expected output:
# time="..." level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=...
# time="..." level=debug msg="Scheduling next bundle refresh" at="..." subsystem_name=bundle_client
```

## Verification Results

### Trust Bundle Exchange

✅ **Cluster 1 SPIRE Server**:
- Successfully fetched and stored Cluster 2's trust bundle
- Trust domain: `apps.cluster-2.devcluster.openshift.com`
- Automatic bundle rotation: **ACTIVE** ✓
  ```
  time="2025-10-09T10:50:22Z" level=info msg="Bundle refreshed" 
  time="2025-10-09T10:51:37Z" level=info msg="Bundle refreshed"  (automatic refresh)
  time="2025-10-09T10:51:37Z" level=debug msg="Scheduling next bundle refresh" at="2025-10-09T10:52:52Z"
  ```

✅ **Cluster 2 SPIRE Server**:
- Successfully fetched and stored Cluster 1's trust bundle
- Trust domain: `apps.cluster-1.devcluster.openshift.com`
- Automatic bundle rotation: **ACTIVE** ✓
  ```
  time="2025-10-09T10:51:40Z" level=info msg="Bundle refreshed"
  time="2025-10-09T10:51:40Z" level=debug msg="Scheduling next bundle refresh" at="2025-10-09T10:52:55Z"
  ```

### Registration Entries

✅ **Cluster 1**:
- Entry created for `demo-workload` with `FederatesWith: apps.cluster-2.devcluster.openshift.com`

✅ **Cluster 2**:
- Entry created for `demo-workload` with `FederatesWith: apps.cluster-1.devcluster.openshift.com`

### ClusterFederatedTrustDomain Status

✅ **Cluster 1**:
```
NAME                   TRUST DOMAIN                              ENDPOINT URL
cluster-2-federation   apps.cluster-2.devcluster.openshift.com   https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-2.devcluster.openshift.com
```

✅ **Cluster 2**:
```
NAME                   TRUST DOMAIN                              ENDPOINT URL
cluster-1-federation   apps.cluster-1.devcluster.openshift.com   https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-1.devcluster.openshift.com
```

## Key Concepts

### Trust Domain

A trust domain represents the boundary within which a SPIFFE identity is issued. Each SPIRE server manages one trust domain. In this setup:
- Cluster 1: `apps.cluster-1.devcluster.openshift.com`
- Cluster 2: `apps.cluster-2.devcluster.openshift.com`

### Federation Bundle Endpoint

The bundle endpoint is an HTTPS API that provides:
- The trust domain's root certificates
- JWT signing keys
- Regular updates as keys rotate

### SPIFFE Authentication Profile

The `https_spiffe` profile uses SPIFFE credentials for mutual authentication:
- The client (requesting SPIRE server) presents its SVID
- The server (bundle endpoint) verifies the client's SVID
- The server presents its SVID for verification
- Both sides use their trust bundles for verification

### federatesWith

The `federatesWith` field in registration entries:
- Specifies which foreign trust domains a workload should trust
- Causes the SPIRE agent to provide the workload with federated trust bundles
- Enables the workload to verify SVIDs from the federated trust domain

## Troubleshooting

### Bundle Endpoint Not Accessible

**Symptom**: ClusterFederatedTrustDomain created but bundle not updating

**Check**:
```bash
# Verify route is accessible
curl -k https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-X.devcluster.openshift.com

# Check SPIRE server logs
kubectl --kubeconfig /path/to/clusterX/kubeconfig logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server
```

### Registration Entries Not Created

**Symptom**: ClusterSPIFFEID exists but entries not showing in SPIRE server

**Check**:
```bash
# Verify ClusterSPIFFEID status
kubectl --kubeconfig /path/to/clusterX/kubeconfig get clusterspiffeid RESOURCE_NAME -o yaml

# Check SPIRE controller-manager logs
kubectl --kubeconfig /path/to/clusterX/kubeconfig logs -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-controller-manager
```

### Workloads Not Receiving Federated Bundles

**Symptom**: Workload has SVID but no federated trust bundle

**Check**:
```bash
# Verify federatesWith in entry
kubectl --kubeconfig /path/to/clusterX/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show

# Check SPIRE agent logs
kubectl --kubeconfig /path/to/clusterX/kubeconfig logs -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent
```

## References

- [SPIFFE Federation Specification](https://spiffe.io/docs/latest/architecture/federation/readme/)
- [SPIRE Federation Documentation](https://spiffe.io/docs/latest/spire-helm-charts-hardened-advanced/federation/)
- [ClusterFederatedTrustDomain CRD Documentation](https://github.com/spiffe/spire-controller-manager/blob/main/docs/clusterfederatedtrustdomain-crd.md)
- [Zero Trust Workload Identity Manager](https://github.com/openshift/zero-trust-workload-identity-manager)

## Conclusion

SPIRE federation has been successfully configured between the two OpenShift clusters. Workloads in each cluster can now:
1. Obtain their own SPIFFE identities from their local SPIRE server
2. Receive trust bundles from federated trust domains
3. Verify identities from workloads in other trust domains
4. Establish mutual TLS connections across clusters

The federation is fully operational and will automatically maintain trust bundle updates as certificates rotate.

