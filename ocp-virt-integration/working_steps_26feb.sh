1. install zero trust operator
2. install virtualisation operator
3. install hyperconverged operator
4. enable VSOCK in feature gate

oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  'kubevirt.kubevirt.io/jsonpatch=[{"op":"add","path":"/spec/configuration/developerConfiguration/featureGates/-","value":"VSOCK"}]' \
  --overwrite
  
5. 
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

oc patch vm  rhel9-magenta-gull-92 \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"domain":{"devices":{"autoattachVSOCK":true}}}}}}'
  
  restart the VM after running the oc patch command
  
6. 

NODE=$(oc get vmi rhel9-magenta-gull-92 -n openshift-cnv \
  -o jsonpath='{.status.nodeName}')
  
SPIRE_POD_IP=$(oc get pod spire-server-0 -n zero-trust-workload-identity-manager \
  -o jsonpath='{.status.podIP}')

7.

# Delete any existing bridge (bridge runs in same namespace as VM)
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



rausingh@rausingh-thinkpadp16vgen1:~/Documents/gcp_cluster/26Feb2026$ oc logs -f vsock-socat-bridge 
2026/02/26 09:23:53 socat[1] N VSOCK CID=2
2026/02/26 09:23:53 socat[1] N listening on AF=40 cid:4294967295 port:8081

8.
# Check VSOCK device exists
ls -l /dev/vsock
# Expected: crw-rw-rw- 1 root root 10, 122 ... /dev/vsock

# Check VSOCK modules are loaded
lsmod | grep vsock

# Test VSOCK connection to host (CID 2, port 8081)
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

9. install applications inside VM
redis and postgres


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
sudo dnf install redis -y

sudo systemctl enable --now redis

sudo systemctl status redis

redis-cli ping

sudo dnf module list postgresql

# Enable version 16
sudo dnf module enable postgresql:16 -y

# Install the server
sudo dnf install postgresql-server -y

sudo postgresql-setup --initdb

sudo systemctl enable --now postgresql

sudo systemctl status postgresql
sudo -u postgres psql

10. install socat
# Install socat
sudo dnf install -y socat
# or: sudo yum install -y socat

# Verify installation
which socat


11. Start Local VSOCK Bridge in VM
# Kill any existing socat processes
sudo pkill socat

# Start socat to forward localhost:8081 → VSOCK(2:8081)
sudo socat TCP-LISTEN:8081,fork,reuseaddr VSOCK-CONNECT:2:8081 &

# Verify it's running
ps aux | grep socat | grep -v grep
# Should show the socat process

# Test the local bridge
curl -v http://127.0.0.1:8081 2>&1 | head -5
# Should attempt connection (may get protocol error, but that's ok)

12. Download spire agent binary in VM

curl -L https://github.com/spiffe/spire/releases/download/v1.13.3/spire-1.13.3-linux-amd64-musl.tar.gz \
  -o /tmp/spire.tar.gz
  
cd /tmp
tar xzf spire.tar.gz

sudo cp spire-1.13.3/bin/spire-agent /usr/local/bin/

sudo chmod +x /usr/local/bin/spire-agent

# Verify
/usr/local/bin/spire-agent --version

13. create spire agent configuration
 oc exec -n zero-trust-workload-identity-manager spire-server-0 -- ./spire-server bundle show
copy this to 
->  sudo vi /opt/spire/bundle.pem


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

14. generate JOIN TOKEN

oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server token generate \
    -spiffeID spiffe://$APP_DOMAIN/vm/$VM_NAME \
    -ttl 600000
    
    output: Token: c65562ee-f4d3-494e-b67b-9f34bb3f3ed0


15. start spire agent in vm
export JOIN_TOKEN="3611a3f7-837f-40c5-ac59-1cccfb3e6f64"

# Ensure directories exist
sudo mkdir -p /run/spire/sockets
sudo mkdir -p /var/lib/spire/agent

 // make sure socat command is running inside VM and trust bundle is up-to-date inside VM (configured for spire-agent at trust_bundle_path:/opt/spire/bundle.pem)
