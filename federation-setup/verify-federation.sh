#!/bin/bash

# SPIRE Federation Verification Script
# This script tests and verifies federation is working

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <cluster1-kubeconfig> <cluster2-kubeconfig>"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

CLUSTER1_KUBECONFIG="$1"
CLUSTER2_KUBECONFIG="$2"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         SPIRE Federation Verification & Testing                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Test 1: Trust bundle exchange
echo -e "${YELLOW}Test 1: Verifying Trust Bundle Exchange${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "Cluster 1 bundles:"
C1_BUNDLES=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list 2>/dev/null | grep -c "^\*" || echo "0")

if [ "$C1_BUNDLES" -ge 2 ]; then
    echo -e "  ${GREEN}✓${NC} Cluster 1 has $C1_BUNDLES trust bundles (including federated)"
else
    echo -e "  ${RED}✗${NC} Cluster 1 has only $C1_BUNDLES bundle (federation may not be working)"
fi

echo "Cluster 2 bundles:"
C2_BUNDLES=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list 2>/dev/null | grep -c "^\*" || echo "0")

if [ "$C2_BUNDLES" -ge 2 ]; then
    echo -e "  ${GREEN}✓${NC} Cluster 2 has $C2_BUNDLES trust bundles (including federated)"
else
    echo -e "  ${RED}✗${NC} Cluster 2 has only $C2_BUNDLES bundle (federation may not be working)"
fi

echo ""

# Test 2: Bundle rotation
echo -e "${YELLOW}Test 2: Verifying Automatic Bundle Rotation${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "Recent bundle refreshes in Cluster 1:"
C1_REFRESHES=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 2>/dev/null | grep -c "Bundle refreshed" || echo "0")

if [ "$C1_REFRESHES" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} Found $C1_REFRESHES bundle refresh events"
    kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 2>/dev/null | grep "Bundle refreshed" | tail -3 | awk '{print "    " $1, $2}'
else
    echo -e "  ${RED}✗${NC} No bundle refresh events found"
fi

echo ""
echo "Next scheduled refresh:"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 2>/dev/null | grep "Scheduling next" | tail -1 | awk -F'"' '{print "  Next at: " $4}'

echo ""

# Test 3: Federated vs non-federated entries
echo -e "${YELLOW}Test 3: Comparing Federated vs Non-Federated Entries${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "Federated backend entry:"
FED_ENTRY=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show 2>/dev/null | grep -A 12 "federated-backend" | grep "FederatesWith" || echo "")

if [ ! -z "$FED_ENTRY" ]; then
    echo -e "  ${GREEN}✓${NC} Has FederatesWith field:"
    echo "    $FED_ENTRY"
else
    echo -e "  ${RED}✗${NC} No FederatesWith field found (check if workload is deployed)"
fi

echo ""
echo "Non-federated backend entry:"
NON_FED_ENTRY=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show 2>/dev/null | grep -A 12 "non-federated-backend" | grep "FederatesWith" || echo "")

if [ -z "$NON_FED_ENTRY" ]; then
    echo -e "  ${GREEN}✓${NC} No FederatesWith field (correct for non-federated)"
else
    echo -e "  ${RED}✗${NC} Unexpected: Has FederatesWith field"
fi

echo ""

# Test 4: Pod status
echo -e "${YELLOW}Test 4: Checking Pod Status${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "Cluster 2 (Backends):"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get pods -n federation-demo -o wide 2>/dev/null || echo "  No pods found (may not be deployed yet)"

echo ""
echo "Cluster 1 (Frontends):"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get pods -n federation-demo -o wide 2>/dev/null || echo "  No pods found (may not be deployed yet)"

echo ""

# Test 5: API endpoints
echo -e "${YELLOW}Test 5: API Endpoint URLs${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FED_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route federated-backend -n federation-demo -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "not ready")
NON_FED_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route non-federated-backend -n federation-demo -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "not ready")

echo -e "${GREEN}Federated Backend API:${NC}"
echo "  $FED_URL/api/stock-data"
echo ""
echo -e "${RED}Non-Federated Backend API:${NC}"
echo "  $NON_FED_URL/api/stock-data"
echo ""

# Test 6: Curl tests
echo -e "${YELLOW}Test 6: CURL Test Commands (Copy-Paste These!)${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "# Test federated backend (should return stock data):"
echo "curl $FED_URL/api/stock-data"
echo ""
echo "# Test non-federated backend (should return error):"
echo "curl $NON_FED_URL/api/stock-data"
echo ""
echo "# Watch federated frontend calling backend:"
echo "kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -f federated-frontend -n federation-demo"
echo ""
echo "# Watch federated backend receiving calls:"
echo "kubectl --kubeconfig $CLUSTER2_KUBECONFIG logs -f federated-backend -n federation-demo"
echo ""
echo "# Watch bundle rotation live (wait ~75 seconds):"
echo "kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep 'Bundle refresh'"
echo ""

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    WHAT TO EXPECT                                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Federated Frontend → Federated Backend:${NC}"
echo "  • Frontend calls: http://federated-backend.../api/stock-data"
echo "  • Backend receives request and verifies SPIFFE ID"
echo "  • Backend responds with JSON stock data"
echo "  • Frontend logs show: ✅ SUCCESS!"
echo "  • Backend logs show: 📥 API REQUEST → ✅ Response sent"
echo ""
echo -e "${RED}Non-Federated Frontend → Non-Federated Backend:${NC}"
echo "  • Frontend tries to call backend"
echo "  • Connection fails (no trust bundle)"
echo "  • Frontend logs show: ❌ FAILED"
echo "  • Backend logs show: (nothing - request never arrives)"
echo ""
echo -e "${BLUE}Bundle Rotation:${NC}"
echo "  • Logs show 'Bundle refreshed' every ~75 seconds"
echo "  • Automatic and continuous"
echo "  • No manual intervention needed"
echo ""

echo -e "${GREEN}🎉 Run the curl commands above to test the APIs!${NC}"
echo ""

