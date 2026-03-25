# Registration Entries in SPIRE: Complete Guide

This document explains how SPIRE registration entries work, how they're created, and how they enable workload identity.

---

## What is a Registration Entry?

A **registration entry** is a configuration in SPIRE that defines:
1. **Who should get this identity** (based on selectors)
2. **What identity they should get** (SPIFFE ID)
3. **Who is authorized to issue this identity** (parent SPIFFE ID)

Think of it as a **policy rule** that says: "If a workload matches these characteristics, give it this identity."

---

## The Parent-Child Relationship

### Understanding the Hierarchy

SPIRE uses a **hierarchical trust model**:

```
SPIRE Server (root of trust)
    │
    └─→ Issues SVIDs to "Node Agents"
         │
         └─→ Node Agents issue SVIDs to "Workloads"
```

**Parent SPIFFE ID** = The entity authorized to request SVIDs for its children  
**Child SPIFFE ID** = The identity that will be issued to the workload

### Example Hierarchy

```
spiffe://example.org/spire/server                    ← Root (SPIRE Server)
    │
    ├─→ spiffe://example.org/k8s-cluster/my-cluster/node/worker-1
    │   │                                            ← Node Agent (standard)
    │   │
    │   └─→ spiffe://example.org/ns/prod/sa/nginx   ← Pod workload
    │
    └─→ spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm
        │                                            ← VM Node Agent (our implementation!)
        │
        ├─→ spiffe://example.org/ns/prod/vm/app-vm/nginx      ← nginx in VM
        ├─→ spiffe://example.org/ns/prod/vm/app-vm/postgres   ← postgres in VM
        └─→ spiffe://example.org/ns/prod/vm/app-vm/redis      ← redis in VM
```

**Key concept**: A parent can request SVIDs on behalf of its children, but only for children it's authorized for.

---

## How Registration Entries Are Created

Registration entries are **NOT created automatically** - they must be explicitly registered in SPIRE Server. There are several ways to create them:

### Method 1: Command Line (spire-server CLI)

This is the most common method for manual or one-off registrations.

#### Creating a Node Entry (VM)

```bash
# Get access to SPIRE Server pod
kubectl exec -n spire spire-server-0 -it -- /bin/sh

# Create node registration for the VM
/opt/spire/bin/spire-server entry create \
  -parentID spiffe://example.org/spire/server \
  -spiffeID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm \
  -selector kubevirt:vm-namespace:prod \
  -selector kubevirt:vm-name:app-vm \
  -node
```

**What this does**:
- Creates an entry for the VM itself
- Parent: SPIRE Server (root)
- SPIFFE ID: The VM's identity
- Selectors: How to identify this VM
- `-node` flag: This is a node agent entry

**When is this used?**:
When the VM's SPIRE Agent first attests, SPIRE Server uses this entry to validate and issue the VM's node SVID.

#### Creating Workload Entries (Apps in VM)

```bash
# Register nginx workload in the VM
/opt/spire/bin/spire-server entry create \
  -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm \
  -spiffeID spiffe://example.org/ns/prod/vm/app-vm/nginx \
  -selector unix:uid:33 \
  -selector unix:path:/usr/sbin/nginx \
  -ttl 3600

# Register postgres workload in the VM
/opt/spire/bin/spire-server entry create \
  -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm \
  -spiffeID spiffe://example.org/ns/prod/vm/app-vm/postgres \
  -selector unix:uid:70 \
  -selector unix:path:/usr/bin/postgres \
  -ttl 3600

# Register redis workload in the VM
/opt/spire/bin/spire-server entry create \
  -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm \
  -spiffeID spiffe://example.org/ns/prod/vm/app-vm/redis \
  -selector unix:uid:999 \
  -selector unix:path:/usr/bin/redis-server \
  -ttl 3600
```

**What this does**:
- Creates entries for workloads inside the VM
- Parent: The VM's SPIFFE ID (not the SPIRE Server!)
- SPIFFE ID: Each workload's unique identity
- Selectors: How to identify each workload (UID, path)
- TTL: How long the SVID is valid (3600 seconds = 1 hour)

---

## The Complete Registration Flow

Let me show you the complete process from VM creation to workload identity:

### Step 1: Deploy SPIRE and VM (No Entries Yet)

