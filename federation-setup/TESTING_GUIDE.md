# SPIRE Federation Testing Guide

This guide shows how to test and prove that SPIRE federation is working correctly between your two OpenShift clusters.

## Prerequisites

Clusters:
- **Cluster 1**: `/home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig`
- **Cluster 2**: `/home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig`

## Test 1: Verify Trust Bundle Exchange

This proves that both clusters have each other's trust bundles.

### Cluster 1 - Check for Cluster 2's Bundle

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list
```

**Expected Output:**
```
****************************************
* apps.cluster-2.devcluster.openshift.com
****************************************
-----BEGIN CERTIFICATE-----
MIIEBjCCAu6gAwIBAgIRAJJN...
-----END CERTIFICATE-----
```

### Cluster 2 - Check for Cluster 1's Bundle

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list
```

**Expected Output:**
```
****************************************
* apps.cluster-1.devcluster.openshift.com
****************************************
-----BEGIN CERTIFICATE-----
MIIEBjCCAu6gAwIBAgIRAOqc...
-----END CERTIFICATE-----
```

✅ **Success Criteria**: Each cluster lists the OTHER cluster's trust domain and certificate.

---

## Test 2: Verify Federated Registration Entries

This proves that workloads have `federatesWith` configured.

### Check Federated Entries in Cluster 1

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show
```

**Expected Output (look for):**
```
SPIFFE ID        : spiffe://apps.cluster-1.devcluster.openshift.com/ns/federation-test/sa/federated-frontend
...
FederatesWith    : apps.cluster-2.devcluster.openshift.com
```

### Check Federated Entries in Cluster 2

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show
```

**Expected Output (look for):**
```
SPIFFE ID        : spiffe://apps.cluster-2.devcluster.openshift.com/ns/federation-test/sa/federated-backend
...
FederatesWith    : apps.cluster-1.devcluster.openshift.com
```

✅ **Success Criteria**: Entries show `FederatesWith` pointing to the other trust domain.

---

## Test 3: Prove Automatic Bundle Rotation

This is the CRITICAL test that proves the `federates_with` configuration is working.

### View Bundle Refresh History

```bash
# Cluster 1 - Show bundle refresh activity
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 | \
  grep -E "(Trust domain is now managed|Bundle refresh|Scheduling next)"
```

**Expected Output:**
```
time="2025-10-09T10:50:22Z" level=info msg="Trust domain is now managed" 
                                          bundle_endpoint_url="https://...cluster-2..." 
                                          trust_domain=apps.cluster-2.devcluster.openshift.com

time="2025-10-09T10:50:22Z" level=info msg="Bundle refreshed" 
                                          trust_domain=apps.cluster-2.devcluster.openshift.com

time="2025-10-09T10:51:37Z" level=info msg="Bundle refreshed" 
                                          trust_domain=apps.cluster-2.devcluster.openshift.com
                                          
time="2025-10-09T10:51:37Z" level=debug msg="Scheduling next bundle refresh" 
                                           at="2025-10-09T10:52:52Z"
```

```bash
# Cluster 2 - Show bundle refresh activity
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 | \
  grep -E "(Trust domain is now managed|Bundle refresh|Scheduling next)"
```

### Watch Bundle Rotation in Real-Time

Open 2 terminals and run these commands simultaneously to see live bundle refreshes:

**Terminal 1 - Cluster 1:**
```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh"
```

**Terminal 2 - Cluster 2:**
```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh"
```

Wait ~5 minutes and you'll see:
```
time="..." level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=apps.cluster-X.devcluster.openshift.com
```

✅ **Success Criteria**: 
- Multiple "Bundle refreshed" messages appear
- "Scheduling next bundle refresh" shows future refresh times
- Refreshes happen automatically every ~5 minutes

---

## Test 4: Federated vs Non-Federated Workloads

This demonstrates the difference between workloads with and without federation.

### Deploy Test Workloads

```bash
# Cluster 2 - Deploy backends
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  apply -f federation-setup/test-workloads/01-federated-backend.yaml

# Cluster 1 - Deploy frontends  
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  apply -f federation-setup/test-workloads/02-federated-frontend.yaml
```

### Verify Federated Workload Has Both Bundles

```bash
# Check what bundles the federated frontend receives
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n federation-test -l app=federated-frontend --tail=100
```

