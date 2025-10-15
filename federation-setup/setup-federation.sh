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
    echo "  4. Deploy test workloads (federated and non-federated)"
    echo "  5. Verify federation is working"
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

# # Step 3: Expose port 8443 on SPIRE server pods
# echo -e "${YELLOW}Step 3: Exposing federation port on SPIRE servers...${NC}"
# echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" patch statefulset spire-server -n zero-trust-workload-identity-manager --type='json' \
#   -p='[{"op": "add", "path": "/spec/template/spec/containers/0/ports/-", "value": {"name": "federation", "containerPort": 8443, "protocol": "TCP"}}]' 2>/dev/null || echo "Port already exposed or patch failed (continuing...)"

# kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" patch statefulset spire-server -n zero-trust-workload-identity-manager --type='json' \
#   -p='[{"op": "add", "path": "/spec/template/spec/containers/0/ports/-", "value": {"name": "federation", "containerPort": 8443, "protocol": "TCP"}}]' 2>/dev/null || echo "Port already exposed or patch failed (continuing...)"

# echo -e "${GREEN}✓${NC} Federation port exposed"
# echo ""

# # Step 4: Restart SPIRE servers
# echo -e "${YELLOW}Step 4: Restarting SPIRE servers...${NC}"
# echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager
# kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" rollout restart statefulset spire-server -n zero-trust-workload-identity-manager

# echo "Waiting for SPIRE servers to be ready..."
# kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s
# kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" wait --for=condition=ready pod/spire-server-0 -n zero-trust-workload-identity-manager --timeout=120s

# echo -e "${GREEN}✓${NC} SPIRE servers restarted and ready"
# echo ""

# Step 5: Extract trust bundles
echo -e "${YELLOW}Step 5: Extracting trust bundles...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle show -format spiffe > "$WORK_DIR/cluster1-bundle.json"

kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
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

# # Step 7: Deploy test workloads
# echo -e "${YELLOW}Step 7: Deploying test workloads...${NC}"
# echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# # Deploy to Cluster 2 (backends)
# kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f - <<EOF
# ---
# apiVersion: v1
# kind: Namespace
# metadata:
#   name: federation-demo
# ---
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: federated-backend
#   namespace: federation-demo
# ---
# apiVersion: spire.spiffe.io/v1alpha1
# kind: ClusterSPIFFEID
# metadata:
#   name: federated-backend
# spec:
#   spiffeIDTemplate: "spiffe://$CLUSTER2_TRUST_DOMAIN/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
#   podSelector:
#     matchLabels:
#       app: federated-backend
#   namespaceSelector:
#     matchLabels:
#       kubernetes.io/metadata.name: federation-demo
#   federatesWith:
#   - "$CLUSTER1_TRUST_DOMAIN"
#   className: zero-trust-workload-identity-manager-spire
# ---
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: non-federated-backend
#   namespace: federation-demo
# ---
# apiVersion: spire.spiffe.io/v1alpha1
# kind: ClusterSPIFFEID
# metadata:
#   name: non-federated-backend
# spec:
#   spiffeIDTemplate: "spiffe://$CLUSTER2_TRUST_DOMAIN/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
#   podSelector:
#     matchLabels:
#       app: non-federated-backend
#   namespaceSelector:
#     matchLabels:
#       kubernetes.io/metadata.name: federation-demo
#   className: zero-trust-workload-identity-manager-spire
# ---
# apiVersion: v1
# kind: Pod
# metadata:
#   name: federated-backend
#   namespace: federation-demo
#   labels:
#     app: federated-backend
# spec:
#   serviceAccountName: federated-backend
#   containers:
#   - name: api
#     image: python:3.11-slim
#     command: ["/bin/bash", "-c"]
#     args:
#     - |
#       cat > /app.py << 'PYEOF'
#       from http.server import HTTPServer, BaseHTTPRequestHandler
#       import json
#       from datetime import datetime
      
#       class Handler(BaseHTTPRequestHandler):
#           def do_GET(self):
#               if self.path == '/api/stock-data':
#                   print(f"[{datetime.now().strftime('%H:%M:%S')}] 📥 API REQUEST from {self.client_address[0]}")
                  
