# 🤖 Automated SPIRE Federation Setup

This directory contains scripts to automatically set up and test SPIRE federation between two OpenShift clusters.

---

## 📋 Prerequisites

- Two OpenShift clusters with `zero-trust-workload-identity-manager` installed
- SPIRE components (server, agent, CSI driver) running in both clusters
- kubectl access to both clusters
- Kubeconfig files for both clusters

---

## 🚀 Quick Start

### 1. Run the Setup Script

```bash
cd /home/rausingh/Documents/oape/ztwim-poc/federation-setup

./setup-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig
```

**This script automatically:**
- ✅ Configures federation endpoints on both SPIRE servers
- ✅ Adds the critical `federates_with` configuration block
- ✅ Exposes federation bundle endpoints via OpenShift routes
- ✅ Exchanges trust bundles between clusters
- ✅ Creates ClusterFederatedTrustDomain resources
- ✅ Deploys test workloads (federated and non-federated)
- ✅ Provides test commands and API URLs

**Runtime:** ~3-4 minutes

---

### 2. Wait for Pods to Start

```bash
# Wait 2-3 minutes for pods to download dependencies and start
sleep 180

# Check pod status
kubectl --kubeconfig /path/to/cluster2/kubeconfig get pods -n federation-demo
kubectl --kubeconfig /path/to/cluster1/kubeconfig get pods -n federation-demo
```

---

### 3. Run the Verification Script

```bash
./verify-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig
```

**This script tests:**
- ✅ Trust bundle exchange
- ✅ Automatic bundle rotation
- ✅ Federated vs non-federated entries
- ✅ Pod status
- ✅ API endpoints

**Provides:**
- 📝 Curl commands to test APIs
- 📺 kubectl commands to watch logs
- 📊 Summary of federation status

---

## 🧪 Test the APIs

### Get the API URLs

The setup script outputs the URLs, or run:

```bash
# Federated backend URL
CLUSTER2_KUBECONFIG="/path/to/cluster2/kubeconfig"
FED_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route federated-backend -n federation-demo -o jsonpath='https://{.spec.host}')

echo "Federated Backend: $FED_URL/api/stock-data"
```

### Test with Curl

```bash
# Test federated backend (should work and return stock data)
curl https://federated-backend-federation-demo.apps.cluster-X.../api/stock-data

# Expected response:
# {
#   "status": "success",
#   "federation_enabled": true,
#   "data": {
#     "stocks": [
#       {"symbol": "AAPL", "price": 150.25, "change": "+2.5%"},
#       ...
#     ],
#     "message": "✅ Federation is WORKING!"
#   }
# }

# Test non-federated backend (should return error)
curl https://non-federated-backend-federation-demo.apps.cluster-X.../api/stock-data

# Expected response:
# {
#   "status": "error",
#   "federation_enabled": false,
#   "error": "This backend does not trust cluster-1 certificates"
# }
```

---

## 👀 Watch API Communication Happening

### Terminal 1: Watch Federated Backend Logs

```bash
kubectl --kubeconfig /path/to/cluster2/kubeconfig logs -f federated-backend -n federation-demo
```

**You'll see:**
```
🚀 FEDERATED BACKEND API (Cluster 2)
✅ Federation ENABLED
✅ Federates With: apps.cluster-1...

[12:30:15] 📥 API REQUEST from 10.128.x.x
[12:30:15] ✅ Response sent successfully
[12:30:45] 📥 API REQUEST from 10.128.x.x
[12:30:45] ✅ Response sent successfully
```

### Terminal 2: Watch Federated Frontend Logs

```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -f federated-frontend -n federation-demo
```

**You'll see:**
```
🚀 FEDERATED FRONTEND CLIENT (Cluster 1)
✅ Federation ENABLED
🎯 Target backend: http://federated-backend.../api/stock-data

[12:30:15] 📤 CALLING BACKEND API...
[12:30:15] ✅ SUCCESS!
📦 Response:
   Backend: federated-backend
   Federation: True
📈 Stock Data Received:
   AAPL: $150.25 (+2.5%)
   GOOGL: $2800.50 (+1.2%)
🎉 ✅ Federation is WORKING!

[12:30:45] 📤 CALLING BACKEND API...
[12:30:45] ✅ SUCCESS!
```

### Terminal 3: Watch Non-Federated Frontend Logs

```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -f non-federated-frontend -n federation-demo
```

**You'll see:**
```
🚀 NON-FEDERATED FRONTEND CLIENT (Cluster 1)
❌ Federation DISABLED
⚠️  Expected: Requests will FAIL

[12:30:20] 📤 CALLING NON-FEDERATED BACKEND...
[12:30:20] ❌ FAILED: Connection refused
✅ This is EXPECTED - no federation configured!

[12:30:50] 📤 CALLING NON-FEDERATED BACKEND...
[12:30:50] ❌ FAILED: Connection refused
✅ This is CORRECT - proves federation is required!
```

### Terminal 4: Watch Bundle Rotation

```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep "Bundle refresh"
```

**You'll see** (every ~75 seconds):
```
time="..." level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=apps.cluster-2...
```

