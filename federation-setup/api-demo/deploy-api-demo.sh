#!/bin/bash

CLUSTER1_KUBECONFIG="/home/rausingh/Documents/aws_cluster/09OctCluster1/auth/kubeconfig"
CLUSTER2_KUBECONFIG="/home/rausingh/Documents/aws_cluster/09OctCluster2/auth/kubeconfig"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║              DEPLOYING API DEMO - FEDERATED vs NOT             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

echo "📦 Step 1: Creating namespaces..."
kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" create namespace federation-demo --dry-run=client -o yaml | kubectl --kubeconfig "$CLUSTER1_KUBECONFIG" apply -f -
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" create namespace federation-demo --dry-run=client -o yaml | kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f -

echo ""
echo "📦 Step 2: Deploying FEDERATED backend to Cluster 2..."
kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: federated-backend
  namespace: federation-demo
---
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: federated-backend
spec:
  spiffeIDTemplate: "spiffe://apps.cluster-2.devcluster.openshift.com/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: federated-backend
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: federation-demo
  federatesWith:
  - "apps.cluster-1.devcluster.openshift.com"
  className: zero-trust-workload-identity-manager-spire
---
apiVersion: v1
kind: Pod
metadata:
  name: federated-backend
  namespace: federation-demo
  labels:
    app: federated-backend
spec:
  serviceAccountName: federated-backend
  containers:
  - name: api
    image: registry.access.redhat.com/ubi9/python-311:latest
    command: ["/bin/bash", "-c"]
    args:
    - |
      cat > /tmp/app.py << 'PYEOF'
      from http.server import HTTPServer, BaseHTTPRequestHandler
      import json
      import subprocess
      from datetime import datetime
      
      class APIHandler(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path == '/api/data':
                  print(f"[{datetime.now().strftime('%H:%M:%S')}] 📥 API CALL received")
                  
                  response = {
                      'status': 'success',
                      'message': 'FEDERATED Backend API in Cluster 2',
                      'federation_enabled': True,
                      'data': {'stocks': [{'AAPL': 150.25}, {'GOOGL': 2800.50}]},
                      'timestamp': datetime.now().isoformat()
                  }
                  
                  self.send_response(200)
                  self.send_header('Content-Type', 'application/json')
                  self.end_headers()
                  self.wfile.write(json.dumps(response).encode())
                  print(f"[{datetime.now().strftime('%H:%M:%S')}] ✅ Sent response")
              else:
                  self.send_response(404)
                  self.end_headers()
      
      print("=" * 70)
      print("🚀 FEDERATED BACKEND API (Cluster 2) - WITH FEDERATION")
      print("=" * 70)
      print("✅ Federation enabled: apps.cluster-1.devcluster.openshift.com")
      print("📡 API: GET /api/data")
      print("🌐 Listening on port 8080...")
      print("")
      
      server = HTTPServer(('0.0.0.0', 8080), APIHandler)
      server.serve_forever()
      PYEOF
      
      python3 /tmp/app.py
    ports:
    - containerPort: 8080
    volumeMounts:
    - name: spiffe-workload-api
      mountPath: /spiffe-workload-api
      readOnly: true
  volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io
      readOnly: true
---
apiVersion: v1
kind: Service
metadata:
  name: federated-backend
  namespace: federation-demo
spec:
  selector:
    app: federated-backend
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: federated-backend
  namespace: federation-demo
spec:
  to:
    kind: Service
    name: federated-backend
  port:
    targetPort: 8080
  tls:
    termination: edge
EOF

echo ""
echo "✅ Federated backend deployed!"
echo ""

sleep 5
echo "Getting backend route URL..."
BACKEND_URL=$(kubectl --kubeconfig "$CLUSTER2_KUBECONFIG" get route federated-backend -n federation-demo -o jsonpath='https://{.spec.host}')
echo "Backend API URL: $BACKEND_URL/api/data"
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    DEPLOYMENT COMPLETE                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "🧪 TEST COMMANDS:"
echo ""
echo "1. Test backend API with curl:"
echo "   curl $BACKEND_URL/api/data"
echo ""
echo "2. Watch backend logs (see API calls):"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG logs -f federated-backend -n federation-demo"
echo ""
echo "3. Check SPIFFE configuration:"
echo "   kubectl --kubeconfig $CLUSTER2_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- ./spire-server entry show | grep -A 12 federated-backend"
echo ""
EOF

chmod +x /home/rausingh/Documents/oape/ztwim-poc/federation-setup/api-demo/deploy-api-demo.sh
/home/rausingh/Documents/oape/ztwim-poc/federation-setup/api-demo/deploy-api-demo.sh

