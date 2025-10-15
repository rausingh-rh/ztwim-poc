#!/bin/bash

# Script to deploy auto-federation ClusterSPIFFEID resources to all clusters

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Cluster configurations
CLUSTER1_KUBECONFIG="/home/rausingh/Documents/aws_cluster/13Oct2025Cluster2/auth/kubeconfig"
CLUSTER2_KUBECONFIG="/home/rausingh/Documents/aws_cluster/13Oct2025Cluster1/auth/kubeconfig"
CLUSTER3_KUBECONFIG="/home/rausingh/Downloads/kubeconfig"

CLUSTER1_TRUST_DOMAIN="apps.client-1.devcluster.openshift.com"
CLUSTER2_TRUST_DOMAIN="apps.server-1.devcluster.openshift.com"
CLUSTER3_TRUST_DOMAIN="apps.aagnihot-cluster-fss.devcluster.openshift.com"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Deploy Auto-Federation ClusterSPIFFEID Resources              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to deploy ClusterSPIFFEID to a cluster
deploy_to_cluster() {
    local kubeconfig=$1
    local trust_domain=$2
    local cluster_name=$3
    
    echo -e "${YELLOW}Deploying to $cluster_name ($trust_domain)...${NC}"
    
    # Create demo namespace if it doesn't exist
    kubectl --kubeconfig "$kubeconfig" create namespace demo --dry-run=client -o yaml | kubectl --kubeconfig "$kubeconfig" apply -f - 2>/dev/null || true
    
    # Deploy ClusterSPIFFEID for demo namespace
    cat <<EOF | kubectl --kubeconfig "$kubeconfig" apply -f -
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: demo-namespace-auto-federated
spec:
  spiffeIDTemplate: "spiffe://$trust_domain/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels: {}
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: demo
  federatesWith:
  - "apps.client-1.devcluster.openshift.com"
  - "apps.server-1.devcluster.openshift.com"
  - "apps.aagnihot-cluster-fss.devcluster.openshift.com"
  className: zero-trust-workload-identity-manager-spire
EOF
    
    # Deploy ClusterSPIFFEID for label-based selection
    cat <<EOF | kubectl --kubeconfig "$kubeconfig" apply -f -
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: label-based-auto-federated
spec:
  spiffeIDTemplate: "spiffe://$trust_domain/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      federated: "true"
  namespaceSelector:
    matchLabels: {}
  federatesWith:
  - "apps.client-1.devcluster.openshift.com"
  - "apps.server-1.devcluster.openshift.com"
  - "apps.aagnihot-cluster-fss.devcluster.openshift.com"
  className: zero-trust-workload-identity-manager-spire
EOF
    
    echo -e "${GREEN}✓${NC} Deployed to $cluster_name"
    echo ""
}

# Deploy to all clusters
deploy_to_cluster "$CLUSTER1_KUBECONFIG" "$CLUSTER1_TRUST_DOMAIN" "Cluster 1"
deploy_to_cluster "$CLUSTER2_KUBECONFIG" "$CLUSTER2_TRUST_DOMAIN" "Cluster 2"
deploy_to_cluster "$CLUSTER3_KUBECONFIG" "$CLUSTER3_TRUST_DOMAIN" "Cluster 3"

echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Auto-Federation Deployed Successfully!                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}📋 What was deployed:${NC}"
echo ""
echo "1️⃣  demo-namespace-auto-federated"
echo "   - Federates ALL workloads in 'demo' namespace"
echo "   - Works across all 3 clusters"
echo ""
echo "2️⃣  label-based-auto-federated"
echo "   - Federates workloads with label 'federated=true'"
echo "   - Works in ANY namespace"
echo ""

echo -e "${BLUE}🚀 How to use:${NC}"
echo ""
echo "Method 1: Deploy to 'demo' namespace (automatic federation)"
echo "  kubectl create namespace demo"
echo "  kubectl run nginx --image=nginx -n demo"
echo "  # This pod automatically gets federated entry!"
echo ""
echo "Method 2: Add label to pod (works in any namespace)"
echo "  kubectl run nginx --image=nginx --labels=federated=true"
echo "  # This pod automatically gets federated entry!"
echo ""

echo -e "${BLUE}🔍 Verify:${NC}"
echo ""
echo "Check ClusterSPIFFEID resources:"
echo "  kubectl get clusterspiffeid"
echo ""
echo "Check SPIRE entries (after deploying a pod):"
echo "  kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \\"
echo "    ./spire-server entry show"
echo ""

echo -e "${GREEN}🎉 Done! Your workloads will now be automatically federated!${NC}"
echo ""