# Start SPIRE Agent in FOREGROUND (to see if it works)
sudo /usr/local/bin/spire-agent run \
  -config /opt/spire/conf/agent/agent.conf \
  -joinToken $JOIN_TOKEN &
  
  
  
16. create registration entries for redis and postgres  
  export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/08Feb2026/auth/kubeconfig

# The agent's SPIFFE ID is shown in the agent startup logs
# It follows the pattern: spiffe://TRUST_DOMAIN/spire/agent/join_token/TOKEN_UUID

# You can also see it in the server entries (SPIRE namespace):
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server entry show | grep "join_token"
  
  
  
  get the agent's current spiffeID (VM's)
  oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --   ./spire-server agent list
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

SPIFFE ID         : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/c65562ee-f4d3-494e-b67b-9f34bb3f3ed0
Attestation type  : join_token
Expiration time   : 2026-02-26 15:05:22 +0000 UTC
Serial number     : 272224175320839099320198295271769451813
Can re-attest     : false

SPIFFE ID         : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64
Attestation type  : join_token
Expiration time   : 2026-02-27 09:40:05 +0000 UTC
Serial number     : 89527571018400848187715918095005903139
Can re-attest     : false
 ^
 |
 latest
 
 
 check process details for redis and postgres
 
 echo "=== Checking redis and postgres processes in VM ==="
virtctl ssh cloud-user@vm/rhel9-magenta-gull-92 \
  -n openshift-cnv \
  --identity-file=~/.ssh/id_ed25519 \
  --command "echo '=== Redis ===' && ps -o user,uid,gid,pid,cmd -C redis-server 2>/dev/null
  
  
  echo "=== Getting postgres details ==="
virtctl ssh cloud-user@vm/rhel9-magenta-gull-92 \
  -n openshift-cnv \
  --identity-file=~/.ssh/id_ed25519 \
  --command "ps aux | grep postgres | grep -v grep | head -3 && echo '' && echo '=== Postgres User Info ===' && id postgres 2>/dev/null && echo '' && echo '=== Postgres Binary Path ===' && which postgres 2>/dev/null || find /usr -name postgres -type f 2>/dev/null | head -1"
  
 
 
 
 Application Details
Application	User	UID	GID	Binary Path
Redis	redis	994	993	/usr/bin/redis-server
Postgres	postgres	26	26	/usr/bin/postgres

 
 
 # Use the agent with longer expiration
AGENT_ID="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64"

echo "=== Step 3: Cleaning old entries ==="
# List all entries to see what exists
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show | grep -E "Entry ID" | awk '{print $4}' > /tmp/all-entries.txt

# Count them
ENTRY_COUNT=$(wc -l < /tmp/all-entries.txt)
echo "Found $ENTRY_COUNT entries"

# Show what we have
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show | grep -E "Found|Entry ID|SPIFFE ID|Parent" | head -50
  
  
  
   let's create registration entries for both redis and postgres:
   
   AGENT_ID="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64"

echo "=== Step 4: Creating Registration Entries ==="
echo "Using Agent ID: $AGENT_ID"
echo ""

echo "Creating entry for Redis (UID 994)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis \
    -selector unix:uid:994 \
    -x509SVIDTTL 3600

echo ""
echo "Creating entry for Postgres (UID 26)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres \
    -selector unix:uid:26 \
    -x509SVIDTTL 3600

echo ""
echo "Creating entry for root (UID 0) - for testing..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/root-test \
    -selector unix:uid:0 \
    -x509SVIDTTL 3600

echo ""
echo "✅ All entries created!"


verify all entries
echo "=== Step 5: Verifying all entries for current agent ==="
AGENT_ID="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64"

oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -parentID "$AGENT_ID"
  
  
 17. Test fetching of SVIDs in VM
 
 Test 1: Fetch SVID for Redis
 
 [cloud-user@rhel9-magenta-gull-92 ~]$ sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock
Received 1 svid after 6.123148ms

SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis
SVID Valid After:	2026-02-27 08:55:07 +0000 UTC
SVID Valid Until:	2026-02-27 09:55:17 +0000 UTC
CA #1 Valid After:	2026-02-26 09:16:15 +0000 UTC
CA #1 Valid Until:	2026-02-27 09:16:25 +0000 UTC
CA #2 Valid After:	2026-02-26 21:16:15 +0000 UTC
CA #2 Valid Until:	2026-02-27 21:16:25 +0000 UTC




