#!/bin/bash

# 🔄 Trust Bundle Refresh Monitor
# This script helps you observe and verify trust bundle refresh behavior

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default kubeconfig paths (update these to match your setup)
CLUSTER1_KUBECONFIG="${CLUSTER1_KUBECONFIG:-/home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig}"
CLUSTER2_KUBECONFIG="${CLUSTER2_KUBECONFIG:-/home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig}"
NAMESPACE="zero-trust-workload-identity-manager"

function print_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

function print_section() {
    echo ""
    echo -e "${BLUE}▶ $1${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
}

function show_menu() {
    clear
    echo -e "${GREEN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║       🔄 Trust Bundle Refresh Monitoring Tool 🔄              ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo "Choose an option:"
    echo ""
    echo -e "${YELLOW}1)${NC} Show Current Refresh Configuration"
    echo -e "${YELLOW}2)${NC} Watch Real-Time Bundle Refreshes (Live)"
    echo -e "${YELLOW}3)${NC} View Refresh History (Last 10 events)"
    echo -e "${YELLOW}4)${NC} Calculate Refresh Interval from Logs"
    echo -e "${YELLOW}5)${NC} Test Federation Endpoint Response"
    echo -e "${YELLOW}6)${NC} Monitor Both Clusters Simultaneously"
    echo -e "${YELLOW}7)${NC} Show Next Scheduled Refresh"
    echo -e "${YELLOW}8)${NC} Run Full Diagnostics"
    echo -e "${YELLOW}9)${NC} Exit"
    echo ""
    read -p "Enter choice [1-9]: " choice
}

function check_refresh_config() {
    print_header "📋 Current Refresh Configuration"
    
    print_section "Cluster 1 Federation Endpoint"
    
    echo "Fetching refresh_hint from Cluster 1's federation endpoint..."
    ROUTE1=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get route federation -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -n "$ROUTE1" ]; then
        HINT1=$(curl -sk "https://$ROUTE1/" | jq -r '.spiffe_refresh_hint' 2>/dev/null || echo "N/A")
        echo -e "  Endpoint: ${GREEN}https://$ROUTE1/${NC}"
        echo -e "  Refresh Hint: ${GREEN}$HINT1 seconds${NC}"
        
        if [ "$HINT1" != "N/A" ] && [ "$HINT1" != "null" ]; then
            POLL_INTERVAL=$((HINT1 / 4))
            echo -e "  Actual Poll Interval: ${CYAN}~$POLL_INTERVAL seconds${NC} (hint ÷ 4)"
            HOURLY=$((3600 / POLL_INTERVAL))
            echo -e "  Refreshes per Hour: ${CYAN}~$HOURLY${NC}"
        fi
    else
        echo -e "  ${RED}✗ Could not get federation route${NC}"
    fi
    
    echo ""
    print_section "Cluster 2 Federation Endpoint"
    
    echo "Fetching refresh_hint from Cluster 2's federation endpoint..."
    ROUTE2=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route federation -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -n "$ROUTE2" ]; then
        HINT2=$(curl -sk "https://$ROUTE2/" | jq -r '.spiffe_refresh_hint' 2>/dev/null || echo "N/A")
        echo -e "  Endpoint: ${GREEN}https://$ROUTE2/${NC}"
        echo -e "  Refresh Hint: ${GREEN}$HINT2 seconds${NC}"
        
        if [ "$HINT2" != "N/A" ] && [ "$HINT2" != "null" ]; then
            POLL_INTERVAL=$((HINT2 / 4))
            echo -e "  Actual Poll Interval: ${CYAN}~$POLL_INTERVAL seconds${NC} (hint ÷ 4)"
            HOURLY=$((3600 / POLL_INTERVAL))
            echo -e "  Refreshes per Hour: ${CYAN}~$HOURLY${NC}"
        fi
    else
        echo -e "  ${RED}✗ Could not get federation route${NC}"
    fi
}

function watch_realtime() {
    print_header "👁️  Real-Time Bundle Refresh Monitor"
    
    echo "Monitoring SPIRE server logs for bundle refresh events..."
    echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
    echo ""
    echo "Watching Cluster 1 for refreshes..."
    echo ""
    
    kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -f \
        -n "$NAMESPACE" spire-server-0 -c spire-server 2>/dev/null | \
        grep --line-buffered "Bundle refresh" | \
        while IFS= read -r line; do
            TIMESTAMP=$(echo "$line" | grep -oP 'time="\K[^"]+')
            TRUST_DOMAIN=$(echo "$line" | grep -oP 'trust_domain=\K[^ ]+')
            echo -e "🔄 ${GREEN}$(date '+%H:%M:%S')${NC} - Bundle refreshed for ${CYAN}$TRUST_DOMAIN${NC}"
        done
}

