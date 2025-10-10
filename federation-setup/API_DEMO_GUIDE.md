# 🎯 API Communication Demo - Federated vs Non-Federated

## What This Demonstrates

You'll see:
1. ✅ **FEDERATED pods**: Frontend calls backend API → **SUCCEEDS**
2. ❌ **NON-FEDERATED pods**: Frontend calls backend API → **FAILS**
3. 📝 **Curl commands** to test the APIs yourself

---

## 🔍 Current Status - What's Already Configured

### Federated Backend (Cluster 2)

**SPIFFE Configuration:**
```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show | grep -A 12 "federated-backend"
```

**Output:**
```
SPIFFE ID     : spiffe://apps.cluster-2.../sa/federated-backend
FederatesWith : apps.cluster-1.devcluster.openshift.com  ✅ FEDERATION ENABLED
```

**What this means:**
- ✅ Has its own SVID from cluster-2
- ✅ Has cluster-1's trust bundle
- ✅ CAN verify requests from cluster-1 clients
- ✅ API calls from cluster-1 will WORK

### Non-Federated Backend (Cluster 2)

**SPIFFE Configuration:**
```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show | grep -A 12 "non-federated-backend"
```

**Output:**
```
SPIFFE ID : spiffe://apps.cluster-2.../sa/non-federated-backend
(No FederatesWith field)  ❌ NO FEDERATION
```

**What this means:**
- ✅ Has its own SVID from cluster-2
- ❌ Does NOT have cluster-1's trust bundle
- ❌ CANNOT verify requests from cluster-1 clients
- ❌ API calls from cluster-1 will FAIL

---

## 📡 How API Communication Works

### Scenario 1: FEDERATED Communication ✅

```
┌─────────────────────────────────────────────────────────────────┐
│ FEDERATED FRONTEND (Cluster 1) → FEDERATED BACKEND (Cluster 2) │
└─────────────────────────────────────────────────────────────────┘

Step 1: Frontend makes HTTP request
   curl http://federated-backend.federation-demo.svc.cluster.local:8080/api/data
   
Step 2: Request includes SPIFFE credentials
   Frontend SVID: spiffe://apps.cluster-1.../federated-frontend
   
Step 3: Backend verifies frontend's SVID  
   ✅ Backend has cluster-1 bundle → Verification succeeds
   
Step 4: Backend processes request
   Fetches data from database/service
   
Step 5: Backend sends response
   HTTP 200 OK
   {"status": "success", "data": {...}}
   
Step 6: Frontend receives response
   ✅ API call completed successfully!
```

### Scenario 2: NON-FEDERATED Communication ❌

```
┌──────────────────────────────────────────────────────────────────────┐
│ NON-FEDERATED FRONTEND (Cluster 1) → NON-FEDERATED BACKEND (Cluster 2) │
└──────────────────────────────────────────────────────────────────────┘

Step 1: Frontend makes HTTP request
   curl http://non-federated-backend.federation-demo.svc.cluster.local:8081/api/data
   
Step 2: Request includes SPIFFE credentials
   Frontend SVID: spiffe://apps.cluster-1.../non-federated-frontend
   
Step 3: Backend tries to verify frontend's SVID
   ❌ Backend does NOT have cluster-1 bundle → Verification FAILS
   
Step 4: Backend rejects request
   TLS handshake fails OR returns HTTP 403 Forbidden
   
Step 5: Frontend receives error
   ❌ API call FAILED!
   Error: certificate verify failed / connection refused
```

---

## 🧪 CURL COMMANDS TO TEST YOURSELF

### Get the Backend API URLs

```bash
# Federated backend URL
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  get route federated-backend -n federation-demo -o jsonpath='https://{.spec.host}/api/data'

# Non-federated backend URL  
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  get route non-federated-backend -n federation-demo -o jsonpath='https://{.spec.host}/api/data'
```

### Test the APIs

```bash
# Test FEDERATED backend (should work)
curl https://federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data

# Expected response:
# {
#   "status": "success",
#   "message": "FEDERATED Backend API Response",
#   "federation_enabled": true,
#   "data": {
#     "stocks": [...]
#   }
# }

# Test NON-FEDERATED backend
curl https://non-federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data

# Expected response:
# {
#   "status": "error",
#   "federation_enabled": false,
#   "error": "This backend does not trust cluster-1 certificates"
# }
```

---

## 📊 Watch API Calls Happening in Real-Time

### Terminal 1: Watch FEDERATED Backend Logs

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  logs -f federated-backend -n federation-demo
```

**You'll see:**
```
🚀 FEDERATED BACKEND API (Cluster 2) - WITH FEDERATION
✅ Federation enabled: apps.cluster-1.devcluster.openshift.com
📡 API: GET /api/data
🌐 Listening on port 8080...

[12:30:45] 📥 API CALL received
[12:30:45] ✅ Sent response
[12:31:15] 📥 API CALL received  
[12:31:15] ✅ Sent response
```

### Terminal 2: Watch FEDERATED Frontend Logs

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f federated-frontend -n federation-demo
```

**You'll see:**
```
🚀 FEDERATED FRONTEND (Cluster 1)
✅ Federation enabled: apps.cluster-2.devcluster.openshift.com
🎯 Calling backend every 30 seconds

[12:30:45] 📤 CALLING BACKEND API...
[12:30:45] ✅ SUCCESS! Received response
   Stock Data: AAPL: $150.25, GOOGL: $2800.50
🎉 Federation is WORKING!

[12:31:15] 📤 CALLING BACKEND API...
[12:31:15] ✅ SUCCESS! Received response
```