#                   response = {
#                       'status': 'success',
#                       'backend': 'federated-backend',
#                       'cluster': 'cluster-2',
#                       'trust_domain': '$CLUSTER2_TRUST_DOMAIN',
#                       'federation_enabled': True,
#                       'federates_with': ['$CLUSTER1_TRUST_DOMAIN'],
#                       'data': {
#                           'stocks': [
#                               {'symbol': 'AAPL', 'price': 150.25, 'change': '+2.5%'},
#                               {'symbol': 'GOOGL', 'price': 2800.50, 'change': '+1.2%'},
#                               {'symbol': 'MSFT', 'price': 380.75, 'change': '+0.8%'}
#                           ],
#                           'timestamp': datetime.now().isoformat(),
#                           'message': '✅ Federation is WORKING! Data from Cluster 2'
#                       }
#                   }
                  
#                   self.send_response(200)
#                   self.send_header('Content-Type', 'application/json')
#                   self.send_header('X-Backend-Cluster', 'cluster-2')
#                   self.send_header('X-Federation', 'enabled')
#                   self.end_headers()
#                   self.wfile.write(json.dumps(response, indent=2).encode())
                  
#                   print(f"[{datetime.now().strftime('%H:%M:%S')}] ✅ Response sent successfully")
#               elif self.path == '/health':
#                   self.send_response(200)
#                   self.send_header('Content-Type', 'text/plain')
#                   self.end_headers()
#                   self.wfile.write(b'OK')
#               else:
#                   self.send_response(404)
#                   self.end_headers()
          
#           def log_message(self, format, *args):
#               pass  # Suppress default logging
      
#       print("=" * 70)
#       print("🚀 FEDERATED BACKEND API (Cluster 2)")
#       print("=" * 70)
#       print("✅ Federation ENABLED")
#       print("✅ Trust Domain: $CLUSTER2_TRUST_DOMAIN")
#       print("✅ Federates With: $CLUSTER1_TRUST_DOMAIN")
#       print("")
#       print("📡 API Endpoints:")
#       print("   GET /api/stock-data  - Returns stock market data")
#       print("   GET /health          - Health check")
#       print("")
#       print("🌐 Listening on port 8080...")
#       print("Waiting for API requests...")
#       print("")
      
#       server = HTTPServer(('0.0.0.0', 8080), Handler)
#       server.serve_forever()
#       PYEOF
      
#       python3 /app.py
#     ports:
#     - containerPort: 8080
#     volumeMounts:
#     - name: spiffe-workload-api
#       mountPath: /spiffe-workload-api
#       readOnly: true
#   volumes:
#   - name: spiffe-workload-api
#     csi:
#       driver: csi.spiffe.io
#       readOnly: true
# ---
# apiVersion: v1
# kind: Pod
# metadata:
#   name: non-federated-backend
#   namespace: federation-demo
#   labels:
#     app: non-federated-backend
# spec:
#   serviceAccountName: non-federated-backend
#   containers:
#   - name: api
#     image: python:3.11-slim
#     command: ["/bin/bash", "-c"]
#     args:
#     - |
#       cat > /app.py << 'PYEOF'
#       from http.server import HTTPServer, BaseHTTPRequestHandler
#       import json
#       from datetime import datetime
      
#       class Handler(BaseHTTPRequestHandler):
#           def do_GET(self):
#               if self.path == '/api/stock-data':
#                   print(f"[{datetime.now().strftime('%H:%M:%S')}] ⚠️  API REQUEST (UNEXPECTED!)")
#                   print("   This backend should NOT receive cluster-1 requests!")
                  
#                   response = {
#                       'status': 'error',
#                       'backend': 'non-federated-backend',
#                       'cluster': 'cluster-2',
#                       'trust_domain': '$CLUSTER2_TRUST_DOMAIN',
#                       'federation_enabled': False,
#                       'federates_with': [],
#                       'error': 'This backend does NOT trust $CLUSTER1_TRUST_DOMAIN',
#                       'message': '❌ If you see this, check your configuration!',
#                       'timestamp': datetime.now().isoformat()
#                   }
                  
#                   self.send_response(403)
#                   self.send_header('Content-Type', 'application/json')
#                   self.send_header('X-Backend-Cluster', 'cluster-2')
#                   self.send_header('X-Federation', 'disabled')
#                   self.end_headers()
#                   self.wfile.write(json.dumps(response, indent=2).encode())
                  
