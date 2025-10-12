#!/bin/bash

# SPIRE Federation Cleanup Script

set -e

usage() {
    echo "Usage: $0 <cluster1-kubeconfig> <cluster2-kubeconfig>"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

CLUSTER1_KUBECONFIG="$1"
CLUSTER2_KUBECONFIG="$2"

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         SPIRE Federation Cleanup                                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

echo "This will remove:"
echo "  • Federation demo namespace and workloads"
echo "  • ClusterFederatedTrustDomain resources"
echo "  • Federation routes and services"
echo ""
read -p "Continue? (y/N): " CONFIRM

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Cleaning up Cluster 1..."
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" delete namespace federation-demo --ignore-not-found=true
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" delete clusterfederatedtrustdomain --all --ignore-not-found=true
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" delete route spire-server-federation -n zero-trust-workload-identity-manager --ignore-not-found=true
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" delete service spire-server-federation -n zero-trust-workload-identity-manager --ignore-not-found=true

echo "Cleaning up Cluster 2..."
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" delete namespace federation-demo --ignore-not-found=true
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" delete clusterfederatedtrustdomain --all --ignore-not-found=true
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" delete route spire-server-federation -n zero-trust-workload-identity-manager --ignore-not-found=true
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" delete service spire-server-federation -n zero-trust-workload-identity-manager --ignore-not-found=true

echo ""
echo "✓ Cleanup complete!"
echo ""
echo "Note: SPIRE server configs still have federation configuration."
echo "To fully remove federation, you would need to:"
echo "  1. Remove 'federation' block from spire-server ConfigMap"
echo "  2. Restart spire-server StatefulSet"
echo ""

