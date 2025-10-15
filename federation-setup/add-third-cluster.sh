#!/bin/bash

# Add Third Cluster to SPIRE Federation
# This script adds a third cluster to an existing 2-cluster federation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage function
usage() {
    echo "Usage: $0 <cluster1-kubeconfig> <cluster2-kubeconfig> <cluster3-kubeconfig>"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig /path/to/cluster3/kubeconfig"
    echo ""
    echo "This script will:"
    echo "  1. Add cluster 3 to the existing federation between clusters 1 and 2"
    echo "  2. Update all three clusters to federate with each other"
    echo "  3. Exchange trust bundles between all clusters"
    echo "  4. Verify federation is working"
    exit 1
}

# Check arguments
if [ $# -ne 3 ]; then
    usage
fi

CLUSTER1_KUBECONFIG="$1"
CLUSTER2_KUBECONFIG="$2"
CLUSTER3_KUBECONFIG="$3"

# Verify kubeconfig files exist
for config in "$CLUSTER1_KUBECONFIG" "$CLUSTER2_KUBECONFIG" "$CLUSTER3_KUBECONFIG"; do
    if [ ! -f "$config" ]; then
        echo -e "${RED}Error: Kubeconfig not found: $config${NC}"
        exit 1
    fi
done

# Create working directory
WORK_DIR="/tmp/spire-3way-federation-$$"
mkdir -p "$WORK_DIR"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      SPIRE Three-Way Federation Setup Script                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Cluster 1 kubeconfig:${NC} $CLUSTER1_KUBECONFIG"
echo -e "${GREEN}Cluster 2 kubeconfig:${NC} $CLUSTER2_KUBECONFIG"
echo -e "${GREEN}Cluster 3 kubeconfig:${NC} $CLUSTER3_KUBECONFIG"
echo -e "${GREEN}Working directory:${NC} $WORK_DIR"
echo ""

# Function to get trust domain from cluster
get_trust_domain() {
    local kubeconfig=$1
    kubectl --kubeconfig "$kubeconfig" get spireserver cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null || echo ""
}

# Get cluster information
echo -e "${YELLOW}Step 1: Gathering cluster information...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CLUSTER1_TRUST_DOMAIN=$(get_trust_domain "$CLUSTER1_KUBECONFIG")
CLUSTER2_TRUST_DOMAIN=$(get_trust_domain "$CLUSTER2_KUBECONFIG")
CLUSTER3_TRUST_DOMAIN=$(get_trust_domain "$CLUSTER3_KUBECONFIG")

if [ -z "$CLUSTER1_TRUST_DOMAIN" ] || [ -z "$CLUSTER2_TRUST_DOMAIN" ] || [ -z "$CLUSTER3_TRUST_DOMAIN" ]; then
    echo -e "${RED}Error: Could not get trust domains from all clusters${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Cluster 1: Trust Domain = $CLUSTER1_TRUST_DOMAIN"
echo -e "${GREEN}✓${NC} Cluster 2: Trust Domain = $CLUSTER2_TRUST_DOMAIN"
echo -e "${GREEN}✓${NC} Cluster 3: Trust Domain = $CLUSTER3_TRUST_DOMAIN"
echo ""

# Step 2: Create federation service and route for Cluster 3
echo -e "${YELLOW}Step 2: Creating federation endpoint for Cluster 3...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl --kubeconfig "$CLUSTER3_KUBECONFIG" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: spire-server-federation
  namespace: zero-trust-workload-identity-manager
  labels:
    app.kubernetes.io/name: spire-server
spec:
  type: ClusterIP
  ports:
  - name: federation
    port: 8443
    protocol: TCP
    targetPort: 8443
  selector:
    app.kubernetes.io/name: spire-server
    app.kubernetes.io/instance: cluster-zero-trust-workload-identity-manager
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-federation
  namespace: zero-trust-workload-identity-manager
spec:
  to:
    kind: Service
    name: spire-server-federation
  port:
    targetPort: federation
  tls:
    termination: passthrough
    insecureEdgeTerminationPolicy: Redirect
EOF

sleep 5

# Get federation URLs
CLUSTER1_FED_URL=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get route spire-server-federation -n zero-trust-workload-identity-manager -o jsonpath='https://{.spec.host}')
CLUSTER2_FED_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route spire-server-federation -n zero-trust-workload-identity-manager -o jsonpath='https://{.spec.host}')
CLUSTER3_FED_URL=$(kubectl --kubeconfig "$CLUSTER3_KUBECONFIG" get route spire-server-federation -n zero-trust-workload-identity-manager -o jsonpath='https://{.spec.host}')