```
┌─────────────────────────────────────────────────┐
│  SPIRE Server Deployed                          │
│  Registration Database: EMPTY (or just default)│
└─────────────────────────────────────────────────┘

VM is created and boots, SPIRE Agent starts in VM
But cannot attest yet - no registration entry!
```

### Step 2: Administrator Creates Node Entry for VM

**When**: Before or after VM boots (preferably before)  
**Who**: Cluster administrator or automation  
**How**: Using spire-server CLI

```bash
# SSH into SPIRE Server pod (or use kubectl exec)
kubectl exec -n spire spire-server-0 -it -- bash

# Create node entry for the VM
spire-server entry create \
  -parentID spiffe://example.org/spire/server \
  -spiffeID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm \
  -selector kubevirt:vm-namespace:prod \
  -selector kubevirt:vm-name:app-vm \
  -selector kubevirt:vm-uid:abc-123-def-456 \
  -node

# Output:
Entry ID         : 12345678-1234-1234-1234-123456789abc
SPIFFE ID        : spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm
Parent ID        : spiffe://example.org/spire/server
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : kubevirt:vm-namespace:prod
Selector         : kubevirt:vm-name:app-vm
Selector         : kubevirt:vm-uid:abc-123-def-456
```

**What just happened**:

```
┌─────────────────────────────────────────────────┐
│  SPIRE Server Registration Database             │
├─────────────────────────────────────────────────┤
│                                                 │
│  Entry #1 (Node Entry):                         │
│  ┌───────────────────────────────────────────┐  │
│  │ SPIFFE ID:                                │  │
│  │   spiffe://.../vm/app-vm                  │  │
│  │                                           │  │
│  │ Parent ID:                                │  │
│  │   spiffe://example.org/spire/server       │  │
│  │                                           │  │
│  │ Selectors:                                │  │
│  │   kubevirt:vm-namespace:prod              │  │
│  │   kubevirt:vm-name:app-vm                 │  │
│  │   kubevirt:vm-uid:abc-123-def-456         │  │
│  │                                           │  │
│  │ Type: Node                                │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
└─────────────────────────────────────────────────┘
```

Now SPIRE knows: "If a VM with these selectors tries to attest, give it this SPIFFE ID."

### Step 3: VM Attests and Gets Node SVID

```
┌──────────────────────────────────────────────────────┐
│  VM SPIRE Agent (in VM)                              │
│  Sends attestation with selectors:                   │
│    kubevirt:vm-namespace:prod                        │
│    kubevirt:vm-name:app-vm                           │
│    kubevirt:vm-uid:abc-123-def-456                   │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│  SPIRE Server                                        │
│  "Do I have an entry matching these selectors?"      │
│                                                      │
│  Search database...                                  │
│  ✅ Found Entry #1!                                  │
│  Selectors match exactly                             │
│                                                      │
│  Issue node SVID:                                    │
│    spiffe://.../vm/app-vm                            │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│  VM SPIRE Agent                                      │
│  ✅ Received node SVID                               │
│  ✅ Can now serve workloads                          │
└──────────────────────────────────────────────────────┘
```

**Important**: Without the registration entry, the VM cannot attest! The entry must be created first.

### Step 4: Administrator Creates Workload Entries

**When**: Before workloads need to get SVIDs  
**Who**: Cluster administrator or automation  
**How**: Using spire-server CLI

```bash
# Still in SPIRE Server pod

# Register nginx
spire-server entry create \
  -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm \
  -spiffeID spiffe://example.org/ns/prod/vm/app-vm/nginx \
  -selector unix:uid:33 \
  -selector unix:path:/usr/sbin/nginx

# Register postgres
spire-server entry create \
  -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm \
  -spiffeID spiffe://example.org/ns/prod/vm/app-vm/postgres \
  -selector unix:uid:70 \
  -selector unix:path:/usr/bin/postgres

# Register redis
spire-server entry create \
  -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm \
  -spiffeID spiffe://example.org/ns/prod/vm/app-vm/redis \
  -selector unix:uid:999 \
  -selector unix:path:/usr/bin/redis-server
```

**What just happened**:

