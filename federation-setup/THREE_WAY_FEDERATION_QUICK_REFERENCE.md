# 🚀 Three-Way Federation - Quick Reference Card

## ✅ Status: FULLY OPERATIONAL

Your three clusters are now federated and can securely communicate using SPIFFE identities!

---

## 📍 Cluster Information

| Cluster | Trust Domain | Kubeconfig |
|---------|--------------|------------|
| **Cluster 1** | `apps.client-1.devcluster.openshift.com` | `/home/rausingh/Documents/aws_cluster/13Oct2025Cluster2/auth/kubeconfig` |
| **Cluster 2** | `apps.server-1.devcluster.openshift.com` | `/home/rausingh/Documents/aws_cluster/13Oct2025Cluster1/auth/kubeconfig` |
| **Cluster 3** | `apps.aagnihot-cluster-fss.devcluster.openshift.com` | `/home/rausingh/Downloads/kubeconfig` |

---

## 🔧 Common Commands

### Check Federation Status

```bash
# Check trust bundles on any cluster (should show 2 other domains)
kubectl --kubeconfig <kubeconfig> exec -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server -- ./spire-server bundle list

# Check ClusterFederatedTrustDomain resources (should show 2)
kubectl --kubeconfig <kubeconfig> get clusterfederatedtrustdomain

# Watch live bundle rotation
kubectl --kubeconfig <kubeconfig> logs -f -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server | grep "Bundle refresh"
```

### Check Workload Registration

```bash
# List all ClusterSPIFFEID resources
kubectl --kubeconfig <kubeconfig> get clusterspiffeid -A

# Check specific workload identity
kubectl --kubeconfig <kubeconfig> get clusterspiffeid <name> -o yaml

# Verify workload entries in SPIRE
kubectl --kubeconfig <kubeconfig> exec -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server -- ./spire-server entry show
```

---

## 📝 Deploy Federated Workload - Template

### Step 1: Create Namespace
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
```

### Step 2: Create ServiceAccount
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app-sa
  namespace: my-app
```

### Step 3: Create ClusterSPIFFEID with Federation
```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: my-app-federated
spec:
  # SPIFFE ID template
  spiffeIDTemplate: "spiffe://YOUR-TRUST-DOMAIN/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  
  # Select pods by label
  podSelector:
    matchLabels:
      app: my-app
  
  # Select namespace
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: my-app
  
  # IMPORTANT: Enable federation with other clusters
  federatesWith:
  - "apps.client-1.devcluster.openshift.com"    # Trust Cluster 1
  - "apps.server-1.devcluster.openshift.com"    # Trust Cluster 2
  - "apps.aagnihot-cluster-fss.devcluster.openshift.com"  # Trust Cluster 3
  
  className: zero-trust-workload-identity-manager-spire
```

### Step 4: Deploy Your Application
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  namespace: my-app
  labels:
    app: my-app
spec:
  serviceAccountName: my-app-sa
  containers:
  - name: app
    image: your-image:tag
    volumeMounts:
    - name: spiffe-workload-api
      mountPath: /spiffe-workload-api
      readOnly: true
  volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io
      readOnly: true
```

---

## 💡 Key Points

### ✅ Federation IS Enabled When:
- ClusterSPIFFEID has `federatesWith` field listing other trust domains
- Workload receives trust bundles from specified domains
- Workload can verify identities from federated clusters
- mTLS works across clusters

### ❌ Federation IS NOT Enabled When:
- ClusterSPIFFEID does NOT have `federatesWith` field
- Workload only receives its own trust domain bundle
- Workload cannot verify identities from other clusters
- mTLS fails for cross-cluster communication

---

## 🔍 Troubleshooting

### Problem: Workload not getting SPIFFE identity

```bash
# Check if ClusterSPIFFEID exists and matches pod
kubectl get clusterspiffeid -A
kubectl describe clusterspiffeid <name>

# Check pod labels match the selector
kubectl get pod <pod-name> -n <namespace> --show-labels

# Check SPIRE agent logs
kubectl logs -n zero-trust-workload-identity-manager <spire-agent-pod> -c spire-agent
```

### Problem: Federation not working

```bash
# Verify trust bundles are exchanged
kubectl --kubeconfig <kubeconfig> exec -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server -- ./spire-server bundle list

