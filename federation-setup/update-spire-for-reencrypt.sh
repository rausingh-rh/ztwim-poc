#!/bin/bash

# Script to update SPIRE server configuration to use https_web profile
# This is required when using reencrypt routes instead of passthrough

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Kubeconfig paths
CLUSTER1_KUBECONFIG="${CLUSTER1_KUBECONFIG:-/home/rausingh/Downloads/kubeconfig}"
CLUSTER2_KUBECONFIG="${CLUSTER2_KUBECONFIG:-/home/rausingh/Downloads/kubeconfiganirudh}"

# Namespace
NAMESPACE="zero-trust-workload-identity-manager"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Updating SPIRE Configuration for Reencrypt Routes       ║"
echo "╔════════════════════════════════════════════════════════════╗"
echo ""

# Function to update SPIRE server configmap
update_spire_config() {
    local kubeconfig=$1
    local cluster_name=$2
    local fed_trust_domain=$3
    local fed_url=$4
    
    echo "Updating SPIRE configuration for $cluster_name..."
    
    # Get current config
    local current_config=$(kubectl --kubeconfig "$kubeconfig" get configmap spire-server \
        -n "$NAMESPACE" -o jsonpath='{.data.server\.conf}')
    
    # Create temp file
    local temp_file=$(mktemp)
    echo "$current_config" > "$temp_file"
    
    # Update configuration using Python
    python3 <<EOF
import json
import sys

with open('$temp_file', 'r') as f:
    config = json.load(f)

# Ensure federation section exists
if 'federation' not in config['server']:
    config['server']['federation'] = {}

# Ensure bundle_endpoint exists
if 'bundle_endpoint' not in config['server']['federation']:
    config['server']['federation']['bundle_endpoint'] = {
        'address': '0.0.0.0',
        'port': 8443
    }

# Update federates_with to use https_web profile
config['server']['federation']['federates_with'] = {
    '$fed_trust_domain': {
        'bundle_endpoint_url': '$fed_url',
        'bundle_endpoint_profile': {
            'https_web': {}
        }
    }
}

with open('$temp_file', 'w') as f:
    json.dump(config, f, indent=2)

print('Configuration updated successfully')
EOF
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗${NC} Failed to update configuration"
        rm -f "$temp_file"
        exit 1
    fi
    
    # Update the configmap
    kubectl --kubeconfig "$kubeconfig" create configmap spire-server \
        -n "$NAMESPACE" \
        --from-file=server.conf="$temp_file" \
        --dry-run=client -o yaml | \
        kubectl --kubeconfig "$kubeconfig" apply -f -
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} ConfigMap updated successfully"
    else
        echo -e "${RED}✗${NC} Failed to update ConfigMap"
        rm -f "$temp_file"
        exit 1
    fi
    
    # Clean up
    rm -f "$temp_file"
}

# Get federation URLs
echo "Getting federation routes..."
CLUSTER1_FED_URL=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get route spire-server-federation \
    -n "$NAMESPACE" -o jsonpath='https://{.spec.host}')
CLUSTER2_FED_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route spire-server-federation \
    -n "$NAMESPACE" -o jsonpath='https://{.spec.host}')

echo -e "${GREEN}✓${NC} Cluster 1 federation URL: $CLUSTER1_FED_URL"
echo -e "${GREEN}✓${NC} Cluster 2 federation URL: $CLUSTER2_FED_URL"
echo ""

# Get trust domains
CLUSTER1_TRUST_DOMAIN=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get configmap spire-server \
    -n "$NAMESPACE" -o jsonpath='{.data.server\.conf}' | python3 -c "import json,sys; print(json.load(sys.stdin)['server']['trust_domain'])")
CLUSTER2_TRUST_DOMAIN=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get configmap spire-server \
    -n "$NAMESPACE" -o jsonpath='{.data.server\.conf}' | python3 -c "import json,sys; print(json.load(sys.stdin)['server']['trust_domain'])")

echo "Cluster 1 trust domain: $CLUSTER1_TRUST_DOMAIN"
echo "Cluster 2 trust domain: $CLUSTER2_TRUST_DOMAIN"
echo ""

# Update configurations
echo "═══════════════════════════════════════════════════════════"
echo "  Updating Cluster 1 SPIRE Configuration"
echo "═══════════════════════════════════════════════════════════"
echo ""
update_spire_config "$CLUSTER1_KUBECONFIG" "cluster1" "$CLUSTER2_TRUST_DOMAIN" "$CLUSTER2_FED_URL"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Updating Cluster 2 SPIRE Configuration"
echo "═══════════════════════════════════════════════════════════"
echo ""
update_spire_config "$CLUSTER2_KUBECONFIG" "cluster2" "$CLUSTER1_TRUST_DOMAIN" "$CLUSTER1_FED_URL"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Configuration Updates Complete"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}✓${NC} Both SPIRE servers configured to use https_web profile"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. Restart SPIRE servers to apply the new configuration:"
echo ""
echo "   # Cluster 1"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG rollout restart statefulset spire-server -n $NAMESPACE"
echo ""
echo "   # Cluster 2"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG rollout restart statefulset spire-server -n $NAMESPACE"
echo ""
echo "2. Wait for pods to be ready:"
echo ""
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG wait --for=condition=ready pod -l app.kubernetes.io/name=spire-server -n $NAMESPACE --timeout=120s"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG wait --for=condition=ready pod -l app.kubernetes.io/name=spire-server -n $NAMESPACE --timeout=120s"
echo ""
echo "3. Verify federation is working:"
echo ""
echo "   # Check Cluster 1 logs"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -n $NAMESPACE statefulset/spire-server -c spire-server --tail=50 | grep -i federation"
echo ""
echo "   # Check Cluster 2 logs"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG logs -n $NAMESPACE statefulset/spire-server -c spire-server --tail=50 | grep -i federation"
echo ""
echo "4. Test the federation endpoint:"
echo ""
echo "   curl -v $CLUSTER1_FED_URL"
echo "   curl -v $CLUSTER2_FED_URL"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""



