# 🧪 CURL Commands to Test Federation

## 📋 COPY-PASTE THESE COMMANDS

---

## ✅ Test 1: See Trust Bundles Are Exchanged

```bash
# Cluster 1 - Should show cluster-2's bundle
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list
```

**Look for:** `* apps.cluster-2.devcluster.openshift.com`  
✅ If you see this = Federation is working!

---

## ✅ Test 2: Show Federated vs Non-Federated Configuration

```bash
# Show ALL entries (federated and non-federated)
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show
```

**Look for:**
- Entry with `FederatesWith: apps.cluster-1...` = ✅ CAN communicate
- Entry without `FederatesWith` = ❌ CANNOT communicate

---

## 🔄 Test 3: Watch Bundle Rotation LIVE

```bash
# Watch bundles rotating in real-time (wait ~75 seconds)
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep --line-buffered "Bundle refresh"
```

**You'll see** (every ~75 seconds):
```
time="..." level=info msg="Bundle refreshed" ...
```

✅ This is LIVE proof bundles are rotating RIGHT NOW!  
(Press Ctrl+C to stop)

---

## 📊 Test 4: See Rotation History

```bash
# Show last 10 automatic rotations
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=300 | grep "Bundle refreshed" | tail -10
```

**You'll see:**
```
time="12:20:22Z" ... msg="Bundle refreshed" ...
time="12:21:37Z" ... msg="Bundle refreshed" ...
time="12:22:52Z" ... msg="Bundle refreshed" ...
... (10 entries with ~75 second intervals)
```

✅ Proves rotation has been happening continuously!

---

## 🌐 Test 5: Curl the Backend APIs (If Pods Running)

### Get API URLs
```bash
# Federated backend
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig get route federated-backend -n federation-demo -o jsonpath='https://{.spec.host}'

# Non-federated backend
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig get route non-federated-backend -n federation-demo -o jsonpath='https://{.spec.host}'
```

### Test the APIs
```bash
# Test federated backend (should work)
curl https://federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data

# Test non-federated backend
curl https://non-federated-backend-federation-demo.apps.cluster-2.devcluster.openshift.com/api/data
```

---

## 👀 Watch API Calls in Logs

```bash
# Terminal 1: Watch backend logs
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig logs -f -l app=federated-backend -n federation-demo

# Terminal 2: Watch frontend logs
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig logs -f -l app=federated-frontend -n federation-demo

# Then curl the backend and watch the logs show the request!
```

---

## 🎯 THE SIMPLEST PROOF - 3 Commands

```bash
# Command 1: Show trust bundles (10 sec)
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list

# Command 2: Show federated entry (10 sec)
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show | grep -A 10 "federated-backend"

# Command 3: Watch rotation live (75 sec)
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep "Bundle refresh"
```

**Total time**: Under 2 minutes to see everything!

---

## 🚀 ALL-IN-ONE TEST SCRIPT

```bash
/home/rausingh/Documents/oape/ztwim-poc/federation-setup/test-scripts/test-federation.sh
```

This runs all tests automatically!

---

## 📝 What Each Test Proves

| Command | What It Shows | Proves |
|---------|---------------|--------|
| `bundle list` | Trust bundles from both clusters | ✅ Bundles exchanged |
| `entry show \| grep federated` | Entry with FederatesWith field | ✅ Federation configured |
| `entry show \| grep non-federated` | Entry without FederatesWith | ❌ No federation |
| `logs \| grep "Bundle refresh"` | Automatic rotation happening | ✅ Rotation active |
| `curl API` | API responds with data | ✅ Communication works |

---

## 🎬 SEE IT NOW

**Run this command RIGHT NOW** to see proof federation is working:

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list && echo "" && echo "✅ If you see 'apps.cluster-2.devcluster.openshift.com' above, federation is WORKING!"
```

**And this to see it rotating:**

```bash
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 | grep "Bundle refreshed" | tail -5 && echo "" && echo "✅ Multiple refreshes = Rotation is ACTIVE!"
```

---

**Ready to copy-paste and test!** 🎉

