# SPIRE Federation POC - Documentation Index

Quick reference to all documentation in this repository.

---

## 📚 Main Documentation

### 🌟 Start Here

**[SPIRE_FEDERATION_COMPLETE_GUIDE.md](SPIRE_FEDERATION_COMPLETE_GUIDE.md)** ⭐  
**Comprehensive guide covering ALL POCs** - Architecture, setup, usage, troubleshooting, and examples.  
**This is your main resource for understanding everything we built.**

---

## 📖 Phase-Specific Documentation

### Phase 1: Two-Way Federation

| Document | Description |
|----------|-------------|
| [FEDERATION_COMPLETE.md](FEDERATION_COMPLETE.md) | Original 2-cluster federation setup |
| [FEDERATION_AUTOMATION_COMPLETE.md](FEDERATION_AUTOMATION_COMPLETE.md) | Automation details and scripts |
| [README-FEDERATION.md](README-FEDERATION.md) | Quick reference for 2-way setup |

**What was done**: Federated Cluster 1 and Cluster 2 with automatic bundle rotation

---

### Phase 2: Three-Way Federation

| Document | Description |
|----------|-------------|
| [THREE_WAY_FEDERATION_COMPLETE.md](THREE_WAY_FEDERATION_COMPLETE.md) | Adding 3rd cluster to federation |
| [federation-setup/THREE_WAY_FEDERATION_QUICK_REFERENCE.md](federation-setup/THREE_WAY_FEDERATION_QUICK_REFERENCE.md) | Quick commands and examples |

**What was done**: Added Cluster 3 to create full mesh federation between all three clusters

---

### Phase 3: Auto-Federation

| Document | Description |
|----------|-------------|
| [AUTO_FEDERATION_DEPLOYED.md](AUTO_FEDERATION_DEPLOYED.md) | Auto-federation setup details |

**What was done**: Configured ClusterSPIFFEID resources to automatically federate all workloads

---

## 🔧 Scripts and Tools

### Setup Scripts

```bash
federation-setup/
├── setup-federation.sh              # 2-way federation setup
├── add-third-cluster.sh             # Add 3rd cluster
├── deploy-auto-federation-no-class.sh  # Deploy ClusterSPIFFEID (without className)
└── deploy-auto-federation.sh        # Deploy ClusterSPIFFEID (with className)
```

### Verification Scripts

```bash
federation-setup/
├── verify-federation.sh             # Verify 2-way federation
├── verify-3way-federation.sh        # Verify 3-way federation
└── monitor-bundle-refresh.sh        # 🆕 Interactive bundle refresh monitor
```

### Test Scripts

```bash
federation-setup/test-scripts/
├── direct-test.sh                   # Direct federation testing
├── show-workload-bundles.sh         # Show bundle information
└── README.md                        # Testing guide
```

---

## 🎯 Quick Start Guides

### New to This POC?

1. **Read**: [SPIRE_FEDERATION_COMPLETE_GUIDE.md](SPIRE_FEDERATION_COMPLETE_GUIDE.md) - Overview and architecture
2. **Check**: Current federation status
3. **Deploy**: Your first federated workload
4. **Verify**: It's working

### Setting Up New Clusters?

1. **For 2 clusters**: Run `federation-setup/setup-federation.sh`
2. **For 3rd cluster**: Run `federation-setup/add-third-cluster.sh`
3. **Verify**: Run verification scripts

### Deploying Workloads?

1. **Automatic**: Just deploy in any namespace - automatic federation!
2. **Manual**: Create custom ClusterSPIFFEID for specific needs
3. **Verify**: Check SPIRE entries with `spire-server entry show`

---

## 📋 Reference Information

### 🔄 Trust Bundle Refresh

| Document | Description |
|----------|-------------|
| **[TRUST_BUNDLE_REFRESH_GUIDE.md](federation-setup/TRUST_BUNDLE_REFRESH_GUIDE.md)** | 🆕 Complete guide on bundle refresh behavior |
| **[BUNDLE_REFRESH_CHEATSHEET.md](federation-setup/BUNDLE_REFRESH_CHEATSHEET.md)** | 🆕 Quick reference for refresh intervals |
| **[monitor-bundle-refresh.sh](federation-setup/monitor-bundle-refresh.sh)** | 🆕 Interactive monitoring tool |

**Key Facts**:
- Refresh Hint: 300 seconds (5 minutes)
- Actual Poll Interval: ~75 seconds (300 ÷ 4)
- Refreshes per Hour: ~48
- JSON Field: `spiffe_refresh_hint`

### Cluster Details

| Cluster | Trust Domain |
|---------|--------------|
| Cluster 1 | `apps.client-1.devcluster.openshift.com` |
| Cluster 2 | `apps.server-1.devcluster.openshift.com` |
| Cluster 3 | `apps.aagnihot-cluster-fss.devcluster.openshift.com` |

### Kubeconfig Paths

```bash
CLUSTER1="/home/rausingh/Documents/aws_cluster/13Oct2025Cluster2/auth/kubeconfig"
CLUSTER2="/home/rausingh/Documents/aws_cluster/13Oct2025Cluster1/auth/kubeconfig"
CLUSTER3="/home/rausingh/Downloads/kubeconfig"
```

---

## 🔍 Common Tasks

### Check Federation Status
```bash
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list
```

### Deploy Federated Workload
```bash
kubectl run myapp --image=nginx -n any-namespace
```

### Verify Workload Federation
```bash
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show -spiffeID spiffe://<trust-domain>/ns/<namespace>/sa/<sa>
```

### Watch Bundle Rotation
```bash
# Real-time monitoring
kubectl logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep "Bundle refresh"

# OR use the interactive monitor
./federation-setup/monitor-bundle-refresh.sh
```

