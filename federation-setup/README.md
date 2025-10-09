# SPIRE Federation Setup - Quick Reference

This directory contains all configuration files and documentation for setting up SPIRE-to-SPIRE federation between two OpenShift clusters.

## Quick Start

### Cluster Information
- **Cluster 1**: Trust Domain: `apps.cluster-1.devcluster.openshift.com`
- **Cluster 2**: Trust Domain: `apps.cluster-2.devcluster.openshift.com`

### Setup Summary

1. **Configure Federation Endpoints** - Add federation bundle endpoints to SPIRE server configs
2. **Expose Federation Services** - Create Services and Routes for bundle endpoints
3. **Bootstrap Federation** - Exchange trust bundles using ClusterFederatedTrustDomain CRDs
4. **Create Federated Workloads** - Deploy workloads with ClusterSPIFFEID resources with `federatesWith`

## Files

### Configuration Files
- `cluster1-current-cm.yaml` - SPIRE server ConfigMap with federation endpoint (Cluster 1)
- `cluster2-current-cm.yaml` - SPIRE server ConfigMap with federation endpoint (Cluster 2)
- `cluster1-federation-service.yaml` - Kubernetes Service for federation endpoint (Cluster 1)
- `cluster2-federation-service.yaml` - Kubernetes Service for federation endpoint (Cluster 2)
- `cluster1-federation-route.yaml` - OpenShift Route for federation endpoint (Cluster 1)
- `cluster2-federation-route.yaml` - OpenShift Route for federation endpoint (Cluster 2)

### Federation Resources
- `cluster1-federated-trust-domain.yaml` - ClusterFederatedTrustDomain resource (Cluster 1)
- `cluster2-federated-trust-domain.yaml` - ClusterFederatedTrustDomain resource (Cluster 2)
- `cluster1-bundle.json` - Exported trust bundle from Cluster 1
- `cluster2-bundle.json` - Exported trust bundle from Cluster 2

### Workload Resources
- `workloads/backend-server.yaml` - Backend server deployment (Cluster 2)
- `workloads/frontend-client.yaml` - Frontend client deployment (Cluster 1)
- `workloads/backend-server-spiffeid.yaml` - ClusterSPIFFEID with federation (Cluster 2)
- `workloads/frontend-client-spiffeid.yaml` - ClusterSPIFFEID with federation (Cluster 1)

### Documentation
- `FEDERATION_SETUP_DOCUMENTATION.md` - Complete step-by-step documentation

## Verification Commands

### Check Trust Bundles
```bash
# Cluster 1 - Should list cluster-2's bundle
kubectl --kubeconfig /path/to/cluster1/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list

# Cluster 2 - Should list cluster-1's bundle  
kubectl --kubeconfig /path/to/cluster2/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list
```

### Check Registration Entries
```bash
# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show

# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show
```

### Check Federation Status
```bash
# Cluster 1
kubectl --kubeconfig /path/to/cluster1/kubeconfig get clusterfederatedtrustdomain -o wide

# Cluster 2
kubectl --kubeconfig /path/to/cluster2/kubeconfig get clusterfederatedtrustdomain -o wide
```

## Key Points

✅ **Federation is Working When**:
- Each cluster lists the other's trust bundle in `spire-server bundle list`
- Registration entries show `FederatesWith` field with the federated trust domain
- ClusterFederatedTrustDomain resources are created and show endpoint URLs
- Workloads can verify SVIDs from the federated trust domain

⚠️ **Important Notes**:
- Federation uses SPIFFE Authentication (`https_spiffe` profile)
- Initial trust bootstrap requires manual bundle exchange
- Subsequent updates are automatic via bundle endpoints
- Port 8443 must be exposed on SPIRE server pods for federation

## Federation Architecture

```
┌─────────────────────────────────────┐      ┌─────────────────────────────────────┐
│         Cluster 1                   │      │         Cluster 2                   │
│  Trust Domain: cluster-1...         │      │  Trust Domain: cluster-2...         │
│                                     │      │                                     │
│  ┌──────────────────┐              │      │  ┌──────────────────┐              │
│  │  SPIRE Server    │              │      │  │  SPIRE Server    │              │
│  │  Port: 8443      │◄─────────────┼──────┼─►│  Port: 8443      │              │
│  │  (Federation     │  Bundle      │      │  │  (Federation     │              │
│  │   Endpoint)      │  Exchange    │      │  │   Endpoint)      │              │
│  └──────────────────┘              │      │  └──────────────────┘              │
│           │                         │      │           │                         │
│           │ Issues SVIDs            │      │           │ Issues SVIDs            │
│           │ + Fed Bundles           │      │           │ + Fed Bundles           │
│           ▼                         │      │           ▼                         │
│  ┌──────────────────┐              │      │  ┌──────────────────┐              │
│  │  Frontend Client │              │      │  │  Backend Server  │              │
│  │  SPIFFE ID:      │              │      │  │  SPIFFE ID:      │              │
│  │  cluster-1.../   │◄─────────────┼──────┼─►│  cluster-2.../   │              │
│  │  frontend-client │   mTLS with  │      │  │  backend-server  │              │
│  │                  │   Federation │      │  │                  │              │
│  └──────────────────┘              │      │  └──────────────────┘              │
└─────────────────────────────────────┘      └─────────────────────────────────────┘
```

## Next Steps

1. Deploy your application workloads
2. Create ClusterSPIFFEID resources with appropriate `federatesWith` fields
3. Configure your applications to use SPIFFE Workload API for mTLS
4. Monitor federation health using SPIRE server logs and metrics

For detailed information, see `FEDERATION_SETUP_DOCUMENTATION.md`.

