# Federation Test Scripts

This directory contains automated test scripts to verify SPIRE federation is working correctly.

## Quick Start

```bash
# Run all tests
./test-federation.sh

# Show workload bundle comparison
./show-workload-bundles.sh

# Or run individual tests below
```

## Available Tests

### 1. `test-federation.sh` - Comprehensive Federation Test

Runs all federation tests in sequence:
- ✅ Trust bundle exchange verification
- ✅ Federated registration entries check
- ✅ Bundle rotation history analysis
- ✅ Real-time rotation monitoring (90 seconds)

**Usage:**
```bash
./test-federation.sh
```

**Expected Output:** All tests should pass with "Bundle refreshed" messages

### 2. `show-workload-bundles.sh` - Bundle Comparison

Shows the difference between federated and non-federated workloads:
- Displays registration entries side-by-side
- Shows which bundles each workload type receives
- Explains impact on cross-cluster communication
- Proves rotation is continuous

**Usage:**
```bash
./show-workload-bundles.sh
```

**Expected Output:** Clear distinction between federated (has 2+ bundles) vs non-federated (has 1 bundle)

### 3. Manual Verification Commands

```bash
# Check trust bundles in Cluster 1
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list

# Check trust bundles in Cluster 2
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list

# Watch live bundle rotation
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh"
```

## Test Results Documentation

After running tests, see:
- `../TEST_RESULTS.md` - Detailed test results with timestamps
- `../PROOF_OF_WORKING_FEDERATION.md` - Visual proof of working federation
- `../TESTING_GUIDE.md` - Manual testing procedures

## What To Look For

### ✅ Federation is Working
- Each cluster lists the OTHER cluster's trust domain in `bundle list`
- "Bundle refreshed" messages appear every ~75 seconds
- Federated entries show `FederatesWith` field
- No "Error updating bundle" messages

### ❌ Federation is NOT Working
- Only local trust domain appears in `bundle list`
- "Error updating bundle" in logs
- No bundle refresh messages
- ClusterFederatedTrustDomain exists but bundles not updating

## Troubleshooting

If tests fail, check:
1. `federates_with` block is in SPIRE server ConfigMap
2. Port 8443 is exposed on SPIRE server pods
3. Federation routes are accessible
4. SPIRE servers have been restarted after config changes

See `../TESTING_GUIDE.md` for detailed troubleshooting steps.

