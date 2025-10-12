# 🚀 SPIRE Federation - Complete Automation

## One-Command Federation Setup Between Any Two OpenShift Clusters

---

## 🎯 What This Does

Automatically sets up complete SPIRE federation between two clusters with:
- ✅ Federation endpoints configured
- ✅ Trust bundles exchanged
- ✅ Automatic bundle rotation enabled
- ✅ Test workloads deployed (federated and non-federated)
- ✅ REST APIs you can test with curl
- ✅ Complete verification

**Total time:** ~7 minutes from start to working APIs!

---

## 🏃 Quick Start (3 Commands)

```bash
cd /home/rausingh/Documents/oape/ztwim-poc/federation-setup

# 1. Setup federation
./setup-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig

# 2. Wait for pods (2-3 minutes)
sleep 180

# 3. Verify and get test commands
./verify-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig
```

**That's it!** Federation is now configured and you have curl commands to test.

---

## 📁 Files You Need

### Main Scripts (Use These!)

| Script | Purpose | Runtime |
|--------|---------|---------|
| **`setup-federation.sh`** | Complete federation setup | 3-4 min |
| **`verify-federation.sh`** | Test and verify everything | 30 sec |
| **`cleanup-federation.sh`** | Remove federation setup | 30 sec |

### Documentation

| File | Content |
|------|---------|
| **`HOW_TO_USE.md`** | Detailed usage guide |
| **`AUTOMATION_README.md`** | Automation details |
| **`CURL_TEST_COMMANDS.md`** | All curl/kubectl test commands |
| **`FEDERATION_SETUP_DOCUMENTATION.md`** | Complete technical guide |

---

## 🎬 What You'll See

### During Setup

```
╔════════════════════════════════════════════════════════════════════╗
║         SPIRE Federation Setup Script                             ║
╚════════════════════════════════════════════════════════════════════╝

Step 1: Gathering cluster information...
✓ Cluster 1: Trust Domain = apps.cluster-1.example.com
✓ Cluster 2: Trust Domain = apps.cluster-2.example.com

Step 2: Configuring federation endpoints...
✓ Updated SPIRE server configurations

Step 3: Exposing federation port...
✓ Federation port exposed

Step 4: Restarting SPIRE servers...
✓ SPIRE servers restarted

Step 5: Extracting trust bundles...
✓ Trust bundles extracted

Step 6: Creating ClusterFederatedTrustDomain resources...
✓ ClusterFederatedTrustDomain resources created

Step 7: Deploying test workloads...
✓ Test workloads deployed

╔════════════════════════════════════════════════════════════════════╗
║                    SETUP COMPLETE!                                 ║
╚════════════════════════════════════════════════════════════════════╝
```

### After Pods Start (watch logs)

**Federated Backend:**
```
🚀 FEDERATED BACKEND API (Cluster 2)
✅ Federation ENABLED
✅ Federates With: apps.cluster-1...
📡 API: GET /api/stock-data
🌐 Listening on port 8080...

[12:30:15] 📥 API REQUEST from 10.128.x.x
[12:30:15] ✅ Response sent successfully
[12:30:45] 📥 API REQUEST from 10.128.x.x
[12:30:45] ✅ Response sent successfully
```

**Federated Frontend:**
```
🚀 FEDERATED FRONTEND CLIENT (Cluster 1)
✅ Federation ENABLED
🎯 Target: http://federated-backend.../api/stock-data

[12:30:15] 📤 CALLING BACKEND API...
[12:30:15] ✅ SUCCESS!
📦 Response:
   Backend: federated-backend
   Federation: True
📈 Stock Data Received:
   AAPL: $150.25 (+2.5%)
   GOOGL: $2800.50 (+1.2%)
🎉 ✅ Federation is WORKING!
```

**Your Curl Test:**
```
$ curl https://federated-backend.../api/stock-data

{
  "status": "success",
  "federation_enabled": true,
  "data": {
    "stocks": [
      {"symbol": "AAPL", "price": 150.25, "change": "+2.5%"},
      {"symbol": "GOOGL", "price": 2800.50, "change": "+1.2%"}
    ],
    "message": "✅ Federation is WORKING! Data from Cluster 2"
  }
}
```