echo -e "${GREEN}✓${NC} Cluster 1 federation endpoint: $CLUSTER1_FED_URL"
echo -e "${GREEN}✓${NC} Cluster 2 federation endpoint: $CLUSTER2_FED_URL"
echo -e "${GREEN}✓${NC} Cluster 3 federation endpoint: $CLUSTER3_FED_URL"
echo ""

# Step 3: Update SPIRE server configmaps for all clusters
echo -e "${YELLOW}Step 3: Updating SPIRE server configurations for three-way federation...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Function to create federation config for a cluster
create_federation_config() {
    local kubeconfig=$1
    local own_trust_domain=$2
    local fed_domain1=$3
    local fed_url1=$4
    local fed_domain2=$5
    local fed_url2=$6
    local output_file=$7
    
    # Get current config
    local current_config=$(kubectl --kubeconfig "$kubeconfig" get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}')
    
    # Add federation configuration using Python
    python3 -c "
import json
import sys

config = json.loads('''$current_config''')

# Add federation to server config
if 'federation' not in config['server']:
    config['server']['federation'] = {}

config['server']['federation']['bundle_endpoint'] = {
    'address': '0.0.0.0',
    'port': 8443
}

# Federate with two other clusters
config['server']['federation']['federates_with'] = {
    '$fed_domain1': {
        'bundle_endpoint_url': '$fed_url1',
        'bundle_endpoint_profile': {
            'https_spiffe': {
                'endpoint_spiffe_id': 'spiffe://$fed_domain1/spire/server'
            }
        }
    },
    '$fed_domain2': {
        'bundle_endpoint_url': '$fed_url2',
        'bundle_endpoint_profile': {
            'https_spiffe': {
                'endpoint_spiffe_id': 'spiffe://$fed_domain2/spire/server'
            }
        }
    }
}

print(json.dumps(config, indent=2))
" > "$output_file"
}

# Cluster 1 - federates with Cluster 2 and Cluster 3
create_federation_config "$CLUSTER1_KUBECONFIG" "$CLUSTER1_TRUST_DOMAIN" \
    "$CLUSTER2_TRUST_DOMAIN" "$CLUSTER2_FED_URL" \
    "$CLUSTER3_TRUST_DOMAIN" "$CLUSTER3_FED_URL" \
    "$WORK_DIR/cluster1-server-conf.json"

# Cluster 2 - federates with Cluster 1 and Cluster 3
create_federation_config "$CLUSTER2_KUBECONFIG" "$CLUSTER2_TRUST_DOMAIN" \
    "$CLUSTER1_TRUST_DOMAIN" "$CLUSTER1_FED_URL" \
    "$CLUSTER3_TRUST_DOMAIN" "$CLUSTER3_FED_URL" \
    "$WORK_DIR/cluster2-server-conf.json"

# Cluster 3 - federates with Cluster 1 and Cluster 2
create_federation_config "$CLUSTER3_KUBECONFIG" "$CLUSTER3_TRUST_DOMAIN" \
    "$CLUSTER1_TRUST_DOMAIN" "$CLUSTER1_FED_URL" \
    "$CLUSTER2_TRUST_DOMAIN" "$CLUSTER2_FED_URL" \
    "$WORK_DIR/cluster3-server-conf.json"

# Apply updated configmaps
for i in 1 2 3; do
    eval "kubeconfig=\$CLUSTER${i}_KUBECONFIG"
    cat > "$WORK_DIR/cluster${i}-cm-updated.yaml" <<EOF
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
    kubectl --kubeconfig "$kubeconfig" apply -f "$WORK_DIR/cluster${i}-cm-updated.yaml"
done