Test 2: Fetch SVID for Postgres

[cloud-user@rhel9-magenta-gull-92 ~]$ # In VM
sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock
Received 1 svid after 6.333925ms

SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres
SVID Valid After:	2026-02-27 08:55:07 +0000 UTC
SVID Valid Until:	2026-02-27 09:55:17 +0000 UTC
CA #1 Valid After:	2026-02-26 09:16:15 +0000 UTC
CA #1 Valid Until:	2026-02-27 09:16:25 +0000 UTC
CA #2 Valid After:	2026-02-26 21:16:15 +0000 UTC
CA #2 Valid Until:	2026-02-27 21:16:25 +0000 UTC


Test 3: Save Both SVIDs to Files

# In VM - Save Redis SVID
sudo -u redis mkdir -p /tmp/redis-svid
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock \
  -write /tmp/redis-svid

# Check Redis files
ls -la /tmp/redis-svid/
cat /tmp/redis-svid/svid.0.pem

# Save Postgres SVID
sudo -u postgres mkdir -p /tmp/postgres-svid
sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock \
  -write /tmp/postgres-svid

# Check Postgres files
ls -la /tmp/postgres-svid/
cat /tmp/postgres-svid/svid.0.pem



[cloud-user@rhel9-magenta-gull-92 ~]$ # In VM - Save Redis SVID
sudo -u redis mkdir -p /tmp/redis-svid
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock \
  -write /tmp/redis-svid

# Check Redis files
ls -la /tmp/redis-svid/
cat /tmp/redis-svid/svid.0.pem

# Save Postgres SVID
sudo -u postgres mkdir -p /tmp/postgres-svid
sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock \
  -write /tmp/postgres-svid

# Check Postgres files
ls -la /tmp/postgres-svid/
cat /tmp/postgres-svid/svid.0.pem
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
-----BEGIN CERTIFICATE-----
MIIDQjCCAiqgAwIBAgIRAIsm3dBsksidKiEWeQwZUt4wDQYJKoZIhvcNAQELBQAw
gYExCzAJBgNVBAYTAlVTMQswCQYDVQQKEwJSSDEzMDEGA1UEAxMqYXBwcy5nY3Ay
NmZlYi5nY3AuZGV2Y2x1c3Rlci5vcGVuc2hpZnQuY29tMTAwLgYDVQQFEyczMTcz
NTgzMjg3MTQ2MjIzODUwODgxMTEzMTUzMjQ1Nzc0MjI4MjYwHhcNMjYwMjI3MDg1
NTA3WhcNMjYwMjI3MDk1NTE3WjAdMQswCQYDVQQGEwJVUzEOMAwGA1UEChMFU1BJ
UkUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATXiK31hYYjrzUuuTdvke2Yfo3u
nKHANqRDGtt7SGNWNGCMKqCoYUcjZV7YiiUaV9N47jkmA9iT5xb6BVAp+Bjpo4Hi
MIHfMA4GA1UdDwEB/wQEAwIDqDAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUH
AwIwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUhusN6eP2K2hOKKJLOEV+QzLBYEMw
HwYDVR0jBBgwFoAUdv85t/UhQS+beeXTkmHdBYceSngwYAYDVR0RBFkwV4ZVc3Bp
ZmZlOi8vYXBwcy5nY3AyNmZlYi5nY3AuZGV2Y2x1c3Rlci5vcGVuc2hpZnQuY29t
L3ZtL3JoZWw5LW1hZ2VudGEtZ3VsbC05Mi9wb3N0Z3JlczANBgkqhkiG9w0BAQsF
AAOCAQEAQEHFrjX0g9qNF7+G8L55Ji7svIYwjcqeKCvRSkk1Ni1N5Nv8k9Vz5tvx
+65HX3hfTi8ho9FBNlW9Qw4++zvmHvghV3gSJdTcMMCFI7GlLPEXlzNP5AxpyoEN
irdwe1pkiOnxu5R/ZWjDnnvV3vfmV1crDNOZdC1nZZs5LDeyhbgEkuMyzGelszJY
o73NrDuKUYBRuc+epcIqT6hPBCKO33G1JznC9kOiiWKT2Y7MgALiY+axUw3G2lVP
KLq8U7Iloh7VUw89eWUKGi8502UEA0vewuMNUxU7JInPkvbG6e9iGwEQFgyIISU1
G9/rw+8lGqA+W8Ox7qPPCjWXUtetIA==
-----END CERTIFICATE-----
[cloud-user@rhel9-magenta-gull-92 ~]$ 