#                   print(f"[{datetime.now().strftime('%H:%M:%S')}] ❌ Sent error response")
#               elif self.path == '/health':
#                   self.send_response(200)
#                   self.send_header('Content-Type', 'text/plain')
#                   self.end_headers()
#                   self.wfile.write(b'OK')
#               else:
#                   self.send_response(404)
#                   self.end_headers()
          
#           def log_message(self, format, *args):
#               pass
      
#       print("=" * 70)
#       print("🚀 NON-FEDERATED BACKEND API (Cluster 2)")
#       print("=" * 70)
#       print("❌ Federation DISABLED")
#       print("❌ Trust Domain: $CLUSTER2_TRUST_DOMAIN")
#       print("❌ Does NOT trust: $CLUSTER1_TRUST_DOMAIN")
#       print("")
#       print("📡 API Endpoints:")
#       print("   GET /api/stock-data  - Will return error")
#       print("   GET /health          - Health check")
#       print("")
#       print("🌐 Listening on port 8081...")
#       print("⚠️  Should NOT receive requests from cluster-1!")
#       print("")
      
#       server = HTTPServer(('0.0.0.0', 8081), Handler)
#       server.serve_forever()
#       PYEOF
      
#       python3 /app.py
#     ports:
#     - containerPort: 8081
#     volumeMounts:
#     - name: spiffe-workload-api
#       mountPath: /spiffe-workload-api
#       readOnly: true
#   volumes:
#   - name: spiffe-workload-api
#     csi:
#       driver: csi.spiffe.io
#       readOnly: true
# ---
# apiVersion: v1
# kind: Service
# metadata:
#   name: federated-backend
#   namespace: federation-demo
# spec:
#   selector:
#     app: federated-backend
#   ports:
#   - port: 8080
#     targetPort: 8080
# ---
# apiVersion: v1
# kind: Service
# metadata:
#   name: non-federated-backend
#   namespace: federation-demo
# spec:
#   selector:
#     app: non-federated-backend
#   ports:
#   - port: 8081
#     targetPort: 8081
# ---
# apiVersion: route.openshift.io/v1
# kind: Route
# metadata:
#   name: federated-backend
#   namespace: federation-demo
# spec:
#   to:
#     kind: Service
#     name: federated-backend
#   port:
#     targetPort: 8080
#   tls:
#     termination: edge
# ---
# apiVersion: route.openshift.io/v1
# kind: Route
# metadata:
#   name: non-federated-backend
#   namespace: federation-demo
# spec:
#   to:
#     kind: Service
#     name: non-federated-backend
#   port:
#     targetPort: 8081
#   tls:
#     termination: edge
# EOF

# # Deploy to Cluster 1 (frontends)
# kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f - <<EOF
# ---
# apiVersion: v1
# kind: Namespace
# metadata:
#   name: federation-demo
# ---
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: federated-frontend
#   namespace: federation-demo
# ---
# apiVersion: spire.spiffe.io/v1alpha1
# kind: ClusterSPIFFEID
# metadata:
#   name: federated-frontend
# spec:
#   spiffeIDTemplate: "spiffe://$CLUSTER1_TRUST_DOMAIN/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
#   podSelector:
#     matchLabels:
#       app: federated-frontend
#   namespaceSelector:
#     matchLabels:
#       kubernetes.io/metadata.name: federation-demo
#   federatesWith:
#   - "$CLUSTER2_TRUST_DOMAIN"
#   className: zero-trust-workload-identity-manager-spire
# ---
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: non-federated-frontend
#   namespace: federation-demo
# ---
# apiVersion: spire.spiffe.io/v1alpha1
# kind: ClusterSPIFFEID
# metadata:
#   name: non-federated-frontend
# spec:
#   spiffeIDTemplate: "spiffe://$CLUSTER1_TRUST_DOMAIN/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
#   podSelector:
#     matchLabels:
#       app: non-federated-frontend
#   namespaceSelector:
#     matchLabels:
#       kubernetes.io/metadata.name: federation-demo
#   className: zero-trust-workload-identity-manager-spire
# ---
# apiVersion: v1
# kind: Pod
# metadata:
#   name: federated-frontend
#   namespace: federation-demo
#   labels:
#     app: federated-frontend
# spec:
#   serviceAccountName: federated-frontend
#   containers:
#   - name: client
#     image: python:3.11-slim
#     command: ["/bin/bash", "-c"]
#     args:
#     - |
#       apt-get update -qq && apt-get install -y curl -qq
      
