# 🔧 Guide: Removing a Cluster from SPIRE Federation

This guide explains how to safely remove a cluster from an existing SPIRE federation setup.

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Automated Method (Recommended)](#automated-method-recommended)
4. [Manual Method](#manual-method)
5. [Verification](#verification)
6. [Troubleshooting](#troubleshooting)
7. [Important Considerations](#important-considerations)

---

## Overview

When you remove a cluster from federation, the following changes occur:

### On the Removed Cluster:
- ✅ All `ClusterFederatedTrustDomain` resources are deleted
- ✅ Federation route and service are removed
- ✅ SPIRE server configuration is updated to remove federation settings
- ✅ SPIRE server is restarted
- ✅ Cluster continues to operate independently with its own SPIRE setup

### On Remaining Clusters:
- ✅ `ClusterFederatedTrustDomain` resources pointing to removed cluster are deleted
- ✅ Removed cluster's trust domain is removed from `federates_with` configuration
- ✅ SPIRE servers are restarted to apply changes
- ✅ Trust bundles for removed cluster are no longer refreshed
- ✅ Federation continues to work between remaining clusters

---

## Prerequisites

Before removing a cluster from federation, ensure:

1. **Backup Configuration**: Save current federation setup
   ```bash
   # For each cluster
   kubectl get clusterfederatedtrustdomain -o yaml > backup-cftd.yaml
   kubectl get configmap spire-server -n zero-trust-workload-identity-manager -o yaml > backup-spire-config.yaml
   ```

2. **Identify Dependent Workloads**: Check which workloads depend on the cluster being removed
   ```bash
   # Search for ClusterSPIFFEID resources that federate with the cluster
   kubectl get clusterspiffeid -A -o yaml | grep -A 5 "federatesWith"
   ```

3. **Access to All Clusters**: Have kubeconfig files for:
   - The cluster you want to remove
   - All remaining clusters in the federation

4. **Maintenance Window**: Plan for brief service interruption (SPIRE server restarts take ~30-60 seconds)

---

## Automated Method (Recommended)

### Option 1: Using the Removal Script

The easiest way to remove a cluster is using our automated script:

```bash
cd /home/rausingh/Documents/oape/ztwim-poc/federation-setup

# Make script executable
chmod +x remove-cluster-from-federation.sh

# Remove cluster3 from a 3-cluster federation
./remove-cluster-from-federation.sh \
  --remove /path/to/cluster3/kubeconfig \
  --from /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig
```

**What it does:**
1. ✅ Gathers cluster information and trust domains
2. ✅ Cleans up the removed cluster
3. ✅ Updates all remaining clusters
4. ✅ Restarts SPIRE servers
5. ✅ Provides verification commands

**Runtime:** 2-3 minutes

---

## Manual Method

If you prefer to remove a cluster manually or need to understand the process:

### Step 1: Clean Up the Cluster Being Removed

On the cluster you want to remove:

```bash
export CLUSTER_TO_REMOVE=/path/to/cluster/kubeconfig

# 1. Delete all ClusterFederatedTrustDomain resources
kubectl --kubeconfig $CLUSTER_TO_REMOVE delete clusterfederatedtrustdomain --all

# 2. Delete federation route and service
kubectl --kubeconfig $CLUSTER_TO_REMOVE delete route spire-server-federation \
  -n zero-trust-workload-identity-manager --ignore-not-found

kubectl --kubeconfig $CLUSTER_TO_REMOVE delete service spire-server-federation \
  -n zero-trust-workload-identity-manager --ignore-not-found

# 3. Edit SPIRE server ConfigMap to remove federation block
kubectl --kubeconfig $CLUSTER_TO_REMOVE edit configmap spire-server \
  -n zero-trust-workload-identity-manager

# In the editor, remove the entire "federation" section from server.conf:
# Delete these lines:
#   "federation": {
#     "bundle_endpoint": { ... },
#     "federates_with": { ... }
#   }

# 4. Restart SPIRE server
kubectl --kubeconfig $CLUSTER_TO_REMOVE rollout restart statefulset spire-server \
  -n zero-trust-workload-identity-manager

# 5. Wait for restart
kubectl --kubeconfig $CLUSTER_TO_REMOVE wait --for=condition=ready \
  pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s
```

### Step 2: Update Each Remaining Cluster

For **each** cluster that remains in the federation:

```bash
export REMAINING_CLUSTER=/path/to/remaining/cluster/kubeconfig
export REMOVED_TRUST_DOMAIN="apps.removed-cluster.example.com"

# 1. Find and delete ClusterFederatedTrustDomain for removed cluster
# First, list all CFTDs and identify the one for removed cluster
kubectl --kubeconfig $REMAINING_CLUSTER get clusterfederatedtrustdomain

# Delete the CFTD (replace <name> with actual resource name)
kubectl --kubeconfig $REMAINING_CLUSTER delete clusterfederatedtrustdomain <name>

# 2. Edit SPIRE server ConfigMap
kubectl --kubeconfig $REMAINING_CLUSTER edit configmap spire-server \
  -n zero-trust-workload-identity-manager

# In the editor, remove the removed cluster from "federates_with":
# Remove the block like:
#   "apps.removed-cluster.example.com": {
#     "bundle_endpoint_url": "...",
#     "bundle_endpoint_profile": { ... }
#   }

# 3. Restart SPIRE server
kubectl --kubeconfig $REMAINING_CLUSTER rollout restart statefulset spire-server \
  -n zero-trust-workload-identity-manager

# 4. Wait for restart
kubectl --kubeconfig $REMAINING_CLUSTER wait --for=condition=ready \
  pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s
```

Repeat Step 2 for **each** remaining cluster in the federation.

### Step 3: Update Workload Configurations (if needed)

If any workloads on remaining clusters have `federatesWith` entries for the removed cluster:

```bash
# Find affected ClusterSPIFFEID resources
kubectl get clusterspiffeid -A -o yaml | grep -B 10 "$REMOVED_TRUST_DOMAIN"

# Edit each affected resource
kubectl edit clusterspiffeid <name>

# Remove the removed trust domain from the federatesWith list:
# Before:
#   federatesWith:
#   - "apps.cluster1.example.com"
#   - "apps.removed-cluster.example.com"  ← Remove this line
#   - "apps.cluster3.example.com"
#
# After:
#   federatesWith:
#   - "apps.cluster1.example.com"
#   - "apps.cluster3.example.com"
```

---

## Verification

After removal, verify the changes:

### 1. Verify Removed Cluster

```bash
export REMOVED_CLUSTER=/path/to/removed/cluster/kubeconfig

# Should show: No resources found
kubectl --kubeconfig $REMOVED_CLUSTER get clusterfederatedtrustdomain

# Should show only its own trust domain
kubectl --kubeconfig $REMOVED_CLUSTER exec -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server -- ./spire-server bundle list

# Should show no federation configuration
kubectl --kubeconfig $REMOVED_CLUSTER get configmap spire-server \
  -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}' | \
  grep -A 20 "federation" || echo "No federation config found (expected)"
```

### 2. Verify Each Remaining Cluster

```bash
export REMAINING_CLUSTER=/path/to/remaining/cluster/kubeconfig
export REMOVED_TRUST_DOMAIN="apps.removed-cluster.example.com"

# Should NOT list the removed cluster
kubectl --kubeconfig $REMAINING_CLUSTER get clusterfederatedtrustdomain

# Should NOT show removed cluster's trust domain
kubectl --kubeconfig $REMAINING_CLUSTER exec -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server -- ./spire-server bundle list | \
  grep "$REMOVED_TRUST_DOMAIN" && echo "ERROR: Still has removed cluster's bundle" || echo "✓ Removed cluster's bundle not present"

# Check federates_with configuration
kubectl --kubeconfig $REMAINING_CLUSTER get configmap spire-server \
  -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}' | \
  python3 -c "
import json, sys
config = json.load(sys.stdin)
fed_with = config.get('server', {}).get('federation', {}).get('federates_with', {})
if '$REMOVED_TRUST_DOMAIN' in fed_with:
    print('ERROR: Still has removed cluster in federates_with')
    sys.exit(1)
else:
    print('✓ Removed cluster not in federates_with')
"
```

### 3. Test Remaining Federation

If you have 2 or more clusters remaining, verify they can still federate:

```bash
# On any remaining cluster, check bundle list (should show other remaining clusters)
kubectl --kubeconfig /path/to/cluster1/kubeconfig exec -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server -- ./spire-server bundle list

# Watch bundle rotation (should see refreshes every ~75 seconds)
kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -f \
  -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep "Bundle refresh"
```

---

## Troubleshooting

### Issue: ClusterFederatedTrustDomain Won't Delete

**Symptoms:**
```bash
kubectl delete clusterfederatedtrustdomain <name>
# Hangs or shows "deleting..."
```

**Solution:**
```bash
# Remove finalizers
kubectl patch clusterfederatedtrustdomain <name> \
  -p '{"metadata":{"finalizers":[]}}' --type=merge

# Try delete again
kubectl delete clusterfederatedtrustdomain <name>
```

### Issue: SPIRE Server Won't Restart

**Symptoms:**
- Pod stuck in `Terminating` state
- New pod not starting

**Solution:**
```bash
# Check pod status
kubectl get pods -n zero-trust-workload-identity-manager

# View logs
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server

# Force delete if stuck
kubectl delete pod spire-server-0 -n zero-trust-workload-identity-manager --force --grace-period=0

# Check StatefulSet
kubectl describe statefulset spire-server -n zero-trust-workload-identity-manager
```

### Issue: Bundle Still Showing on Remaining Clusters

**Symptoms:**
- Removed cluster's trust domain still appears in bundle list

**Solution:**
```bash
# This is actually expected initially
# Bundles will naturally expire after ~1 hour of no refresh
# To force removal:

# Option 1: Wait for natural expiration (recommended)
# Check expiration time in bundle
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle show -format spiffe | grep -A 50 "$REMOVED_TRUST_DOMAIN"

# Option 2: Manually delete bundle (use with caution)
# This will immediately break any workloads still trying to use it
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle delete -id "$REMOVED_TRUST_DOMAIN"
```

### Issue: ConfigMap Edit Fails

**Symptoms:**
- Error applying ConfigMap changes
- JSON parsing errors

**Solution:**
```bash
# Extract current config
kubectl get configmap spire-server -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.server\.conf}' > current-config.json

# Validate JSON
python3 -m json.tool current-config.json

# Edit with care (ensure valid JSON)
# Use a proper JSON editor or Python script to modify

# Apply changes
kubectl create configmap spire-server \
  --from-file=server.conf=current-config.json \
  -n zero-trust-workload-identity-manager \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Important Considerations

### Federation Topology

**2-Cluster Federation → 1-Cluster:**
- After removing one cluster, the remaining cluster has no federation
- Consider removing all federation config from the last cluster

**3+ Cluster Federation → N-1 Clusters:**
- Remaining clusters continue to federate with each other
- Update mesh if you had full mesh topology

### Workload Impact

**Immediate Impact:**
- ❌ Workloads on remaining clusters cannot communicate with workloads on removed cluster
- ❌ mTLS validation fails for any attempts
- ✅ Workloads on remaining clusters can still communicate with each other
- ✅ Intra-cluster workloads are unaffected

**Grace Period:**
- Trust bundles remain valid until they expire (~1 hour)
- During this time, existing connections may continue
- New connections will fail immediately

### Re-adding a Cluster

If you need to re-add a removed cluster to federation:

1. **Clean State**: Ensure the cluster has no stale federation config
2. **Use Setup Script**: Run the original federation setup as if it's a new cluster
3. **For 3+ Clusters**: Use `add-third-cluster.sh` or similar

```bash
# To re-add to a 2-cluster federation
./setup-federation.sh /path/to/existing/cluster/kubeconfig /path/to/readd/cluster/kubeconfig

# To add as third cluster
./add-third-cluster.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig /path/to/readd/cluster/kubeconfig
```

### Data Preservation

**What is Preserved:**
- ✅ SPIRE server database on all clusters
- ✅ Existing workload registrations (ClusterSPIFFEID resources)
- ✅ Intra-cluster identities and SVIDs
- ✅ Remaining federation relationships

**What is Removed:**
- ❌ Cross-cluster trust for removed cluster
- ❌ Bundle refresh for removed cluster
- ❌ Federation routes and services

---

## Quick Reference Commands

### Complete Removal (Automated)

```bash
./remove-cluster-from-federation.sh \
  --remove /path/to/removed/kubeconfig \
  --from /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig
```

### Verification Summary

```bash
# Check removed cluster
kubectl --kubeconfig $REMOVED_CLUSTER get clusterfederatedtrustdomain
kubectl --kubeconfig $REMOVED_CLUSTER exec -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server -- ./spire-server bundle list

# Check remaining clusters
kubectl --kubeconfig $REMAINING_CLUSTER get clusterfederatedtrustdomain
kubectl --kubeconfig $REMAINING_CLUSTER exec -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server -- ./spire-server bundle list
```

---

## Related Documentation

- **Federation Setup**: `setup-federation.sh` - Initial 2-cluster setup
- **Add Third Cluster**: `add-third-cluster.sh` - Expand federation
- **Complete Cleanup**: `cleanup-federation.sh` - Remove all federation
- **Three-Way Federation**: `THREE_WAY_FEDERATION_QUICK_REFERENCE.md`
- **General Documentation**: `FEDERATION_SETUP_DOCUMENTATION.md`

---

## Summary

Removing a cluster from SPIRE federation is a straightforward process:

1. ✅ Use the automated script for safest removal
2. ✅ Verify changes on all clusters
3. ✅ Update workload configurations if needed
4. ✅ Remaining clusters continue to federate with each other
5. ✅ Removed cluster operates independently

**Total time:** 2-3 minutes with automated script, 10-15 minutes manually.

**Impact:** Minimal - only affects cross-cluster communication with the removed cluster.

---

**Need help?** Check the troubleshooting section or refer to the complete federation documentation.