```
┌─────────────────────────────────────────────────┐
│  SPIRE Server Registration Database             │
├─────────────────────────────────────────────────┤
│                                                 │
│  Entry #1 (Node Entry): VM                      │
│  [already exists from step 2]                   │
│                                                 │
│  Entry #2 (Workload Entry): nginx               │
│  ┌───────────────────────────────────────────┐  │
│  │ SPIFFE ID:                                │  │
│  │   spiffe://.../vm/app-vm/nginx            │  │
│  │                                           │  │
│  │ Parent ID:                                │  │
│  │   spiffe://.../vm/app-vm ← VM's SPIFFE ID│  │
│  │                                           │  │
│  │ Selectors:                                │  │
│  │   unix:uid:33                             │  │
│  │   unix:path:/usr/sbin/nginx               │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  Entry #3 (Workload Entry): postgres            │
│  ┌───────────────────────────────────────────┐  │
│  │ SPIFFE ID:                                │  │
│  │   spiffe://.../vm/app-vm/postgres         │  │
│  │                                           │  │
│  │ Parent ID:                                │  │
│  │   spiffe://.../vm/app-vm ← Same VM        │  │
│  │                                           │  │
│  │ Selectors:                                │  │
│  │   unix:uid:70                             │  │
│  │   unix:path:/usr/bin/postgres             │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  Entry #4 (Workload Entry): redis               │
│  ┌───────────────────────────────────────────┐  │
│  │ SPIFFE ID: .../vm/app-vm/redis            │  │
│  │ Parent ID: .../vm/app-vm                  │  │
│  │ Selectors: unix:uid:999, ...              │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Step 5: Workloads Request SVIDs

Now when workloads connect, they get their SVIDs:

```bash
# Inside VM, nginx process connects
# Automatically happens when nginx uses SPIFFE library
```

```
┌──────────────────────────────────────────────────────┐
│  nginx (PID 1234, UID 33) connects to agent socket   │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│  VM SPIRE Agent identifies:                          │
│  • UID: 33                                           │
│  • Path: /usr/sbin/nginx                             │
│                                                      │
│  Generates selectors:                                │
│  • unix:uid:33                                       │
│  • unix:path:/usr/sbin/nginx                         │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│  VM SPIRE Agent queries SPIRE Server:                │
│  "Give me SVID for workload with:                    │
│   Parent: spiffe://.../vm/app-vm (my node ID)        │
│   Selectors: unix:uid:33, unix:path:/usr/sbin/nginx" │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│  SPIRE Server searches database:                     │
│  "Find entry where:                                  │
│   1. Parent = spiffe://.../vm/app-vm                 │
│   2. Selectors match"                                │
│                                                      │
│  Found: Entry #2 (nginx) ✅                          │
│  Selectors: unix:uid:33, unix:path:/usr/sbin/nginx   │
│  ✅ Perfect match!                                   │
│                                                      │
│  Issue SVID:                                         │
│    spiffe://.../vm/app-vm/nginx                      │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│  nginx receives its unique SVID! ✅                  │
└──────────────────────────────────────────────────────┘
```

---

## Method 2: SPIRE Server API

You can also create entries programmatically via the SPIRE Server API.

### Using gRPC API

```go
// Go code example
package main

import (
    "context"
    entryv1 "github.com/spiffe/spire-api-sdk/proto/spire/api/server/entry/v1"
    "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
    "google.golang.org/grpc"
)

func createWorkloadEntry(client entryv1.EntryClient) error {
    entry := &types.Entry{
        ParentId: &types.SPIFFEID{
            TrustDomain: "example.org",
            Path:        "/k8s-cluster/my-cluster/ns/prod/vm/app-vm",
        },
        SpiffeId: &types.SPIFFEID{
            TrustDomain: "example.org",
            Path:        "/ns/prod/vm/app-vm/nginx",
        },
        Selectors: []*types.Selector{
            {Type: "unix", Value: "uid:33"},
            {Type: "unix", Value: "path:/usr/sbin/nginx"},
        },
        X509SvidTtl: 3600,
    }

    _, err := client.BatchCreateEntry(context.Background(), &entryv1.BatchCreateEntryRequest{
        Entries: []*types.Entry{entry},
    })
    return err
}
```

### Using REST API

```bash
# Create entry via REST API (if SPIRE Server has HTTP API enabled)
curl -X POST https://spire-server:8081/api/v1/entries \
  -H "Content-Type: application/json" \
  -d '{
    "parentId": "spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm",
    "spiffeId": "spiffe://example.org/ns/prod/vm/app-vm/nginx",
    "selectors": [
      {"type": "unix", "value": "uid:33"},
      {"type": "unix", "value": "path:/usr/sbin/nginx"}
    ],
    "x509SvidTtl": 3600
  }'