function view_history() {
    print_header "📜 Bundle Refresh History"
    
    print_section "Cluster 1 - Last 10 Refreshes"
    
    kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs \
        -n "$NAMESPACE" spire-server-0 -c spire-server --tail=500 2>/dev/null | \
        grep "Bundle refreshed" | tail -10 | \
        while IFS= read -r line; do
            TIMESTAMP=$(echo "$line" | grep -oP 'time="\K[^"]+')
            TRUST_DOMAIN=$(echo "$line" | grep -oP 'trust_domain=\K[^ ]+')
            echo -e "  ${GREEN}$TIMESTAMP${NC} - $TRUST_DOMAIN"
        done
    
    echo ""
    print_section "Cluster 2 - Last 10 Refreshes"
    
    kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" logs \
        -n "$NAMESPACE" spire-server-0 -c spire-server --tail=500 2>/dev/null | \
        grep "Bundle refreshed" | tail -10 | \
        while IFS= read -r line; do
            TIMESTAMP=$(echo "$line" | grep -oP 'time="\K[^"]+')
            TRUST_DOMAIN=$(echo "$line" | grep -oP 'trust_domain=\K[^ ]+')
            echo -e "  ${GREEN}$TIMESTAMP${NC} - $TRUST_DOMAIN"
        done
}

function calculate_interval() {
    print_header "📊 Refresh Interval Analysis"
    
    print_section "Analyzing Cluster 1 Refresh Intervals"
    
    echo "Extracting timestamps from last 20 refresh events..."
    
    TIMESTAMPS=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs \
        -n "$NAMESPACE" spire-server-0 -c spire-server --tail=500 2>/dev/null | \
        grep "Bundle refreshed" | tail -20 | \
        grep -oP 'time="\K[^"]+')
    
    if [ -n "$TIMESTAMPS" ]; then
        echo "$TIMESTAMPS" | {
            PREV=""
            TOTAL=0
            COUNT=0
            
            while IFS= read -r TS; do
                if [ -n "$PREV" ]; then
                    # Calculate difference in seconds
                    PREV_SEC=$(date -d "$PREV" +%s 2>/dev/null || echo 0)
                    CURR_SEC=$(date -d "$TS" +%s 2>/dev/null || echo 0)
                    
                    if [ "$PREV_SEC" -ne 0 ] && [ "$CURR_SEC" -ne 0 ]; then
                        DIFF=$((CURR_SEC - PREV_SEC))
                        echo -e "  Interval: ${CYAN}$DIFF seconds${NC}"
                        TOTAL=$((TOTAL + DIFF))
                        COUNT=$((COUNT + 1))
                    fi
                fi
                PREV="$TS"
            done
            
            if [ "$COUNT" -gt 0 ]; then
                AVG=$((TOTAL / COUNT))
                echo ""
                echo -e "  ${GREEN}Average Interval: $AVG seconds${NC}"
                echo -e "  ${GREEN}Expected: ~75 seconds (for 300s refresh hint)${NC}"
                
                if [ "$AVG" -ge 70 ] && [ "$AVG" -le 80 ]; then
                    echo -e "  ${GREEN}✓ Interval is within expected range!${NC}"
                else
                    echo -e "  ${YELLOW}⚠ Interval differs from expected (~75s)${NC}"
                fi
            fi
        }
    else
        echo -e "  ${RED}✗ No refresh events found${NC}"
    fi
}

function test_endpoint() {
    print_header "🌐 Federation Endpoint Test"
    
    print_section "Cluster 1 Endpoint Response"
    
    ROUTE1=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get route federation -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -n "$ROUTE1" ]; then
        echo "Querying: https://$ROUTE1/"
        echo ""
        
        RESPONSE=$(curl -sk "https://$ROUTE1/" 2>/dev/null)
        
        if [ -n "$RESPONSE" ]; then
            echo -e "${GREEN}Response received:${NC}"
            echo "$RESPONSE" | jq '.'
            
            echo ""
            echo -e "${YELLOW}Key Fields:${NC}"
            echo "  spiffe_sequence: $(echo "$RESPONSE" | jq -r '.spiffe_sequence')"
            echo "  spiffe_refresh_hint: $(echo "$RESPONSE" | jq -r '.spiffe_refresh_hint') seconds"
            echo "  Number of keys: $(echo "$RESPONSE" | jq -r '.keys | length')"
        else
            echo -e "${RED}✗ No response from endpoint${NC}"
        fi
    else
        echo -e "${RED}✗ Could not get federation route${NC}"
    fi
    
    echo ""
    print_section "Cluster 2 Endpoint Response"
    
    ROUTE2=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route federation -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -n "$ROUTE2" ]; then
        echo "Querying: https://$ROUTE2/"
        echo ""
        
        RESPONSE=$(curl -sk "https://$ROUTE2/" 2>/dev/null)
        
        if [ -n "$RESPONSE" ]; then
            echo -e "${GREEN}Response received:${NC}"
            echo "$RESPONSE" | jq '.'
            
            echo ""
            echo -e "${YELLOW}Key Fields:${NC}"
            echo "  spiffe_sequence: $(echo "$RESPONSE" | jq -r '.spiffe_sequence')"
            echo "  spiffe_refresh_hint: $(echo "$RESPONSE" | jq -r '.spiffe_refresh_hint') seconds"
            echo "  Number of keys: $(echo "$RESPONSE" | jq -r '.keys | length')"
        else
            echo -e "${RED}✗ No response from endpoint${NC}"
        fi
    else
        echo -e "${RED}✗ Could not get federation route${NC}"
    fi
}