Test 4: Verify Both Applications Have Unique Identities

# In VM - Compare SPIFFE IDs
echo "=== Redis SPIFFE ID ==="
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock | grep "SPIFFE ID"

echo ""
echo "=== Postgres SPIFFE ID ==="
sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock | grep "SPIFFE ID"

echo ""
echo "✅ Both applications have unique identities!"

[cloud-user@rhel9-magenta-gull-92 ~]$ # In VM - Compare SPIFFE IDs
echo "=== Redis SPIFFE ID ==="
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock | grep "SPIFFE ID"

echo ""
echo "=== Postgres SPIFFE ID ==="
sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock | grep "SPIFFE ID"

echo ""
echo "✅ Both applications have unique identities!"
=== Redis SPIFFE ID ===
SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis

=== Postgres SPIFFE ID ===
SPIFFE ID:		spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres

✅ Both applications have unique identities!



Step 7: Verify Certificate Details

# In VM - View certificate details for Redis
openssl x509 -in /tmp/redis-svid/svid.0.pem -noout -text | grep -A 3 "Subject Alternative Name"

# View certificate details for Postgres
openssl x509 -in /tmp/postgres-svid/svid.0.pem -noout -text | grep -A 3 "Subject Alternative Name"

[cloud-user@rhel9-magenta-gull-92 ~]$ # In VM - View certificate details for Redis
openssl x509 -in /tmp/redis-svid/svid.0.pem -noout -text | grep -A 3 "Subject Alternative Name"

# View certificate details for Postgres
openssl x509 -in /tmp/postgres-svid/svid.0.pem -noout -text | grep -A 3 "Subject Alternative Name"
            X509v3 Subject Alternative Name: 
                URI:spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis
    Signature Algorithm: sha256WithRSAEncryption
    Signature Value:
            X509v3 Subject Alternative Name: 
                URI:spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres
    Signature Algorithm: sha256WithRSAEncryption
    Signature Value:



# In VM - View certificate details for Redis
openssl x509 -in /tmp/redis-svid/svid.0.pem -noout -text
# View certificate details for Postgres
openssl x509 -in /tmp/postgres-svid/svid.0.pem -noout -text 