```

---

## Method 3: Kubernetes Controller (Automation)

For production, you want **automatic registration** when VMs are created. This requires a Kubernetes controller.

### Using spire-controller-manager

SPIRE has a Kubernetes controller that can automatically create entries:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: vm-nginx-workloads
spec:
  # Match all virt-launcher pods
  podSelector:
    matchLabels:
      kubevirt.io: virt-launcher
  
  # SPIFFE ID template
  spiffeIDTemplate: "spiffe://example.org/ns/{{ .PodMeta.Namespace }}/vm/{{ .PodMeta.Labels.vm-name }}/nginx"
  
  # Selectors
  workloadSelectorTemplates:
    - "unix:uid:33"
    - "unix:path:/usr/sbin/nginx"
```

**This automatically creates registration entries** when VMs are created!

### Custom Controller (More Flexible)

You can also write a custom controller:

```go
// Watch for VirtualMachine CRs
func (r *VMRegistrationReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // Get VM
    vm := &kubevirtv1.VirtualMachine{}
    if err := r.Get(ctx, req.NamespacedName, vm); err != nil {
        return ctrl.Result{}, err
    }

    // Get VM's SPIFFE ID (after it attests)
    vmSpiffeID := fmt.Sprintf("spiffe://example.org/k8s-cluster/my-cluster/ns/%s/vm/%s",
        vm.Namespace, vm.Name)

    // Register workloads based on annotations or ConfigMap
    workloads := getWorkloadConfig(vm)
    
    for _, workload := range workloads {
        entry := &types.Entry{
            ParentId: vmSpiffeID,
            SpiffeId: fmt.Sprintf("%s/%s", vmSpiffeID, workload.Name),
            Selectors: workload.Selectors,
        }
        
        // Create entry in SPIRE
        r.spireClient.BatchCreateEntry(ctx, entry)
    }
    
    return ctrl.Result{}, nil
}
```

---

## Method 4: Declarative Configuration (GitOps)

For GitOps workflows, you can define entries in YAML and apply them:

### Using SPIRE Controller Manager CRDs

```yaml
---
# Node entry for VM
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: vm-node-app-vm
spec:
  spiffeIDTemplate: "spiffe://example.org/k8s-cluster/my-cluster/ns/{{ .PodMeta.Namespace }}/vm/app-vm"
  podSelector:
    matchLabels:
      kubevirt.io/vm: app-vm
  workloadSelectorTemplates:
    - "kubevirt:vm-namespace:{{ .PodMeta.Namespace }}"
    - "kubevirt:vm-name:app-vm"

---
# Workload entry for nginx
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: vm-workload-nginx
spec:
  parentIDTemplate: "spiffe://example.org/k8s-cluster/my-cluster/ns/{{ .PodMeta.Namespace }}/vm/app-vm"
  spiffeIDTemplate: "spiffe://example.org/ns/{{ .PodMeta.Namespace }}/vm/app-vm/nginx"
  podSelector:
    matchLabels:
      kubevirt.io/vm: app-vm
  workloadSelectorTemplates:
    - "unix:uid:33"
    - "unix:path:/usr/sbin/nginx"

---
# Workload entry for postgres
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: vm-workload-postgres
spec:
  parentIDTemplate: "spiffe://example.org/k8s-cluster/my-cluster/ns/{{ .PodMeta.Namespace }}/vm/app-vm"
  spiffeIDTemplate: "spiffe://example.org/ns/{{ .PodMeta.Namespace }}/vm/app-vm/postgres"
  podSelector:
    matchLabels:
      kubevirt.io/vm: app-vm
  workloadSelectorTemplates:
    - "unix:uid:70"
    - "unix:path:/usr/bin/postgres"
```

Apply with:
```bash
kubectl apply -f vm-registration-entries.yaml
```

The controller watches these CRs and creates actual SPIRE registration entries.

---

## Complete Example: From VM Creation to Workload Identity

Let me show you the complete operational flow:

### Scenario: Deploy a Database VM with postgres and redis