function monitor_both() {
    print_header "👥 Monitoring Both Clusters"
    
    echo "Watching for bundle refreshes on both clusters..."
    echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
    echo ""
    
    (
        kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -f \
            -n "$NAMESPACE" spire-server-0 -c spire-server 2>/dev/null | \
            grep --line-buffered "Bundle refresh" | \
            while IFS= read -r line; do
                TRUST_DOMAIN=$(echo "$line" | grep -oP 'trust_domain=\K[^ ]+')
                echo -e "🔄 ${GREEN}[CLUSTER-1]${NC} $(date '+%H:%M:%S') - Refreshed: ${CYAN}$TRUST_DOMAIN${NC}"
            done
    ) &
    PID1=$!
    
    (
        kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" logs -f \
            -n "$NAMESPACE" spire-server-0 -c spire-server 2>/dev/null | \
            grep --line-buffered "Bundle refresh" | \
            while IFS= read -r line; do
                TRUST_DOMAIN=$(echo "$line" | grep -oP 'trust_domain=\K[^ ]+')
                echo -e "🔄 ${BLUE}[CLUSTER-2]${NC} $(date '+%H:%M:%S') - Refreshed: ${CYAN}$TRUST_DOMAIN${NC}"
            done
    ) &
    PID2=$!
    
    # Wait for both processes
    wait $PID1 $PID2
}

function show_next_scheduled() {
    print_header "⏰ Next Scheduled Refresh"
    
    print_section "Cluster 1"
    
    NEXT=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs \
        -n "$NAMESPACE" spire-server-0 -c spire-server --tail=50 2>/dev/null | \
        grep "Scheduling next bundle refresh" | tail -1)
    
    if [ -n "$NEXT" ]; then
        NEXT_TIME=$(echo "$NEXT" | grep -oP 'at="\K[^"]+')
        echo -e "  Next refresh at: ${GREEN}$NEXT_TIME${NC}"
    else
        echo -e "  ${YELLOW}No scheduled refresh found in recent logs${NC}"
    fi
    
    echo ""
    print_section "Cluster 2"
    
    NEXT=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" logs \
        -n "$NAMESPACE" spire-server-0 -c spire-server --tail=50 2>/dev/null | \
        grep "Scheduling next bundle refresh" | tail -1)
    
    if [ -n "$NEXT" ]; then
        NEXT_TIME=$(echo "$NEXT" | grep -oP 'at="\K[^"]+')
        echo -e "  Next refresh at: ${GREEN}$NEXT_TIME${NC}"
    else
        echo -e "  ${YELLOW}No scheduled refresh found in recent logs${NC}"
    fi
}

function run_diagnostics() {
    print_header "🔍 Full Refresh Diagnostics"
    
    check_refresh_config
    echo ""
    
    show_next_scheduled
    echo ""
    
    print_section "Recent Refresh Events"
    
    echo "Cluster 1:"
    C1_COUNT=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs \
        -n "$NAMESPACE" spire-server-0 -c spire-server --tail=500 2>/dev/null | \
        grep -c "Bundle refreshed" || echo 0)
    echo -e "  Total refresh events in last 500 logs: ${GREEN}$C1_COUNT${NC}"
    
    echo ""
    echo "Cluster 2:"
    C2_COUNT=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" logs \
        -n "$NAMESPACE" spire-server-0 -c spire-server --tail=500 2>/dev/null | \
        grep -c "Bundle refreshed" || echo 0)
    echo -e "  Total refresh events in last 500 logs: ${GREEN}$C2_COUNT${NC}"
    
    echo ""
    print_section "Bundle List"
    
    echo "Cluster 1 bundles:"
    kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec \
        -n "$NAMESPACE" spire-server-0 -c spire-server -- \
        ./spire-server bundle list 2>/dev/null | grep "^\*" | \
        while IFS= read -r line; do
            echo -e "  ${GREEN}$line${NC}"
        done
    
    echo ""
    echo "Cluster 2 bundles:"
    kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec \
        -n "$NAMESPACE" spire-server-0 -c spire-server -- \
        ./spire-server bundle list 2>/dev/null | grep "^\*" | \
        while IFS= read -r line; do
            echo -e "  ${GREEN}$line${NC}"
        done
    
    echo ""
    print_section "Health Summary"
    
    if [ "$C1_COUNT" -gt 0 ] && [ "$C2_COUNT" -gt 0 ]; then
        echo -e "  ${GREEN}✓ Both clusters are actively refreshing bundles${NC}"
    else
        echo -e "  ${RED}✗ One or both clusters may not be refreshing properly${NC}"
    fi
}

# Main loop
while true; do
    show_menu
    
    case $choice in
        1) check_refresh_config ;;
        2) watch_realtime ;;
        3) view_history ;;
        4) calculate_interval ;;
        5) test_endpoint ;;
        6) monitor_both ;;
        7) show_next_scheduled ;;
        8) run_diagnostics ;;
        9) echo "Exiting..."; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    echo ""
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read
done

