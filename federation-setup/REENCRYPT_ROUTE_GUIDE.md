# Converting Federation Routes from Passthrough to Reencrypt

## Overview

This guide explains how to convert the SPIRE federation routes from **passthrough** to **reencrypt** termination.

## Important Considerations

### ⚠️ Critical Impact on SPIFFE Authentication

**Current Setup (Passthrough):**
- OpenShift router passes TLS connection directly to SPIRE server
- SPIRE server performs SPIFFE authentication using mTLS
- End-to-end SPIFFE identity verification maintained

**Reencrypt Setup:**
- Router terminates the incoming TLS connection at the edge
- Router re-establishes a new TLS connection to the backend
- **This breaks SPIFFE mTLS authentication** because:
  - The original client certificate (with SPIFFE ID) is terminated at the router
  - SPIRE server receives connections from the router, not the original client
  - SPIFFE identity chain is broken

### When to Use Reencrypt

Reencrypt is useful when you need:
- Certificate management at the router level
- Different certificates for external vs internal traffic
- Router-level traffic inspection or policies
- Integration with enterprise PKI/certificate management

### Alternative Approaches

If you need reencrypt but want to maintain SPIFFE authentication, consider:

1. **Switch to Web PKI Authentication:**
   - Modify SPIRE federation to use `https_web` profile instead of `https_spiffe`
   - Use standard TLS certificates validated by traditional CAs
   - Loses the benefits of SPIFFE identity-based authentication

2. **Use Edge Route with Backend Passthrough:**
   - Edge termination at router for external traffic
   - Internal services maintain SPIFFE authentication
   - Requires architectural changes

## Changes Required for Reencrypt

### 1. Certificate Requirements

For reencrypt routes, you need:

**At the Router (Edge):**
- TLS certificate for the route hostname
- Private key for the certificate
- CA certificate that signed the route certificate

**At the Backend (SPIRE Server):**
- Destination CA certificate (SPIRE server's CA)

### 2. Certificate Preparation

#### Option A: Use OpenShift Service Serving Certificates

OpenShift can automatically generate certificates for services:

```bash
# Annotate the service to generate certificates
kubectl annotate service spire-server-federation \
  -n zero-trust-workload-identity-manager \
  service.beta.openshift.io/serving-cert-secret-name=spire-federation-tls
```

This creates a secret `spire-federation-tls` with:
- `tls.crt` - The certificate
- `tls.key` - The private key

#### Option B: Provide Your Own Certificates

Create a secret with your own certificates:

```bash
kubectl create secret tls spire-federation-tls \
  -n zero-trust-workload-identity-manager \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key
```

### 3. Get SPIRE Server CA Certificate

Extract the SPIRE server's CA certificate:

```bash
# Get the SPIRE bundle (CA certificate)
kubectl get configmap spire-bundle \
  -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.bundle\.crt}' > spire-ca.crt
```

### 4. Updated Route Configuration

Here's the reencrypt route configuration:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-federation
  namespace: zero-trust-workload-identity-manager
  labels:
    app.kubernetes.io/name: spire-server
    app.kubernetes.io/component: control-plane
spec:
  to:
    kind: Service
    name: spire-server-federation
    weight: 100
  port:
    targetPort: federation
  tls:
    termination: reencrypt
    # Certificate for the route (edge/external)
    certificate: |
      -----BEGIN CERTIFICATE-----
      <your-route-certificate>
      -----END CERTIFICATE-----
    key: |
      -----BEGIN PRIVATE KEY-----
      <your-route-private-key>
      -----END PRIVATE KEY-----
    caCertificate: |
      -----BEGIN CERTIFICATE-----
      <ca-that-signed-route-certificate>
      -----END CERTIFICATE-----
    # CA certificate of the backend service (SPIRE server)
    destinationCACertificate: |
      -----BEGIN CERTIFICATE-----
      <spire-server-ca-certificate>
      -----END CERTIFICATE-----
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
```

### 5. Update SPIRE Federation Configuration

If using reencrypt, you'll need to change the federation profile from `https_spiffe` to `https_web`:

**Current configuration:**
```json
"federates_with": {
  "apps.cluster-2.devcluster.openshift.com": {
    "bundle_endpoint_url": "https://...",
    "bundle_endpoint_profile": {
      "https_spiffe": {
        "endpoint_spiffe_id": "spiffe://apps.cluster-2.devcluster.openshift.com/spire/server"
      }
    }
  }
}
```

**Updated configuration for reencrypt:**
```json
"federates_with": {
  "apps.cluster-2.devcluster.openshift.com": {
    "bundle_endpoint_url": "https://...",
    "bundle_endpoint_profile": {
      "https_web": {}
    }
  }
}
```

## Implementation Steps

### Step 1: Backup Current Configuration

```bash
# Export current routes
kubectl get route spire-server-federation \
  -n zero-trust-workload-identity-manager \
  -o yaml > route-backup.yaml
```

### Step 2: Generate/Prepare Certificates

Choose either OpenShift Service Serving Certificates or provide your own.

### Step 3: Extract SPIRE CA

```bash
# For Cluster 1
kubectl --kubeconfig /home/rausingh/Downloads/kubeconfig \
  get configmap spire-bundle \
  -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.bundle\.crt}' > cluster1-spire-ca.crt