```
STEP 1: Create the VM
══════════════════════════════════════════════════════════════

$ kubectl apply -f database-vm.yaml

apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: database-vm
  namespace: production
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          autoattachVSOCK: true  # Enable VSOCK!
        resources:
          requests:
            memory: 4Gi
            cpu: 2

VM is created, starts booting...


STEP 2: Create Node Registration Entry (Administrator)
══════════════════════════════════════════════════════════════

$ kubectl exec -n spire spire-server-0 -- \
  spire-server entry create \
    -parentID spiffe://example.org/spire/server \
    -spiffeID spiffe://example.org/k8s-cluster/my-cluster/ns/production/vm/database-vm \
    -selector kubevirt:vm-namespace:production \
    -selector kubevirt:vm-name:database-vm \
    -node

Entry ID: entry-001
✅ Created


STEP 3: VM Boots and Attests
══════════════════════════════════════════════════════════════

VM boots, SPIRE Agent starts:
• Reads metadata: {namespace: production, name: database-vm, ...}
• Connects via VSOCK to proxy
• Sends attestation with selectors
• SPIRE Server finds Entry #entry-001
• VM receives node SVID: spiffe://.../vm/database-vm
✅ VM can now serve workloads


STEP 4: Create Workload Registration Entries
══════════════════════════════════════════════════════════════

# Register postgres
$ kubectl exec -n spire spire-server-0 -- \
  spire-server entry create \
    -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/production/vm/database-vm \
    -spiffeID spiffe://example.org/ns/production/vm/database-vm/postgres \
    -selector unix:uid:70 \
    -selector unix:path:/usr/bin/postgres \
    -ttl 3600

Entry ID: entry-002
✅ Created

# Register redis
$ kubectl exec -n spire spire-server-0 -- \
  spire-server entry create \
    -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/production/vm/database-vm \
    -spiffeID spiffe://example.org/ns/production/vm/database-vm/redis \
    -selector unix:uid:999 \
    -selector unix:path:/usr/bin/redis-server \
    -ttl 3600

Entry ID: entry-003
✅ Created


STEP 5: Workloads Start and Get SVIDs
══════════════════════════════════════════════════════════════

Inside VM:

# postgres starts (UID 70, PID 5678)
$ systemctl start postgresql

postgres connects to agent socket
→ VM Agent identifies: unix:uid:70, unix:path:/usr/bin/postgres
→ Queries SPIRE Server
→ SPIRE finds Entry #entry-002 ✅
→ Issues SVID: spiffe://.../vm/database-vm/postgres
✅ postgres has identity!

# redis starts (UID 999, PID 9012)
$ systemctl start redis

redis connects to agent socket
→ VM Agent identifies: unix:uid:999, unix:path:/usr/bin/redis-server
→ Queries SPIRE Server
→ SPIRE finds Entry #entry-003 ✅
→ Issues SVID: spiffe://.../vm/database-vm/redis
✅ redis has identity!


STEP 6: Verify
══════════════════════════════════════════════════════════════

# Inside VM, check identities
$ spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock

Found 2 SVIDs:
  SPIFFE ID: spiffe://.../vm/database-vm/postgres
  SPIFFE ID: spiffe://.../vm/database-vm/redis

✅ Each workload has unique identity!
```

---

## The Parent-Child Authorization Model

### Why Parent ID Matters

The parent ID enforces **delegation of authority**:

```
SPIRE Server says:
  "I trust the VM with SPIFFE ID spiffe://.../vm/app-vm"
  "That VM can request SVIDs for its workloads"
  "But only for entries where parent = VM's SPIFFE ID"

Security properties:
  ✅ VM-A cannot request SVIDs for workloads in VM-B
  ✅ A compromised VM can only affect its own workloads
  ✅ Clear trust boundaries
```

### Example: Cross-VM Attack Prevention

```
Scenario: VM-A tries to get SVID for workload in VM-B

VM-A's SPIFFE ID: spiffe://.../vm/vm-a
VM-B's SPIFFE ID: spiffe://.../vm/vm-b

Registration entry for postgres in VM-B:
  Parent: spiffe://.../vm/vm-b
  SPIFFE ID: spiffe://.../vm/vm-b/postgres
  Selectors: unix:uid:70

Attack: VM-A tries to request postgres SVID

VM-A's agent queries server:
  "Give me SVID for:
   Parent: spiffe://.../vm/vm-a (VM-A's ID)
   Selectors: unix:uid:70"

SPIRE Server searches:
  Looking for entry where:
    Parent = spiffe://.../vm/vm-a
    Selectors match unix:uid:70
  
  postgres entry has:
    Parent = spiffe://.../vm/vm-b ← Different!
  
  ❌ No match found!

Attack prevented ✅

VM-A can only request SVIDs for entries where parent = VM-A's SPIFFE ID
```