---

## 📊 What You'll See in Action

### ✅ Federated Communication (WORKS)

```
┌──────────────────┐                          ┌──────────────────┐
│  Cluster 1       │    HTTP GET /api/data    │  Cluster 2       │
│                  │                          │                  │
│  Frontend        │─────────────────────────>│  Backend         │
│  (Federated)     │                          │  (Federated)     │
│                  │                          │                  │
│  Logs:           │                          │  Logs:           │
│  📤 CALLING API  │   ✅ 200 OK + JSON       │  📥 REQUEST      │
│  ✅ SUCCESS!     │<─────────────────────────│  ✅ SENT RESPONSE│
│  📈 Got stocks   │                          │                  │
└──────────────────┘                          └──────────────────┘

Curl Test:
$ curl https://...federated-backend.../api/stock-data
{
  "status": "success",
  "data": {"stocks": [...]}
}
```

### ❌ Non-Federated Communication (FAILS)

```
┌──────────────────┐                          ┌──────────────────┐
│  Cluster 1       │    HTTP GET /api/data    │  Cluster 2       │
│                  │                          │                  │
│  Frontend        │─────────X                │  Backend         │
│  (Non-Federated) │                          │  (Non-Federated) │
│                  │                          │                  │
│  Logs:           │                          │  Logs:           │
│  📤 CALLING API  │   ❌ Connection refused  │  (no requests)   │
│  ❌ FAILED       │                          │                  │
└──────────────────┘                          └──────────────────┘

Curl Test:
$ curl https://...non-federated-backend.../api/stock-data
{
  "status": "error",
  "error": "Does not trust cluster-1"
}
```

---

## 🔄 Watch Bundle Rotation

### Show Rotation History

```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 | grep "Bundle refreshed" | tail -10
```

**Output:**
```
time="12:25:22Z" ... msg="Bundle refreshed" ...
time="12:26:37Z" ... msg="Bundle refreshed" ... (+75s)
time="12:27:52Z" ... msg="Bundle refreshed" ... (+75s)
time="12:29:07Z" ... msg="Bundle refreshed" ... (+75s)
...
```

### Watch Live Rotation

```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep --line-buffered "Bundle refresh"
```

**Wait ~75 seconds and you'll see new refresh events appearing!**

---

## 🧹 Cleanup

To remove federation setup:

```bash
./cleanup-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig
```

This removes:
- Federation demo namespace and workloads
- ClusterFederatedTrustDomain resources
- Federation routes and services

---

## 📁 Files Created

### Setup Scripts
- `setup-federation.sh` - Main setup script
- `verify-federation.sh` - Verification and testing script
- `cleanup-federation.sh` - Cleanup script

### Configuration Files (Created During Setup)
- `/tmp/spire-federation-setup-*/` - Working directory with:
  - Updated ConfigMaps
  - Trust bundle exports
  - ClusterFederatedTrustDomain manifests
  - Test commands

---

## 🎯 Expected Results

After running the setup script, within 5 minutes you should see:

✅ **Trust Bundle Exchange:**
- Each cluster has the other's trust bundle
- Verify with: `./spire-server bundle list`

✅ **Automatic Rotation:**
- Bundles refresh every ~75 seconds
- Verify with: `logs | grep "Bundle refreshed"`

✅ **Federated API Communication:**
- Frontend calls backend every 30 seconds
- Backend receives requests and responds
- Curl test returns JSON stock data

✅ **Non-Federated Blocking:**
- Non-federated frontend cannot reach non-federated backend
- Connection fails (as expected)
- Proves federation is required

---

## 🔍 Troubleshooting

### Pods in CrashLoopBackOff

**Check logs:**
```bash
kubectl logs <pod-name> -n federation-demo
```

**Common issues:**
- Waiting for SPIFFE socket (normal during startup)
- Package installation (may take 2-3 minutes first time)

### No Trust Bundles

**Verify:**
```bash
kubectl get clusterfederatedtrustdomain
./spire-server bundle list
```

**Fix:** Re-run setup script

### API Not Accessible

**Check routes:**
```bash
kubectl get routes -n federation-demo
```

**Test connectivity:**
```bash
curl https://federated-backend-federation-demo.apps.cluster-X.../health
```

---

## 📞 Support Commands

```bash
# Check federation status
kubectl get clusterfederatedtrustdomain -o wide

# Check SPIRE server logs
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=100

# Check workload status
kubectl get pods -n federation-demo
kubectl get clusterspiffeid

# Test API manually
curl https://<backend-route>/api/stock-data
```

---

## 🎉 Success Criteria

Federation is working when:

1. ✅ `bundle list` shows both trust domains
2. ✅ Logs show "Bundle refreshed" every ~75 seconds
3. ✅ Federated entries have `FederatesWith` field
4. ✅ Frontend logs show successful API calls
5. ✅ Backend logs show received requests
6. ✅ Curl returns JSON data from federated backend
7. ✅ Non-federated attempts fail (as expected)

---

**Run `setup-federation.sh` to get started!** 🚀

