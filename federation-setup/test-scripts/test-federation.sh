#!/bin/bash

# Test script for SPIRE federation
CLUSTER1_KUBECONFIG="/home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig"
CLUSTER2_KUBECONFIG="/home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig"

echo "========================================"
echo "SPIRE FEDERATION TEST SUITE"
echo "========================================"
echo ""

echo "Test 1: Verify Trust Bundles are Exchanged"
echo "-------------------------------------------"
echo ""
echo "Cluster 1 - Trust bundles:"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list | grep -E "(\*\*\*|apps\.cluster)" || echo "Error fetching bundles"

echo ""
echo "Cluster 2 - Trust bundles:"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list | grep -E "(\*\*\*|apps\.cluster)" || echo "Error fetching bundles"

echo ""
echo ""
echo "Test 2: Verify Registration Entries with Federation"
echo "----------------------------------------------------"
echo ""
echo "Cluster 1 - Federated entries:"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show | grep -A 15 "federated-frontend" || echo "No federated-frontend entry yet"

echo ""
echo "Cluster 2 - Federated entries:"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show | grep -A 15 "federated-backend" || echo "No federated-backend entry yet"

echo ""
echo ""
echo "Test 3: Prove Bundle Rotation is Active"
echo "----------------------------------------"
echo "Checking last 5 bundle refresh events in each cluster..."
echo ""
echo "Cluster 1 - Recent bundle refreshes:"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 | grep "Bundle refresh" | tail -5

echo ""
echo "Cluster 2 - Recent bundle refreshes:"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 | grep "Bundle refresh" | tail -5

echo ""
echo "Checking scheduled next refresh..."
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 | grep "Scheduling next bundle refresh" | tail -1
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 | grep "Scheduling next bundle refresh" | tail -1

echo ""
echo ""
echo "Test 4: Show Bundle Rotation in Real-Time"
echo "------------------------------------------"
echo "Monitoring for next bundle refresh (will wait up to 2 minutes)..."
echo ""

CLUSTER1_POD="spire-server-0"
CLUSTER2_POD="spire-server-0"
NS="zero-trust-workload-identity-manager"

echo "Starting log monitor..."
timeout 120 bash -c "
kubectl --kubeconfig '$CLUSTER1_KUBECONFIG' logs -f -n $NS $CLUSTER1_POD -c spire-server 2>/dev/null | grep --line-buffered 'Bundle refresh' &
PID1=\$!

kubectl --kubeconfig '$CLUSTER2_KUBECONFIG' logs -f -n $NS $CLUSTER2_POD -c spire-server 2>/dev/null | grep --line-buffered 'Bundle refresh' &
PID2=\$!

wait \$PID1 \$PID2
" || echo "Timeout reached or bundles refreshed"

echo ""
echo "========================================"
echo "FEDERATION TEST COMPLETE"
echo "========================================"