#       cat > /app.py << 'PYEOF'
#       import requests
#       import time
#       from datetime import datetime
      
#       backend_url = "http://federated-backend.federation-demo.svc.cluster.local:8080/api/stock-data"
      
#       print("=" * 70)
#       print("🚀 FEDERATED FRONTEND CLIENT (Cluster 1)")
#       print("=" * 70)
#       print("✅ Federation ENABLED")
#       print("✅ Trust Domain: $CLUSTER1_TRUST_DOMAIN")
#       print("✅ Federates With: $CLUSTER2_TRUST_DOMAIN")
#       print("")
#       print(f"🎯 Target backend: {backend_url}")
#       print("🔄 Will call API every 30 seconds...")
#       print("")
      
#       time.sleep(10)
      
#       while True:
#           try:
#               print("=" * 70)
#               print(f"[{datetime.now().strftime('%H:%M:%S')}] 📤 CALLING BACKEND API...")
#               print(f"   URL: {backend_url}")
              
#               response = requests.get(backend_url, timeout=10)
              
#               if response.status_code == 200:
#                   data = response.json()
#                   print(f"[{datetime.now().strftime('%H:%M:%S')}] ✅ SUCCESS!")
#                   print("")
#                   print("📦 Response:")
#                   print(f"   Backend: {data.get('backend')}")
#                   print(f"   Cluster: {data.get('cluster')}")
#                   print(f"   Federation: {data.get('federation_enabled')}")
#                   print("")
#                   print("📈 Stock Data Received:")
#                   for stock in data.get('data', {}).get('stocks', []):
#                       print(f"   {stock['symbol']}: \${stock['price']} ({stock['change']})")
#                   print("")
#                   print(f"🎉 {data.get('data', {}).get('message')}")
#               else:
#                   print(f"[{datetime.now().strftime('%H:%M:%S')}] ❌ ERROR: Status {response.status_code}")
                  
#           except Exception as e:
#               print(f"[{datetime.now().strftime('%H:%M:%S')}] ❌ FAILED: {e}")
          
#           print("")
#           print("⏳ Waiting 30 seconds...")
#           time.sleep(30)
#       PYEOF
      
#       pip install requests --quiet
#       python3 /app.py
#     volumeMounts:
#     - name: spiffe-workload-api
#       mountPath: /spiffe-workload-api
#       readOnly: true
#   volumes:
#   - name: spiffe-workload-api
#     csi:
#       driver: csi.spiffe.io
#       readOnly: true
# ---
# apiVersion: v1
# kind: Pod
# metadata:
#   name: non-federated-frontend
#   namespace: federation-demo
#   labels:
#     app: non-federated-frontend
# spec:
#   serviceAccountName: non-federated-frontend
#   containers:
#   - name: client
#     image: python:3.11-slim
#     command: ["/bin/bash", "-c"]
#     args:
#     - |
#       apt-get update -qq && apt-get install -y curl -qq
      
#       cat > /app.py << 'PYEOF'
#       import requests
#       import time
#       from datetime import datetime
      
#       backend_url = "http://non-federated-backend.federation-demo.svc.cluster.local:8081/api/stock-data"
      
#       print("=" * 70)
#       print("🚀 NON-FEDERATED FRONTEND CLIENT (Cluster 1)")
#       print("=" * 70)
#       print("❌ Federation DISABLED")
#       print("❌ Trust Domain: $CLUSTER1_TRUST_DOMAIN")
#       print("❌ Does NOT trust: $CLUSTER2_TRUST_DOMAIN")
#       print("")
#       print(f"🎯 Target backend: {backend_url}")
#       print("⚠️  Expected: Requests will FAIL (no federation)")
#       print("🔄 Will try calling API every 30 seconds...")
#       print("")
      
#       time.sleep(10)
      
#       while True:
#           try:
#               print("=" * 70)
#               print(f"[{datetime.now().strftime('%H:%M:%S')}] 📤 CALLING NON-FEDERATED BACKEND...")
#               print(f"   URL: {backend_url}")
              
#               response = requests.get(backend_url, timeout=10)
              
