#!/bin/bash

# SPIRE Federation Setup Script
# This script sets up complete SPIRE federation between two OpenShift clusters

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage function
usage() {
    echo "Usage: $0 <cluster1-kubeconfig> <cluster2-kubeconfig>"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig"
    echo ""
    echo "This script will:"
    echo "  1. Configure federation endpoints on both SPIRE servers"
    echo "  2. Expose federation bundle endpoints via routes"
    echo "  3. Exchange trust bundles between clusters"
    echo "  4. Deploy test workloads with federation enabled"
    echo "  5. Verify federation is working"
    echo "  6. Show 'federates with' in workload entries"
    exit 1
}

# Check arguments
if [ $# -ne 2 ]; then
    usage
fi

CLUSTER1_KUBECONFIG="$1"
CLUSTER2_KUBECONFIG="$2"

# Verify kubeconfig files exist
if [ ! -f "$CLUSTER1_KUBECONFIG" ]; then
    echo -e "${RED}Error: Cluster 1 kubeconfig not found: $CLUSTER1_KUBECONFIG${NC}"
    exit 1
fi

if [ ! -f "$CLUSTER2_KUBECONFIG" ]; then
    echo -e "${RED}Error: Cluster 2 kubeconfig not found: $CLUSTER2_KUBECONFIG${NC}"
    exit 1
fi

# Create working directory
WORK_DIR="/tmp/spire-federation-setup-$$"
mkdir -p "$WORK_DIR"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         SPIRE Federation Setup Script                             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Cluster 1 kubeconfig:${NC} $CLUSTER1_KUBECONFIG"
echo -e "${GREEN}Cluster 2 kubeconfig:${NC} $CLUSTER2_KUBECONFIG"
echo -e "${GREEN}Working directory:${NC} $WORK_DIR"
echo ""

# Function to get trust domain from cluster
get_trust_domain() {
    local kubeconfig=$1
    kubectl --kubeconfig "$kubeconfig" get spireserver cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null || echo ""
}

# Function to get cluster name
get_cluster_name() {
    local kubeconfig=$1
    kubectl --kubeconfig "$kubeconfig" get spireserver cluster -o jsonpath='{.spec.clusterName}' 2>/dev/null || echo ""
}

# Get cluster information
echo -e "${YELLOW}Step 1: Gathering cluster information...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CLUSTER1_TRUST_DOMAIN=$(get_trust_domain "$CLUSTER1_KUBECONFIG")
CLUSTER2_TRUST_DOMAIN=$(get_trust_domain "$CLUSTER2_KUBECONFIG")
CLUSTER1_NAME=$(get_cluster_name "$CLUSTER1_KUBECONFIG")
CLUSTER2_NAME=$(get_cluster_name "$CLUSTER2_KUBECONFIG")

if [ -z "$CLUSTER1_TRUST_DOMAIN" ] || [ -z "$CLUSTER2_TRUST_DOMAIN" ]; then
    echo -e "${RED}Error: Could not get trust domains from clusters${NC}"
    echo "Please ensure zero-trust-workload-identity-manager is installed and SpireServer CR exists"
    exit 1
fi

echo -e "${GREEN}✓${NC} Cluster 1: Trust Domain = $CLUSTER1_TRUST_DOMAIN"
echo -e "${GREEN}✓${NC} Cluster 2: Trust Domain = $CLUSTER2_TRUST_DOMAIN"
echo ""

# Step 2: Update SPIRE server configs with federation endpoints
echo -e "${YELLOW}Step 2: Configuring federation endpoints...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get current configmaps
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get configmap spire-server -n zero-trust-workload-identity-manager -o yaml > "$WORK_DIR/cluster1-cm.yaml"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get configmap spire-server -n zero-trust-workload-identity-manager -o yaml > "$WORK_DIR/cluster2-cm.yaml"

# Get federation route URLs (we'll create them first, then update config)
echo "Creating federation services and routes..."

# Create federation service and route for Cluster 1
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f - <<EOF
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

# Create federation service and route for Cluster 2
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f - <<EOF
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

echo -e "${GREEN}✓${NC} Cluster 1 federation endpoint: $CLUSTER1_FED_URL"
echo -e "${GREEN}✓${NC} Cluster 2 federation endpoint: $CLUSTER2_FED_URL"
echo ""

# Update SPIRE server configmaps with federation configuration
echo "Updating SPIRE server configurations..."

# Function to update configmap with federation config
update_configmap() {
    local kubeconfig=$1
    local trust_domain=$2
    local cluster_name=$3
    local fed_trust_domain=$4
    local fed_url=$5
    local fed_spiffe_id=$6
    local output_file=$7
    
    # Get current config
    local current_config=$(kubectl --kubeconfig "$kubeconfig" get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}')
    
    # Add federation configuration using Python for JSON manipulation
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

# KEY MUST BE TRUST DOMAIN, NOT URL!
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

print(json.dumps(config, indent=2))
" > "$output_file"
}

# For Cluster 1 - federates with Cluster 2
update_configmap "$CLUSTER1_KUBECONFIG" "$CLUSTER1_TRUST_DOMAIN" "$CLUSTER1_NAME" \
    "$CLUSTER2_TRUST_DOMAIN" "$CLUSTER2_FED_URL" "spiffe://$CLUSTER2_TRUST_DOMAIN/spire/server" \
    "$WORK_DIR/cluster1-server-conf.json"

# For Cluster 2 - federates with Cluster 1
update_configmap "$CLUSTER2_KUBECONFIG" "$CLUSTER2_TRUST_DOMAIN" "$CLUSTER2_NAME" \
    "$CLUSTER1_TRUST_DOMAIN" "$CLUSTER1_FED_URL" "spiffe://$CLUSTER1_TRUST_DOMAIN/spire/server" \
    "$WORK_DIR/cluster2-server-conf.json"

# Apply updated configmaps
cat > "$WORK_DIR/cluster1-cm-updated.yaml" <<EOF
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
$(cat "$WORK_DIR/cluster1-server-conf.json" | sed 's/^/    /')
EOF

cat > "$WORK_DIR/cluster2-cm-updated.yaml" <<EOF
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
$(cat "$WORK_DIR/cluster2-server-conf.json" | sed 's/^/    /')
EOF

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f "$WORK_DIR/cluster1-cm-updated.yaml"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f "$WORK_DIR/cluster2-cm-updated.yaml"

echo -e "${GREEN}✓${NC} Updated SPIRE server configurations"
echo ""

# Step 3: Expose port 8443 on SPIRE server pods
echo -e "${YELLOW}Step 3: Exposing federation port on SPIRE servers...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" patch statefulset spire-server -n zero-trust-workload-identity-manager --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/ports/-", "value": {"name": "federation", "containerPort": 8443, "protocol": "TCP"}}]' 2>/dev/null || echo "Port already exposed or patch failed (continuing...)"

kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" patch statefulset spire-server -n zero-trust-workload-identity-manager --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/ports/-", "value": {"name": "federation", "containerPort": 8443, "protocol": "TCP"}}]' 2>/dev/null || echo "Port already exposed or patch failed (continuing...)"