# For Cluster 2
kubectl --kubeconfig /home/rausingh/Downloads/kubeconfiganirudh \
  get configmap spire-bundle \
  -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.bundle\.crt}' > cluster2-spire-ca.crt
```

### Step 4: Create Route Certificates Secret (if using your own certs)

```bash
# Cluster 1
kubectl --kubeconfig /home/rausingh/Downloads/kubeconfig \
  create secret tls spire-route-tls \
  -n zero-trust-workload-identity-manager \
  --cert=cluster1-route.crt \
  --key=cluster1-route.key

# Cluster 2
kubectl --kubeconfig /home/rausingh/Downloads/kubeconfiganirudh \
  create secret tls spire-route-tls \
  -n zero-trust-workload-identity-manager \
  --cert=cluster2-route.crt \
  --key=cluster2-route.key
```

### Step 5: Update Routes with Reencrypt Configuration

Apply the updated route configurations (see template files created below).

### Step 6: Update SPIRE Server Configuration

Update the SPIRE server ConfigMaps to use `https_web` profile instead of `https_spiffe`.

### Step 7: Restart SPIRE Servers

```bash
# Cluster 1
kubectl --kubeconfig /home/rausingh/Downloads/kubeconfig \
  rollout restart statefulset spire-server \
  -n zero-trust-workload-identity-manager

# Cluster 2
kubectl --kubeconfig /home/rausingh/Downloads/kubeconfiganirudh \
  rollout restart statefulset spire-server \
  -n zero-trust-workload-identity-manager
```

### Step 8: Verify Federation

```bash
# Check if bundles are being fetched
kubectl --kubeconfig /home/rausingh/Downloads/kubeconfig \
  logs -n zero-trust-workload-identity-manager \
  statefulset/spire-server -c spire-server | grep -i federation
```

## Testing

Test the federation endpoint:

```bash
# Get the route URL
ROUTE_URL=$(kubectl get route spire-server-federation \
  -n zero-trust-workload-identity-manager \
  -o jsonpath='https://{.spec.host}')

# Test the endpoint
curl -v $ROUTE_URL
```

## Rollback

If you need to rollback to passthrough:

```bash
kubectl apply -f route-backup.yaml
```

## Troubleshooting

### Routes Not Working

1. Check route status:
   ```bash
   kubectl get route spire-server-federation -n zero-trust-workload-identity-manager -o yaml
   ```

2. Check router logs:
   ```bash
   kubectl logs -n openshift-ingress deployment/router-default
   ```

### Federation Not Updating Bundles

1. Check SPIRE server logs:
   ```bash
   kubectl logs -n zero-trust-workload-identity-manager statefulset/spire-server -c spire-server
   ```

2. Verify the federation configuration in ConfigMap
3. Ensure the route is accessible from the other cluster

## Recommendation

**⚠️ For SPIRE Federation, we recommend keeping passthrough termination** because:

1. Maintains end-to-end SPIFFE identity verification
2. No need to manage additional certificates at the router
3. Better security model for zero-trust architectures
4. Simpler certificate rotation (handled by SPIRE)

Use reencrypt only if you have specific requirements for certificate management at the router level and understand the implications for SPIFFE authentication.



