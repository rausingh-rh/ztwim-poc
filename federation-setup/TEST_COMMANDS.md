# 🧪 Self-Test Commands - Run These Yourself!

Copy and paste these commands to verify federation is working.

---

## 🔍 Test 1: Check Federation Bundle Endpoints Are Exposed

### Test Cluster 1's Federation Endpoint

```bash
# Get the route URL
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  get route spire-server-federation -n zero-trust-workload-identity-manager \
  -o jsonpath='https://{.spec.host}'

# Test the endpoint with curl (it will fail auth but proves it's accessible)
curl -k -v https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-1.devcluster.openshift.com 2>&1 | head -20
```

**Expected**: Connection succeeds, might get auth error (that's OK - proves endpoint is up)

### Test Cluster 2's Federation Endpoint

```bash
# Get the route URL
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  get route spire-server-federation -n zero-trust-workload-identity-manager \
  -o jsonpath='https://{.spec.host}'

# Test the endpoint
curl -k -v https://spire-server-federation-zero-trust-workload-identity-manager.apps.cluster-2.devcluster.openshift.com 2>&1 | head -20
```

---

## ✅ Test 2: Verify Trust Bundles Are Exchanged

### Check Cluster 1 Has Cluster 2's Bundle

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
...
-----END CERTIFICATE-----
```

✅ If you see `apps.cluster-2.devcluster.openshift.com`, federation is working!

### Check Cluster 2 Has Cluster 1's Bundle

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
...
-----END CERTIFICATE-----
```

✅ If you see `apps.cluster-1.devcluster.openshift.com`, federation is working!

---

## 🔄 Test 3: Watch Bundle Rotation Happening LIVE

### Method 1: Watch for Next Refresh (Wait ~75 seconds)

```bash
# This will show you bundles refreshing in REAL-TIME
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh"
```

**Expected Output** (appears every ~75 seconds):
```
time="2025-10-09T..." level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=apps.cluster-2.devcluster.openshift.com
```

**Keep this running** - you'll see new refreshes happening automatically!

### Method 2: Check Recent Refresh History

```bash
# Show last 10 bundle refreshes in Cluster 1
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 | \
  grep "Bundle refreshed" | tail -10
```

**Expected Output:**
```
time="..." level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=apps.cluster-2...
time="..." level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=apps.cluster-2...
... (multiple entries with increasing timestamps)
```

✅ If you see multiple refreshes with timestamps ~75 seconds apart, rotation is working!

### Method 3: Check When Next Refresh is Scheduled

```bash
# See when the next automatic refresh will happen
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 | \
  grep "Scheduling next bundle refresh"
```

**Expected Output:**
```
time="..." level=debug msg="Scheduling next bundle refresh" at="2025-10-09T..." subsystem_name=bundle_client
```

✅ This shows a future timestamp when the next automatic refresh will happen!

---

## 📋 Test 4: Compare Federated vs Non-Federated Entries

### Show Federated Entry (Has FederatesWith)

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show | grep -A 15 "federated-backend"
```

**Expected Output:**
```
Entry ID         : cluster-2.9d3b8ab4...
SPIFFE ID        : spiffe://apps.cluster-2.../sa/federated-backend
Parent ID        : spiffe://apps.cluster-2.../spire/agent/k8s_psat/...
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : k8s:pod-uid:...
FederatesWith    : apps.cluster-1.devcluster.openshift.com  ← LOOK HERE!
```

✅ Look for `FederatesWith` field - proves workload gets federated bundles!

### Show Non-Federated Entry (No FederatesWith)

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show | grep -A 15 "non-federated-backend"
```

**Expected Output:**
```
Entry ID      : cluster-2.c27bfecd...
SPIFFE ID     : spiffe://apps.cluster-2.../sa/non-federated-backend
Parent ID     : spiffe://apps.cluster-2.../spire/agent/k8s_psat/...
Revision      : 0
X509-SVID TTL : default
JWT-SVID TTL  : default
Selector      : k8s:pod-uid:...
(No FederatesWith field)  ← NO FEDERATION!
```

✅ Notice NO `FederatesWith` field - workload only gets own domain bundle!

---

## 🎬 Test 5: Watch BOTH Clusters Rotating Simultaneously

### Open 2 Terminals Side-by-Side

**Terminal 1 (Cluster 1):**
```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh" | \
  while read line; do echo "[CLUSTER 1] $(date '+%H:%M:%S') - $line"; done
```

**Terminal 2 (Cluster 2):**
```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh" | \
  while read line; do echo "[CLUSTER 2] $(date '+%H:%M:%S') - $line"; done
```

**You'll see** (every ~75 seconds):
```
[CLUSTER 1] 17:45:24 - Bundle refreshed
[CLUSTER 2] 17:45:26 - Bundle refreshed
  (wait ~75 seconds...)
[CLUSTER 1] 17:46:38 - Bundle refreshed
[CLUSTER 2] 17:46:40 - Bundle refreshed
```

✅ **This is LIVE proof that rotation is happening right now!**

---

## 🚀 Test 6: All-in-One Verification

### Run This Single Command

```bash
/home/rausingh/Documents/oape/ztwim-poc/federation-setup/test-scripts/test-federation.sh
```

**This automatically tests:**
- ✅ Trust bundle exchange
- ✅ Federated entries
- ✅ Bundle rotation history
- ✅ Real-time rotation (waits 90 seconds for live capture)

**Expected Output:**
```
╔════════════════════════════════════════════════════════════════╗
║         SPIRE FEDERATION PROOF OF CONCEPT TEST                 ║
╚════════════════════════════════════════════════════════════════╝

📋 Test 1: Trust Bundle Exchange Verification
  ✅ SUCCESS: Cluster 1 has Cluster 2's trust bundle
  ✅ SUCCESS: Cluster 2 has Cluster 1's trust bundle

📋 Test 2: Federated vs Non-Federated Registration Entries
  1️⃣  FEDERATED BACKEND:
      FederatesWith : apps.cluster-1.devcluster.openshift.com
  2️⃣  NON-FEDERATED BACKEND:
      (No FederatesWith field)

📋 Test 3: Proof of Automatic Bundle Rotation
  Last 10 bundle refreshes shown...
  Next scheduled at: ...

📋 Test 4: Real-Time Bundle Rotation Monitor
  🔄 CLUSTER 1: Bundle refreshed...
  🔄 CLUSTER 2: Bundle refreshed...

✅ All tests PASSED!
```

---

## 🔬 Deep Dive Tests

### Check the `federates_with` Configuration

```bash
# Verify federates_with block is in Cluster 1 config
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  get configmap spire-server -n zero-trust-workload-identity-manager -o yaml | \
  grep -A 15 "federates_with"
```

**Expected Output:**
```json
"federates_with": {
  "apps.cluster-2.devcluster.openshift.com": {
    "bundle_endpoint_url": "https://...",
    "bundle_endpoint_profile": {
      "https_spiffe": {
        "endpoint_spiffe_id": "spiffe://apps.cluster-2.../spire/server"
      }
    }
  }
}
```

✅ This block enables automatic rotation!

### Check ClusterFederatedTrustDomain Resources

```bash
# Cluster 1 - Should show cluster-2 federation
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  get clusterfederatedtrustdomain -o wide

# Cluster 2 - Should show cluster-1 federation
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  get clusterfederatedtrustdomain -o wide
```

**Expected Output:**
```
NAME                   TRUST DOMAIN                              ENDPOINT URL
cluster-2-federation   apps.cluster-2.devcluster.openshift.com   https://spire-server-federation...
```

---

## 📊 Quick Status Check - One Command

```bash
cat << 'TESTEOF' > /tmp/quick-federation-check.sh
#!/bin/bash
echo "🔍 Quick Federation Status Check"
echo "=================================="
echo ""
echo "1. Cluster 1 trust bundles:"
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list 2>/dev/null | grep "apps.cluster-" || echo "  ❌ No bundles"

echo ""
echo "2. Cluster 2 trust bundles:"
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list 2>/dev/null | grep "apps.cluster-" || echo "  ❌ No bundles"

echo ""
echo "3. Recent bundle refreshes (Cluster 1):"
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 2>/dev/null | \
  grep "Bundle refreshed" | tail -3

echo ""
echo "4. Next scheduled refresh:"
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 2>/dev/null | \
  grep "Scheduling next" | tail -1

echo ""
echo "✅ If you see bundles and refreshes above, federation is working!"
TESTEOF

chmod +x /tmp/quick-federation-check.sh
/tmp/quick-federation-check.sh
```

---

## 🎯 The Easiest Test - Just Run This

```bash
# Single command to prove everything
/home/rausingh/Documents/oape/ztwim-poc/federation-setup/test-scripts/test-federation.sh
```

This runs ALL tests automatically and shows you the results!

---

## 🔄 Watch Bundle Rotation in Real-Time

### Copy this exact command and run it:

```bash
timeout 120 bash << 'EOF'
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server 2>/dev/null | \
  grep --line-buffered "Bundle refresh" | \
  while read line; do 
    echo "🔄 $(date '+%H:%M:%S') - CLUSTER 1: $line"
  done &

kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server 2>/dev/null | \
  grep --line-buffered "Bundle refresh" | \
  while read line; do
    echo "🔄 $(date '+%H:%M:%S') - CLUSTER 2: $line"
  done &

wait
EOF
```

**This monitors BOTH clusters for 2 minutes. You'll see bundles refreshing live!**

---

## 📦 Test Federated vs Non-Federated Workloads

### Show Federated Workload Configuration

```bash
# This entry SHOULD have FederatesWith
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show | grep -A 12 "federated-backend"
```

**Look for this line:**
```
FederatesWith    : apps.cluster-1.devcluster.openshift.com
```

### Show Non-Federated Workload Configuration

```bash
# This entry should NOT have FederatesWith
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show | grep -A 12 "non-federated-backend"
```

**Notice NO FederatesWith line** - proves it won't get federated bundles!

---

## 🎬 Interactive Demo

### Run the Full Interactive Demo

```bash
/home/rausingh/Documents/oape/ztwim-poc/federation-setup/LIVE_DEMO.sh
```

This shows:
- Federated vs non-federated entries side-by-side
- Trust bundle contents
- Live bundle rotation capture
- All with clear explanations

**Runtime**: ~3 minutes (includes 2 min live monitoring)

---

## 🏃 Quick Commands - Copy & Paste

### See Everything in 30 Seconds

```bash
echo "=== TRUST BUNDLES ==="
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list 2>/dev/null | grep "apps.cluster"

echo ""
echo "=== RECENT ROTATIONS ==="
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 2>/dev/null | \
  grep "Bundle refreshed" | tail -5

echo ""
echo "=== FEDERATED ENTRY ==="
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show 2>/dev/null | grep -A 10 "federated-backend" | grep -E "(SPIFFE ID|FederatesWith)"

echo ""
echo "✅ If you see trust bundles, refreshes, and FederatesWith field, it's working!"
```

---

## 🎯 Expected vs Actual

### ✅ Federation IS Working If You See:

1. **Trust bundles:**
   ```
   * apps.cluster-2.devcluster.openshift.com  (in Cluster 1)
   * apps.cluster-1.devcluster.openshift.com  (in Cluster 2)
   ```

2. **Bundle refreshes:**
   ```
   time="..." msg="Bundle refreshed" (multiple entries)
   ```

3. **Federated entries:**
   ```
   FederatesWith : apps.cluster-X.devcluster.openshift.com
   ```

4. **Scheduled refreshes:**
   ```
   msg="Scheduling next bundle refresh" at="<future time>"
   ```

### ❌ Federation is NOT Working If You See:

1. Only one trust domain in bundle list (missing federated bundle)
2. "Error updating bundle" messages
3. No "Bundle refreshed" messages
4. No FederatesWith in entries

---

## 🔍 Troubleshooting Commands

### If Bundle Rotation Seems Stopped

```bash
# Check for errors
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=100 | \
  grep -E "(Error|error|fail)"
```

### If Federation Endpoint Not Accessible

```bash
# Test the route
ROUTE=$(kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  get route spire-server-federation -n zero-trust-workload-identity-manager -o jsonpath='{.spec.host}')

echo "Testing: https://$ROUTE"
curl -k -v https://$ROUTE 2>&1 | grep -E "(Connected|SSL|certificate)"
```

---

## 📝 Summary of Test Commands

| Test | Command | Expected Result |
|------|---------|----------------|
| Bundle exchange | `./spire-server bundle list` | Shows both trust domains |
| Bundle rotation | `logs ... \| grep "Bundle refresh"` | Multiple refresh events |
| Federated entry | `./spire-server entry show \| grep federated` | Has `FederatesWith` field |
| Non-federated entry | `./spire-server entry show \| grep non-federated` | NO `FederatesWith` field |
| Live rotation | `logs -f ... \| grep "Bundle refresh"` | New events every ~75s |
| Next refresh | `logs ... \| grep "Scheduling next"` | Shows future timestamp |

---

## 🎉 You Can Test Right Now!

**Simplest test** (10 seconds):
```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list
```

If you see `apps.cluster-2.devcluster.openshift.com`, **federation is working!** ✅

**Complete test** (3 minutes):
```bash
/home/rausingh/Documents/oape/ztwim-poc/federation-setup/LIVE_DEMO.sh
```

**Live rotation** (wait ~75 seconds):
```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep "Bundle refresh"
```

---

**All commands are ready to copy-paste and run!** 🚀

