# 🎯 How to Use the Federation Automation Scripts

This is your complete guide to setting up SPIRE federation between any two OpenShift clusters.

---

## 📦 What You Get

Three powerful automation scripts:
1. **`setup-federation.sh`** - Complete federation setup (one command!)
2. **`verify-federation.sh`** - Test and verify everything
3. **`cleanup-federation.sh`** - Clean removal

Plus: Complete documentation and test commands

---

## 🚀 Step-by-Step Guide

### Step 1: Prepare Your Clusters

**Requirements:**
- Two OpenShift clusters
- `zero-trust-workload-identity-manager` operator installed on both
- SPIRE components running (server, agent, CSI driver)
- Kubeconfig files for both clusters

**Verify SPIRE is running:**
```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig get pods -n zero-trust-workload-identity-manager
kubectl --kubeconfig /path/to/cluster2/kubeconfig get pods -n zero-trust-workload-identity-manager
```

You should see: `spire-server-0`, `spire-agent-*`, `spire-spiffe-csi-driver-*`

---

### Step 2: Run the Setup Script

```bash
cd /home/rausingh/Documents/oape/ztwim-poc/federation-setup

chmod +x setup-federation.sh verify-federation.sh cleanup-federation.sh

./setup-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig
```

**What it does:**
```
1. Gathers cluster information (trust domains, names)
2. Creates federation services and routes
3. Updates SPIRE server configs with:
   • bundle_endpoint (exposes federation)
   • federates_with (enables rotation) ← CRITICAL!
4. Exposes port 8443 on SPIRE server pods
5. Restarts SPIRE servers
6. Extracts trust bundles
7. Creates ClusterFederatedTrustDomain resources
8. Deploys test workloads:
   • Federated backend + frontend
   • Non-federated backend + frontend
```

**Runtime:** 3-4 minutes

**Output:** Test commands and API URLs

---

### Step 3: Wait for Pods

```bash
# Wait 2-3 minutes for pods to download Python packages
sleep 180

# Check status
kubectl --kubeconfig /path/to/cluster2/kubeconfig get pods -n federation-demo
```

**Expected:**
```
NAME                       READY   STATUS    RESTARTS   AGE
federated-backend          1/1     Running   0          3m
non-federated-backend      1/1     Running   0          3m
```

---

### Step 4: Verify Federation

```bash
./verify-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig
```

**This shows:**
- ✅ Trust bundle exchange status
- ✅ Bundle rotation history (10+ refreshes)
- ✅ Federated vs non-federated entries
- ✅ Pod status
- ✅ API URLs for curl testing
- 📋 Copy-paste ready test commands

---

### Step 5: Watch API Communication

**Open 3 terminals:**

**Terminal 1 - Federated Backend:**
```bash
kubectl --kubeconfig /path/to/cluster2/kubeconfig logs -f federated-backend -n federation-demo
```

**Terminal 2 - Federated Frontend:**
```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -f federated-frontend -n federation-demo
```

**Terminal 3 - Non-Federated Frontend:**
```bash
kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -f non-federated-frontend -n federation-demo
```

**You'll see:**
- ✅ Frontend calling backend every 30 seconds
- ✅ Backend receiving requests
- ✅ Backend sending responses
- ✅ Frontend receiving data
- ❌ Non-federated frontend failing to connect

---

### Step 6: Test with Curl

```bash
# Get URLs (output from setup script, or run verify script)
FED_URL="https://federated-backend-federation-demo.apps.cluster-X.../api/stock-data"
NON_FED_URL="https://non-federated-backend-federation-demo.apps.cluster-X.../api/stock-data"

# Test federated backend
curl $FED_URL

# Test non-federated backend
curl $NON_FED_URL
```

**While you curl, watch the backend logs to see the request arrive!**

---

## 🎬 Complete Demo Flow

```bash
# 1. Setup federation (3-4 min)
./setup-federation.sh cluster1.kubeconfig cluster2.kubeconfig

# 2. Wait for pods (3 min)
sleep 180

# 3. Verify (30 sec)
./verify-federation.sh cluster1.kubeconfig cluster2.kubeconfig

# 4. Watch federated backend logs
kubectl logs -f federated-backend -n federation-demo &

# 5. Test with curl and see request in logs!
curl https://federated-backend-federation-demo.apps.cluster-X.../api/stock-data
```

**Total time:** ~7 minutes from zero to working federation with visible API calls!

---

## 📋 What You'll Prove

### 1. Federated Pods CAN Communicate ✅

**Evidence:**
- Frontend logs: "📤 CALLING API" → "✅ SUCCESS" → "📈 Got stock data"
- Backend logs: "📥 API REQUEST" → "✅ Response sent"
- Curl returns: JSON with stock data
- **API communication happening!**

### 2. Non-Federated Pods CANNOT Communicate ❌