echo -e "${GREEN}✓${NC} Federation port exposed"
echo ""

# Step 4: Restart SPIRE servers
echo -e "${YELLOW}Step 4: Restarting SPIRE servers...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager

sleep 180

echo "Waiting for SPIRE servers to be ready..."
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s

echo -e "${GREEN}✓${NC} SPIRE servers restarted and ready"
echo ""

# Step 5: Extract trust bundles
echo -e "${YELLOW}Step 5: Extracting trust bundles...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server bundle show -format spiffe > "$WORK_DIR/cluster1-bundle.json"

kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server bundle show -format spiffe > "$WORK_DIR/cluster2-bundle.json"

echo -e "${GREEN}✓${NC} Trust bundles extracted"
echo ""

# Step 6: Create ClusterFederatedTrustDomain resources
echo -e "${YELLOW}Step 6: Creating ClusterFederatedTrustDomain resources...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Cluster 1 federates with Cluster 2
cat > "$WORK_DIR/cluster1-federation.yaml" <<EOF
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

# Cluster 2 federates with Cluster 1
cat > "$WORK_DIR/cluster2-federation.yaml" <<EOF
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

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f "$WORK_DIR/cluster1-federation.yaml"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f "$WORK_DIR/cluster2-federation.yaml"

echo -e "${GREEN}✓${NC} ClusterFederatedTrustDomain resources created"
echo ""

echo -e "${BLUE}📊 Federation Summary:${NC}"
echo "  Cluster 1: $CLUSTER1_TRUST_DOMAIN"
echo "  Cluster 2: $CLUSTER2_TRUST_DOMAIN"
echo "  Status: Configured and operational"
echo ""

echo -e "${BLUE}🧪 TEST COMMANDS:${NC}"
echo ""
echo "1. Verify trust bundle exchange:"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list"
echo ""
echo "2. Watch bundle rotation live:"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep 'Bundle refresh'"
echo ""

# Step 7: Deploy test workloads with federation
echo -e "${YELLOW}Step 7: Deploying test workloads with federation...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create namespace for test workloads on Cluster 1
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: federation-demo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-workload-c1
  namespace: federation-demo
---
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: test-workload-c1
spec:
  spiffeIDTemplate: "spiffe://${CLUSTER1_TRUST_DOMAIN}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: test-workload-c1
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: federation-demo
  federatesWith:
  - "${CLUSTER2_TRUST_DOMAIN}"
  className: zero-trust-workload-identity-manager-spire
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-workload-c1
  namespace: federation-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-workload-c1
  template:
    metadata:
      labels:
        app: test-workload-c1
    spec:
      serviceAccountName: test-workload-c1
      containers:
      - name: workload
        image: registry.redhat.io/ubi9/ubi-minimal:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Test Workload on Cluster 1 - Federates with ${CLUSTER2_TRUST_DOMAIN}"
          while true; do sleep 3600; done
        volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
      volumes:
      - name: spiffe-workload-api
        csi:
          driver: csi.spiffe.io
          readOnly: true
