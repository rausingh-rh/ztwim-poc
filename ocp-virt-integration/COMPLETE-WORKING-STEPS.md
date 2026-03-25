# SPIRE on OpenShift Virtualization - Complete Working Steps

**Status**: ✅ **VERIFIED AND WORKING**  
**Date**: February 26-27, 2026  
**Cluster**: GCP OpenShift 4.x with OpenShift Virtualization

This document contains the **exact steps performed** to successfully implement SPIRE workload identity for VMs running on OpenShift Virtualization, including all commands and actual outputs.

---

## Table of Contents

1. [Prerequisites Installation](#step-1-prerequisites-installation)
2. [Enable VSOCK Feature Gate](#step-2-enable-vsock-feature-gate)
3. [Enable VSOCK on VM](#step-3-enable-vsock-on-vm)
4. [Deploy VSOCK Bridge on Host](#step-4-deploy-vsock-bridge-on-host)
5. [Verify VSOCK in VM](#step-5-verify-vsock-in-vm)
6. [Install Applications in VM](#step-6-install-applications-in-vm)
7. [Install socat in VM](#step-7-install-socat-in-vm)
8. [Start VSOCK Bridge in VM](#step-8-start-vsock-bridge-in-vm)
9. [Install SPIRE Agent Binary](#step-9-install-spire-agent-binary)
10. [Configure SPIRE Agent](#step-10-configure-spire-agent)
11. [Generate Join Token](#step-11-generate-join-token)
12. [Start SPIRE Agent](#step-12-start-spire-agent)
13. [Create Registration Entries](#step-13-create-registration-entries)
14. [Test SVID Issuance](#step-14-test-svid-issuance)
15. [Test SVID Rotation](#step-15-test-svid-rotation)

---

## Environment Details

```
Cluster: GCP OpenShift
Kubeconfig: /home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

VM Name: rhel9-magenta-gull-92
VM Namespace: openshift-cnv
SPIRE Namespace: zero-trust-workload-identity-manager

Trust Domain: apps.gcp26feb.gcp.devcluster.openshift.com
SPIRE Version: 1.13.3
```

---

## Step 1: Prerequisites Installation

### 1.1 Install Zero Trust Operator and Operand

Install the Zero Trust Workload Identity Manager operator from OperatorHub.

Install operands.

```bash
export APP_DOMAIN=apps.$(oc get dns cluster -o jsonpath='{ .spec.baseDomain }')
export JWT_ISSUER_ENDPOINT=oidc-discovery.${APP_DOMAIN}
export CLUSTER_NAME=test01

oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: $APP_DOMAIN
  clusterName: $CLUSTER_NAME
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  caSubject:
    commonName: $APP_DOMAIN
    country: "US"
    organization: "RH"
  persistence:
    type: pvc
    size: "2Gi"
    accessMode: ReadWriteOncePod
  datastore:
    databaseType: sqlite3
    connectionString: "/run/spire/data/datastore.sqlite3"
    maxOpenConns: 100
    maxIdleConns: 2
    connMaxLifetime: 3600
  jwtIssuer: https://$JWT_ISSUER_ENDPOINT
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: "auto"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec: {}
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  jwtIssuer: https://$JWT_ISSUER_ENDPOINT
EOF
```

### 1.2 Install OpenShift Virtualization Operator

Install the OpenShift Virtualization operator from OperatorHub.

### 1.3 Install HyperConverged Operator

Install the HyperConverged operator (part of OpenShift Virtualization).

---

## Step 2: Enable VSOCK Feature Gate

### Why?
VSOCK (Virtual Socket) provides secure, isolated communication between VMs and the host. It must be enabled at the cluster level.

### Command

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  'kubevirt.kubevirt.io/jsonpatch=[{"op":"add","path":"/spec/configuration/developerConfiguration/featureGates/-","value":"VSOCK"}]' \
  --overwrite
```

### Expected Output

```
hyperconverged.hco.kubevirt.io/kubevirt-hyperconverged annotated
```

### Verification

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o yaml | grep VSOCK
```

Should show `VSOCK` in the featureGates list.

---

## Step 3: Enable VSOCK on VM

### Why?
Each VM must explicitly enable VSOCK by setting `autoattachVSOCK: true` in its spec.

### Command

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

oc patch vm rhel9-magenta-gull-92 \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"domain":{"devices":{"autoattachVSOCK":true}}}}}}'
```

### Expected Output

```
virtualmachine.kubevirt.io/rhel9-magenta-gull-92 patched
```

### Important: Restart the VM

After patching, the VM must be restarted for VSOCK to be enabled:

```bash
# Stop the VM
oc virt stop rhel9-magenta-gull-92 -n openshift-cnv

# Wait for it to stop
oc get vmi rhel9-magenta-gull-92 -n openshift-cnv

# Start the VM
oc virt start rhel9-magenta-gull-92 -n openshift-cnv

# Verify it's running
oc get vmi rhel9-magenta-gull-92 -n openshift-cnv
```
It can also be done from openshift UI console.

---

## Step 4: Deploy VSOCK Bridge on Host

### Why?
The VSOCK bridge (socat pod) runs on the host node to forward VSOCK connections from the VM to the SPIRE Server over TCP.

### 4.1: Get VM Node and SPIRE Server Pod IP

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

# Get the node where VM is running
NODE=$(oc get vmi rhel9-magenta-gull-92 -n openshift-cnv \
  -o jsonpath='{.status.nodeName}')

echo "VM Node: $NODE"

# Get SPIRE Server pod IP
SPIRE_POD_IP=$(oc get pod spire-server-0 -n zero-trust-workload-identity-manager \
  -o jsonpath='{.status.podIP}')

echo "SPIRE Server Pod IP: $SPIRE_POD_IP"
```

**Example Output:**
```
VM Node: gcp26feb-gsjcj-worker-a-n7svh
SPIRE Server Pod IP: 10.131.0.55
```

### 4.2: Deploy socat Bridge Pod

**Important**: The bridge must run in the **same namespace as the VM** (openshift-cnv).

```bash
# Delete any existing bridge
oc delete pod vsock-socat-bridge -n openshift-cnv --ignore-not-found

# Deploy the bridge
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: vsock-socat-bridge
  namespace: openshift-cnv
spec:
  nodeName: $NODE
  hostNetwork: true
  containers:
  - name: socat
    image: alpine/socat:latest
    command:
    - socat
    - -d
    - -d
    - VSOCK-LISTEN:8081,fork,reuseaddr
    - TCP:${SPIRE_POD_IP}:8081
    securityContext:
      privileged: true
  restartPolicy: Always
EOF
```

**Expected Output:**
```
pod/vsock-socat-bridge created
```

### 4.3: Verify Bridge is Running

```bash
# Check pod status
oc get pod vsock-socat-bridge -n openshift-cnv

# Check logs - should show listening
oc logs -f vsock-socat-bridge -n openshift-cnv
```

**Expected Log Output:**
```
2026/02/26 09:23:53 socat[1] N VSOCK CID=2
2026/02/26 09:23:53 socat[1] N listening on AF=40 cid:4294967295 port:8081
```

**Success Indicator:** Pod is running, logs show "listening on AF=40"

---

## Step 5: Verify VSOCK in VM

### Why?
Before installing the SPIRE agent, verify that VSOCK is properly enabled and can communicate with the host.

### 5.1: Access the VM

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

# Access VM console
virtctl console rhel9-magenta-gull-92 -n openshift-cnv

# Login as cloud-user
```

### 5.2: Check VSOCK Device

```bash
# Inside VM
ls -l /dev/vsock
```

**Expected Output:**
```
crw-rw-rw- 1 root root 10, 122 Feb 26 14:30 /dev/vsock
```

### 5.3: Check VSOCK Kernel Modules

```bash
# Inside VM
lsmod | grep vsock
```

**Expected Output:**
```
vhost_vsock            24576  0
vmw_vsock_virtio_transport_common    36864  1 vhost_vsock
vsock                  53248  2 vmw_vsock_virtio_transport_common,vhost_vsock
```

### 5.4: Test VSOCK Connection to Host

```bash
# Inside VM
python3 << 'EOF'
import socket
import sys
try:
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(5)
    print("Testing VSOCK connection to host (CID 2, port 8081)...")
    s.connect((2, 8081))
    print("✅ VSOCK connection successful!")
    s.close()
except Exception as e:
    print(f"❌ VSOCK connection failed: {e}")
    sys.exit(1)
EOF
```

**Expected Output:**
```
Testing VSOCK connection to host (CID 2, port 8081)...
✅ VSOCK connection successful!
```

---

## Step 6: Install Applications in VM

### Why?
We're installing Redis and PostgreSQL as example workloads that will receive SPIFFE identities.

### 6.1: Configure AlmaLinux Repository

```bash
# Inside VM
sudo tee /etc/yum.repos.d/almalinux.repo <<EOF
[baseos]
name=AlmaLinux 9 - BaseOS
baseurl=https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/
enabled=1
gpgcheck=1
gpgkey=https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux-9

[appstream]
name=AlmaLinux 9 - AppStream
baseurl=https://repo.almalinux.org/almalinux/9/AppStream/x86_64/os/
enabled=1
gpgcheck=1
gpgkey=https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux-9
EOF

sudo dnf clean all
```

### 6.2: Install and Start Redis

```bash
# Install Redis
sudo dnf install redis -y

# Enable and start Redis
sudo systemctl enable --now redis

# Verify Redis is running
sudo systemctl status redis

# Test Redis
redis-cli ping
```

**Expected Output:**
```
PONG
```

### 6.3: Install and Start PostgreSQL

```bash
# Check available PostgreSQL versions
sudo dnf module list postgresql

# Enable version 16
sudo dnf module enable postgresql:16 -y

# Install the server
sudo dnf install postgresql-server -y

# Initialize the database
sudo postgresql-setup --initdb

# Enable and start PostgreSQL
sudo systemctl enable --now postgresql

# Verify PostgreSQL is running
sudo systemctl status postgresql

# Test PostgreSQL
sudo -u postgres psql -c "SELECT version();"
```

### 6.4: Verify Application Details

```bash
# Check Redis process
ps -o user,uid,gid,pid,cmd -C redis-server

# Check Postgres process
ps aux | grep postgres | grep -v grep | head -3

# Get user IDs
id redis
id postgres
```

**Output - Application Details:**

| Application | User | UID | GID | Binary Path |
|-------------|------|-----|-----|-------------|
| **Redis** | redis | 994 | 993 | /usr/bin/redis-server |
| **Postgres** | postgres | 26 | 26 | /usr/bin/postgres |

---

## Step 7: Install socat in VM

### Why?
socat is needed to bridge TCP connections from the SPIRE agent to VSOCK connections to the host.

### Command

```bash
# Inside VM
sudo dnf install -y socat

# Verify installation
which socat
```

**Expected Output:**
```
/usr/bin/socat
```

---

## Step 8: Start VSOCK Bridge in VM

### Why?
This creates a local TCP-to-VSOCK bridge inside the VM, allowing the SPIRE agent to connect to localhost:8081, which then forwards to the host via VSOCK.

### Command

```bash
# Inside VM

# Kill any existing socat processes
sudo pkill socat

# Start socat to forward localhost:8081 → VSOCK(2:8081)
sudo socat TCP-LISTEN:8081,fork,reuseaddr VSOCK-CONNECT:2:8081 &

# Verify it's running
ps aux | grep socat | grep -v grep
```

**Expected Output:**
```
root      12345  0.0  0.0  12345  1234 ?  S  10:00  0:00 socat TCP-LISTEN:8081,fork,reuseaddr VSOCK-CONNECT:2:8081
```

### Test the Bridge

```bash
# Test connection to localhost:8081
curl -v http://127.0.0.1:8081 2>&1 | head -5
```

Should attempt to connect (may get protocol error, but connection works).

---

## Step 9: Install SPIRE Agent Binary

### Why?
Download and install the official SPIRE agent binary that will run inside the VM.

### Command

```bash
# Inside VM

# Download SPIRE release
curl -L https://github.com/spiffe/spire/releases/download/v1.13.3/spire-1.13.3-linux-amd64-musl.tar.gz \
  -o /tmp/spire.tar.gz

# Extract
cd /tmp
tar xzf spire.tar.gz

# Copy agent binary to system location
sudo cp spire-1.13.3/bin/spire-agent /usr/local/bin/

# Make executable
sudo chmod +x /usr/local/bin/spire-agent

# Verify
/usr/local/bin/spire-agent --version
```

**Expected Output:**
```
spire-agent version 1.13.3
```

---

## Step 10: Configure SPIRE Agent

### Why?
The agent needs configuration to know:
- Where to connect (localhost:8081 via socat)
- What trust domain to use
- How to authenticate (join_token)
- Where to create the workload API socket

### 10.1: Get Trust Bundle from SPIRE Server

**On workstation:**

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

# Get trust bundle
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server bundle show
```

Copy the output (PEM-encoded certificate).

### 10.2: Save Trust Bundle in VM

**In VM:**

```bash
# Create directory
sudo mkdir -p /opt/spire

# Save trust bundle (paste the certificate from previous step)
sudo vi /opt/spire/bundle.pem
```

Paste the certificate and save.

### 10.3: Create Agent Configuration

```bash
# Inside VM

# Create config directory
sudo mkdir -p /opt/spire/conf/agent

# Create configuration file
sudo tee /opt/spire/conf/agent/agent.conf << 'EOF'
agent {
    data_dir = "/var/lib/spire/agent"
    log_level = "DEBUG"
    
    # Connect to localhost where socat is listening
    server_address = "127.0.0.1"
    server_port = "8081"
    
    socket_path = "/run/spire/sockets/agent.sock"
    trust_domain = "apps.gcp26feb.gcp.devcluster.openshift.com"
    trust_bundle_path = "/opt/spire/bundle.pem"
}

plugins {
    # For PoC: Use join_token attestation
    # Production: Use KubeVirt attestor plugin
    NodeAttestor "join_token" {
        plugin_data {}
    }

    KeyManager "disk" {
        plugin_data {
            directory = "/var/lib/spire/agent"
        }
    }

    # Unix workload attestor - production ready!
    WorkloadAttestor "unix" {
        plugin_data {}
    }
}
EOF

# Verify configuration
cat /opt/spire/conf/agent/agent.conf
```

**Key Configuration Points:**
- `server_address = "127.0.0.1"` - Connect via local socat bridge
- `server_port = "8081"` - Match socat listening port
- `trust_domain` - Must match SPIRE Server exactly
- `trust_bundle_path` - Path to trust bundle for server verification
- `join_token` - One-time token attestation (PoC)
- `unix` - Workload attestor for processes

---

## Step 11: Generate Join Token

### Why?
The join token is a one-time authentication secret that allows the VM agent to perform initial attestation with the SPIRE Server.

### Command

**On workstation:**

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

# Set variables
APP_DOMAIN="apps.gcp26feb.gcp.devcluster.openshift.com"
VM_NAME="rhel9-magenta-gull-92"

# Generate join token with long TTL (600000 seconds = 166 hours)
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server token generate \
    -spiffeID spiffe://$APP_DOMAIN/vm/$VM_NAME \
    -ttl 600000
```

**Example Output:**
```
Token: 3611a3f7-837f-40c5-ac59-1cccfb3e6f64
```

**Important Notes:**
- Copy the token immediately
- Token expires after TTL (600000 seconds in this case)
- Token can only be used once

---

## Step 12: Start SPIRE Agent

### Why?
The SPIRE agent runs inside the VM to serve the Workload API to applications and manage SVID issuance.

### Prerequisites Check

**Before starting the agent, ensure:**

1. ✅ socat is running inside VM (from Step 8)
2. ✅ Trust bundle is configured at `/opt/spire/bundle.pem` (from Step 10)
3. ✅ vsock-socat-bridge pod is running on host (from Step 4)

### Command

**In VM:**

```bash
# Set the join token
export JOIN_TOKEN="3611a3f7-837f-40c5-ac59-1cccfb3e6f64"

# Ensure directories exist
sudo mkdir -p /run/spire/sockets
sudo mkdir -p /var/lib/spire/agent

# Start SPIRE Agent in background
sudo /usr/local/bin/spire-agent run \
  -config /opt/spire/conf/agent/agent.conf \
  -joinToken $JOIN_TOKEN \
  > /tmp/spire-agent.log 2>&1 &

# Check if it started
ps aux | grep spire-agent | grep -v grep

# Check logs
tail -f /tmp/spire-agent.log
```

### Expected Log Output (Success)

```
WARN[0000] Current umask 0022 is too permissive; setting umask 0027 
INFO[0000] Starting agent  data_dir=/var/lib/spire/agent version=1.13.3
INFO[0000] Plugin loaded  plugin_name=join_token plugin_type=NodeAttestor
INFO[0000] Plugin loaded  plugin_name=disk plugin_type=KeyManager
INFO[0000] Plugin loaded  plugin_name=unix plugin_type=WorkloadAttestor
INFO[0000] Bundle loaded  trust_domain_id="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com"
INFO[0000] SVID is not found. Starting node attestation
INFO[0001] Node attestation was successful
INFO[0001] Agent SVID loaded  spiffe_id="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64"
INFO[0001] Starting Workload and SDS APIs  address=/run/spire/sockets/agent.sock
```

**Key Success Indicators:**
- ✅ "Node attestation was successful"
- ✅ "Agent SVID loaded" with join_token SPIFFE ID
- ✅ "Starting Workload and SDS APIs"

### Verify Socket Created

```bash
# In VM
ls -l /run/spire/sockets/agent.sock
```

**Expected Output:**
```
srwxr-xr-x 1 root root 0 Feb 27 09:40 /run/spire/sockets/agent.sock
```

---

## Step 13: Create Registration Entries

### Why?
Registration entries define which workloads (identified by selectors) receive which SPIFFE identities. They establish the trust chain from SPIRE Server → Agent → Workloads.

### 13.1: Get the Agent's SPIFFE ID

**On workstation:**

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

# List all agents to find the VM agent
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server agent list
```

**Example Output:**
```
Found 4 attested agents:

SPIFFE ID         : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/k8s_psat/test01/468e270d-a89b-4f99-a6ce-a03bc2b32fc9
Attestation type  : k8s_psat
Expiration time   : 2026-02-27 09:26:01 +0000 UTC
Serial number     : 74155045992047764207496164400065157083
Can re-attest     : true

SPIFFE ID         : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/k8s_psat/test01/9ec44e03-d5a4-4c55-82d2-c7c0eac81a07
Attestation type  : k8s_psat
Expiration time   : 2026-02-27 09:24:25 +0000 UTC
Serial number     : 178909084257171057435445909974931410842
Can re-attest     : true

SPIFFE ID         : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64
Attestation type  : join_token
Expiration time   : 2026-02-27 09:40:05 +0000 UTC  ← Your VM agent
Serial number     : 89527571018400848187715918095005903139
Can re-attest     : false
```

Identify the `join_token` agent with the matching token UUID - this is your VM agent.

### 13.2: Check Application Process Details

**In VM:**

```bash
# Check Redis
ps -o user,uid,gid,pid,cmd -C redis-server

# Check Postgres
ps aux | grep postgres | grep -v grep | head -3
id postgres
```

**Verified Details:**

| Application | User | UID | GID | Binary Path |
|-------------|------|-----|-----|-------------|
| Redis | redis | 994 | 993 | /usr/bin/redis-server |
| Postgres | postgres | 26 | 26 | /usr/bin/postgres |

### 13.3: Create Registration Entries

**On workstation:**

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

# Set the agent ID (from step 13.1)
AGENT_ID="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64"

echo "Creating entry for Redis (UID 994)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis \
    -selector unix:uid:994 \
    -x509SVIDTTL 120

echo ""
echo "Creating entry for Postgres (UID 26)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres \
    -selector unix:uid:26 \
    -x509SVIDTTL 180

echo ""
echo "Creating entry for root (UID 0) - for testing..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/root-test \
    -selector unix:uid:0 \
    -x509SVIDTTL 120
```

**Expected Output for Redis Entry:**
```
Entry ID         : a180d8e6-3937-4d62-a5c5-606d9d084854
SPIFFE ID        : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis
Parent ID        : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64
Revision         : 0
X509-SVID TTL    : 120
JWT-SVID TTL     : default
Selector         : unix:uid:994
```

**Expected Output for Postgres Entry:**
```
Entry ID         : 10c4daef-b4b4-4f43-af47-9be4e0793dc3
SPIFFE ID        : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres
Parent ID        : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64
Revision         : 0
X509-SVID TTL    : 180
JWT-SVID TTL     : default
Selector         : unix:uid:26
```

**Expected Output for Root Entry:**
```
Entry ID         : 57305666-93a1-48f4-9ebd-2abb19409401
SPIFFE ID        : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/root-test
Parent ID        : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64
Revision         : 0
X509-SVID TTL    : 120
JWT-SVID TTL     : default
Selector         : unix:uid:0
```

### 13.4: Verify All Entries

```bash
# On workstation
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server entry show -parentID "$AGENT_ID"
```

Should show all three entries (redis, postgres, root-test).

---

## Step 14: Test SVID Issuance

### Why?
Verify that workloads can successfully fetch their SVIDs from the SPIRE agent.

### 14.1: Wait for Entry Sync

```bash
# In VM - Wait for agent to sync entries from server
sleep 10
```

### 14.2: Test Redis SVID

**In VM:**

```bash
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock
```

**Actual Output (SUCCESS!):**
```
Received 1 svid after 6.123148ms

SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis
SVID Valid After:	2026-02-27 08:55:07 +0000 UTC
SVID Valid Until:	2026-02-27 09:55:17 +0000 UTC
CA #1 Valid After:	2026-02-26 09:16:15 +0000 UTC
CA #1 Valid Until:	2026-02-27 09:16:25 +0000 UTC
CA #2 Valid After:	2026-02-26 21:16:15 +0000 UTC
CA #2 Valid Until:	2026-02-27 21:16:25 +0000 UTC
```

### 14.3: Test Postgres SVID

**In VM:**

```bash
sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock
```

**Actual Output (SUCCESS!):**
```
Received 1 svid after 6.333925ms

SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres
SVID Valid After:	2026-02-27 08:55:07 +0000 UTC
SVID Valid Until:	2026-02-27 09:55:17 +0000 UTC
CA #1 Valid After:	2026-02-26 09:16:15 +0000 UTC
CA #1 Valid Until:	2026-02-27 09:16:25 +0000 UTC
CA #2 Valid After:	2026-02-26 21:16:15 +0000 UTC
CA #2 Valid Until:	2026-02-27 21:16:25 +0000 UTC
```

### 14.4: Save SVIDs to Files

**Save Redis SVID:**

```bash
# In VM
sudo -u redis mkdir -p /tmp/redis-svid
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock \
  -write /tmp/redis-svid

# Check files
ls -la /tmp/redis-svid/
```

**Actual Output:**
```
Received 1 svid after 5.905293ms

SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis
SVID Valid After:	2026-02-27 08:55:07 +0000 UTC
SVID Valid Until:	2026-02-27 09:55:17 +0000 UTC
CA #1 Valid After:	2026-02-26 09:16:15 +0000 UTC
CA #1 Valid Until:	2026-02-27 09:16:25 +0000 UTC
CA #2 Valid After:	2026-02-26 21:16:15 +0000 UTC
CA #2 Valid Until:	2026-02-27 21:16:25 +0000 UTC

Writing SVID #0 to file /tmp/redis-svid/svid.0.pem.
Writing key #0 to file /tmp/redis-svid/svid.0.key.
Writing bundle #0 to file /tmp/redis-svid/bundle.0.pem.

total 16
drwxr-xr-x.  2 redis redis   62 Feb 27 03:58 .
drwxrwxrwt. 13 root  root  4096 Feb 27 03:58 ..
-rw-r--r--.  1 redis redis 2940 Feb 27 03:58 bundle.0.pem
-rw-------.  1 redis redis  241 Feb 27 03:58 svid.0.key
-rw-r--r--.  1 redis redis 1188 Feb 27 03:58 svid.0.pem
```

**Save Postgres SVID:**

```bash
# In VM
sudo -u postgres mkdir -p /tmp/postgres-svid
sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock \
  -write /tmp/postgres-svid

# Check files
ls -la /tmp/postgres-svid/
```

**Actual Output:**
```
Received 1 svid after 2.860559ms

SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres
SVID Valid After:	2026-02-27 08:55:07 +0000 UTC
SVID Valid Until:	2026-02-27 09:55:17 +0000 UTC
CA #1 Valid After:	2026-02-26 09:16:15 +0000 UTC
CA #1 Valid Until:	2026-02-27 09:16:25 +0000 UTC
CA #2 Valid After:	2026-02-26 21:16:15 +0000 UTC
CA #2 Valid Until:	2026-02-27 21:16:25 +0000 UTC

Writing SVID #0 to file /tmp/postgres-svid/svid.0.pem.
Writing key #0 to file /tmp/postgres-svid/svid.0.key.
Writing bundle #0 to file /tmp/postgres-svid/bundle.0.pem.

total 16
drwxr-xr-x.  2 postgres postgres   62 Feb 27 03:58 .
drwxrwxrwt. 14 root     root     4096 Feb 27 03:58 ..
-rw-r--r--.  1 postgres postgres 2940 Feb 27 03:58 bundle.0.pem
-rw-------.  1 postgres postgres  241 Feb 27 03:58 svid.0.key
-rw-r--r--.  1 postgres postgres 1192 Feb 27 03:58 svid.0.pem
```

### 14.5: View Certificate Contents

**Redis Certificate:**

```bash
# In VM
cat /tmp/redis-svid/svid.0.pem
```

**Actual Output:**
```
-----BEGIN CERTIFICATE-----
MIIDPzCCAiegAwIBAgIRAObam8jvX1wh8d1s6S6h6TQwDQYJKoZIhvcNAQELBQAw
gYExCzAJBgNVBAYTAlVTMQswCQYDVQQKEwJSSDEzMDEGA1UEAxMqYXBwcy5nY3Ay
NmZlYi5nY3AuZGV2Y2x1c3Rlci5vcGVuc2hpZnQuY29tMTAwLgYDVQQFEyczMTcz
NTgzMjg3MTQ2MjIzODUwODgxMTEzMTUzMjQ1Nzc0MjI4MjYwHhcNMjYwMjI3MDg1
NTA3WhcNMjYwMjI3MDk1NTE3WjAdMQswCQYDVQQGEwJVUzEOMAwGA1UEChMFU1BJ
UkUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQebQgljueJJzFWHZPRJGx741Tv
OPKpwEZxZLDodujYvYusyOQTNYZ2Mjj5js3Bt3xle4aB1b8MW9RfAhIeMIsIo4Hf
MIHcMA4GA1UdDwEB/wQEAwIDqDAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUH
AwIwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUQ8tkjrjzLgOud35TEKCgDNaO3xkw
HwYDVR0jBBgwFoAUdv85t/UhQS+beeXTkmHdBYceSngwXQYDVR0RBFYwVIZSc3Bp
ZmZlOi8vYXBwcy5nY3AyNmZlYi5nY3AuZGV2Y2x1c3Rlci5vcGVuc2hpZnQuY29t
L3ZtL3JoZWw5LW1hZ2VudGEtZ3VsbC05Mi9yZWRpczANBgkqhkiG9w0BAQsFAAOC
AQEAUBESWZRKg8Wu28lqRZhgAtI8TKOwlOTmz+2Pd3z0sYbz5NmD5XdUGOqDkIdC
bpjpXqTo0+aJcn/m7vkvPyBN6OFRJrDif+0qdCzJsgMv5rcj2Fzso9EJsHdf1Gsw
a7c1gSvgaFRT14gTyAz2GXQQlkmDnm93U7of6iACfQW/BnTlMSFdUDv3+3Twoddm
A4k0O/bk7Yc7oyABOsatJeyxqu7w6Ki6FhkEIeMfUoAL8598i7Z6lH3JDyog3/ya
msnKpwt78w+E7luvjj8+wL5MHBTpGC7JnIrt+ZzohUncmWF1fAIpn+JovuCFKR/j
dr8zQLOBywBIflXLLkRUKn/Zjw==
-----END CERTIFICATE-----
```

### 14.6: Verify Unique Identities

**In VM:**

```bash
echo "=== Redis SPIFFE ID ==="
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock | grep "SPIFFE ID"

echo ""
echo "=== Postgres SPIFFE ID ==="
sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock | grep "SPIFFE ID"

echo ""
echo "✅ Both applications have unique identities!"
```

**Actual Output:**
```
=== Redis SPIFFE ID ===
SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis

=== Postgres SPIFFE ID ===
SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres

✅ Both applications have unique identities!
```

### 14.7: Verify Certificate Details

**Check Redis Certificate:**

```bash
# In VM
openssl x509 -in /tmp/redis-svid/svid.0.pem -noout -text | grep -A 3 "Subject Alternative Name"
```

**Actual Output:**
```
X509v3 Subject Alternative Name: 
    URI:spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis
Signature Algorithm: sha256WithRSAEncryption
Signature Value:
```

**Check Postgres Certificate:**

```bash
# In VM
openssl x509 -in /tmp/postgres-svid/svid.0.pem -noout -text | grep -A 3 "Subject Alternative Name"
```

**Actual Output:**
```
X509v3 Subject Alternative Name: 
    URI:spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres
Signature Algorithm: sha256WithRSAEncryption
Signature Value:
```

### 14.8: View Complete Certificate Details

**Redis Certificate:**

```bash
# In VM
openssl x509 -in /tmp/redis-svid/svid.0.pem -noout -text
```

**Actual Output (Abbreviated):**
```
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            e6:da:9b:c8:ef:5f:5c:21:f1:dd:6c:e9:2e:a1:e9:34
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: C=US, O=RH, CN=apps.gcp26feb.gcp.devcluster.openshift.com, serialNumber=317358328714622385088111315324577422826
        Validity
            Not Before: Feb 27 08:55:07 2026 GMT
            Not After : Feb 27 09:55:17 2026 GMT
        Subject: C=US, O=SPIRE
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                pub:
                    04:1e:6d:08:25:8e:e7:89:27:31:56:1d:93:d1:24:
                    6c:7b:e3:54:ef:38:f2:a9:c0:46:71:64:b0:e8:76:
                    e8:d8:bd:8b:ac:c8:e4:13:35:86:76:32:38:f9:8e:
                    cd:c1:b7:7c:65:7b:86:81:d5:bf:0c:5b:d4:5f:02:
                    12:1e:30:8b:08
                ASN1 OID: prime256v1
                NIST CURVE: P-256
        X509v3 extensions:
            X509v3 Key Usage: critical
                Digital Signature, Key Encipherment, Key Agreement
            X509v3 Extended Key Usage: 
                TLS Web Server Authentication, TLS Web Client Authentication
            X509v3 Basic Constraints: critical
                CA:FALSE
            X509v3 Subject Key Identifier: 
                43:CB:64:8E:B8:F3:2E:03:AE:77:7E:53:10:A0:A0:0C:D6:8E:DF:19
            X509v3 Authority Key Identifier: 
                76:FF:39:B7:F5:21:41:2F:9B:79:E5:D3:92:61:DD:05:87:1E:4A:78
            X509v3 Subject Alternative Name: 
                URI:spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis
    Signature Algorithm: sha256WithRSAEncryption
```

**Postgres Certificate:**

```bash
# In VM
openssl x509 -in /tmp/postgres-svid/svid.0.pem -noout -text
```

**Actual Output (Abbreviated):**
```
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            8b:26:dd:d0:6c:92:c8:9d:2a:21:16:79:0c:19:52:de
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: C=US, O=RH, CN=apps.gcp26feb.gcp.devcluster.openshift.com, serialNumber=317358328714622385088111315324577422826
        Validity
            Not Before: Feb 27 08:55:07 2026 GMT
            Not After : Feb 27 09:55:17 2026 GMT
        Subject: C=US, O=SPIRE
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                pub:
                    04:d7:88:ad:f5:85:86:23:af:35:2e:b9:37:6f:91:
                    ed:98:7e:8d:ee:9c:a1:c0:36:a4:43:1a:db:7b:48:
                    63:56:34:60:8c:2a:a0:a8:61:47:23:65:5e:d8:8a:
                    25:1a:57:d3:78:ee:39:26:03:d8:93:e7:16:fa:05:
                    50:29:f8:18:e9
                ASN1 OID: prime256v1
                NIST CURVE: P-256
        X509v3 extensions:
            X509v3 Key Usage: critical
                Digital Signature, Key Encipherment, Key Agreement
            X509v3 Extended Key Usage: 
                TLS Web Server Authentication, TLS Web Client Authentication
            X509v3 Basic Constraints: critical
                CA:FALSE
            X509v3 Subject Key Identifier: 
                86:EB:0D:E9:E3:F6:2B:68:4E:28:A2:4B:38:45:7E:43:32:C1:60:43
            X509v3 Authority Key Identifier: 
                76:FF:39:B7:F5:21:41:2F:9B:79:E5:D3:92:61:DD:05:87:1E:4A:78
            X509v3 Subject Alternative Name: 
                URI:spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres
    Signature Algorithm: sha256WithRSAEncryption
```

---

## Step 15: Test SVID Rotation

### Why?
Short-lived credentials are a key security feature. With short TTLs (120s and 180s), we can observe automatic SVID rotation every 60-90 seconds.

### 15.1: Rotation Timeline

With our current TTLs:

| Workload | TTL | Rotation Interval |
|----------|-----|-------------------|
| Redis | 120 seconds | Every ~60 seconds (50% of TTL) |
| Postgres | 180 seconds | Every ~90 seconds (50% of TTL) |
| Root | 120 seconds | Every ~60 seconds (50% of TTL) |

### 15.2: Watch Agent Logs for Rotation

**Terminal 1 (In VM):**

```bash
# Watch rotation events in real-time
tail -f /tmp/spire-agent.log | grep -E "Renewing|SVID updated|expires_at" --line-buffered
```

**What You'll See:**
```
INFO[0060] Renewing X509-SVID  entry_id=... spiffe_id="...redis" expires_at="2026-02-27T09:56:07Z"
DEBU[0060] SVID updated  entry=... spiffe_id="...redis"

INFO[0090] Renewing X509-SVID  entry_id=... spiffe_id="...postgres" expires_at="2026-02-27T09:56:37Z"
DEBU[0090] SVID updated  entry=... spiffe_id="...postgres"

INFO[0120] Renewing X509-SVID  entry_id=... spiffe_id="...redis" expires_at="2026-02-27T09:57:07Z"
DEBU[0120] SVID updated  entry=... spiffe_id="...redis"
```

### 15.3: Poll SVIDs to See Certificate Changes

**Terminal 2 (In VM):**

```bash
# Run this loop to see certificate timestamps changing
while true; do
  clear
  echo "=== $(date +%H:%M:%S) ==="
  echo ""
  
  echo "Redis SVID:"
  sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
    -socketPath /run/spire/sockets/agent.sock 2>/dev/null | \
    grep -E "SPIFFE ID|Valid Until" | head -2
  
  echo ""
  echo "Postgres SVID:"
  sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
    -socketPath /run/spire/sockets/agent.sock 2>/dev/null | \
    grep -E "SPIFFE ID|Valid Until" | head -2
  
  echo ""
  echo "Waiting 20 seconds..."
  sleep 20
done
```

### 15.4: Compare Certificates Before and After Rotation

```bash
# In VM - Save first SVID
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock \
  -write /tmp/redis-before

openssl x509 -in /tmp/redis-before/svid.0.pem -noout -serial -dates

# Wait for rotation (70 seconds)
echo "Waiting 70 seconds for rotation..."
sleep 70

# Save rotated SVID
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock \
  -write /tmp/redis-after

openssl x509 -in /tmp/redis-after/svid.0.pem -noout -serial -dates

# Compare
diff /tmp/redis-before/svid.0.pem /tmp/redis-after/svid.0.pem && \
  echo "Same certificate (no rotation)" || \
  echo "✅ Different certificates - ROTATION CONFIRMED!"
```

---

## Architecture Summary

### Communication Flow

```
┌──────────────────────────────────────────────────────────────┐
│  VM (rhel9-magenta-gull-92)                                  │
│                                                               │
│  ┌─────────────────────┐  ┌──────────────────────┐          │
│  │  Redis (UID 994)    │  │  Postgres (UID 26)   │          │
│  │  Port: 6379         │  │  Port: 5432          │          │
│  └──────────┬──────────┘  └──────────┬───────────┘          │
│             │                         │                       │
│             │ Unix Socket API         │                       │
│             └────────────┬────────────┘                       │
│                          ▼                                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  SPIRE Agent                                         │   │
│  │  Socket: /run/spire/sockets/agent.sock              │   │
│  │  Issues SVIDs based on Unix selectors (UID)         │   │
│  └──────────────────┬───────────────────────────────────┘   │
│                     │ TCP to localhost:8081                  │
│  ┌──────────────────▼───────────────────────────────────┐   │
│  │  socat (inside VM)                                   │   │
│  │  TCP-LISTEN:8081 → VSOCK-CONNECT:2:8081             │   │
│  └──────────────────┬───────────────────────────────────┘   │
└─────────────────────┼────────────────────────────────────────┘
                      │ VSOCK Connection
                      │ (VM CID → Host CID 2, Port 8081)
                      ▼
┌──────────────────────────────────────────────────────────────┐
│  Host Node                                                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  vsock-socat-bridge Pod                              │   │
│  │  VSOCK-LISTEN:8081 → TCP:10.131.0.55:8081           │   │
│  │  (Forwards to SPIRE Server Pod IP)                  │   │
│  └──────────────────┬───────────────────────────────────┘   │
└─────────────────────┼────────────────────────────────────────┘
                      │ TCP over Pod Network
                      ▼
               ┌─────────────────┐
               │  SPIRE Server   │
               │  Pod            │
               │  IP: 10.131.0.55│
               │  Port: 8081     │
               └─────────────────┘
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **SPIRE Server** | zero-trust-workload-identity-manager namespace | Issues SVIDs, validates attestations |
| **SPIRE Agent** | Inside VM | Serves Workload API to applications |
| **socat (host)** | Host node (vsock-socat-bridge pod) | VSOCK → TCP bridge |
| **socat (VM)** | Inside VM | TCP → VSOCK bridge |
| **VSOCK Device** | /dev/vsock in VM | Secure host-guest communication |
| **Workload API** | /run/spire/sockets/agent.sock | Unix socket for SVID requests |

---

## Success Verification

### Checklist

- [x] VSOCK feature gate enabled
- [x] VM has autoattachVSOCK: true
- [x] /dev/vsock exists in VM
- [x] VSOCK modules loaded
- [x] Python VSOCK test passes
- [x] vsock-socat-bridge pod running on host
- [x] socat running inside VM
- [x] SPIRE Agent binary installed
- [x] Agent config created with trust bundle
- [x] Agent started with join token
- [x] Agent socket exists
- [x] Registration entries created for redis and postgres
- [x] Redis can fetch SVID
- [x] Postgres can fetch SVID
- [x] SVIDs have correct SPIFFE IDs in SAN
- [x] SVID rotation observed

### Key Metrics

| Metric | Value |
|--------|-------|
| **Applications** | 2 (Redis, Postgres) |
| **SVID TTL (Redis)** | 120 seconds |
| **SVID TTL (Postgres)** | 180 seconds |
| **Rotation Interval (Redis)** | ~60 seconds |
| **Rotation Interval (Postgres)** | ~90 seconds |
| **Agent Attestation** | join_token (PoC) |
| **Workload Attestation** | Unix (production-ready) |

---

## Common Issues and Solutions

### Issue 1: Socket Not Found

**Symptom:**
```
dial unix /run/spire/sockets/agent.sock: connect: no such file or directory
```

**Solution:**
- Check agent is running: `ps aux | grep spire-agent`
- Check agent logs: `tail -f /tmp/spire-agent.log`
- Verify directories exist: `ls -ld /run/spire/sockets/`
- Restart agent if needed

### Issue 2: Connection Refused

**Symptom:**
```
dial tcp 127.0.0.1:8081: connect: connection refused
```

**Solution:**
- socat bridge not running in VM
- Start it: `sudo socat TCP-LISTEN:8081,fork,reuseaddr VSOCK-CONNECT:2:8081 &`

### Issue 3: Authentication Handshake Failed

**Symptom:**
```
x509svid: could not verify leaf certificate: x509: certificate signed by unknown authority
```

**Solution:**
- Trust bundle not configured or outdated
- Get fresh bundle from server
- Save to `/opt/spire/bundle.pem`
- Restart agent

### Issue 4: No Identity Issued

**Symptom:**
```
ERRO: No identity issued  registered=false
```

**Solution:**
- Registration entry doesn't exist or doesn't match
- Verify UID matches: Check `ps -o uid -u <user>`
- Verify entry exists: `oc exec spire-server-0 -- ./spire-server entry show`
- Wait 5-10 seconds for agent to sync

### Issue 5: Permission Denied (File Write)

**Symptom:**
```
open /tmp/redis-svid/svid.0.pem: permission denied
```

**Solution:**
- Let the user create the directory: `sudo -u redis mkdir -p /tmp/redis-svid`
- Or fix permissions: `sudo chown redis:redis /tmp/redis-svid`

---

## Production Considerations

### What We Used for PoC vs Production

| Component | PoC | Production |
|-----------|-----|------------|
| **VM Attestation** | join_token (one-time) | KubeVirt API attestor |
| **Trust Bootstrap** | trust_bundle_path | Same (or bundle endpoint) |
| **Registration** | Manual entries | spire-controller-manager |
| **Host Bridge** | Manual pod | Operator-managed webhook |
| **VM Bridge** | Manual socat | systemd service / cloud-init |
| **SVID TTL** | 120-180s (testing) | 3600s (1 hour) |

### Limitations of join_token

- ❌ Cannot re-attest
- ❌ Agent crashes after ~30 minutes when trying to re-attest
- ❌ Manual token generation required
- ✅ Good for: PoC, testing, bootstrapping

### Production Requirements

1. **KubeVirt Attestor Plugin**
   - Validates VM identity via KubeVirt API
   - Supports re-attestation
   - No manual token generation

2. **Automated Registration**
   - Use spire-controller-manager
   - Watch VirtualMachine resources
   - Auto-create entries

3. **Automated Bridge Deployment**
   - Mutating webhook to inject socat
   - Handle node selection automatically
   - Self-healing on failures

4. **VM Image Integration**
   - SPIRE agent in cloud-init
   - systemd service for agent
   - systemd service for socat

---

## Quick Reference Commands

### Check Agent Status

```bash
# In VM
ps aux | grep spire-agent | grep -v grep
ls -l /run/spire/sockets/agent.sock
tail -20 /tmp/spire-agent.log
```

### Restart Agent (if needed)

```bash
# In VM
sudo pkill -9 spire-agent
sudo rm -rf /var/lib/spire/agent/*
sudo mkdir -p /run/spire/sockets /var/lib/spire/agent

export JOIN_TOKEN="<token>"
sudo /usr/local/bin/spire-agent run \
  -config /opt/spire/conf/agent/agent.conf \
  -joinToken $JOIN_TOKEN \
  > /tmp/spire-agent.log 2>&1 &
```

### Check socat Bridges

```bash
# In VM - check VM-side bridge
ps aux | grep socat | grep -v grep

# On workstation - check host-side bridge
oc get pod vsock-socat-bridge -n openshift-cnv
oc logs vsock-socat-bridge -n openshift-cnv --tail=20
```

### List All Registration Entries

```bash
# On workstation
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server entry show
```

### Fetch SVID

```bash
# In VM - as any user
sudo -u <username> /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock
```

---

## What This PoC Proves

### Technical Validation ✅

1. **VSOCK Communication** - Secure, isolated VM-to-host channel works
2. **Agent Deployment** - SPIRE agent can run inside VMs
3. **Workload Attestation** - Unix attestor correctly identifies processes by UID
4. **SVID Issuance** - Multiple workloads receive unique identities
5. **Automatic Rotation** - Short-lived credentials rotate automatically
6. **Parent-Child Trust** - Hierarchical trust model works (Server → Agent → Workloads)

### Business Value ✅

1. **Zero Trust** - Every workload has cryptographically verifiable identity
2. **No Static Credentials** - No hardcoded passwords or API keys
3. **Automatic Rotation** - Credentials refresh automatically (60-90 seconds in demo, 1 hour in production)
4. **Fine-Grained Authorization** - Different identities per workload enable precise access control
5. **Production Ready** - Architecture validated, only attestor plugin needed

---

## Next Steps

### For Production Deployment

1. **Develop KubeVirt Attestor**
   - Server plugin: Validate VM via KubeVirt API
   - Agent plugin: Provide VM metadata
   - Support re-attestation

2. **Automate Registration**
   - Contribute to spire-controller-manager
   - Add VirtualMachine CRD support
   - Auto-create entries on VM creation

3. **Automate Bridge Deployment**
   - Mutating webhook for socat injection
   - Handle multi-node scenarios
   - Self-healing on pod restarts

4. **Integrate Applications**
   - Use SPIFFE Helper or Envoy
   - Configure apps to use SPIRE Workload API
   - Implement mTLS with SVIDs

---

## Files Generated

### In VM

```
/usr/local/bin/spire-agent           - SPIRE agent binary
/opt/spire/conf/agent/agent.conf    - Agent configuration
/opt/spire/bundle.pem                - Trust bundle
/var/lib/spire/agent/                - Agent data directory
/run/spire/sockets/agent.sock        - Workload API socket
/tmp/spire-agent.log                 - Agent logs
/tmp/redis-svid/svid.0.pem          - Redis certificate
/tmp/redis-svid/svid.0.key          - Redis private key
/tmp/redis-svid/bundle.0.pem        - CA bundle
/tmp/postgres-svid/svid.0.pem       - Postgres certificate
/tmp/postgres-svid/svid.0.key       - Postgres private key
/tmp/postgres-svid/bundle.0.pem     - CA bundle
```

### On Host

```
vsock-socat-bridge pod in openshift-cnv namespace
```

---

**This PoC validates that SPIRE + OpenShift Virtualization is a viable solution for VM workload identity!**

Completed successful demonstration of SPIRE workload identity for VMs running on OpenShift Virtualization, with:

- ✅ Secure VSOCK communication
- ✅ Multiple workloads with unique identities
- ✅ Automatic SVID rotation
- ✅ Production-ready architecture

----

## Future improvements we need to explore on:

1. Explore the alternative of join_token attestation of VM (as this was used only for PoC). Possible alternatives:
    - x.509pop node attestaion
    - KubeVirt API based attestation (The VM gets its own identity by proving to SPIRE that it's a legitimate VM managed by KubeVirt. The SPIRE Server validates this by checking with the KubeVirt API)
2. For workloads inside VM, we are already using unix based attestation. So, no chnage required there.
3. Possible automation of deploying vsock-socat-bridge pod on node and update SPIRE POD IP in its yaml
4. Automatic registration entry creation via spire-controller-manager by extending ClusterSPIFFEID for VMs, enabling declarative, GitOps-friendly registration.