[cloud-user@rhel9-magenta-gull-92 ~]$ # In VM - View certificate details for Redis
openssl x509 -in /tmp/redis-svid/svid.0.pem -noout -text
# View certificate details for Postgres
openssl x509 -in /tmp/postgres-svid/svid.0.pem -noout -text 
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
    Signature Value:
        50:11:12:59:94:4a:83:c5:ae:db:c9:6a:45:98:60:02:d2:3c:
        4c:a3:b0:94:e4:e6:cf:ed:8f:77:7c:f4:b1:86:f3:e4:d9:83:
        e5:77:54:18:ea:83:90:87:42:6e:98:e9:5e:a4:e8:d3:e6:89:
        72:7f:e6:ee:f9:2f:3f:20:4d:e8:e1:51:26:b0:e2:7f:ed:2a:
        74:2c:c9:b2:03:2f:e6:b7:23:d8:5c:ec:a3:d1:09:b0:77:5f:
        d4:6b:30:6b:b7:35:81:2b:e0:68:54:53:d7:88:13:c8:0c:f6:
        19:74:10:96:49:83:9e:6f:77:53:ba:1f:ea:20:02:7d:05:bf:
        06:74:e5:31:21:5d:50:3b:f7:fb:74:f0:a1:d7:66:03:89:34:
        3b:f6:e4:ed:87:3b:a3:20:01:3a:c6:ad:25:ec:b1:aa:ee:f0:
        e8:a8:ba:16:19:04:21:e3:1f:52:80:0b:f3:9f:7c:8b:b6:7a:
        94:7d:c9:0f:2a:20:df:fc:9a:9a:c9:ca:a7:0b:7b:f3:0f:84:
        ee:5b:af:8e:3f:3e:c0:be:4c:1c:14:e9:18:2e:c9:9c:8a:ed:
        f9:9c:e8:85:49:dc:99:61:75:7c:02:29:9f:e2:68:be:e0:85:
        29:1f:e3:76:bf:33:40:b3:81:cb:00:48:7e:55:cb:2e:44:54:
        2a:7f:d9:8f
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
    Signature Value:
        40:41:c5:ae:35:f4:83:da:8d:17:bf:86:f0:be:79:26:2e:ec:
        bc:86:30:8d:ca:9e:28:2b:d1:4a:49:35:36:2d:4d:e4:db:fc:
        93:d5:73:e6:db:f1:fb:ae:47:5f:78:5f:4e:2f:21:a3:d1:41:
        36:55:bd:43:0e:3e:fb:3b:e6:1e:f8:21:57:78:12:25:d4:dc:
        30:c0:85:23:b1:a5:2c:f1:17:97:33:4f:e4:0c:69:ca:81:0d:
        8a:b7:70:7b:5a:64:88:e9:f1:bb:94:7f:65:68:c3:9e:7b:d5:
        de:f7:e6:57:57:2b:0c:d3:99:74:2d:67:65:9b:39:2c:37:b2:
        85:b8:04:92:e3:32:cc:67:a5:b3:32:58:a3:bd:cd:ac:3b:8a:
        51:80:51:b9:cf:9e:a5:c2:2a:4f:a8:4f:04:22:8e:df:71:b5:
        27:39:c2:f6:43:a2:89:62:93:d9:8e:cc:80:02:e2:63:e6:b1:
        53:0d:c6:da:55:4f:28:ba:bc:53:b2:25:a2:1e:d5:53:0f:3d:
        79:65:0a:1a:2f:39:d3:65:04:03:4b:de:c2:e3:0d:53:15:3b:
        24:89:cf:92:f6:c6:e9:ef:62:1b:01:10:16:0c:88:21:25:35:
        1b:df:eb:c3:ef:25:1a:a0:3e:5b:c3:b1:ee:a3:cf:0a:35:97:
        52:d7:ad:20
[cloud-user@rhel9-magenta-gull-92 ~]$ 


18. test SVID renewal
echo "=== Deleting old entries and recreating with short TTL ==="
echo ""

# Delete the entries we just created
echo "Deleting old entries..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry delete -entryID ee11295f-f718-4a5b-b47f-c145d72eba38 | grep Deleted

oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry delete -entryID 2d41b008-05f4-46f5-b9ed-759bfc854939 | grep Deleted

oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry delete -entryID 97ad9ec9-2cec-4a05-afc4-f4c4456df0d1 | grep Deleted

echo ""
echo "✅ Old entries deleted"
=== Deleting old entries and recreating with short TTL ===

Deleting old entries...
Deleted entry with ID: ee11295f-f718-4a5b-b47f-c145d72eba38
Deleted 1 entries successfully
Deleted entry with ID: 2d41b008-05f4-46f5-b9ed-759bfc854939
Deleted 1 entries successfully
Deleted entry with ID: 97ad9ec9-2cec-4a05-afc4-f4c4456df0d1
Deleted 1 entries successfully



AGENT_ID="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64"

echo "=== Creating NEW entries with SHORT TTLs for rotation testing ==="
echo ""

echo "1. Redis - 120 second TTL (rotates every ~60s)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/redis \
    -selector unix:uid:994 \
    -x509SVIDTTL 120 | grep -E "Entry ID|SPIFFE ID|TTL|Selector"

echo ""
echo "2. Postgres - 180 second TTL (rotates every ~90s)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/postgres \
    -selector unix:uid:26 \
    -x509SVIDTTL 180 | grep -E "Entry ID|SPIFFE ID|TTL|Selector"