**Expected Output:**
```
My SPIFFE ID:
  URI:spiffe://apps.cluster-1.devcluster.openshift.com/ns/federation-test/sa/federated-frontend

Trust bundles available:
------------------------
2 certificates in bundle

Trust domain from cert:
  URI:spiffe://apps.cluster-1.devcluster.openshift.com  (own domain)
  
Trust domain from cert:
  URI:spiffe://apps.cluster-2.devcluster.openshift.com  (FEDERATED domain)
```

### Verify Non-Federated Workload Has Only Its Own Bundle

Create a non-federated workload:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: non-federated-test
spec:
  spiffeIDTemplate: "spiffe://apps.cluster-1.devcluster.openshift.com/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: non-federated-test
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: federation-test
  # NOTE: NO federatesWith field
  className: zero-trust-workload-identity-manager-spire
```

**Expected Output:**
```
Trust bundles available:
------------------------
1 certificate in bundle  (only own domain, no federated bundles)
```

✅ **Success Criteria**: 
- Federated workload has 2+ certificates in bundle (own + federated)
- Non-federated workload has only 1 certificate (own domain only)

---

## Test 5: Cross-Cluster mTLS Communication

### Test Commands

Create a simple test pod in Cluster 1:

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  run test-client -n federation-test --rm -it --image=alpine -- sh
```

Inside the pod:
```bash
# Install tools
apk add openssl curl

# Try to connect to backend in Cluster 2 (will fail without SPIFFE)
curl -k https://federated-backend.federation-test.svc.cluster.local:8443
```

This will fail because we're not using SPIFFE credentials for mTLS.

### Proper Test with SPIFFE Workload API

The workloads deployed earlier automatically test this. Check logs:

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n federation-test -l app=federated-frontend -f
```

---

## Automated Test Script

Run the comprehensive test script:

```bash
chmod +x federation-setup/test-scripts/test-federation.sh
./federation-setup/test-scripts/test-federation.sh
```

This script automatically:
1. Verifies trust bundle exchange
2. Checks federated registration entries  
3. Proves bundle rotation is active
4. Monitors for real-time bundle refreshes

---

## Expected Results Summary

### ✅ Federation is Working If:

1. **Trust Bundles Exchanged**
   - Cluster 1 has Cluster 2's bundle
   - Cluster 2 has Cluster 1's bundle

2. **Registration Entries Show Federation**
   - Entries have `FederatesWith` field
   - Points to the correct federated trust domain

3. **Automatic Rotation is Active**
   - Log shows "Trust domain is now managed"
   - Multiple "Bundle refreshed" messages
   - "Scheduling next bundle refresh" shows future times
   - Refreshes happen every ~5 minutes automatically

4. **Workloads Receive Federated Bundles**
   - Federated workloads get multiple trust domain certificates
   - Non-federated workloads get only their own domain certificate

5. **mTLS Communication Works**
   - Federated workloads can verify each other's SVIDs
   - Non-federated workloads cannot verify cross-cluster SVIDs

### ❌ Federation is NOT Working If:

- Only one cluster has bundles (not exchanged)
- No "Bundle refreshed" messages in logs
- Only "Error updating bundle" messages
- No `FederatesWith` in registration entries
- Workloads only have 1 certificate in bundle regardless of configuration

---

## Troubleshooting

### Issue: No Bundle Refreshes

**Check:**
```bash
# Verify federates_with is in config
kubectl --kubeconfig /path/to/kubeconfig get configmap spire-server \
  -n zero-trust-workload-identity-manager -o yaml | grep -A 10 "federates_with"
```

**Fix:** Ensure `federates_with` block is present in SPIRE server config.

### Issue: "Error updating bundle"

**Check:**
```bash
# Check if federation endpoint is accessible
kubectl --kubeconfig /path/to/kubeconfig get route spire-server-federation \
  -n zero-trust-workload-identity-manager
```

**Test connectivity:**
```bash
curl -k https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-X.devcluster.openshift.com
```

---

## Continuous Monitoring

Set up continuous monitoring to ensure federation stays healthy:

```bash
# Monitor bundle refreshes in real-time
watch -n 60 'kubectl --kubeconfig /path/to/cluster1/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=10 | \
  grep "Bundle refresh"'
```

This will show you that bundles are being refreshed regularly, proving that automatic rotation is working.

