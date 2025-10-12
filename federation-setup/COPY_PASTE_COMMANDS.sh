#!/bin/bash
# Copy and paste these commands to test federation yourself!

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         COPY-PASTE TEST COMMANDS FOR FEDERATION               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Choose a test to run:"
echo ""
echo "1. Quick status check (10 seconds)"
echo "2. Show federated vs non-federated entries"
echo "3. Watch bundle rotation LIVE (wait ~75 seconds)"
echo "4. Run comprehensive automated test"
echo "5. Show recent rotation history"
echo ""
read -p "Enter choice (1-5): " CHOICE

case $CHOICE in
  1)
    echo ""
    echo "🔍 QUICK STATUS CHECK"
    echo "===================="
    echo ""
    
    echo "✅ Cluster 1 trust bundles:"
    kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
      exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
      ./spire-server bundle list 2>/dev/null | grep "apps.cluster"
    
    echo ""
    echo "✅ Cluster 2 trust bundles:"
    kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
      exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
      ./spire-server bundle list 2>/dev/null | grep "apps.cluster"
    
    echo ""
    echo "✅ If you see BOTH trust domains listed, federation is working!"
    ;;
    
  2)
    echo ""
    echo "📋 FEDERATED vs NON-FEDERATED COMPARISON"
    echo "========================================"
    echo ""
    
    echo "1️⃣  FEDERATED Backend (Cluster 2):"
    echo "-----------------------------------"
    kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
      exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
      ./spire-server entry show 2>/dev/null | grep -A 12 "federated-backend" | head -13
    
    echo ""
    echo "2️⃣  NON-FEDERATED Backend (Cluster 2):"
    echo "---------------------------------------"
    kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
      exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
      ./spire-server entry show 2>/dev/null | grep -A 12 "non-federated-backend" | head -13
    
    echo ""
    echo "👀 LOOK FOR THE DIFFERENCE:"
    echo "   Federated entry has: FederatesWith field ✅"
    echo "   Non-federated entry: NO FederatesWith field ❌"
    ;;
    
  3)
    echo ""
    echo "🔴 LIVE BUNDLE ROTATION MONITOR"
    echo "================================"
    echo ""
    echo "Monitoring BOTH clusters for bundle refreshes..."
    echo "(Press Ctrl+C to stop, or wait ~90 seconds to see rotation)"
    echo ""
    
    timeout 90 bash << 'INNER'
kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server 2>/dev/null | \
  grep --line-buffered "Bundle refresh" | \
  while read line; do
    echo "🔄 [CLUSTER 1] $(date '+%H:%M:%S') - Bundle refreshed automatically!"
  done &

kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server 2>/dev/null | \
  grep --line-buffered "Bundle refresh" | \
  while read line; do
    echo "🔄 [CLUSTER 2] $(date '+%H:%M:%S') - Bundle refreshed automatically!"
  done &

wait
INNER
    
    echo ""
    echo "✅ If you saw refresh events, rotation is active!"
    ;;
    
  4)
    echo ""
    echo "🧪 RUNNING COMPREHENSIVE TEST"
    echo "============================="
    echo ""
    /home/rausingh/Documents/oape/ztwim-poc/federation-setup/test-scripts/test-federation.sh
    ;;
    
  5)
    echo ""
    echo "📊 ROTATION HISTORY"
    echo "==================="
    echo ""
    
    echo "Cluster 1 - Last 10 bundle refreshes:"
    kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
      logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 2>/dev/null | \
      grep "Bundle refreshed" | grep "cluster-2" | tail -10 | \
      awk '{print "  " $1, $2, "- Auto refresh"}'
    
    echo ""
    echo "Cluster 2 - Last 10 bundle refreshes:"
    kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
      logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 2>/dev/null | \
      grep "Bundle refreshed" | grep "cluster-1" | tail -10 | \
      awk '{print "  " $1, $2, "- Auto refresh"}'
    
    echo ""
    echo "Next scheduled refresh:"
    kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig \
      logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 2>/dev/null | \
      grep "Scheduling next" | tail -1 | awk -F'"' '{print "  Cluster 1: " $4}'
    kubectl --kubeconfig /home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig \
      logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 2>/dev/null | \
      grep "Scheduling next" | tail -1 | awk -F'"' '{print "  Cluster 2: " $4}'
    
    echo ""
    echo "✅ Multiple refreshes = Rotation is working!"
    ;;
    
  *)
    echo "Invalid choice"
    ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "See TEST_COMMANDS.md for all available test commands!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

