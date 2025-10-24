# 🎯 SPIRE Federation Automation Suite

**Complete automation for SPIRE-to-SPIRE federation between OpenShift clusters**

---

## 🚀 Quick Start

```bash
cd federation-setup

# Setup federation on any two clusters
./setup-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig

# Wait for pods to start
sleep 180

# Verify and get curl commands
./verify-federation.sh /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig

# Test the API
curl <backend-url-from-output>/api/stock-data
```

**Total time:** 7 minutes from zero to working APIs!

---

## 📦 What You Get

### 🤖 Automation Scripts

1. **`setup-federation.sh`** (3-4 min runtime)
   - Configures federation on both SPIRE servers
   - Exchanges trust bundles
   - Enables automatic rotation
   - Deploys test APIs

2. **`verify-federation.sh`** (30 sec runtime)
   - Tests all federation components
   - Provides curl commands
   - Shows configuration status

3. **`cleanup-federation.sh`** (30 sec runtime)
   - Clean removal of federation

### 📡 Working APIs for Testing

- **Federated Backend:** REST API returning stock data
- **Federated Frontend:** Calls backend every 30s  
- **Non-Federated Backend:** Returns errors (no federation)
- **Non-Federated Frontend:** Calls fail (demonstrates blocking)

### 📚 Complete Documentation (30+ files)

- Setup guides
- Test procedures
- Configuration examples
- Curl command references

---

## 🎬 See API Communication in Action

### Watch Federated API Calls

**Terminal 1 - Backend:**
```bash
kubectl logs -f federated-backend -n federation-demo
```

**Terminal 2 - Frontend:**
```bash
kubectl logs -f federated-frontend -n federation-demo
```

**Terminal 3 - Curl:**
```bash
curl https://federated-backend.../api/stock-data
```

**You'll see:**
- Backend: "📥 API REQUEST" → "✅ Response sent"
- Frontend: "📤 CALLING API" → "✅ SUCCESS!"
- Curl: JSON response with stock data

✅ **API communication visible in real-time!**

---

## 🔄 Watch Bundle Rotation

```bash
kubectl logs -f spire-server-0 -c spire-server | grep "Bundle refresh"
```

**Every ~75 seconds:**
```
time="..." msg="Bundle refreshed" ...
```

✅ **See automatic rotation happening live!**

---

## 📋 What Gets Configured

### Federation Infrastructure

- ✅ Federation bundle endpoints (port 8443)
- ✅ OpenShift Routes for external access
- ✅ `federates_with` block in SPIRE config (enables rotation)
- ✅ ClusterFederatedTrustDomain resources
- ✅ Initial trust bundle bootstrap

### Test Workloads

- ✅ Federated backend API (Python HTTP server)
- ✅ Federated frontend (Python HTTP client)
- ✅ Non-federated backend API
- ✅ Non-federated frontend

All with SPIFFE CSI driver for automatic credential delivery.

---

## 🎯 What You'll Prove

1. ✅ **Federated pods CAN communicate**
   - Frontend calls backend API
   - Backend receives and responds
   - Curl returns JSON data
   - Logs show communication

2. ❌ **Non-federated pods CANNOT communicate**
   - Frontend calls fail
   - Backend never receives requests
   - Curl times out or errors
   - Proves federation is required

3. 🔄 **Bundles rotate automatically**
   - 10+ refreshes in logs
   - ~75 second intervals
   - Live monitoring shows new refreshes
   - Zero manual intervention

---

## 📁 File Organization

```
federation-setup/
├── 00-START-HERE.md              ← Quick start guide
├── HOW_TO_USE.md                 ← Detailed usage
├── AUTOMATION_README.md          ← Automation details
│
├── setup-federation.sh           ← Main setup script
├── verify-federation.sh          ← Verification script
├── cleanup-federation.sh         ← Cleanup script
│
├── CURL_TEST_COMMANDS.md         ← All test commands
├── FEDERATION_SETUP_DOCUMENTATION.md
├── TEST_RESULTS.md
├── PROOF_OF_WORKING_FEDERATION.md
│
└── ... (30+ more files)
```

---

## 📖 Documentation Guide

**Start here:** `federation-setup/00-START-HERE.md`

**For usage:** `federation-setup/HOW_TO_USE.md`

**For curl commands:** `federation-setup/CURL_TEST_COMMANDS.md`

**Complete summary:** `federation-setup/FINAL_SUMMARY.txt`

---

## 🎉 Ready to Use!

```bash
cd /home/rausingh/Documents/oape/ztwim-poc/federation-setup

./setup-federation.sh cluster1.kubeconfig cluster2.kubeconfig
```

**Your new clusters will have:**
- ✅ Working federation
- ✅ REST APIs to test
- ✅ Curl commands ready
- ✅ Automatic bundle rotation
- ✅ Complete verification

**All in under 10 minutes!** 🚀