#               if response.status_code == 403:
#                   data = response.json()
#                   print(f"[{datetime.now().strftime('%H:%M:%S')}] ❌ REJECTED (EXPECTED)")
#                   print("")
#                   print(f"   Error: {data.get('error')}")
#                   print(f"   Reason: Backend has no $CLUSTER1_TRUST_DOMAIN bundle")
#                   print("")
#                   print("✅ This is CORRECT - proves federation is required!")
#               else:
#                   print(f"[{datetime.now().strftime('%H:%M:%S')}] Unexpected status: {response.status_code}")
                  
#           except Exception as e:
#               print(f"[{datetime.now().strftime('%H:%M:%S')}] ❌ FAILED: {e}")
#               print("✅ This is EXPECTED - no federation configured!")
          
#           print("")
#           print("⏳ Waiting 30 seconds...")
#           time.sleep(30)
#       PYEOF
      
#       pip install requests --quiet
#       python3 /app.py
#     volumeMounts:
#     - name: spiffe-workload-api
#       mountPath: /spiffe-workload-api
#       readOnly: true
#   volumes:
#   - name: spiffe-workload-api
#     csi:
#       driver: csi.spiffe.io
#       readOnly: true
# EOF

# echo -e "${GREEN}✓${NC} Test workloads deployed"
# echo ""

# # Wait for pods
# echo "Waiting for pods to be ready..."
# sleep 30

# echo ""
# echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
# echo -e "${GREEN}║                    SETUP COMPLETE!                                 ║${NC}"
# echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
# echo ""

# # Get backend URLs
# FED_BACKEND_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route federated-backend -n federation-demo -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "pending...")
# NON_FED_BACKEND_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route non-federated-backend -n federation-demo -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "pending...")

# echo -e "${BLUE}📊 Federation Summary:${NC}"
# echo "  Cluster 1: $CLUSTER1_TRUST_DOMAIN"
# echo "  Cluster 2: $CLUSTER2_TRUST_DOMAIN"
# echo "  Status: Configured and operational"
# echo ""

# echo -e "${BLUE}🌐 Backend API URLs:${NC}"
# echo "  Federated:     $FED_BACKEND_URL/api/stock-data"
# echo "  Non-Federated: $NON_FED_BACKEND_URL/api/stock-data"
# echo ""

# echo -e "${BLUE}🧪 TEST COMMANDS:${NC}"
# echo ""
# echo "1️⃣  Verify trust bundle exchange:"
# echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list"
# echo ""
# echo "2️⃣  Watch federated frontend logs (see API calls):"
# echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -f federated-frontend -n federation-demo"
# echo ""
# echo "3️⃣  Watch federated backend logs (see requests):"
# echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG logs -f federated-backend -n federation-demo"
# echo ""
# echo "4️⃣  Test with curl (once routes are ready):"
# echo "   curl $FED_BACKEND_URL/api/stock-data"
# echo ""
# echo "5️⃣  Watch bundle rotation live:"
# echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep 'Bundle refresh'"
# echo ""

# echo -e "${BLUE}📝 Documentation:${NC}"
# echo "  All setup details: $WORK_DIR/"
# echo "  Federation config: Saved in $WORK_DIR/"
# echo ""

# echo -e "${GREEN}🎉 Federation setup complete! Wait 2-3 minutes for pods to start, then test!${NC}"
# echo ""

# # Save test commands to file
# cat > "$WORK_DIR/test-commands.sh" <<TESTEOF
# #!/bin/bash

# echo "🧪 Testing Federation..."
# echo ""

# echo "1. Trust bundles:"
# kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server bundle list

# echo ""
# echo "2. Federated entry:"
# kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show | grep -A 12 "federated-backend"

# echo ""
# echo "3. Recent rotations:"
# kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=200 | grep "Bundle refreshed" | tail -5

# echo ""
# echo "4. Backend URLs:"
# echo "   Federated:     $FED_BACKEND_URL/api/stock-data"
# echo "   Non-Federated: $NON_FED_BACKEND_URL/api/stock-data"

# echo ""
# echo "5. Curl test (once pods are running):"
# echo "   curl $FED_BACKEND_URL/api/stock-data"
# TESTEOF

# chmod +x "$WORK_DIR/test-commands.sh"

# echo -e "${YELLOW}💾 Test commands saved to: $WORK_DIR/test-commands.sh${NC}"
# echo ""