**Backend logs at the same time:**
```
[12:35:23] 📥 API REQUEST from 203.0.113.x
[12:35:23] ✅ Response sent successfully
```

✅ **YOU SEE THE API CALL HAPPENING IN REAL-TIME!**

---

## 🎯 Test Scenarios

### ✅ Scenario 1: Federated Communication

```bash
# Watch backend
kubectl logs -f federated-backend -n federation-demo

# In another terminal, curl it
curl https://federated-backend.../api/stock-data

# Backend logs immediately show:
# [HH:MM:SS] 📥 API REQUEST
# [HH:MM:SS] ✅ Response sent
```

### ❌ Scenario 2: Non-Federated Communication

```bash
# Watch non-federated frontend
kubectl logs -f non-federated-frontend -n federation-demo

# You'll see:
# [HH:MM:SS] 📤 CALLING BACKEND...
# [HH:MM:SS] ❌ FAILED: Connection refused
# ✅ This is CORRECT - no federation!
```

### 🔄 Scenario 3: Bundle Rotation

```bash
# Watch live rotation
kubectl logs -f spire-server-0 -c spire-server | grep "Bundle refresh"

# Every ~75 seconds you'll see:
# time="..." msg="Bundle refreshed" ...
```

---

## 📝 Complete Command Reference

### Setup
```bash
./setup-federation.sh cluster1.kubeconfig cluster2.kubeconfig
```

### Verify
```bash
./verify-federation.sh cluster1.kubeconfig cluster2.kubeconfig
```

### Watch Federated API Communication
```bash
# Terminal 1
kubectl --kubeconfig cluster2.kubeconfig logs -f federated-backend -n federation-demo

# Terminal 2
kubectl --kubeconfig cluster1.kubeconfig logs -f federated-frontend -n federation-demo

# Terminal 3 - Curl while watching logs
curl https://federated-backend-federation-demo.apps.cluster-2.../api/stock-data
```

### Watch Bundle Rotation
```bash
kubectl --kubeconfig cluster1.kubeconfig logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep "Bundle refresh"
```

### Cleanup
```bash
./cleanup-federation.sh cluster1.kubeconfig cluster2.kubeconfig
```

---

## 🎓 What This Proves

After running these scripts, you will have proven:

1. ✅ **Trust bundles exchanged** - `bundle list` shows both domains
2. ✅ **Federated workloads work** - API calls succeed, logs show communication
3. ✅ **Non-federated workloads blocked** - API calls fail, as expected
4. ✅ **Bundles rotating automatically** - Logs show continuous refreshes
5. ✅ **Curl tests work** - You can hit APIs and see responses
6. ✅ **Real-time monitoring** - Watch API calls happening in logs

---

## 🔍 Troubleshooting

### Pods Not Starting

```bash
kubectl logs <pod-name> -n federation-demo
```

Wait 2-3 minutes for Python package downloads.

### No Bundle Rotation

Check `federates_with` in ConfigMap:
```bash
kubectl get configmap spire-server -n zero-trust-workload-identity-manager -o yaml | grep -A 10 "federates_with"
```

### API Not Accessible

```bash
kubectl get routes -n federation-demo
curl https://<route-url>/health
```

---

## 📞 Quick Help

```bash
# Is federation configured?
kubectl get clusterfederatedtrustdomain

# Are bundles rotating?
kubectl logs spire-server-0 -c spire-server --tail=100 | grep "Bundle refresh"

# Are pods running?
kubectl get pods -n federation-demo

# What are the API URLs?
kubectl get routes -n federation-demo
```

---

## 🎉 Get Started Now!

```bash
cd /home/rausingh/Documents/oape/ztwim-poc/federation-setup
./setup-federation.sh <cluster1-kubeconfig> <cluster2-kubeconfig>
```

**In 7 minutes you'll have working federation with APIs you can curl!** 🚀

For detailed information, see `HOW_TO_USE.md` and `AUTOMATION_README.md`.

