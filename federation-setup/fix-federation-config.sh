#!/bin/bash

# Quick fix script for federation configuration error
# Fixes the "scheme is missing or invalid" error

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <cluster1-kubeconfig> <cluster2-kubeconfig>"
    echo ""
    echo "This fixes the 'scheme is missing or invalid' error"
    echo "by correcting the federates_with configuration"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

CLUSTER1_KUBECONFIG="$1"
CLUSTER2_KUBECONFIG="$2"

echo -e "${YELLOW}Fixing federation configuration...${NC}"
echo ""

# Get cluster info
CLUSTER1_TRUST_DOMAIN=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get spireserver cluster -o jsonpath='{.spec.trustDomain}')
CLUSTER2_TRUST_DOMAIN=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get spireserver cluster -o jsonpath='{.spec.trustDomain}')

CLUSTER1_FED_URL=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get route spire-server-federation -n zero-trust-workload-identity-manager -o jsonpath='https://{.spec.host}')
CLUSTER2_FED_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route spire-server-federation -n zero-trust-workload-identity-manager -o jsonpath='https://{.spec.host}')

echo "Cluster 1: $CLUSTER1_TRUST_DOMAIN"
echo "Cluster 2: $CLUSTER2_TRUST_DOMAIN"
echo ""

# Fix Cluster 1 config
echo "Fixing Cluster 1 configuration..."
WORK_DIR="/tmp/federation-fix-$$"
mkdir -p "$WORK_DIR"

CURRENT_CONFIG=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}')

python3 -c "
import json

config = json.loads('''$CURRENT_CONFIG''')

# Fix federation config - KEY MUST BE TRUST DOMAIN!
config['server']['federation'] = {
    'bundle_endpoint': {
        'address': '0.0.0.0',
        'port': 8443
    },
    'federates_with': {
        '$CLUSTER2_TRUST_DOMAIN': {
            'bundle_endpoint_url': '$CLUSTER2_FED_URL',
            'bundle_endpoint_profile': {
                'https_spiffe': {
                    'endpoint_spiffe_id': 'spiffe://$CLUSTER2_TRUST_DOMAIN/spire/server'
                }
            }
        }
    }
}

print(json.dumps(config, indent=2))
" > "$WORK_DIR/cluster1-fixed.json"

cat > "$WORK_DIR/cluster1-cm.yaml" <<CMEOF
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
$(cat "$WORK_DIR/cluster1-fixed.json" | sed 's/^/    /')
CMEOF

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f "$WORK_DIR/cluster1-cm.yaml"

echo -e "${GREEN}✓${NC} Cluster 1 config fixed"
echo ""

# Fix Cluster 2 config
echo "Fixing Cluster 2 configuration..."

CURRENT_CONFIG=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}')

python3 -c "
import json

config = json.loads('''$CURRENT_CONFIG''')

# Fix federation config - KEY MUST BE TRUST DOMAIN!
config['server']['federation'] = {
    'bundle_endpoint': {
        'address': '0.0.0.0',
        'port': 8443
    },
    'federates_with': {
        '$CLUSTER1_TRUST_DOMAIN': {
            'bundle_endpoint_url': '$CLUSTER1_FED_URL',
            'bundle_endpoint_profile': {
                'https_spiffe': {
                    'endpoint_spiffe_id': 'spiffe://$CLUSTER1_TRUST_DOMAIN/spire/server'
                }
            }
        }
    }
}

print(json.dumps(config, indent=2))
" > "$WORK_DIR/cluster2-fixed.json"

cat > "$WORK_DIR/cluster2-cm.yaml" <<CMEOF
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
$(cat "$WORK_DIR/cluster2-fixed.json" | sed 's/^/    /')
CMEOF

kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f "$WORK_DIR/cluster2-cm.yaml"

echo -e "${GREEN}✓${NC} Cluster 2 config fixed"
echo ""

# Restart SPIRE servers
echo "Restarting SPIRE servers..."
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager

echo "Waiting for pods to be ready..."
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=180s
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=180s

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    FIX APPLIED!                                    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "The federates_with configuration has been corrected."
echo "The key is now the trust domain (not the URL)."
echo ""
echo "Verify it worked:"
echo "  kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50"
echo ""
echo "Look for:"
echo '  "Trust domain is now managed"'
echo '  "Bundle refreshed"'
echo ""
echo "If you see these, federation is working!"
echo ""

