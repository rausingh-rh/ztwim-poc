#!/bin/bash

# Script to monitor for spiffe_sequence changes
# This will alert you when certificate rotation happens

CLUSTER1_ENDPOINT="https://spire-server-federation-zero-trust-workload-identity-manager.apps.client-3.devcluster.openshift.com"
CLUSTER2_ENDPOINT="https://spire-server-federation-zero-trust-workload-identity-manager.apps.server-3.devcluster.openshift.com"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}     Monitoring spiffe_sequence for Changes${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "This script will alert you when the bundle sequence changes"
echo "(indicating certificate rotation)"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

PREV_C1=""
PREV_C2=""

while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Get current sequences
    CURR_C1=$(curl -sk "$CLUSTER1_ENDPOINT" 2>/dev/null | jq -r '.spiffe_sequence // "error"')
    CURR_C2=$(curl -sk "$CLUSTER2_ENDPOINT" 2>/dev/null | jq -r '.spiffe_sequence // "error"')
    
    # Check Cluster 1
    if [ "$CURR_C1" != "$PREV_C1" ] && [ -n "$PREV_C1" ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  🔔 CLUSTER 1 SEQUENCE CHANGED! 🔔                       ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo -e "  Time: ${CYAN}$TIMESTAMP${NC}"
        echo -e "  Old: ${RED}$PREV_C1${NC} → New: ${GREEN}$CURR_C1${NC}"
        echo -e "  ${YELLOW}Certificate rotation detected!${NC}"
        echo ""
        
        # Show certificate dates
        echo -e "  ${CYAN}New certificate details:${NC}"
        curl -sk "$CLUSTER1_ENDPOINT" | jq -r '.keys[] | select(.use == "x509-svid") | .x5c[0]' | \
            base64 -d | openssl x509 -noout -dates 2>/dev/null | sed 's/^/  /'
        echo ""
    fi
    
    # Check Cluster 2
    if [ "$CURR_C2" != "$PREV_C2" ] && [ -n "$PREV_C2" ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  🔔 CLUSTER 2 SEQUENCE CHANGED! 🔔                       ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo -e "  Time: ${CYAN}$TIMESTAMP${NC}"
        echo -e "  Old: ${RED}$PREV_C2${NC} → New: ${GREEN}$CURR_C2${NC}"
        echo -e "  ${YELLOW}Certificate rotation detected!${NC}"
        echo ""
        
        # Show certificate dates
        echo -e "  ${CYAN}New certificate details:${NC}"
        curl -sk "$CLUSTER2_ENDPOINT" | jq -r '.keys[] | select(.use == "x509-svid") | .x5c[0]' | \
            base64 -d | openssl x509 -noout -dates 2>/dev/null | sed 's/^/  /'
        echo ""
    fi
    
    # Regular status update (every 10 minutes)
    if [ $(($(date +%M) % 10)) -eq 0 ] && [ "$(date +%S)" -lt 65 ]; then
        echo -e "${CYAN}[$TIMESTAMP]${NC} Status: C1=${CURR_C1}, C2=${CURR_C2} (stable)"
    fi
    
    PREV_C1=$CURR_C1
    PREV_C2=$CURR_C2
    
    sleep 60  # Check every minute
done

