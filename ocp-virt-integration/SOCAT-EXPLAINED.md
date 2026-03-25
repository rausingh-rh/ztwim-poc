# socat Explained: The Simple Bridge Solution

## What is socat?

**socat** = **SOcket CAT** (like `cat` but for sockets)

**In simple terms**: socat is a command-line tool that **connects two things together** and **copies data between them**.

**Analogy**: Think of socat like a pipe or cable that connects two endpoints and passes everything through bidirectionally.

---

## Basic socat Concept

### The Problem socat Solves

You have two programs that need to talk to each other, but they use **different types of connections**:

```
Program A speaks: Type X (e.g., Unix socket)
Program B speaks: Type Y (e.g., TCP)

Problem: They can't talk directly!

Solution: socat bridges them
  Program A ←[Type X]→ socat ←[Type Y]→ Program B
```

socat acts as a **translator** - it reads from one side and writes to the other.

---

## socat Examples (Simple)

### Example 1: Copy Between Two Files

```bash
# Read from file1, write to file2
socat FILE:/tmp/input.txt FILE:/tmp/output.txt

# Like: cat /tmp/input.txt > /tmp/output.txt
```

### Example 2: TCP Server to File

```bash
# Listen on TCP port 8080, write everything to a file
socat TCP-LISTEN:8080 FILE:/tmp/data.log

# When someone connects to port 8080, data goes to file
```

### Example 3: Bridge Two TCP Connections

```bash
# Forward local port 8080 to remote server
socat TCP-LISTEN:8080 TCP:example.com:80

# Connections to localhost:8080 → forwarded to → example.com:80
```

**Key concept**: socat connects two different types of endpoints and forwards data!

---

## Our Use Case: VSOCK to TCP Bridge

### The Problem

```
VM wants to talk to SPIRE Server:

VM (VSOCK) ❌ Cannot directly talk to ❌ SPIRE Server (TCP)
           Different protocols!

VM only knows: VSOCK (host-guest sockets)
SPIRE Server only knows: TCP (network sockets)

Need: Something to bridge them!
```

### The socat Solution

```
VM (VSOCK) ←→ socat ←→ SPIRE Server (TCP)
           Bridge!

socat command:
  socat VSOCK-LISTEN:8081,fork TCP:spire-server:8081
        ↑                        ↑
    Listen on VSOCK          Forward to TCP
```

**What this does**:
1. **Left side**: Listen for VSOCK connections on port 8081
2. **Right side**: When connection comes in, open TCP connection to spire-server:8081
3. **Middle**: Copy data bidirectionally (VM ↔ Server)

---

## Breaking Down Our socat Command

### The Complete Command

```bash
socat VSOCK-LISTEN:8081,fork,reuseaddr TCP:spire-server.zero-trust-workload-identity-manager.svc.cluster.local:8081
```

**Part 1: `socat`**
- The program name

