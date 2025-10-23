#!/bin/bash

# Remove a Cluster from SPIRE Federation
# This script removes one cluster from an existing multi-cluster federation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage function
usage() {
    echo "Usage: $0 --remove <cluster-to-remove-kubeconfig> --from <cluster1-kubeconfig> [<cluster2-kubeconfig> ...]"
    echo ""
    echo "Example (remove cluster3 from a 3-cluster federation):"
    echo "  $0 --remove cluster3.kubeconfig --from cluster1.kubeconfig cluster2.kubeconfig"
    echo ""
    echo "This script will:"
    echo "  1. Clean up federation resources on the removed cluster"
    echo "  2. Update all remaining clusters to remove references to the removed cluster"
    echo "  3. Update SPIRE server configurations on remaining clusters"
    echo "  4. Restart SPIRE servers to apply changes"
    exit 1
}

# Parse arguments
if [ $# -lt 4 ]; then
    usage
fi

if [ "$1" != "--remove" ]; then
    usage
fi

CLUSTER_TO_REMOVE="$2"

if [ "$3" != "--from" ]; then
    usage
fi

# Shift to get remaining cluster kubeconfigs
shift 3
REMAINING_CLUSTERS=("$@")

# Verify files exist
if [ ! -f "$CLUSTER_TO_REMOVE" ]; then
    echo -e "${RED}Error: Kubeconfig not found: $CLUSTER_TO_REMOVE${NC}"
    exit 1
fi

for config in "${REMAINING_CLUSTERS[@]}"; do
    if [ ! -f "$config" ]; then
        echo -e "${RED}Error: Kubeconfig not found: $config${NC}"
        exit 1
    fi
done

# Create working directory
WORK_DIR="/tmp/spire-remove-cluster-$$"
mkdir -p "$WORK_DIR"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Remove Cluster from SPIRE Federation                       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to get trust domain from cluster
get_trust_domain() {
    local kubeconfig=$1
    kubectl --kubeconfig "$kubeconfig" get spireserver cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null || echo ""
}

# Get cluster information
echo -e "${YELLOW}Step 1: Gathering cluster information...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

REMOVED_TRUST_DOMAIN=$(get_trust_domain "$CLUSTER_TO_REMOVE")

if [ -z "$REMOVED_TRUST_DOMAIN" ]; then
    echo -e "${RED}Error: Could not get trust domain from cluster to remove${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Cluster to remove: Trust Domain = $REMOVED_TRUST_DOMAIN"
echo ""
echo "Remaining clusters:"

REMAINING_TRUST_DOMAINS=()
for i in "${!REMAINING_CLUSTERS[@]}"; do
    config="${REMAINING_CLUSTERS[$i]}"
    trust_domain=$(get_trust_domain "$config")
    if [ -z "$trust_domain" ]; then
        echo -e "${RED}Error: Could not get trust domain from cluster $((i+1))${NC}"
        exit 1
    fi
    REMAINING_TRUST_DOMAINS+=("$trust_domain")
    echo -e "${GREEN}✓${NC} Cluster $((i+1)): Trust Domain = $trust_domain"
done
echo ""

# Confirm before proceeding
echo -e "${RED}⚠️  WARNING: This will remove cluster $REMOVED_TRUST_DOMAIN from federation!${NC}"
echo ""
echo "This will:"
echo "  • Remove all federation resources from $REMOVED_TRUST_DOMAIN"
echo "  • Update ${#REMAINING_CLUSTERS[@]} remaining cluster(s) to remove references"
echo "  • Restart SPIRE servers on all remaining clusters"
echo ""
read -p "Continue? (y/N): " CONFIRM

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# Step 2: Clean up the cluster being removed
echo -e "${YELLOW}Step 2: Cleaning up cluster to be removed...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "Removing federation resources from $REMOVED_TRUST_DOMAIN..."
kubectl --kubeconfig "$CLUSTER_TO_REMOVE" delete clusterfederatedtrustdomain --all --ignore-not-found=true 2>/dev/null || true
kubectl --kubeconfig "$CLUSTER_TO_REMOVE" delete route spire-server-federation -n zero-trust-workload-identity-manager --ignore-not-found=true 2>/dev/null || true
kubectl --kubeconfig "$CLUSTER_TO_REMOVE" delete service spire-server-federation -n zero-trust-workload-identity-manager --ignore-not-found=true 2>/dev/null || true

# Remove federation configuration from SPIRE server ConfigMap
echo "Removing federation configuration from SPIRE server..."
current_config=$(kubectl --kubeconfig "$CLUSTER_TO_REMOVE" get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}' 2>/dev/null || echo "")

if [ -n "$current_config" ]; then
    # Use Python to remove the federation block
    python3 -c "
import json
import sys

try:
    config = json.loads('''$current_config''')
    
    # Remove federation section
    if 'federation' in config.get('server', {}):
        del config['server']['federation']
    
    print(json.dumps(config, indent=2))
except Exception as e:
    sys.stderr.write(f'Error parsing config: {e}\n')
    sys.exit(1)
" > "$WORK_DIR/removed-cluster-server-conf.json" 2>/dev/null || true

    if [ -f "$WORK_DIR/removed-cluster-server-conf.json" ]; then
        cat > "$WORK_DIR/removed-cluster-cm.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server
  namespace: zero-trust-workload-identity-manager
  labels:
    app.kubernetes.io/component: control-plane
    app.kubernetes.io/instance: cluster-zero-trust-workload-identity-manager
    app.kubernetes.io/managed-by: zero-trust-workload-identity-manager
    app.kubernetes.io/name: spire-server
data:
  server.conf: |
$(cat "$WORK_DIR/removed-cluster-server-conf.json" | sed 's/^/    /')
EOF
        kubectl --kubeconfig "$CLUSTER_TO_REMOVE" apply -f "$WORK_DIR/removed-cluster-cm.yaml" 2>/dev/null || true
    fi
fi

# Restart SPIRE server on removed cluster
echo "Restarting SPIRE server..."
kubectl --kubeconfig "$CLUSTER_TO_REMOVE" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager 2>/dev/null || true

echo -e "${GREEN}✓${NC} Cluster removed from federation"
echo ""

# Step 3: Update remaining clusters
echo -e "${YELLOW}Step 3: Updating remaining clusters...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for i in "${!REMAINING_CLUSTERS[@]}"; do
    config="${REMAINING_CLUSTERS[$i]}"
    trust_domain="${REMAINING_TRUST_DOMAINS[$i]}"
    
    echo ""
    echo "Processing cluster: $trust_domain"
    echo "─────────────────────────────────────────────────────────────────"
    
    # Delete ClusterFederatedTrustDomain for removed cluster
    echo "  • Deleting ClusterFederatedTrustDomain for removed cluster..."
    
    # Find and delete any CFTD that matches the removed trust domain
    cftd_names=$(kubectl --kubeconfig "$config" get clusterfederatedtrustdomain -o json 2>/dev/null | \
        python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    for item in data.get('items', []):
        if item.get('spec', {}).get('trustDomain') == '$REMOVED_TRUST_DOMAIN':
            print(item['metadata']['name'])
except:
    pass
" 2>/dev/null || echo "")
    
    if [ -n "$cftd_names" ]; then
        for cftd_name in $cftd_names; do
            kubectl --kubeconfig "$config" delete clusterfederatedtrustdomain "$cftd_name" --ignore-not-found=true 2>/dev/null || true
            echo "    ✓ Deleted ClusterFederatedTrustDomain: $cftd_name"
        done
    else
        echo "    ℹ No ClusterFederatedTrustDomain found for removed cluster"
    fi
    
    # Update SPIRE server ConfigMap to remove the trust domain from federates_with
    echo "  • Updating SPIRE server configuration..."
    
    current_config=$(kubectl --kubeconfig "$config" get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}' 2>/dev/null || echo "")
    
    if [ -n "$current_config" ]; then
        python3 -c "
import json
import sys

try:
    config = json.loads('''$current_config''')
    
    # Remove the trust domain from federates_with
    if 'federation' in config.get('server', {}):
        federates_with = config['server']['federation'].get('federates_with', {})
        if '$REMOVED_TRUST_DOMAIN' in federates_with:
            del federates_with['$REMOVED_TRUST_DOMAIN']
            print('Removed $REMOVED_TRUST_DOMAIN from federates_with', file=sys.stderr)
        
        # If no more federations, remove the federation block entirely
        if not federates_with:
            del config['server']['federation']
            print('No remaining federations, removed federation block', file=sys.stderr)
    
    print(json.dumps(config, indent=2))
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" > "$WORK_DIR/cluster${i}-server-conf.json" 2>&1

        if [ -f "$WORK_DIR/cluster${i}-server-conf.json" ]; then
            cat > "$WORK_DIR/cluster${i}-cm.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server
  namespace: zero-trust-workload-identity-manager
  labels:
    app.kubernetes.io/component: control-plane
    app.kubernetes.io/instance: cluster-zero-trust-workload-identity-manager
    app.kubernetes.io/managed-by: zero-trust-workload-identity-manager
    app.kubernetes.io/name: spire-server
data:
  server.conf: |
$(cat "$WORK_DIR/cluster${i}-server-conf.json" | sed 's/^/    /')
EOF
            kubectl --kubeconfig "$config" apply -f "$WORK_DIR/cluster${i}-cm.yaml"
            echo "    ✓ Updated SPIRE server ConfigMap"
        fi
    fi
done

echo ""
echo -e "${GREEN}✓${NC} All remaining clusters updated"
echo ""

# Step 4: Restart SPIRE servers on remaining clusters
echo -e "${YELLOW}Step 4: Restarting SPIRE servers on remaining clusters...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for i in "${!REMAINING_CLUSTERS[@]}"; do
    config="${REMAINING_CLUSTERS[$i]}"
    trust_domain="${REMAINING_TRUST_DOMAINS[$i]}"
    
    echo "Restarting SPIRE server on $trust_domain..."
    kubectl --kubeconfig "$config" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager
done

echo ""
echo "Waiting for SPIRE servers to be ready..."
for i in "${!REMAINING_CLUSTERS[@]}"; do
    config="${REMAINING_CLUSTERS[$i]}"
    echo "  Waiting for cluster $((i+1))..."
    kubectl --kubeconfig "$config" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s 2>/dev/null || echo "  Warning: Timeout waiting for pod (it may still be starting)"
done

echo ""
echo -e "${GREEN}✓${NC} SPIRE servers restarted"
echo ""

# Final summary
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              CLUSTER REMOVAL COMPLETE!                             ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}📊 Summary:${NC}"
echo "  Removed cluster: $REMOVED_TRUST_DOMAIN"
echo "  Remaining clusters: ${#REMAINING_CLUSTERS[@]}"
for i in "${!REMAINING_TRUST_DOMAINS[@]}"; do
    echo "    • ${REMAINING_TRUST_DOMAINS[$i]}"
done
echo ""

echo -e "${BLUE}🧪 VERIFICATION COMMANDS:${NC}"
echo ""
echo "1️⃣  Verify removed cluster has no federation:"
echo "   kubectl --kubeconfig $CLUSTER_TO_REMOVE get clusterfederatedtrustdomain"
echo "   (Should show: No resources found)"
echo ""
echo "   kubectl --kubeconfig $CLUSTER_TO_REMOVE exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list"
echo "   (Should show only its own trust domain)"
echo ""

for i in "${!REMAINING_CLUSTERS[@]}"; do
    config="${REMAINING_CLUSTERS[$i]}"
    echo "$((i+2))️⃣  Verify remaining cluster $((i+1)) no longer has removed cluster's bundle:"
    echo "   kubectl --kubeconfig $config get clusterfederatedtrustdomain"
    echo "   (Should NOT show $REMOVED_TRUST_DOMAIN)"
    echo ""
    echo "   kubectl --kubeconfig $config exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list"
    echo "   (Should NOT show $REMOVED_TRUST_DOMAIN)"
    echo ""
done

echo -e "${BLUE}📝 Configuration saved to:${NC} $WORK_DIR/"
echo ""

echo -e "${GREEN}🎉 Cluster successfully removed from federation!${NC}"
echo ""
echo -e "${YELLOW}⚠️  Important Notes:${NC}"
echo "  • Any workloads on remaining clusters with 'federatesWith: $REMOVED_TRUST_DOMAIN'"
echo "    should be updated to remove that entry"
echo "  • The removed cluster can still operate independently with its own SPIRE setup"
echo "  • To completely remove SPIRE from the removed cluster, use the operator uninstall"
echo ""

