#!/bin/bash

# Quick verification script for three-way federation

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CLUSTER1_KUBECONFIG="/home/rausingh/Documents/aws_cluster/13Oct2025Cluster2/auth/kubeconfig"
CLUSTER2_KUBECONFIG="/home/rausingh/Documents/aws_cluster/13Oct2025Cluster1/auth/kubeconfig"
CLUSTER3_KUBECONFIG="/home/rausingh/Downloads/kubeconfig"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Three-Way Federation Verification                          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to count trust domains
count_trust_domains() {
    local kubeconfig=$1
    local count=$(kubectl --kubeconfig "$kubeconfig" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list 2>/dev/null | grep -c "^\*" || echo "0")
    echo $count
}

# Function to count federation resources
count_fed_resources() {
    local kubeconfig=$1
    local count=$(kubectl --kubeconfig "$kubeconfig" get clusterfederatedtrustdomain --no-headers 2>/dev/null | wc -l)
    echo $count
}

echo -e "${YELLOW}Checking Cluster 1 (client-1)...${NC}"
C1_BUNDLES=$(count_trust_domains "$CLUSTER1_KUBECONFIG")
C1_RESOURCES=$(count_fed_resources "$CLUSTER1_KUBECONFIG")
if [ "$C1_BUNDLES" -eq 2 ] && [ "$C1_RESOURCES" -eq 2 ]; then
    echo -e "${GREEN}✓${NC} Trust bundles: $C1_BUNDLES (Expected: 2)"
    echo -e "${GREEN}✓${NC} Federation resources: $C1_RESOURCES (Expected: 2)"
else
    echo -e "${RED}✗${NC} Trust bundles: $C1_BUNDLES (Expected: 2)"
    echo -e "${RED}✗${NC} Federation resources: $C1_RESOURCES (Expected: 2)"
fi
echo ""

echo -e "${YELLOW}Checking Cluster 2 (server-1)...${NC}"
C2_BUNDLES=$(count_trust_domains "$CLUSTER2_KUBECONFIG")
C2_RESOURCES=$(count_fed_resources "$CLUSTER2_KUBECONFIG")
if [ "$C2_BUNDLES" -eq 2 ] && [ "$C2_RESOURCES" -eq 2 ]; then
    echo -e "${GREEN}✓${NC} Trust bundles: $C2_BUNDLES (Expected: 2)"
    echo -e "${GREEN}✓${NC} Federation resources: $C2_RESOURCES (Expected: 2)"
else
    echo -e "${RED}✗${NC} Trust bundles: $C2_BUNDLES (Expected: 2)"
    echo -e "${RED}✗${NC} Federation resources: $C2_RESOURCES (Expected: 2)"
fi
echo ""

echo -e "${YELLOW}Checking Cluster 3 (aagnihot-cluster-fss)...${NC}"
C3_BUNDLES=$(count_trust_domains "$CLUSTER3_KUBECONFIG")
C3_RESOURCES=$(count_fed_resources "$CLUSTER3_KUBECONFIG")
if [ "$C3_BUNDLES" -eq 2 ] && [ "$C3_RESOURCES" -eq 2 ]; then
    echo -e "${GREEN}✓${NC} Trust bundles: $C3_BUNDLES (Expected: 2)"
    echo -e "${GREEN}✓${NC} Federation resources: $C3_RESOURCES (Expected: 2)"
else
    echo -e "${RED}✗${NC} Trust bundles: $C3_BUNDLES (Expected: 2)"
    echo -e "${RED}✗${NC} Federation resources: $C3_RESOURCES (Expected: 2)"
fi
echo ""

# Check if all pass
TOTAL_CHECKS=6
PASSED_CHECKS=0

[ "$C1_BUNDLES" -eq 2 ] && ((PASSED_CHECKS++))
[ "$C1_RESOURCES" -eq 2 ] && ((PASSED_CHECKS++))
[ "$C2_BUNDLES" -eq 2 ] && ((PASSED_CHECKS++))
[ "$C2_RESOURCES" -eq 2 ] && ((PASSED_CHECKS++))
[ "$C3_BUNDLES" -eq 2 ] && ((PASSED_CHECKS++))
[ "$C3_RESOURCES" -eq 2 ] && ((PASSED_CHECKS++))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$PASSED_CHECKS" -eq "$TOTAL_CHECKS" ]; then
    echo -e "${GREEN}✅ ALL CHECKS PASSED ($PASSED_CHECKS/$TOTAL_CHECKS)${NC}"
    echo -e "${GREEN}✅ Three-way federation is FULLY OPERATIONAL!${NC}"
else
    echo -e "${YELLOW}⚠️  SOME CHECKS FAILED ($PASSED_CHECKS/$TOTAL_CHECKS)${NC}"
    echo -e "${YELLOW}Please review the output above${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo -e "${BLUE}📋 Detailed Information:${NC}"
echo ""
echo "For complete bundle details, run:"
echo "  kubectl --kubeconfig <kubeconfig> exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list"
echo ""
echo "For federation resources, run:"
echo "  kubectl --kubeconfig <kubeconfig> get clusterfederatedtrustdomain"
echo ""
echo "To watch bundle rotation, run:"
echo "  kubectl --kubeconfig <kubeconfig> logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep 'Bundle refresh'"
echo ""