**Part 2: `VSOCK-LISTEN:8081,fork,reuseaddr`**
- `VSOCK-LISTEN`: Listen for VSOCK connections (wait for VMs to connect)
- `:8081`: On port 8081
- `,fork`: Create new process for each connection (handle multiple VMs)
- `,reuseaddr`: Allow restarting socat quickly (don't wait for port timeout)

**Part 3: `TCP:spire-server.zero-trust-workload-identity-manager.svc.cluster.local:8081`**
- `TCP:`: Connect via TCP
- `spire-server.zero-trust-workload-identity-manager.svc.cluster.local`: DNS name of SPIRE Server
- `:8081`: Port 8081 (SPIRE Server's gRPC port)

---

## How It Works: Step by Step

### Scenario: VM Connects to SPIRE Server

```
┌────────────────────────────────────────────────────────┐
│  Step 1: VM Creates VSOCK Connection                   │
└────────────────────────────────────────────────────────┘

Inside VM:
  socket(AF_VSOCK, SOCK_STREAM)
  connect((2, 8081))  # Connect to host (CID 2), port 8081

VSOCK kernel → Delivers connection to host

┌────────────────────────────────────────────────────────┐
│  Step 2: socat Accepts Connection                      │
└────────────────────────────────────────────────────────┘

socat (running on host):
  VSOCK-LISTEN:8081 → Receives connection from VM
  fork → Creates new process to handle this connection

socat logs: "Accepted connection from VSOCK CID 3218942031"

┌────────────────────────────────────────────────────────┐
│  Step 3: socat Opens TCP Connection                    │
└────────────────────────────────────────────────────────┘

socat:
  TCP:spire-server...:8081 → Opens TCP connection to SPIRE Server
  
socat now has TWO connections open:
  • VSOCK connection to VM (left side)
  • TCP connection to SPIRE Server (right side)

┌────────────────────────────────────────────────────────┐
│  Step 4: VM Sends Data                                 │
└────────────────────────────────────────────────────────┘

VM → VSOCK:
  Sends gRPC request (SPIRE protocol)

VSOCK kernel → Delivers to socat

socat:
  Reads from VSOCK
  Writes to TCP
  → Data goes to SPIRE Server

┌────────────────────────────────────────────────────────┐
│  Step 5: SPIRE Server Responds                         │
└────────────────────────────────────────────────────────┘

SPIRE Server → TCP:
  Sends gRPC response

TCP → Arrives at socat

socat:
  Reads from TCP
  Writes to VSOCK
  → Data goes back to VM

┌────────────────────────────────────────────────────────┐
│  Step 6: Ongoing Bidirectional Communication           │
└────────────────────────────────────────────────────────┘

socat continuously copies data:
  VM → VSOCK → socat → TCP → Server
  Server → TCP → socat → VSOCK → VM

Transparent forwarding! ✅
```

---

## Why socat is Perfect for This

### Advantages

✅ **Standard tool** - Widely available, well-tested
```
$ socat -V
socat version 1.7.4.4
```

✅ **One command** - No custom code needed
```
socat VSOCK-LISTEN:8081,fork TCP:server:8081
# That's it! ~100 characters
```

✅ **Small image** - Alpine with socat is ~10MB
```
image: alpine/socat:latest
```

✅ **Transparent** - Doesn't parse or modify data
```
Copies bytes as-is, no protocol knowledge needed
```

✅ **Reliable** - Used in production everywhere
```
socat has been around since 2001, battle-tested
```

---

## Comparison: socat vs Custom Proxy

### Custom Proxy (What We Initially Built)

```go
// Custom Go code (~150 lines)
vsockConn := vsock.Listen(8081)
tcpConn := net.Dial("tcp", "spire-server:8081")

// Forward data
go io.Copy(tcpConn, vsockConn)  // VM → Server
io.Copy(vsockConn, tcpConn)      // Server → VM
```

**Pros**:
- Can add logging, metrics
- Full control over behavior
- Can filter/transform

**Cons**:
- Custom code to maintain
- Need to build and distribute
- More complex

---

### socat (Standard Tool)

```bash
# One command (~40 characters)
socat VSOCK-LISTEN:8081,fork TCP:spire-server:8081
```

**Pros**:
- ✅ No custom code!
- ✅ Standard tool (everyone knows it)
- ✅ Smaller image
- ✅ Less maintenance

**Cons**:
- Basic logging only
- Can't customize behavior easily

**For most use cases: socat wins on simplicity!** ✅

---

## socat in Your Architecture

### Where socat Runs

```
┌──────────────────────────────────────────────────────┐
│  Kubernetes Worker Node                              │
│                                                      │
│  ┌────────────────────────────────────────────────┐ │
│  │  virt-launcher Pod                             │ │
│  │                                                │ │
│  │  ┌──────────────────────────────────────────┐ │ │
│  │  │  Container: compute                      │ │ │
│  │  │  (runs the VM with QEMU)                 │ │ │
│  │  └──────────────────────────────────────────┘ │ │
│  │                                                │ │
│  │  ┌──────────────────────────────────────────┐ │ │
│  │  │  Container: socat ← HERE!                │ │ │
│  │  │                                          │ │ │
│  │  │  Command:                                │ │ │
│  │  │  socat VSOCK-LISTEN:8081,fork \          │ │ │
│  │  │        TCP:spire-server:8081             │ │ │
│  │  │                                          │ │ │
│  │  │  Listens: VSOCK port 8081               │ │ │
│  │  │  Forwards: To SPIRE Server TCP           │ │ │
│  │  └──────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────┘ │
│           ↕ VSOCK                                    │
│  ┌────────────────────────────────────────────────┐ │
│  │  Virtual Machine (Guest)                       │ │
│  │                                                │ │
│  │  SPIRE Agent connects to:                     │ │
│  │  vsock://2:8081 (host, port 8081)             │ │
│  └────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

**socat runs in virt-launcher pod**, not in the VM!

---

## Why Run socat on Host (Not in VM)?

### Option A: socat in VM

```
Pros:
  • Creates Unix socket in VM (/run/spire/sockets/agent.sock)
  • SPIRE Agent connects to local socket (familiar path)

Cons:
  ❌ Must install socat in every VM image
  ❌ Per-VM configuration
  ❌ Harder to update (distributed across VMs)
  ❌ VM image modifications required
```

### Option B: socat on Host (Our Approach)

```
Pros:
  ✅ No VM image modifications needed
  ✅ Works with any VM image
  ✅ Centrally managed (operator injects it)
  ✅ Easy to update (change operator)
  ✅ Consistent for all VMs

Cons:
  • SPIRE Agent in VM uses vsock:// URL (not local Unix socket)
  
But: SPIRE supports vsock:// natively in server_address!
```

**Host-side is operationally better!** ✅

---

## The Complete Flow with socat

### Data Path Visualization

```
┌─────────────┐
│  redis      │  Application in VM
│  (UID 999)  │
└──────┬──────┘
       │ Unix socket: /run/spire/sockets/agent.sock
       ▼
┌─────────────────────────┐
│  SPIRE Agent (in VM)    │
│  • Identifies: uid:999  │
│  • Queries server       │
└──────┬──────────────────┘
       │ VSOCK: vsock://2:8081
       ▼
       🌉 VSOCK (guest → host communication)
       ▼
┌─────────────────────────┐
│  socat (on host)        │
│  • Accepts VSOCK        │
│  • Forwards to TCP      │
└──────┬──────────────────┘
       │ TCP: spire-server:8081
       ▼
┌─────────────────────────┐
│  SPIRE Server           │
│  • Finds entry          │
│  • Issues SVID          │
└──────┬──────────────────┘
       │ Response
       ▼
       TCP → socat → VSOCK → VM Agent → redis
       
redis receives SVID! ✅
```

**socat is the bridge in the middle!**

---

## socat Command Breakdown (In Detail)

### Our Command

```bash
socat VSOCK-LISTEN:8081,fork,reuseaddr TCP:spire-server.zero-trust-workload-identity-manager.svc.cluster.local:8081
│     │                               │
│     └─ Listen side (source)         └─ Connect side (destination)
└─ Program name
```

### Left Side: `VSOCK-LISTEN:8081,fork,reuseaddr`

**VSOCK-LISTEN**:
- Protocol: VSOCK (virtual sockets)
- Direction: LISTEN (wait for incoming connections)
- Like: Server side of a socket

**:8081**:
- Port number: 8081
- VMs will connect to this port

**,fork**:
- Create new process for each connection
- Allows handling multiple VMs simultaneously
- Without fork: Only one connection at a time

**,reuseaddr**:
- Allow reusing the address immediately
- Without this: Must wait after restart
- Good for development/testing

**Together**: "Listen on VSOCK port 8081, handle multiple connections"

---

### Right Side: `TCP:spire-server...svc.cluster.local:8081`

**TCP**:
- Protocol: TCP (network sockets)
- Direction: CONNECT (client side)
- Like: Client side of a socket

**:spire-server...svc.cluster.local**:
- Hostname: Kubernetes service DNS name
- Resolves to: SPIRE Server pod IP

**:8081**:
- Port: 8081 (SPIRE Server's gRPC port)

**Together**: "Connect to SPIRE Server via TCP on port 8081"

---

## What socat Actually Does

### The Forwarding Process

```
When a VM connects:

1. Accept VSOCK connection from VM
   ↓
2. Open TCP connection to SPIRE Server
   ↓
3. Start two copying loops in parallel:
   
   Loop A (VM → Server):
   • Read bytes from VSOCK
   • Write bytes to TCP
   • Repeat continuously
   
   Loop B (Server → VM):
   • Read bytes from TCP
   • Write bytes to VSOCK
   • Repeat continuously
   
4. Continue until connection closes

Bidirectional data flow! ✅
```

**socat doesn't understand SPIRE protocol** - it just copies bytes!

---

## Why This Works

### Protocol Transparency

```
socat doesn't need to understand:
  ❌ What SPIRE is
  ❌ What gRPC is
  ❌ What the data means
  ❌ How to parse messages

socat only needs to:
  ✅ Accept connections
  ✅ Forward connections
  ✅ Copy bytes

This is why it's so simple and reliable!
```

**Like a network cable** - doesn't care what data flows through it!

---

## socat Deployment in Kubernetes

### The Pod Spec

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vsock-socat-bridge
spec:
  nodeName: gcp08feb1-sc4px-worker-d-jncnr  # Same node as VM
  hostNetwork: true  # Access to host's network namespace
  containers:
  - name: socat
    image: alpine/socat:latest  # Small Alpine Linux with socat
    command:
    - socat
    - -d            # Debug mode (some logging)
    - -d            # More debug (verbose logging)
    - VSOCK-LISTEN:8081,fork,reuseaddr
    - TCP:spire-server.zero-trust-workload-identity-manager.svc.cluster.local:8081
    securityContext:
      privileged: true  # Needs access to VSOCK devices
  restartPolicy: Always
```

### Why These Settings?

**nodeName**: Must run on same node as VM
- VSOCK only works between host and guest on same physical machine
- Can't bridge VSOCK across network

**hostNetwork: true**: Uses host's network namespace
- Can access host's VSOCK devices
- Can reach Kubernetes services

**privileged: true**: Needs elevated permissions
- Access to /dev/vsock device
- Create VSOCK sockets

**image: alpine/socat:latest**: Tiny container
- Alpine Linux base (~5MB)
- socat tool pre-installed
- Total: ~10MB image

---

## Seeing socat in Action

### socat Logs

When you run `oc logs vsock-socat-bridge`, you'll see:

```
2026/02/08 13:30:00 socat[1] N starting up
2026/02/08 13:30:00 socat[1] N listening on AF=40 0.0.0.0:8081
2026/02/08 13:30:15 socat[1] N accepting connection from AF=40 3218942031:random-port
2026/02/08 13:30:15 socat[123] N forked off child process
2026/02/08 13:30:15 socat[123] N opening connection to AF=2 10.131.0.123:8081
2026/02/08 13:30:15 socat[123] N successfully connected
2026/02/08 13:30:15 socat[123] N starting data transfer loop
```

**This shows**:
- socat listening on VSOCK
- Connection from VM (CID 3218942031)
- Opening TCP to SPIRE Server
- Data transfer started

---

## Testing the Bridge

### Simple Connection Test

```bash
# Inside VM
python3 << 'EOF'
import socket

# Create VSOCK socket
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)

# Connect to host (CID 2), port 8081
s.connect((2, 8081))

# Send test data
s.send(b"Hello from VM!")

# Try to receive (will fail if SPIRE Server, but connection works)
print("✅ Connected via VSOCK!")

s.close()
EOF
```

**If "Connected" prints**: socat bridge is working! ✅

---

## Why socat Instead of Custom Code?

### The Simplicity Argument

**Custom Go proxy we built**:
```
Code: ~150 lines Go
Dependencies: github.com/mdlayher/vsock, logrus
Build: Need Go compiler
Image: Custom Dockerfile
Result: Custom binary (~4MB)
```

**socat**:
```
Code: 0 lines (use existing tool)
Dependencies: None (pre-installed in alpine)
Build: None (use alpine/socat image)
Image: Public image (alpine/socat)
Result: Standard tool (~10MB including Alpine)
```

**Winner**: socat (simpler, no maintenance) ✅

---

## Alternative socat Modes (For Reference)

### Different Ways to Use socat

**Our use (VSOCK to TCP)**:
```bash
socat VSOCK-LISTEN:8081 TCP:spire-server:8081
```

**Could also do (TCP to VSOCK)**:
```bash
socat TCP-LISTEN:8080 VSOCK-CONNECT:3:8081
# Listen on TCP, forward to VM with CID 3
```

**Or (Unix socket to VSOCK)**:
```bash
socat UNIX-LISTEN:/tmp/socket VSOCK-CONNECT:2:8081
```

**socat is very flexible!** We're using one specific pattern for our use case.

---

## Troubleshooting socat

### Common Issues

**Issue**: socat won't start
```
Error: Permission denied

Fix: Need privileged: true
     Need access to /dev/vsock
```

**Issue**: Connection refused from VM
```
Error: Connection refused on vsock://2:8081

Fix: Check socat is running (oc logs vsock-socat-bridge)
     Check socat on correct node (same as VM)
```

**Issue**: socat starts but no forwarding
```
Error: Can't reach SPIRE Server

Fix: Check DNS resolution (spire-server.ns.svc.cluster.local)
     Check SPIRE Server is listening on 8081
```

---

## Summary

### What is socat?

**socat** = A versatile tool for connecting and forwarding between different types of sockets/connections.

### How we use it?

```
socat VSOCK-LISTEN:8081,fork TCP:spire-server:8081

Translates: VSOCK ↔ TCP
Purpose: Bridge VM (VSOCK) to SPIRE Server (TCP)
Result: VM can talk to SPIRE Server ✅
```

### Why socat?

- ✅ Standard tool (no custom code)
- ✅ Simple (one command)
- ✅ Reliable (battle-tested)
- ✅ Small (tiny container)
- ✅ Transparent (just forwards bytes)

**Perfect for our use case!** ✅

---

## Your Next Step

**Now that you understand socat**, deploy it and test:

```bash
# 1. Deploy socat bridge (from END-TO-END-POC.md Phase 1)
# 2. Test VSOCK connection (from Phase 2)
# 3. Continue with SPIRE Agent setup (Phase 3-5)
```

**You have VSOCK working (/dev/vsock exists), so you're ready!** 🚀

---

**See**: `END-TO-END-POC.md` for complete step-by-step testing!
