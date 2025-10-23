#!/bin/bash

# Script to rollback from reencrypt to passthrough termination for SPIRE federation routes

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
echo "║   Rolling Back to Passthrough Termination                 ║"
echo "╔════════════════════════════════════════════════════════════╗"
echo ""

# Function to restore passthrough route
restore_passthrough_route() {
    local kubeconfig=$1
    local cluster_name=$2
    
    echo "Restoring passthrough route for $cluster_name..."
    
    cat <<EOF | kubectl --kubeconfig "$kubeconfig" apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-federation
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: spire-server
    app.kubernetes.io/component: control-plane
spec:
  to:
    kind: Service
    name: spire-server-federation
    weight: 100
  port:
    targetPort: federation
  tls:
    termination: passthrough
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Passthrough route restored"
    else
        echo -e "${RED}✗${NC} Failed to restore passthrough route"
        exit 1
    fi
}

# Function to update SPIRE server configmap to use https_spiffe
update_spire_config_for_passthrough() {
    local kubeconfig=$1
    local cluster_name=$2
    local fed_trust_domain=$3
    local fed_url=$4
    local fed_spiffe_id=$5
    
    echo "Updating SPIRE configuration for $cluster_name to use https_spiffe..."
    
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

# Update federates_with to use https_spiffe profile
config['server']['federation']['federates_with'] = {
    '$fed_trust_domain': {
        'bundle_endpoint_url': '$fed_url',
        'bundle_endpoint_profile': {
            'https_spiffe': {
                'endpoint_spiffe_id': '$fed_spiffe_id'
            }
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

echo "Cluster 1 federation URL: $CLUSTER1_FED_URL"
echo "Cluster 2 federation URL: $CLUSTER2_FED_URL"
echo ""

# Get trust domains
CLUSTER1_TRUST_DOMAIN=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get configmap spire-server \
    -n "$NAMESPACE" -o jsonpath='{.data.server\.conf}' | python3 -c "import json,sys; print(json.load(sys.stdin)['server']['trust_domain'])")
CLUSTER2_TRUST_DOMAIN=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get configmap spire-server \
    -n "$NAMESPACE" -o jsonpath='{.data.server\.conf}' | python3 -c "import json,sys; print(json.load(sys.stdin)['server']['trust_domain'])")

echo "Cluster 1 trust domain: $CLUSTER1_TRUST_DOMAIN"
echo "Cluster 2 trust domain: $CLUSTER2_TRUST_DOMAIN"
echo ""

# SPIFFE IDs for federation endpoints
CLUSTER1_SPIFFE_ID="spiffe://$CLUSTER1_TRUST_DOMAIN/spire/server"
CLUSTER2_SPIFFE_ID="spiffe://$CLUSTER2_TRUST_DOMAIN/spire/server"

echo "Cluster 1 SPIFFE ID: $CLUSTER1_SPIFFE_ID"
echo "Cluster 2 SPIFFE ID: $CLUSTER2_SPIFFE_ID"
echo ""

# Restore routes
echo "═══════════════════════════════════════════════════════════"
echo "  Restoring Cluster 1 Route"
echo "═══════════════════════════════════════════════════════════"
echo ""
restore_passthrough_route "$CLUSTER1_KUBECONFIG" "cluster1"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Restoring Cluster 2 Route"
echo "═══════════════════════════════════════════════════════════"
echo ""
restore_passthrough_route "$CLUSTER2_KUBECONFIG" "cluster2"

# Update SPIRE configurations
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Updating Cluster 1 SPIRE Configuration"
echo "═══════════════════════════════════════════════════════════"
echo ""
update_spire_config_for_passthrough "$CLUSTER1_KUBECONFIG" "cluster1" \
    "$CLUSTER2_TRUST_DOMAIN" "$CLUSTER2_FED_URL" "$CLUSTER2_SPIFFE_ID"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Updating Cluster 2 SPIRE Configuration"
echo "═══════════════════════════════════════════════════════════"
echo ""
update_spire_config_for_passthrough "$CLUSTER2_KUBECONFIG" "cluster2" \
    "$CLUSTER1_TRUST_DOMAIN" "$CLUSTER1_FED_URL" "$CLUSTER1_SPIFFE_ID"

# Clean up service CA annotations if they exist
echo ""
echo "Cleaning up Service CA annotations..."
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" annotate service spire-server-federation \
    -n "$NAMESPACE" service.beta.openshift.io/serving-cert-secret-name- 2>/dev/null || true
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" annotate service spire-server-federation \
    -n "$NAMESPACE" service.beta.openshift.io/serving-cert-secret-name- 2>/dev/null || true
echo -e "${GREEN}✓${NC} Annotations removed"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Rollback Complete"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}✓${NC} Routes restored to passthrough termination"
echo -e "${GREEN}✓${NC} SPIRE configurations updated to use https_spiffe"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. Restart SPIRE servers to apply the configuration:"
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
echo "3. Verify federation:"
echo ""
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -n $NAMESPACE statefulset/spire-server -c spire-server --tail=50 | grep -i federation"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG logs -n $NAMESPACE statefulset/spire-server -c spire-server --tail=50 | grep -i federation"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""