# Check federation configuration in SPIRE server
kubectl --kubeconfig <kubeconfig> get configmap spire-server \
  -n zero-trust-workload-identity-manager -o yaml | grep -A 20 "federates_with"

# Verify ClusterFederatedTrustDomain resources exist
kubectl --kubeconfig <kubeconfig> get clusterfederatedtrustdomain

# Check SPIRE server logs for errors
kubectl --kubeconfig <kubeconfig> logs -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server --tail=100 | grep -i error
```

### Problem: Bundles not rotating

```bash
# Check if federates_with is configured
kubectl --kubeconfig <kubeconfig> get configmap spire-server \
  -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}' | \
  python3 -m json.tool | grep -A 20 "federates_with"

# Check bundle refresh logs (should see every ~75 seconds)
kubectl --kubeconfig <kubeconfig> logs -n zero-trust-workload-identity-manager \
  spire-server-0 -c spire-server --tail=200 | grep "Bundle refresh"
```

---

## 📚 Example Scenarios

### Scenario 1: Frontend (Cluster 1) → Backend (Cluster 3)

**On Cluster 1 (Frontend):**
```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: frontend
spec:
  spiffeIDTemplate: "spiffe://apps.client-1.devcluster.openshift.com/ns/demo/sa/frontend"
  federatesWith:
  - "apps.aagnihot-cluster-fss.devcluster.openshift.com"  # Trust Cluster 3
  ...
```

**On Cluster 3 (Backend):**
```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: backend
spec:
  spiffeIDTemplate: "spiffe://apps.aagnihot-cluster-fss.devcluster.openshift.com/ns/demo/sa/backend"
  federatesWith:
  - "apps.client-1.devcluster.openshift.com"  # Trust Cluster 1
  ...
```

**Result**: Frontend and Backend can establish mTLS connection! ✅

---

### Scenario 2: Service Mesh Across All Clusters

**On Cluster 1:**
```yaml
federatesWith:
- "apps.server-1.devcluster.openshift.com"
- "apps.aagnihot-cluster-fss.devcluster.openshift.com"
```

**On Cluster 2:**
```yaml
federatesWith:
- "apps.client-1.devcluster.openshift.com"
- "apps.aagnihot-cluster-fss.devcluster.openshift.com"
```

**On Cluster 3:**
```yaml
federatesWith:
- "apps.client-1.devcluster.openshift.com"
- "apps.server-1.devcluster.openshift.com"
```

**Result**: All workloads can communicate with each other across all clusters! ✅

---

## 🎯 Best Practices

1. **Least Privilege**: Only add trust domains to `federatesWith` that the workload needs
2. **Namespace Isolation**: Use different namespaces for different security zones
3. **Monitor Federation**: Regularly check bundle refresh logs
4. **Test Before Production**: Deploy test workloads first to verify federation
5. **Document Dependencies**: Keep track of which workloads federate with which clusters

---

## 📞 Support

For more details, see:
- **Complete Documentation**: `/home/rausingh/Documents/oape/ztwim-poc/THREE_WAY_FEDERATION_COMPLETE.md`
- **Setup Script**: `/home/rausingh/Documents/oape/ztwim-poc/federation-setup/add-third-cluster.sh`
- **Original 2-Way Setup**: `/home/rausingh/Documents/oape/ztwim-poc/federation-setup/setup-federation.sh`

---

## ✅ Quick Health Check

Run these three commands to verify everything is working:

```bash
# 1. Cluster 1 - Should show 2 trust domains
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/13Oct2025Cluster2/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list | grep "^\*"

# 2. Cluster 2 - Should show 2 trust domains
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/13Oct2025Cluster1/auth/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list | grep "^\*"

# 3. Cluster 3 - Should show 2 trust domains
kubectl --kubeconfig /home/rausingh/Downloads/kubeconfig \
  exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list | grep "^\*"
```

Expected output for each: 2 lines starting with `*` (the trust domains)

---

**🎉 Your three-way federation is ready to use!**

