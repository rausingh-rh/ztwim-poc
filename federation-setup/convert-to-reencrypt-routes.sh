#!/bin/bash

# Script to convert SPIRE federation routes from passthrough to reencrypt termination
# WARNING: This will break SPIFFE mTLS authentication unless you also update the SPIRE configuration

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

# Certificate approach: "self-signed" or "openshift-service-ca"
CERT_APPROACH="${CERT_APPROACH:-openshift-service-ca}"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Converting Federation Routes to Reencrypt Termination   ║"
echo "╔════════════════════════════════════════════════════════════╗"
echo ""

echo -e "${YELLOW}⚠️  WARNING: This will change the TLS termination model${NC}"
echo "   Current: Passthrough (end-to-end SPIFFE mTLS)"
echo "   New: Reencrypt (router terminates and re-encrypts)"
echo ""
echo -e "${YELLOW}⚠️  This breaks SPIFFE authentication unless you update SPIRE config${NC}"
echo "   to use 'https_web' instead of 'https_spiffe' profile"
echo ""
read -p "Do you want to continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi
echo ""

# Function to extract SPIRE bundle CA
extract_spire_ca() {
    local kubeconfig=$1
    local output_file=$2
    
    echo "Extracting SPIRE server CA certificate..."
    kubectl --kubeconfig "$kubeconfig" get configmap spire-bundle \
        -n "$NAMESPACE" \
        -o jsonpath='{.data.bundle\.crt}' > "$output_file"
    
    if [ ! -s "$output_file" ]; then
        echo -e "${RED}✗${NC} Failed to extract SPIRE CA certificate"
        exit 1
    fi
    echo -e "${GREEN}✓${NC} SPIRE CA extracted to $output_file"
}

# Function to generate self-signed certificate for route
generate_self_signed_cert() {
    local hostname=$1
    local cert_file=$2
    local key_file=$3
    
    echo "Generating self-signed certificate for $hostname..."
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/CN=$hostname/O=SPIRE Federation" \
        -addext "subjectAltName = DNS:$hostname" 2>/dev/null
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        echo -e "${RED}✗${NC} Failed to generate certificate"
        exit 1
    fi
    
    echo -e "${GREEN}✓${NC} Certificate generated"
}

# Function to use OpenShift Service CA
use_openshift_service_ca() {
    local kubeconfig=$1
    local cluster_name=$2
    
    echo "Setting up OpenShift Service CA for $cluster_name..."
    
    # Annotate the service to generate certificates
    kubectl --kubeconfig "$kubeconfig" annotate service spire-server-federation \
        -n "$NAMESPACE" \
        service.beta.openshift.io/serving-cert-secret-name=spire-federation-route-tls \
        --overwrite
    
    # Wait for the secret to be created
    echo "Waiting for certificate secret to be created..."
    for i in {1..30}; do
        if kubectl --kubeconfig "$kubeconfig" get secret spire-federation-route-tls \
            -n "$NAMESPACE" &>/dev/null; then
            echo -e "${GREEN}✓${NC} Certificate secret created"
            return 0
        fi
        sleep 2
    done
    
    echo -e "${RED}✗${NC} Timeout waiting for certificate secret"
    exit 1
}

# Function to create reencrypt route
create_reencrypt_route() {
    local kubeconfig=$1
    local cluster_name=$2
    local route_cert_file=$3
    local route_key_file=$4
    local spire_ca_file=$5
    
    echo ""
    echo "Creating reencrypt route for $cluster_name..."
    
    # Read certificate contents
    local route_cert=$(cat "$route_cert_file")
    local route_key=$(cat "$route_key_file")
    local spire_ca=$(cat "$spire_ca_file")
    
    # Get the CA certificate (for self-signed, it's the same as the cert)
    local ca_cert="$route_cert"
    
    # Create the route
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
    termination: reencrypt
    certificate: |
$(echo "$route_cert" | sed 's/^/      /')
    key: |
$(echo "$route_key" | sed 's/^/      /')
    caCertificate: |
$(echo "$ca_cert" | sed 's/^/      /')
    destinationCACertificate: |
$(echo "$spire_ca" | sed 's/^/      /')
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Reencrypt route created successfully"
    else
        echo -e "${RED}✗${NC} Failed to create reencrypt route"
        exit 1
    fi
}

# Function to create reencrypt route using OpenShift Service CA
create_reencrypt_route_with_service_ca() {
    local kubeconfig=$1
    local cluster_name=$2
    local spire_ca_file=$3
    
    echo ""
    echo "Creating reencrypt route for $cluster_name (using service CA)..."
    
    # Read SPIRE CA
    local spire_ca=$(cat "$spire_ca_file")
    
    # Extract certificate and key from secret
    local route_cert=$(kubectl --kubeconfig "$kubeconfig" get secret spire-federation-route-tls \
        -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d)
    local route_key=$(kubectl --kubeconfig "$kubeconfig" get secret spire-federation-route-tls \
        -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}' | base64 -d)
    
    # Get service CA
    local ca_cert=$(kubectl --kubeconfig "$kubeconfig" get configmap openshift-service-ca.crt \
        -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}')
    
    # Create the route
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
    termination: reencrypt
    certificate: |
$(echo "$route_cert" | sed 's/^/      /')
    key: |
$(echo "$route_key" | sed 's/^/      /')
    caCertificate: |
$(echo "$ca_cert" | sed 's/^/      /')
    destinationCACertificate: |
$(echo "$spire_ca" | sed 's/^/      /')
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Reencrypt route created successfully"
    else
        echo -e "${RED}✗${NC} Failed to create reencrypt route"
        exit 1
    fi
}