---

## Viewing Registration Entries

### List All Entries

```bash
# List all registration entries
kubectl exec -n spire spire-server-0 -- \
  spire-server entry show

# Output:
Entry ID         : entry-001
SPIFFE ID        : spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm
Parent ID        : spiffe://example.org/spire/server
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : kubevirt:vm-namespace:prod
Selector         : kubevirt:vm-name:app-vm

Entry ID         : entry-002
SPIFFE ID        : spiffe://example.org/ns/prod/vm/app-vm/nginx
Parent ID        : spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm
Revision         : 0
X509-SVID TTL    : 3600
JWT-SVID TTL     : default
Selector         : unix:uid:33
Selector         : unix:path:/usr/sbin/nginx

Entry ID         : entry-003
SPIFFE ID        : spiffe://example.org/ns/prod/vm/app-vm/postgres
Parent ID        : spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm
Revision         : 0
X509-SVID TTL    : 3600
JWT-SVID TTL     : default
Selector         : unix:uid:70
Selector         : unix:path:/usr/bin/postgres
```

### Filter by Parent

```bash
# Show only entries for a specific VM
kubectl exec -n spire spire-server-0 -- \
  spire-server entry show \
    -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/prod/vm/app-vm

# Shows: nginx, postgres, redis entries (children of this VM)
```

### Show Specific Entry

```bash
# Show details of a specific entry
kubectl exec -n spire spire-server-0 -- \
  spire-server entry show \
    -entryID entry-002

# Or by SPIFFE ID
kubectl exec -n spire spire-server-0 -- \
  spire-server entry show \
    -spiffeID spiffe://example.org/ns/prod/vm/app-vm/nginx
```

---

## Updating and Deleting Entries

### Update an Entry

```bash
# Update TTL for nginx entry
kubectl exec -n spire spire-server-0 -- \
  spire-server entry update \
    -entryID entry-002 \
    -ttl 7200

# Add a selector
kubectl exec -n spire spire-server-0 -- \
  spire-server entry update \
    -entryID entry-002 \
    -selector unix:gid:33
```

### Delete an Entry

```bash
# Delete postgres entry
kubectl exec -n spire spire-server-0 -- \
  spire-server entry delete \
    -entryID entry-003

# After deletion, postgres cannot get new SVIDs
# Existing SVIDs remain valid until they expire
```

---

## Automatic Node Entry Creation (Advanced)

For **VM node entries**, you might want automatic creation when VMs attest. This requires modifying the attestor plugin to support **"registration on first attest"**.

### Current Behavior (Manual)

```
1. VM tries to attest
2. No registration entry exists
3. Attestation fails ❌
4. Admin creates entry manually
5. VM attests again
6. Attestation succeeds ✅
```

### Enhanced Behavior (Automatic - Future Enhancement)

```go
// In server-side KubeVirt attestor plugin
func (p *Plugin) Attest(stream nodeattestorv1.NodeAttestor_AttestServer) error {
    // ... receive and validate VM ...
    
    // Check if entry exists
    entry := p.findExistingEntry(vmiNamespace, vmiName)
    if entry == nil {
        // Auto-create entry on first attest
        entry = p.createNodeEntry(vmiNamespace, vmiName, vmiUID)
    }
    
    // Issue SVID
    // ...
}
```

This would make it **fully automatic** - VMs can attest without pre-creating entries!

---

## Registration Entry Best Practices

### Practice 1: Pre-Register VMs

```
✅ DO: Create VM node entries before VMs boot
   Benefit: VM can attest immediately
   
❌ DON'T: Wait for attestation to fail
   Problem: Delays VM initialization
```

### Practice 2: Use Specific Selectors

```
✅ DO: Use multiple selectors for specificity
   -selector unix:uid:33
   -selector unix:path:/usr/sbin/nginx
   
❌ DON'T: Use only UID
   -selector unix:uid:33
   Problem: Any process with UID 33 matches
```