echo ""
echo "3. Root - 120 second TTL (rotates every ~60s)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/vm/rhel9-magenta-gull-92/root-test \
    -selector unix:uid:0 \
    -x509SVIDTTL 120 | grep -E "Entry ID|SPIFFE ID|TTL|Selector"

echo ""
echo "✅ All entries created with short TTLs!"
echo ""
echo "Rotation schedule:"
echo "  - Redis: Every ~60 seconds"
echo "  - Postgres: Every ~90 seconds"  
echo "  - Root: Every ~60 seconds"


Now Test in Your VM
Step 1: Wait for Agent to Sync (5-10 seconds)
# In VMsleep 10
Step 2: Fetch SVIDs for Both Applications
Test Redis:
# In VMsudo -u redis /usr/local/bin/spire-agent api fetch x509 \  -socketPath /run/spire/sockets/agent.sock
Test Postgres:
# In VMsudo -u postgres /usr/local/bin/spire-agent api fetch x509 \  -socketPath /run/spire/sockets/agent.sock
Step 3: Save SVIDs to Files
# Save Redis SVIDsudo -u redis mkdir -p /tmp/redis-svidsudo -u redis /usr/local/bin/spire-agent api fetch x509 \  -socketPath /run/spire/sockets/agent.sock \  -write /tmp/redis-svid# Save Postgres SVIDsudo -u postgres mkdir -p /tmp/postgres-svidsudo -u postgres /usr/local/bin/spire-agent api fetch x509 \  -socketPath /run/spire/sockets/agent.sock \  -write /tmp/postgres-svid# Check what was savedecho "=== Redis SVID Files ==="ls -la /tmp/redis-svid/echo ""echo "=== Postgres SVID Files ==="ls -la /tmp/postgres-svid/
Step 4: Watch SVID Rotation in Real-Time
Terminal 1: Watch Agent Logs
# In VM - Watch rotation eventstail -f /tmp/spire-agent.log | grep -E "Renewing|SVID updated|expires_at" --line-buffered
You should see:
INFO[0060] Renewing X509-SVID  spiffe_id="...redis" expires_at="..."DEBU[0060] SVID updated  spiffe_id="...redis"INFO[0090] Renewing X509-SVID  spiffe_id="...postgres" expires_at="..."DEBU[0090] SVID updated  spiffe_id="...postgres"
Terminal 2: Poll SVIDs to See Changes
# In VM - Run this loop to see certificate changeswhile true; do  clear  echo "=== $(date +%H:%M:%S) ==="  echo ""    echo "Redis SVID:"  sudo -u redis /usr/local/bin/spire-agent api fetch x509 \    -socketPath /run/spire/sockets/agent.sock 2>/dev/null | \    grep -E "SPIFFE ID|Valid Until" | head -2    echo ""  echo "Postgres SVID:"  sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \    -socketPath /run/spire/sockets/agent.sock 2>/dev/null | \    grep -E "SPIFFE ID|Valid Until" | head -2    echo ""  echo "Waiting 20 seconds..."  sleep 20done
Expected Rotation Timeline
Time    Event----    -----00:00   Redis SVID issued (TTL: 120s, expires 02:00)        Postgres SVID issued (TTL: 180s, expires 03:00)01:00   ← Redis rotates (50% of 120s)        New Redis SVID (expires 03:00)01:30   ← Postgres rotates (50% of 180s)        New Postgres SVID (expires 04:30)02:00   ← Redis rotates again        ...continues every 60s for Redis, 90s for Postgres
Quick Test - See Both SVIDs Now
Run this simple command to verify both are working:
# In VMecho "=== Testing Both Applications ==="echo ""echo "1. Redis (UID 994):"sudo -u redis /usr/local/bin/spire-agent api fetch x509 \  -socketPath /run/spire/sockets/agent.sock | grep "SPIFFE ID"echo ""echo "2. Postgres (UID 26):"sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \  -socketPath /run/spire/sockets/agent.sock | grep "SPIFFE ID"echo ""echo "✅ Both applications have unique SPIFFE identities!"
Try these commands and you should see both redis and postgres getting their unique SVIDs! 🎉