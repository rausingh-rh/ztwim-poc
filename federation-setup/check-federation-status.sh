#!/bin/bash

# Quick federation status checker

CLUSTER1_KUBECONFIG="/home/rausingh/Documents/aws_cluster/22Oct2025Cluster1/auth/kubeconfig"
CLUSTER2_KUBECONFIG="/home/rausingh/Documents/aws_cluster/22Oct2025Cluster2/auth/kubeconfig"
C1_ENDPOINT="https://spire-server-federation-zero-trust-workload-identity-manager.apps.client-3.devcluster.openshift.com"
C2_ENDPOINT="https://spire-server-federation-zero-trust-workload-identity-manager.apps.server-3.devcluster.openshift.com"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Federation Status Quick Check                     ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Cluster 1 Federation Endpoint
echo -e "${YELLOW}📡 Cluster 1 Federation Endpoint:${NC}"
C1_DATA=$(curl -sk "$C1_ENDPOINT" 2>/dev/null)
echo "   Sequence: $(echo "$C1_DATA" | jq -r '.spiffe_sequence')"
echo "   Refresh Hint: $(echo "$C1_DATA" | jq -r '.spiffe_refresh_hint') seconds"
echo "   Keys: $(echo "$C1_DATA" | jq -r '.keys | length')"
echo ""

# Cluster 2 Federation Endpoint
echo -e "${YELLOW}📡 Cluster 2 Federation Endpoint:${NC}"
C2_DATA=$(curl -sk "$C2_ENDPOINT" 2>/dev/null)
echo "   Sequence: $(echo "$C2_DATA" | jq -r '.spiffe_sequence')"
echo "   Refresh Hint: $(echo "$C2_DATA" | jq -r '.spiffe_refresh_hint') seconds"
echo "   Keys: $(echo "$C2_DATA" | jq -r '.keys | length')"
echo ""

# Certificate Expiry
echo -e "${YELLOW}📅 Certificate Expiry (Cluster 1):${NC}"
echo "$C1_DATA" | jq -r '.keys[] | select(.use == "x509-svid") | .x5c[0]' | \
    base64 -d | openssl x509 -noout -dates 2>/dev/null | sed 's/^/   /'
echo ""

# Recent Refreshes
echo -e "${YELLOW}🔄 Recent Bundle Refreshes (Cluster 1):${NC}"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -n zero-trust-workload-identity-manager \
    spire-server-0 -c spire-server --tail=200 2>/dev/null | \
    grep "Bundle refreshed" | tail -3 | \
    awk '{print "   " $1, $2}' | sed 's/time="//g' | sed 's/"//g'
echo ""

# Count total refreshes
REFRESH_COUNT=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs \
    -n zero-trust-workload-identity-manager spire-server-0 -c spire-server \
    --tail=500 2>/dev/null | grep -c "Bundle refreshed")
echo -e "${YELLOW}📊 Statistics:${NC}"
echo "   Total refreshes in last 500 logs: $REFRESH_COUNT"
echo ""

# Health Check
echo -e "${YELLOW}✅ Health Summary:${NC}"
if [ "$REFRESH_COUNT" -gt 0 ]; then
    echo -e "   ${GREEN}✓ Bundles are being refreshed${NC}"
else
    echo "   ✗ No recent refreshes found"
fi

C1_SEQ=$(echo "$C1_DATA" | jq -r '.spiffe_sequence')
C2_SEQ=$(echo "$C2_DATA" | jq -r '.spiffe_sequence')
if [ "$C1_SEQ" != "null" ] && [ "$C2_SEQ" != "null" ]; then
    echo -e "   ${GREEN}✓ Both endpoints responding${NC}"
else
    echo "   ✗ Endpoint issues detected"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "   Sequence numbers stable = ${GREEN}NORMAL${NC} (until cert rotation)"
echo -e "   Bundle refreshed logs = ${GREEN}HEALTHY${NC} (polling working)"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