### Practice 3: Document Your Entries

```
✅ DO: Keep a registry of entries
   Entry #entry-002: nginx in database-vm (UID 33)
   Entry #entry-003: postgres in database-vm (UID 70)
   
✅ DO: Use descriptive SPIFFE IDs
   spiffe://.../vm/database-vm/postgres-primary
   
❌ DON'T: Use cryptic IDs
   spiffe://.../vm/vm1/app1
```

### Practice 4: Set Appropriate TTLs

```
For VMs (node entries):
  Use default (usually 1 hour)
  VMs are long-lived, rotation is fine

For workloads:
  Short-lived workloads: 1 hour
  Long-lived services: 2-4 hours
  Critical services: 1 hour (more frequent rotation)
```

---

## Troubleshooting Registration Issues

### Problem: VM Cannot Attest

```
Symptom:
  VM SPIRE Agent logs: "Attestation failed: no matching entry"

Diagnosis:
  $ kubectl exec -n spire spire-server-0 -- \
    spire-server entry show -parentID spiffe://example.org/spire/server
  
  Check: Is there an entry for this VM?

Solution:
  Create node entry for the VM (see Method 1 above)
```

### Problem: Workload Cannot Get SVID

```
Symptom:
  Application error: "Failed to fetch SVID"
  
Diagnosis:
  1. Check VM has node SVID:
     $ spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock
  
  2. Check entry exists:
     $ kubectl exec -n spire spire-server-0 -- \
       spire-server entry show -parentID spiffe://.../vm/my-vm
  
  3. Check selectors match:
     Inside VM: ps aux | grep nginx
     Check: UID 33, path /usr/sbin/nginx

Solution:
  Create workload entry with correct selectors
```

### Problem: Wrong SVID Issued

```
Symptom:
  nginx gets postgres SVID (wrong identity!)

Diagnosis:
  Check selectors overlap:
  $ kubectl exec -n spire spire-server-0 -- \
    spire-server entry show
  
  Both entries might have: unix:uid:33

Solution:
  Make selectors more specific:
  • Add path selector
  • Add GID selector
  • Use SHA256 of binary
```

---

## Registration Entry Lifecycle

### Entry States

```
┌──────────────────────────────────────────────────────┐
│  Registration Entry Lifecycle                        │
└──────────────────────────────────────────────────────┘

Created:
  Entry is in database
  Can be discovered by agents
  Can issue SVIDs

Updated:
  Selectors or SPIFFE ID changed
  Revision number increments
  Existing SVIDs unaffected until expiry

Deleted:
  Entry removed from database
  Cannot issue new SVIDs
  Existing SVIDs valid until expiry (grace period)
```

### SVID Rotation with Entries

```
T+0h:    Entry created, workload gets SVID (valid 1h)
T+0.5h:  SPIRE Agent pre-fetches new SVID (at 50% lifetime)
T+1h:    Old SVID expires, new SVID active
T+1.5h:  Pre-fetch next SVID
T+2h:    Rotation again

Entry unchanged, but SVIDs rotate automatically!
```

---

## Advanced: Dynamic Entry Generation

### Using VM Annotations

You can annotate VMs to define workloads:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: app-vm
  annotations:
    spire.io/workloads: |
      [
        {
          "name": "nginx",
          "uid": 33,
          "path": "/usr/sbin/nginx"
        },
        {
          "name": "app-server",
          "uid": 1000,
          "path": "/opt/app/server"
        }
      ]
```

A controller watches this annotation and creates entries automatically!

### Using ConfigMap for Entry Templates

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vm-workload-templates
  namespace: spire
data:
  nginx: |
    selectors:
      - unix:uid:33
      - unix:path:/usr/sbin/nginx
    ttl: 3600
  
  postgres: |
    selectors:
      - unix:uid:70
      - unix:path:/usr/bin/postgres
    ttl: 3600
```

Controller reads this ConfigMap and creates entries for each VM that needs them.

---

## Summary

### Key Points

1. **Registration entries must be created explicitly** - they don't appear automatically
2. **Parent ID links entries in a hierarchy** - VM is parent of its workloads
3. **Selectors determine who gets which identity** - match based on characteristics
4. **Multiple creation methods exist** - CLI, API, controllers, declarative
5. **Entries are policies** - define who gets what identity

### The Relationship