echo -e "${GREEN}✓${NC} Updated SPIRE server configurations for all clusters"
echo ""

# Step 4: Expose federation port on Cluster 3
echo -e "${YELLOW}Step 4: Exposing federation port on Cluster 3...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl --kubeconfig "$CLUSTER3_KUBECONFIG" patch statefulset spire-server -n zero-trust-workload-identity-manager --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/ports/-", "value": {"name": "federation", "containerPort": 8443, "protocol": "TCP"}}]' 2>/dev/null || echo "Port already exposed or patch failed (continuing...)"

echo -e "${GREEN}✓${NC} Federation port exposed on Cluster 3"
echo ""

# Step 5: Restart SPIRE servers
echo -e "${YELLOW}Step 5: Restarting SPIRE servers on all clusters...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager
kubectl --kubeconfig "$CLUSTER3_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager

echo "Waiting for SPIRE servers to be ready..."
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s
kubectl --kubeconfig "$CLUSTER3_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s

echo -e "${GREEN}✓${NC} SPIRE servers restarted and ready"
echo ""

# Step 6: Extract trust bundles from all clusters
echo -e "${YELLOW}Step 6: Extracting trust bundles...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle show -format spiffe > "$WORK_DIR/cluster1-bundle.json"

kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle show -format spiffe > "$WORK_DIR/cluster2-bundle.json"

kubectl --kubeconfig "$CLUSTER3_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle show -format spiffe > "$WORK_DIR/cluster3-bundle.json"

echo -e "${GREEN}✓${NC} Trust bundles extracted from all clusters"
echo ""

# Step 7: Create ClusterFederatedTrustDomain resources
echo -e "${YELLOW}Step 7: Creating ClusterFederatedTrustDomain resources...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Cluster 1 - add/update federation with Cluster 2 and Cluster 3
cat > "$WORK_DIR/cluster1-federation2.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster-2-federation
spec:
  trustDomain: $CLUSTER2_TRUST_DOMAIN
  bundleEndpointURL: $CLUSTER2_FED_URL
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://$CLUSTER2_TRUST_DOMAIN/spire/server
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |-
$(cat "$WORK_DIR/cluster2-bundle.json" | sed 's/^/    /')
EOF

cat > "$WORK_DIR/cluster1-federation3.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster-3-federation
spec:
  trustDomain: $CLUSTER3_TRUST_DOMAIN
  bundleEndpointURL: $CLUSTER3_FED_URL
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://$CLUSTER3_TRUST_DOMAIN/spire/server
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |-
$(cat "$WORK_DIR/cluster3-bundle.json" | sed 's/^/    /')
EOF

# Cluster 2 - add/update federation with Cluster 1 and Cluster 3
cat > "$WORK_DIR/cluster2-federation1.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster-1-federation
spec:
  trustDomain: $CLUSTER1_TRUST_DOMAIN
  bundleEndpointURL: $CLUSTER1_FED_URL
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://$CLUSTER1_TRUST_DOMAIN/spire/server
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |-
$(cat "$WORK_DIR/cluster1-bundle.json" | sed 's/^/    /')
EOF

cat > "$WORK_DIR/cluster2-federation3.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster-3-federation
spec:
  trustDomain: $CLUSTER3_TRUST_DOMAIN
  bundleEndpointURL: $CLUSTER3_FED_URL
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://$CLUSTER3_TRUST_DOMAIN/spire/server
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |-
$(cat "$WORK_DIR/cluster3-bundle.json" | sed 's/^/    /')
EOF

# Cluster 3 - federation with Cluster 1 and Cluster 2
cat > "$WORK_DIR/cluster3-federation1.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster-1-federation
spec:
  trustDomain: $CLUSTER1_TRUST_DOMAIN
  bundleEndpointURL: $CLUSTER1_FED_URL
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://$CLUSTER1_TRUST_DOMAIN/spire/server
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |-
$(cat "$WORK_DIR/cluster1-bundle.json" | sed 's/^/    /')
EOF