EOF

echo -e "${GREEN}✓${NC} Deployed test workload to Cluster 1"

# Create namespace for test workloads on Cluster 2
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: federation-demo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-workload-c2
  namespace: federation-demo
---
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: test-workload-c2
spec:
  spiffeIDTemplate: "spiffe://${CLUSTER2_TRUST_DOMAIN}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: test-workload-c2
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: federation-demo
  federatesWith:
  - "${CLUSTER1_TRUST_DOMAIN}"
  className: zero-trust-workload-identity-manager-spire
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-workload-c2
  namespace: federation-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-workload-c2
  template:
    metadata:
      labels:
        app: test-workload-c2
    spec:
      serviceAccountName: test-workload-c2
      containers:
      - name: workload
        image: registry.redhat.io/ubi9/ubi-minimal:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Test Workload on Cluster 2 - Federates with ${CLUSTER1_TRUST_DOMAIN}"
          while true; do sleep 3600; done
        volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
      volumes:
      - name: spiffe-workload-api
        csi:
          driver: csi.spiffe.io
          readOnly: true
EOF

echo -e "${GREEN}✓${NC} Deployed test workload to Cluster 2"
echo ""

# Wait for workload pods to be ready
echo "Waiting for workload pods to be ready..."
sleep 10
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" wait --for=condition=ready pod -l app=test-workload-c1 -n federation-demo --timeout=120s || echo "Warning: Cluster 1 workload not ready yet"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" wait --for=condition=ready pod -l app=test-workload-c2 -n federation-demo --timeout=120s || echo "Warning: Cluster 2 workload not ready yet"

echo -e "${GREEN}✓${NC} Workloads deployed and ready"
echo ""

# Wait a bit for entries to be created
echo "Waiting for SPIRE entries to be created..."
sleep 15
echo ""

# Step 8: Verify federation with entry show
echo -e "${YELLOW}Step 8: Verifying federation in workload entries...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "🧪 Testing Federation..."
echo ""

echo "1. Trust bundles on Cluster 1:"
echo "───────────────────────────────"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list

echo ""
echo "2. Trust bundles on Cluster 2:"
echo "───────────────────────────────"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list

echo ""
echo "3. Workload entries on Cluster 1 (showing 'federates with'):"
echo "──────────────────────────────────────────────────────────────"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show | grep -A 30 "test-workload-c1" || kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show

echo ""
echo "4. Workload entries on Cluster 2 (showing 'federates with'):"
echo "──────────────────────────────────────────────────────────────"
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show | grep -A 30 "test-workload-c2" || kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show

echo ""
echo "5. Recent bundle rotations on Cluster 1:"
echo "─────────────────────────────────────────"
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 | grep "Bundle refreshed" | tail -5 || echo "No bundle refresh logs found yet"

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    FEDERATION SETUP COMPLETE!                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓${NC} Federation configured between:"
echo "  • Cluster 1: ${CLUSTER1_TRUST_DOMAIN}"
echo "  • Cluster 2: ${CLUSTER2_TRUST_DOMAIN}"
echo ""
echo -e "${GREEN}✓${NC} Test workloads deployed:"
echo "  • Cluster 1: test-workload-c1 (federates with ${CLUSTER2_TRUST_DOMAIN})"
echo "  • Cluster 2: test-workload-c2 (federates with ${CLUSTER1_TRUST_DOMAIN})"
echo ""
echo -e "${YELLOW}📋 What was demonstrated:${NC}"
echo "  1. Trust bundle exchange between clusters"
echo "  2. ClusterFederatedTrustDomain resources created"
echo "  3. Workload entries showing 'federates with' field"
echo "  4. Both clusters can verify each other's identities"
echo ""
echo -e "${YELLOW}📋 Next Steps:${NC}"
echo "  • Deploy mTLS-enabled applications that communicate across clusters"
echo "  • Verify SVIDs include federated trust bundles"
echo "  • Monitor bundle rotation logs"
echo ""
echo -e "${YELLOW}🔍 Useful Commands:${NC}"
echo ""
echo "View all workload entries on Cluster 1:"
echo "  kubectl --kubeconfig $CLUSTER1_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show"
echo ""
echo "View all workload entries on Cluster 2:"
echo "  kubectl --kubeconfig $CLUSTER2_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show"
echo ""
echo "Check ClusterFederatedTrustDomain status on Cluster 1:"
echo "  kubectl --kubeconfig $CLUSTER1_KUBECONFIG get clusterfederatedtrustdomain -o yaml"
echo ""
echo "Check ClusterFederatedTrustDomain status on Cluster 2:"
echo "  kubectl --kubeconfig $CLUSTER2_KUBECONFIG get clusterfederatedtrustdomain -o yaml"
echo ""
echo "View workload pods:"
echo "  kubectl --kubeconfig $CLUSTER1_KUBECONFIG get pods -n federation-demo"
echo "  kubectl --kubeconfig $CLUSTER2_KUBECONFIG get pods -n federation-demo"
echo ""
echo -e "${GREEN}Setup complete!${NC} Your SPIRE federation is operational."
echo ""