```
Registration Entry (Policy):
  "If workload matches these selectors,
   and is a child of this parent,
   give it this SPIFFE ID"

VM Attestation:
  VM proves it matches node entry
  → Gets node SVID

Workload Attestation:
  App proves it matches workload entry
  → Gets workload SVID

Without registration entries:
  ❌ No identity can be issued
  ❌ Attestation fails
```

### Operational Flow

```
1. Deploy SPIRE Server
2. Create node registration entry for VM
3. Deploy VM
4. VM attests → gets node SVID
5. Create workload registration entries
6. Workloads connect → get workload SVIDs
7. Identity system is operational!
```

---

## Practical Example: Complete Script

Here's a complete script to register a VM and its workloads:

```bash
#!/bin/bash
# register-vm-workloads.sh

SPIRE_SERVER_POD=$(kubectl get pod -n spire -l app=spire-server -o jsonpath='{.items[0].metadata.name}')
VM_NAMESPACE="production"
VM_NAME="database-vm"
VM_UID=$(kubectl get vmi -n $VM_NAMESPACE $VM_NAME -o jsonpath='{.metadata.uid}')

echo "Registering VM: $VM_NAMESPACE/$VM_NAME"

# 1. Create node entry for VM
kubectl exec -n spire $SPIRE_SERVER_POD -- \
  spire-server entry create \
    -parentID spiffe://example.org/spire/server \
    -spiffeID spiffe://example.org/k8s-cluster/my-cluster/ns/$VM_NAMESPACE/vm/$VM_NAME \
    -selector kubevirt:vm-namespace:$VM_NAMESPACE \
    -selector kubevirt:vm-name:$VM_NAME \
    -selector kubevirt:vm-uid:$VM_UID \
    -node

echo "VM node entry created"

# 2. Register postgres
kubectl exec -n spire $SPIRE_SERVER_POD -- \
  spire-server entry create \
    -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/$VM_NAMESPACE/vm/$VM_NAME \
    -spiffeID spiffe://example.org/ns/$VM_NAMESPACE/vm/$VM_NAME/postgres \
    -selector unix:uid:70 \
    -selector unix:path:/usr/bin/postgres

echo "postgres entry created"

# 3. Register redis
kubectl exec -n spire $SPIRE_SERVER_POD -- \
  spire-server entry create \
    -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/$VM_NAMESPACE/vm/$VM_NAME \
    -spiffeID spiffe://example.org/ns/$VM_NAMESPACE/vm/$VM_NAME/redis \
    -selector unix:uid:999 \
    -selector unix:path:/usr/bin/redis-server

echo "redis entry created"

echo "✅ All entries created for $VM_NAME"

# 4. Verify
kubectl exec -n spire $SPIRE_SERVER_POD -- \
  spire-server entry show \
    -parentID spiffe://example.org/k8s-cluster/my-cluster/ns/$VM_NAMESPACE/vm/$VM_NAME

echo "✅ Registration complete!"
```

Save as `deploy/register-vm-workloads.sh` and use:

```bash
chmod +x deploy/register-vm-workloads.sh
./deploy/register-vm-workloads.sh
```

---

## Future Enhancement: Automatic Registration

For production, consider building automation:

### Option 1: Operator-Based

Extend your Zero Trust Workload Identity Manager operator to:
1. Watch for VirtualMachine CRs
2. Automatically create node entries
3. Read workload annotations
4. Create workload entries

### Option 2: GitOps-Based

Store entries in Git:
```
repo/
  spire-entries/
    vms/
      production/
        database-vm.yaml
    workloads/
      production/
        database-vm/
          postgres.yaml
          redis.yaml
```

ArgoCD applies them automatically!

### Option 3: Dynamic Registration API

Build an API service that:
1. VMs call on boot: "Register me!"
2. Service validates VM (check KubeVirt API)
3. Service creates entries in SPIRE
4. Returns success

---

## Key Takeaway

**Registration entries are the "configuration" that tells SPIRE who should get which identity.**

- Created by: Administrator or automation
- Stored in: SPIRE Server database
- Used by: SPIRE Server during attestation
- Define: Parent-child relationships and selector matching

**Without registration entries, no identities can be issued!**

They're like firewall rules - you must explicitly define what's allowed.

---

See `PROBLEM-AND-SOLUTION.md` for how entries fit into the complete attestation flow!