### Check Bundle Refresh Configuration
```bash
# Check refresh hint in federation endpoint JSON
curl -k https://federation-endpoint/ | jq '.spiffe_refresh_hint'
# Returns: 300 (seconds)

# View recent refresh history
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 | \
  grep "Bundle refreshed" | tail -10
```

---

## 🆘 Troubleshooting

See the **Troubleshooting** section in [SPIRE_FEDERATION_COMPLETE_GUIDE.md](SPIRE_FEDERATION_COMPLETE_GUIDE.md#troubleshooting)

Common issues:
- Workload not getting SPIFFE identity
- Entry created but no FederatesWith
- Trust bundles not updating
- Cert-manager or other apps not federated

---

## 📁 Directory Structure

```
ztwim-poc/
├── SPIRE_FEDERATION_COMPLETE_GUIDE.md  ⭐ Main guide
├── DOCUMENTATION_INDEX.md              📚 This file
├── THREE_WAY_FEDERATION_COMPLETE.md    🔗 3-way federation
├── AUTO_FEDERATION_DEPLOYED.md         🤖 Auto-federation
├── FEDERATION_COMPLETE.md              📖 2-way federation
├── FEDERATION_AUTOMATION_COMPLETE.md   ⚙️  Automation
│
├── federation-setup/                   🔧 Scripts directory
│   ├── setup-federation.sh
│   ├── add-third-cluster.sh
│   ├── verify-federation.sh
│   ├── verify-3way-federation.sh
│   ├── deploy-auto-federation.sh
│   ├── monitor-bundle-refresh.sh       🆕 Bundle refresh monitor
│   ├── THREE_WAY_FEDERATION_QUICK_REFERENCE.md
│   ├── TRUST_BUNDLE_REFRESH_GUIDE.md   🆕 Bundle refresh docs
│   ├── BUNDLE_REFRESH_CHEATSHEET.md    🆕 Quick reference
│   │
│   ├── test-scripts/
│   │   ├── direct-test.sh
│   │   ├── show-workload-bundles.sh
│   │   └── README.md
│   │
│   ├── demo/                          📦 Demo workloads
│   ├── test-workloads/                🧪 Test workloads
│   └── workloads/                     💼 Example workloads
│
├── spire/                             📂 SPIRE source
├── spiffe-csi/                        📂 SPIFFE CSI driver
├── spire-controller-manager/          📂 Controller manager
└── zero-trust-workload-identity-manager/  📂 Operator
```

---

## 📊 Status Dashboard

### Current Status: ✅ FULLY OPERATIONAL

| Component | Status |
|-----------|--------|
| 3-Way Federation | ✅ Active |
| Trust Bundle Rotation | ✅ Every ~75s |
| Auto-Federation | ✅ Active |
| Cluster 1 | ✅ Operational |
| Cluster 2 | ✅ Operational |
| Cluster 3 | ⚠️ Network issue |

### Coverage

- **71** Namespaces covered
- **14+** Pods federated
- **39+** FederatesWith entries

---

## 🎓 Learning Resources

### Understanding SPIRE Federation

1. Read: [SPIRE_FEDERATION_COMPLETE_GUIDE.md#federation-architecture](SPIRE_FEDERATION_COMPLETE_GUIDE.md#federation-architecture)
2. See: Trust bundle flow diagram
3. Understand: Workload identity flow

### Key Concepts

- **Trust Domain**: Unique identifier for a cluster's SPIRE deployment
- **Trust Bundle**: Collection of CA certificates from a trust domain
- **Federation**: Sharing trust bundles between trust domains
- **SPIFFE ID**: Unique identity for a workload
- **ClusterSPIFFEID**: Kubernetes CRD that defines workload identities

### Why className is Required

See: [SPIRE_FEDERATION_COMPLETE_GUIDE.md#why-classname-is-required](SPIRE_FEDERATION_COMPLETE_GUIDE.md#why-classname-is-required)

---

## 💡 Examples

See the **Examples and Use Cases** section in [SPIRE_FEDERATION_COMPLETE_GUIDE.md#examples-and-use-cases](SPIRE_FEDERATION_COMPLETE_GUIDE.md#examples-and-use-cases)

Examples include:
1. Frontend-Backend across clusters
2. Multi-region database access
3. Service mesh across all clusters
4. Cert-manager with SPIFFE certificates

---

## 🔄 Recent Changes

**October 22, 2025**:
- 🆕 Added comprehensive trust bundle refresh documentation
- 🆕 Created interactive bundle refresh monitoring tool
- 🆕 Added bundle refresh cheat sheet

**October 13, 2025**:
- ✅ Added 3-way federation
- ✅ Deployed universal auto-federation ClusterSPIFFEID
- ✅ Created comprehensive documentation
- ✅ Verified 71 namespaces covered

**October 9, 2025**:
- ✅ Initial 2-way federation
- ✅ Automatic bundle rotation verified
- ✅ Test workloads deployed

---

## 📞 Support

For questions or issues:

1. **Check documentation**: Start with main guide
2. **Review troubleshooting**: See guide's troubleshooting section
3. **Check logs**: SPIRE server and controller logs
4. **Verify configuration**: Use verification scripts

---

## 🚀 Next Steps

1. ✅ ~~Setup 2-way federation~~ (Complete)
2. ✅ ~~Add 3rd cluster~~ (Complete)
3. ✅ ~~Auto-federation~~ (Complete)
4. ⏳ Fix Cluster 3 network connectivity
5. ⏳ Deploy production workloads
6. ⏳ Implement monitoring

---

**Last Updated**: October 13, 2025  
**Status**: Production Ready  
**Repository**: `/home/rausingh/Documents/oape/ztwim-poc`