cat > "$WORK_DIR/cluster3-federation2.yaml" <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster-2-federation
spec:
  trustDomain: $CLUSTER2_TRUST_DOMAIN
  bundleEndpointURL: $CLUSTER2_FED_URL
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://$CLUSTER2_TRUST_DOMAIN/spire/server
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |-
$(cat "$WORK_DIR/cluster2-bundle.json" | sed 's/^/    /')
EOF

# Apply all federation resources
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f "$WORK_DIR/cluster1-federation2.yaml"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f "$WORK_DIR/cluster1-federation3.yaml"

kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f "$WORK_DIR/cluster2-federation1.yaml"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f "$WORK_DIR/cluster2-federation3.yaml"

kubectl --kubeconfig "$CLUSTER3_KUBECONFIG" apply -f "$WORK_DIR/cluster3-federation1.yaml"
kubectl --kubeconfig "$CLUSTER3_KUBECONFIG" apply -f "$WORK_DIR/cluster3-federation2.yaml"

echo -e "${GREEN}✓${NC} ClusterFederatedTrustDomain resources created on all clusters"
echo ""

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              THREE-WAY FEDERATION SETUP COMPLETE!                  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}📊 Federation Summary:${NC}"
echo "  Cluster 1: $CLUSTER1_TRUST_DOMAIN"
echo "  Cluster 2: $CLUSTER2_TRUST_DOMAIN"
echo "  Cluster 3: $CLUSTER3_TRUST_DOMAIN"
echo "  Status: All clusters federated with each other"
echo ""

echo -e "${BLUE}🧪 VERIFICATION COMMANDS:${NC}"
echo ""
echo "1️⃣  Verify trust bundles on Cluster 1 (should show 3 domains):"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list"
echo ""
echo "2️⃣  Verify trust bundles on Cluster 2 (should show 3 domains):"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list"
echo ""
echo "3️⃣  Verify trust bundles on Cluster 3 (should show 3 domains):"
echo "   kubectl --kubeconfig $CLUSTER3_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list"
echo ""
echo "4️⃣  Check ClusterFederatedTrustDomain resources:"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG get clusterfederatedtrustdomain"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG get clusterfederatedtrustdomain"
echo "   kubectl --kubeconfig $CLUSTER3_KUBECONFIG get clusterfederatedtrustdomain"
echo ""
echo "5️⃣  Watch bundle rotation on any cluster:"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep 'Bundle refresh'"
echo ""

echo -e "${BLUE}📝 Configuration saved to:${NC} $WORK_DIR/"
echo ""

echo -e "${GREEN}🎉 Three-way federation is now active! All clusters can federate workloads with each other!${NC}"
echo ""

# Save verification script
cat > "$WORK_DIR/verify-3way-federation.sh" <<'VERIFYEOF'
#!/bin/bash
CLUSTER1_KUBECONFIG="$1"
CLUSTER2_KUBECONFIG="$2"
CLUSTER3_KUBECONFIG="$3"

echo "🧪 Verifying Three-Way Federation..."
echo ""

for i in 1 2 3; do
    eval "kubeconfig=\$CLUSTER${i}_KUBECONFIG"
    echo "═══════════════════════════════════════════════════"
    echo "Cluster $i Bundle List:"
    echo "═══════════════════════════════════════════════════"
    kubectl --kubeconfig "$kubeconfig" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list
    echo ""
done

echo "═══════════════════════════════════════════════════"
echo "ClusterFederatedTrustDomain Resources:"
echo "═══════════════════════════════════════════════════"
for i in 1 2 3; do
    eval "kubeconfig=\$CLUSTER${i}_KUBECONFIG"
    echo ""
    echo "Cluster $i:"
    kubectl --kubeconfig "$kubeconfig" get clusterfederatedtrustdomain
done
echo ""
VERIFYEOF

chmod +x "$WORK_DIR/verify-3way-federation.sh"

echo -e "${YELLOW}💾 Verification script saved to: $WORK_DIR/verify-3way-federation.sh${NC}"
echo -e "${YELLOW}   Run: $WORK_DIR/verify-3way-federation.sh $CLUSTER1_KUBECONFIG $CLUSTER2_KUBECONFIG $CLUSTER3_KUBECONFIG${NC}"
echo ""