# Main execution
echo "Certificate approach: $CERT_APPROACH"
echo ""

# Create temp directory for certificates
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "═══════════════════════════════════════════════════════════"
echo "  Processing Cluster 1"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Extract SPIRE CA for Cluster 1
extract_spire_ca "$CLUSTER1_KUBECONFIG" "$TEMP_DIR/cluster1-spire-ca.crt"

if [ "$CERT_APPROACH" = "openshift-service-ca" ]; then
    use_openshift_service_ca "$CLUSTER1_KUBECONFIG" "cluster1"
    create_reencrypt_route_with_service_ca "$CLUSTER1_KUBECONFIG" "cluster1" "$TEMP_DIR/cluster1-spire-ca.crt"
else
    # Get route hostname for Cluster 1
    CLUSTER1_ROUTE_HOST=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get route spire-server-federation \
        -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "$CLUSTER1_ROUTE_HOST" ]; then
        echo -e "${YELLOW}⚠${NC} Route doesn't exist yet, creating with passthrough first..."
        kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f cluster1-federation-route.yaml
        sleep 5
        CLUSTER1_ROUTE_HOST=$(kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" get route spire-server-federation \
            -n "$NAMESPACE" -o jsonpath='{.spec.host}')
    fi
    
    echo "Route hostname: $CLUSTER1_ROUTE_HOST"
    
    # Generate self-signed certificate
    generate_self_signed_cert "$CLUSTER1_ROUTE_HOST" \
        "$TEMP_DIR/cluster1-route.crt" \
        "$TEMP_DIR/cluster1-route.key"
    
    # Create reencrypt route
    create_reencrypt_route "$CLUSTER1_KUBECONFIG" "cluster1" \
        "$TEMP_DIR/cluster1-route.crt" \
        "$TEMP_DIR/cluster1-route.key" \
        "$TEMP_DIR/cluster1-spire-ca.crt"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Processing Cluster 2"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Extract SPIRE CA for Cluster 2
extract_spire_ca "$CLUSTER2_KUBECONFIG" "$TEMP_DIR/cluster2-spire-ca.crt"

if [ "$CERT_APPROACH" = "openshift-service-ca" ]; then
    use_openshift_service_ca "$CLUSTER2_KUBECONFIG" "cluster2"
    create_reencrypt_route_with_service_ca "$CLUSTER2_KUBECONFIG" "cluster2" "$TEMP_DIR/cluster2-spire-ca.crt"
else
    # Get route hostname for Cluster 2
    CLUSTER2_ROUTE_HOST=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route spire-server-federation \
        -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "$CLUSTER2_ROUTE_HOST" ]; then
        echo -e "${YELLOW}⚠${NC} Route doesn't exist yet, creating with passthrough first..."
        kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f cluster2-federation-route.yaml
        sleep 5
        CLUSTER2_ROUTE_HOST=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route spire-server-federation \
            -n "$NAMESPACE" -o jsonpath='{.spec.host}')
    fi
    
    echo "Route hostname: $CLUSTER2_ROUTE_HOST"
    
    # Generate self-signed certificate
    generate_self_signed_cert "$CLUSTER2_ROUTE_HOST" \
        "$TEMP_DIR/cluster2-route.crt" \
        "$TEMP_DIR/cluster2-route.key"
    
    # Create reencrypt route
    create_reencrypt_route "$CLUSTER2_KUBECONFIG" "cluster2" \
        "$TEMP_DIR/cluster2-route.crt" \
        "$TEMP_DIR/cluster2-route.key" \
        "$TEMP_DIR/cluster2-spire-ca.crt"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Summary"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}✓${NC} Routes converted to reencrypt termination"
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT NEXT STEPS:${NC}"
echo ""
echo "1. Update SPIRE Federation Configuration:"
echo "   You need to change the bundle endpoint profile from 'https_spiffe' to 'https_web'"
echo "   in both SPIRE server ConfigMaps."
echo ""
echo "   Run this to update the configuration:"
echo "   ./update-spire-for-reencrypt.sh"
echo ""
echo "2. Restart SPIRE servers:"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG rollout restart statefulset spire-server -n $NAMESPACE"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG rollout restart statefulset spire-server -n $NAMESPACE"
echo ""
echo "3. Verify federation:"
echo "   kubectl --kubeconfig $CLUSTER1_KUBECONFIG logs -n $NAMESPACE statefulset/spire-server -c spire-server | grep -i federation"
echo ""
echo "4. Test the routes:"
echo "   curl -v https://$(kubectl --kubeconfig $CLUSTER1_KUBECONFIG get route spire-server-federation -n $NAMESPACE -o jsonpath='{.spec.host}')"
echo "   curl -v https://$(kubectl --kubeconfig $CLUSTER2_KUBECONFIG get route spire-server-federation -n $NAMESPACE -o jsonpath='{.spec.host}')"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""