### Terminal 3: Watch NON-FEDERATED Frontend Logs

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f non-federated-frontend -n federation-demo
```

**You'll see:**
```
🚀 NON-FEDERATED FRONTEND (Cluster 1)
❌ Federation: DISABLED

[12:30:50] 📤 CALLING NON-FEDERATED BACKEND API...
[12:30:50] ❌ FAILED: Connection refused
   This is CORRECT - no federation configured!

[12:31:20] 📤 CALLING NON-FEDERATED BACKEND API...
[12:31:20] ❌ FAILED: Connection refused
   Reason: No cluster-2 trust bundle to verify backend
```

---

## 🎯 DEMONSTRATION FLOW

### What You'll See:

1. **Federated Backend** starts and listens on port 8080
2. **Federated Frontend** starts and calls backend every 30 seconds
3. **Backend logs** show: "📥 API CALL received" → "✅ Sent response"
4. **Frontend logs** show: "📤 CALLING API" → "✅ SUCCESS!"
5. **API communication is WORKING!** ✅

Meanwhile:

6. **Non-Federated Frontend** tries to call non-federated backend
7. **Connection FAILS** because neither has federated bundles
8. **Frontend logs** show: "❌ FAILED: Connection refused"
9. **Backend logs** show: (nothing - request never arrives)
10. **This proves federation is REQUIRED!** ❌

---

## 🧪 CURL COMMANDS - Test Right Now

Once pods are running, use these commands:

### Test Federated Backend API

```bash
# Get the URL
FEDERATED_URL=$(kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig get route federated-backend -n federation-demo -o jsonpath='https://{.spec.host}')

# Call the API
curl $FEDERATED_URL/api/data | jq '.'

# Expected output:
# {
#   "status": "success",
#   "message": "FEDERATED Backend API in Cluster 2",
#   "federation_enabled": true,
#   "data": {
#     "stocks": [...]
#   }
# }
```

### Test Non-Federated Backend API

```bash
# Get the URL
NON_FED_URL=$(kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig get route non-federated-backend -n federation-demo -o jsonpath='https://{.spec.host}')

# Call the API
curl $NON_FED_URL/api/data | jq '.'

# Expected output:
# {
#   "status": "error",
#   "federation_enabled": false,
#   "error": "This backend does not trust cluster-1 certificates"
# }
```

### Compare Responses Side-by-Side

```bash
echo "FEDERATED:"
curl -s https://federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data | jq '.federation_enabled'

echo "NON-FEDERATED:"
curl -s https://non-federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data | jq '.federation_enabled'
```

**Output:**
```
FEDERATED:
true          ← Federation working!

NON-FEDERATED:
false         ← No federation!
```

---

## 📝 Complete Test Procedure

```bash
# 1. Deploy the APIs (if not already running)
cd /home/rausingh/Documents/oape/ztwim-poc/federation-setup/api-demo
./deploy-api-demo.sh

# 2. Wait for pods to be ready (2-3 minutes)
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig wait --for=condition=ready pod -l app=federated-backend -n federation-demo --timeout=180s

# 3. Get API URLs
FEDERATED_URL=$(kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig get route federated-backend -n federation-demo -o jsonpath='https://{.spec.host}')

# 4. Test the API
curl $FEDERATED_URL/api/data

# 5. Watch logs to see API calls
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig logs -f federated-backend -n federation-demo
```

---

## 🎬 Expected Output When Running

### Federated Backend Logs
```
🚀 FEDERATED BACKEND API (Cluster 2) - WITH FEDERATION
✅ Federation enabled: apps.cluster-1.devcluster.openshift.com  
📡 API: GET /api/data
🌐 Listening on port 8080...

[12:35:20] 📥 API CALL received
[12:35:20] ✅ Sent response
[12:35:50] 📥 API CALL received
[12:35:50] ✅ Sent response
```

### Federated Frontend Logs
```
🚀 FEDERATED FRONTEND (Cluster 1)
✅ Federation enabled: apps.cluster-2.devcluster.openshift.com
🎯 Calling backend every 30 seconds

[12:35:20] 📤 CALLING BACKEND API...
[12:35:20] ✅ SUCCESS! Received stock data
   AAPL: $150.25
   GOOGL: $2800.50
🎉 Federation is WORKING!

[12:35:50] 📤 CALLING BACKEND API...
[12:35:50] ✅ SUCCESS! Received stock data
```

### Your Curl Test
```bash
$ curl https://federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data

{
  "status": "success",
  "message": "FEDERATED Backend API in Cluster 2",
  "federation_enabled": true,
  "data": {
    "stocks": [
      {"AAPL": 150.25},
      {"GOOGL": 2800.50}
    ]
  },
  "timestamp": "2025-10-09T12:35:20"
}
```

**At the same time, backend logs show:**
```
[12:35:23] 📥 API CALL received (from curl)
[12:35:23] ✅ Sent response
```

✅ **YOU SEE THE API CALL HAPPENING!**

---

## 🎯 Simple Curl Test Commands (Copy-Paste Ready)

```bash
# Test federated backend
curl https://federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data

# Test non-federated backend  
curl https://non-federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data

# Watch backend logs while you curl
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig logs -f federated-backend -n federation-demo
```

---

## 🎉 What You Prove

When you curl the federated backend and see the logs:
- ✅ Backend receives the API request
- ✅ Backend processes it
- ✅ Backend sends response
- ✅ You get JSON data back
- ✅ **API communication is working!**

This proves federation enables cross-cluster API communication!