**Evidence:**
- Frontend logs: "📤 CALLING API" → "❌ FAILED: Connection refused"
- Backend logs: (nothing - request never arrives)
- Curl returns: Error or connection timeout
- **Communication blocked!**

### 3. Bundles ARE Rotating Automatically 🔄

**Evidence:**
- Logs show: 10+ "Bundle refreshed" events
- Timestamps: ~75 seconds apart
- Next refresh: Scheduled automatically
- Live monitoring: See new refreshes appearing
- **Rotation is active!**

---

## 🎯 Example Session

```bash
$ ./setup-federation.sh cluster1.kubeconfig cluster2.kubeconfig
╔════════════════════════════════════════════════════════════════════╗
║         SPIRE Federation Setup Script                             ║
╚════════════════════════════════════════════════════════════════════╝

Cluster 1 kubeconfig: cluster1.kubeconfig
Cluster 2 kubeconfig: cluster2.kubeconfig

Step 1: Gathering cluster information...
✓ Cluster 1: Trust Domain = apps.cluster-1.example.com
✓ Cluster 2: Trust Domain = apps.cluster-2.example.com

Step 2: Configuring federation endpoints...
✓ Cluster 1 federation endpoint: https://spire-server-federation...
✓ Cluster 2 federation endpoint: https://spire-server-federation...
✓ Updated SPIRE server configurations

Step 3: Exposing federation port on SPIRE servers...
✓ Federation port exposed

Step 4: Restarting SPIRE servers...
✓ SPIRE servers restarted and ready

Step 5: Extracting trust bundles...
✓ Trust bundles extracted

Step 6: Creating ClusterFederatedTrustDomain resources...
✓ ClusterFederatedTrustDomain resources created

Step 7: Deploying test workloads...
✓ Test workloads deployed

╔════════════════════════════════════════════════════════════════════╗
║                    SETUP COMPLETE!                                 ║
╚════════════════════════════════════════════════════════════════════╝

🧪 TEST COMMANDS:
[... curl commands and test instructions ...]

🎉 Federation setup complete!
```

---

## 🔧 Configuration Details

### What Gets Configured

**In Both SPIRE Servers:**
```json
"federation": {
  "bundle_endpoint": {
    "address": "0.0.0.0",
    "port": 8443
  },
  "federates_with": {
    "<other-trust-domain>": {
      "bundle_endpoint_url": "https://...",
      "bundle_endpoint_profile": {
        "https_spiffe": {
          "endpoint_spiffe_id": "spiffe://<other-domain>/spire/server"
        }
      }
    }
  }
}
```

**Federation Resources:**
- Services exposing port 8443
- OpenShift Routes for external access
- ClusterFederatedTrustDomain CRDs with initial bundles

**Test Workloads:**
- Federated backend: Python HTTP server with stock API
- Federated frontend: Python client calling backend every 30s
- Non-federated backend: Python HTTP server (no federation)
- Non-federated frontend: Python client (fails to connect)

---

## 📊 Monitoring

### Check Federation Health

```bash
# Trust bundles
kubectl exec spire-server-0 -c spire-server -- ./spire-server bundle list

# Bundle rotation
kubectl logs spire-server-0 -c spire-server --tail=100 | grep "Bundle refresh"

# Registration entries
kubectl exec spire-server-0 -c spire-server -- ./spire-server entry show

# API pod status
kubectl get pods -n federation-demo

# API logs
kubectl logs -f <pod-name> -n federation-demo
```

### Watch Everything

```bash
# Terminal 1: Bundle rotation
kubectl logs -f spire-server-0 -c spire-server | grep "Bundle refresh"

# Terminal 2: Federated backend
kubectl logs -f federated-backend -n federation-demo

# Terminal 3: Federated frontend
kubectl logs -f federated-frontend -n federation-demo

# Terminal 4: Non-federated frontend
kubectl logs -f non-federated-frontend -n federation-demo
```

---

## 🎉 Success Indicators

You know federation is working when:

1. ✅ `bundle list` shows 2+ trust domains in each cluster
2. ✅ Logs show "Bundle refreshed" every ~75 seconds
3. ✅ Frontend logs show "✅ SUCCESS!" for API calls
4. ✅ Backend logs show "📥 API REQUEST" → "✅ Response sent"
5. ✅ Curl returns JSON stock data from federated backend
6. ✅ Non-federated frontend shows connection failures
7. ✅ All automated without manual intervention

---

## 📚 Additional Documentation

See the `federation-setup/` directory for:
- `FEDERATION_SETUP_DOCUMENTATION.md` - Detailed setup guide
- `TEST_RESULTS.md` - Test results from original clusters
- `PROOF_OF_WORKING_FEDERATION.md` - Visual proof
- `CURL_TEST_COMMANDS.md` - All test commands
- `ANSWERS_TO_YOUR_QUESTIONS.md` - Direct answers

---

**Everything you need to set up, test, and verify SPIRE federation!** 🚀

