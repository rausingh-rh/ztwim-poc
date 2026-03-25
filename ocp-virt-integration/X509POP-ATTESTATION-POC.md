# PoC: X.509 Proof-of-Possession (x509pop) Attestation for VM SPIRE Agents

**Status**: Proposed  
**Date**: March 21, 2026  
**Builds On**: Join Token PoC (February 26-27, 2026)  
**Goal**: Replace join_token node attestation with x509pop to gain re-attestation support without writing a custom KubeVirt attestor plugin

---

## 0. Complete Step-by-Step Walkthrough — What to Run and When

This section gives you the full picture: which steps from the original PoC (`COMPLETE-WORKING-STEPS.md`) you reuse as-is, and exactly where you switch to x509pop-specific steps.

### Step Map

```
Original PoC Step                     This PoC (x509pop)
═══════════════                       ══════════════════

Step 1:  Install operators            ──▶ REUSE AS-IS
Step 2:  Enable VSOCK feature gate    ──▶ REUSE AS-IS
Step 3:  Enable VSOCK on VM           ──▶ REUSE AS-IS
Step 4:  Deploy VSOCK bridge on host  ──▶ REUSE AS-IS
Step 5:  Verify VSOCK in VM           ──▶ REUSE AS-IS
Step 6:  Install apps in VM           ──▶ REUSE AS-IS
Step 7:  Install socat in VM          ──▶ REUSE AS-IS
Step 8:  Start VSOCK bridge in VM     ──▶ REUSE AS-IS
Step 9:  Install SPIRE agent binary   ──▶ REUSE AS-IS
                                      ┌───────────────────────────────────────┐
                                      │  ⚡ DIVERGE HERE — x509pop steps     │
                                      │                                       │
Step 10: Configure SPIRE agent        │  REPLACE with x509pop agent config    │
Step 11: Generate join token          │  SKIP — replaced by cert provisioning │
Step 12: Start SPIRE agent            │  REPLACE — no -joinToken flag         │
                                      │  NEW: Test re-attestation             │
                                      └───────────────────────────────────────┘
Step 13: Create registration entries  ──▶ REUSE (only parent ID changes)
Step 14: Test SVID issuance           ──▶ REUSE AS-IS
Step 15: Test SVID rotation           ──▶ REUSE AS-IS
```

### The Complete Sequence You Should Follow

Run these steps in this exact order. Steps marked **(original)** come from `COMPLETE-WORKING-STEPS.md`. Steps marked **(x509pop)** come from this document (Section 6).

```
PHASE A: Infrastructure (all from original PoC — no changes)
────────────────────────────────────────────────────────────
A1.  Install Zero Trust operator + operand          (original Step 1)
A2.  Install OpenShift Virtualization operator       (original Step 1)
A3.  Enable VSOCK feature gate                       (original Step 2)
A4.  Enable VSOCK on VM + restart VM                 (original Step 3)
A5.  Deploy socat bridge pod on host                 (original Step 4)
A6.  Verify VSOCK in VM                              (original Step 5)


PHASE B: VM Setup (all from original PoC — no changes)
──────────────────────────────────────────────────────
B1.  Install applications in VM (Redis, Postgres)    (original Step 6)
B2.  Install socat in VM                             (original Step 7)
B3.  Start socat bridge in VM                        (original Step 8)
B4.  Download and install SPIRE agent binary in VM   (original Step 9)
B5.  Get trust bundle from SPIRE Server              (original Step 10.1 + 10.2)
     Save to /opt/spire/bundle.pem in VM


PHASE C: x509pop Certificate Setup (NEW — from this document)
─────────────────────────────────────────────────────────────
C1.  Create a CA for VM agent certificates           (x509pop Section 6, Step 1)
     → Run on workstation: generates ca.key + ca.crt

C2.  Generate unique certificate for the VM          (x509pop Section 6, Step 2)
     → Run on workstation: generates agent-cert.pem + agent-key.pem

C3.  Mount CA bundle into SPIRE Server               (x509pop Section 6, Step 4)
     → On workstation: create ConfigMap, patch StatefulSet
     → Add x509pop NodeAttestor to server config
     → Restart SPIRE Server

C4.  Copy cert + key into VM                         (x509pop Section 6, Step 6)
     → In VM: save agent-cert.pem and agent-key.pem


PHASE D: Agent Configuration and Start (REPLACES original Steps 10-12)
──────────────────────────────────────────────────────────────────────
D1.  Create agent config with x509pop                (x509pop Section 6, Step 7)
     → In VM: write agent.conf with NodeAttestor "x509pop"

D2.  Start SPIRE Agent — NO join token needed        (x509pop Section 6, Step 8)
     → In VM: spire-agent run -config agent.conf
     → Verify "Node attestation was successful" in logs
     → Verify SPIFFE ID shows x509pop/<vm-name>

D3.  Test re-attestation (NEW — critical test)       (x509pop Section 6, Step 9)
     → In VM: kill agent, restart, verify it re-attests


PHASE E: Registration and Testing (from original PoC — minor changes)
─────────────────────────────────────────────────────────────────────
E1.  Create registration entries                     (original Step 13)
     ⚠️  Use the new parent ID format:
     OLD: spiffe://.../spire/agent/join_token/<uuid>
     NEW: spiffe://.../spire/agent/x509pop/<vm-name>

E2.  Test SVID issuance                              (original Step 14)
     → In VM: fetch SVIDs for Redis and Postgres

E3.  Test SVID rotation                              (original Step 15)
     → In VM: observe automatic rotation
```

### Visual Timeline

```
Time ──────────────────────────────────────────────────────────────────────▶

│ PHASE A: Infrastructure  │ PHASE B: VM Setup │ PHASE C: Certs  │ PHASE D+E  │
│ (original Steps 1-5)     │ (original 6-9)    │ (NEW x509pop)   │ Agent+Test │
│                           │                   │                  │            │
│ On workstation:           │ Inside VM:        │ On workstation:  │ Inside VM: │
│ • Install operators       │ • Install apps    │ • Create CA      │ • Config   │
│ • VSOCK setup             │ • Install socat   │ • Gen VM cert    │ • Start    │
│ • Deploy bridge pod       │ • Start bridge    │ • Server config  │ • Test     │
│                           │ • Install agent   │                  │            │
│                           │ • Trust bundle    │ In VM:           │ On workst: │
│                           │                   │ • Copy cert+key  │ • Reg.     │
│                           │                   │                  │   entries  │
```

### What Gets Skipped

These original PoC steps are **not needed** with x509pop:

| Original Step | Why Skipped |
|---|---|
| **Step 10.3**: Create agent config with `join_token` | Replaced by x509pop config (Phase D1) |
| **Step 11**: Generate join token on server | Not needed — certificate replaces token |
| **Step 12**: Start agent with `-joinToken` flag | Replaced — agent starts without any token (Phase D2) |

---

## 1. Why Replace join_token?

The original PoC used `join_token` for VM agent attestation. While it worked, it has critical limitations:

| Limitation | Impact |
|---|---|
| **One-time use** | Token consumed on first attestation; cannot be reused |
| **No re-attestation** | Agent crashes after ~30 minutes when SVID expires and re-attestation fails |
| **Manual token generation** | Operator must generate and deliver a token per VM per attestation |
| **Not production-viable** | Requires manual intervention on every agent restart |

---

## 2. What is x509pop? — Conceptual Deep Dive

The `x509pop` (X.509 Proof-of-Possession) plugin is a **built-in SPIRE node attestor** that attests agents using pre-provisioned X.509 certificates. It is shipped with SPIRE out of the box — no custom plugin development required.

### 2.1 The Two Separate PKI Systems

A critical concept to understand: there are **two completely independent PKI systems** involved, and they serve different purposes:

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  PKI #1: The x509pop Identity PKI                                       │
│  ─────────────────────────────────                                       │
│  Purpose: Prove "I am a legitimate VM agent"                             │
│  Used during: Node attestation (agent ↔ server handshake)               │
│  Who creates it: YOU (the cluster operator)                              │
│                                                                          │
│  Components:                                                             │
│    • CA private key (ca.key) — signs VM certificates, kept secret        │
│    • CA certificate (ca.crt) — given to SPIRE Server for verification    │
│    • Per-VM private key (agent-key.pem) — stays inside the VM            │
│    • Per-VM certificate (agent-cert.pem) — signed by CA, given to VM     │
│                                                                          │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  PKI #2: SPIRE's Internal PKI (Trust Bundle)                            │
│  ───────────────────────────────────────────                             │
│  Purpose: Issue SVIDs to workloads + secure agent-server TLS             │
│  Used during: TLS connection, SVID issuance                              │
│  Who creates it: SPIRE Server (automatically)                            │
│                                                                          │
│  Components:                                                             │
│    • SPIRE CA key — managed by SPIRE Server internally                   │
│    • Trust bundle (bundle.pem) — given to agents for TLS verification    │
│    • Workload SVIDs — short-lived certs issued to Redis, Postgres, etc.  │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

These two PKI systems are **completely unrelated**. The x509pop CA has nothing to do with the SPIRE trust bundle. They use different keys, different CAs, and serve different purposes.

### 2.2 Which Keys Exist and Where They Live

Here is every key and certificate involved, where it lives, and what it does:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  YOUR WORKSTATION (or cert-manager)                                      │
│                                                                          │
│  ca.key (PRIVATE)  ── The x509pop CA's private key                      │
│  │                    Used ONLY to sign VM agent certificates.           │
│  │                    NEVER leaves your workstation / cert-manager.      │
│  │                    If compromised, attacker can forge VM identities.  │
│  │                                                                       │
│  ca.crt (PUBLIC)   ── The x509pop CA's certificate                      │
│  │                    Contains the CA's PUBLIC key.                      │
│  │                    Distributed to SPIRE Server (ca_bundle_path).      │
│  │                    Not secret — it's safe to share.                   │
│  │                                                                       │
│  ▼                                                                       │
│  For each VM, you generate:                                              │
│    agent-key.pem (PRIVATE) ── VM-specific private key                   │
│    agent-cert.pem (PUBLIC) ── Certificate signed by ca.key              │
│                                Contains the VM's public key             │
│                                Contains CN=<vm-name>                    │
└──────────────────────────────────────────────────────────────────────────┘

Distribution:

  ca.crt ──────────────────────▶ SPIRE Server (mounted at ca_bundle_path)

  agent-cert.pem + agent-key.pem ──▶ Inside each VM (unique per VM)

  bundle.pem (SPIRE trust bundle) ──▶ Inside each VM (from SPIRE Server)
```

**Summary table:**

| Key / Certificate | Type | Lives On | Purpose | Secret? |
|---|---|---|---|---|
| `ca.key` | Private key | Workstation / cert-manager | Signs VM agent certificates | **YES — most sensitive** |
| `ca.crt` | Certificate (public) | SPIRE Server + optionally VMs | Verifies VM agent certificates | No |
| `agent-key.pem` | Private key | Inside VM only | Proves possession during attestation | **YES — never leaves VM** |
| `agent-cert.pem` | Certificate (public) | Inside VM (sent to server during attestation) | Identifies the VM agent | No |
| `bundle.pem` | Certificate (public) | Inside VM | Verifies SPIRE Server's TLS identity | No |
| SPIRE CA key | Private key | Inside SPIRE Server only | Issues workload SVIDs | **YES — managed by SPIRE** |

### 2.3 The Attestation Flow — Step by Step

```
     VM (SPIRE Agent)                                SPIRE Server
     ════════════════                                ════════════
     Has: agent-key.pem (private)                    Has: ca.crt (CA certificate)
          agent-cert.pem (signed by CA)                   SPIRE CA key (for SVIDs)
          bundle.pem (SPIRE trust bundle)


 ── STEP 1: TLS Connection ──────────────────────────────────────────────

     Agent connects to server via TLS.
     Agent uses bundle.pem to verify the server's TLS certificate.
     This ensures the agent is talking to the real SPIRE Server.

     Agent ─────────── TLS handshake (using SPIRE trust bundle) ──────▶ Server


 ── STEP 2: Agent Presents Its Certificate ──────────────────────────────

     Agent sends agent-cert.pem to the server.
     This certificate contains:
       • The agent's PUBLIC key
       • CN=rhel9-magenta-gull-92 (VM identity)
       • Issuer: vm-spire-ca (who signed it)
       • Signature from the CA's private key

     Agent ─────────── "Here is my certificate" ─────────────────────▶ Server

                                                      Server checks:
                                                      1. Is this cert signed by my ca.crt?
                                                         (verify signature using CA's public key)
                                                      2. Is the cert expired?
                                                      3. Does it have digitalSignature KeyUsage?
                                                      4. Is the cert unique (not used by another agent)?

                                                      If any check fails → REJECT


 ── STEP 3: Server Issues Proof-of-Possession Challenge ────────────────

     The certificate check alone is NOT enough.
     Anyone could COPY agent-cert.pem (it's not secret).
     The server needs to verify the agent has the PRIVATE key.

     Server generates a random nonce (random bytes).

     Agent ◀────────── "Sign this random nonce" ─────────────────────── Server


 ── STEP 4: Agent Signs the Challenge ───────────────────────────────────

     Agent uses agent-key.pem (its PRIVATE key) to sign the nonce.
     Only the holder of the private key can produce a valid signature.
     The private key NEVER leaves the VM — only the signature is sent.

     Agent ─────────── "Here is the signed nonce" ───────────────────▶ Server

                                                      Server verifies the signature
                                                      using the PUBLIC key from
                                                      agent-cert.pem.

                                                      Signature valid?
                                                      ✅ YES → Agent proved it has the private key
                                                      ❌ NO  → REJECT (cert was copied/stolen)


 ── STEP 5: Agent Gets Its SPIFFE ID ───────────────────────────────────

     Server assigns SPIFFE ID based on the certificate:

     spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/
       spire/agent/x509pop/rhel9-magenta-gull-92

     Server issues an Agent SVID (short-lived certificate from SPIRE's
     own PKI — this is PKI #2, completely separate from x509pop).

     Agent ◀────────── "You are authenticated. Here is your SVID" ──── Server


 ── ON RESTART: Same Flow Repeats ──────────────────────────────────────

     Because agent-cert.pem and agent-key.pem persist on disk,
     the agent can repeat Steps 1-5 on every restart.

     This is why x509pop supports re-attestation and join_token does not.
     (join_token is consumed on first use and deleted from the server.)
```

### 2.4 Why "Proof of Possession" Matters

The name "x509pop" specifically refers to the proof-of-possession challenge (Steps 3-4). Here's why it's essential:

```
Without PoP (just checking the certificate):

  Attacker copies agent-cert.pem from VM ──▶ Presents it to server
  Server checks: "Certificate is valid" ✅
  Attacker gets SVID ← SECURITY BREACH!

With PoP (x509pop):

  Attacker copies agent-cert.pem from VM ──▶ Presents it to server
  Server checks: "Certificate is valid" ✅
  Server: "Sign this random challenge"
  Attacker: ❌ Cannot sign — doesn't have agent-key.pem
  Attestation FAILS ← SECURE!
```

The certificate (public) can be freely shared or even intercepted — it doesn't matter. Only the holder of the private key can pass the PoP challenge.

### 2.5 Why x509pop Solves Our Problems

| Problem with join_token | How x509pop Fixes It |
|---|---|
| Cannot re-attest | Certificate persists on disk; agent can re-attest on restart |
| One-time use | Same certificate used for every attestation |
| Manual token per attestation | Certificate provisioned once, used indefinitely |
| Agent crashes after ~30 min | Agent re-attests automatically when SVID nears expiry |
| No production path | x509pop is production-grade and used widely |

---

## 3. Can We Use Let's Encrypt?

**No. Let's Encrypt is not suitable for x509pop.** Here are the specific reasons:

### 3.1 Domain Identity vs Node Identity

Let's Encrypt proves: *"I control the domain example.com"*
x509pop needs to prove: *"I am VM rhel9-magenta-gull-92"*

These are fundamentally different identity claims. Let's Encrypt validates domain ownership via ACME challenges (HTTP-01 or DNS-01). There is no domain involved in a VM's SPIRE agent identity.

### 3.2 ACME Challenge Is Impossible Inside a KubeVirt VM

Let's Encrypt requires the certificate requester to prove domain ownership by:
- **HTTP-01**: Serving a specific file on port 80 of the domain — VMs on VSOCK have no public HTTP endpoint
- **DNS-01**: Creating a DNS TXT record — VMs don't control DNS
- **TLS-ALPN-01**: Serving a special TLS cert on port 443 — same problem as HTTP-01

A KubeVirt VM behind VSOCK simply cannot complete any of these challenges.

### 3.3 Critical Security Problem: Trust Scope

With x509pop, the SPIRE Server is configured with `ca_bundle_path` — it trusts **only** certificates signed by that specific CA. This is the security boundary:

```
Private CA (you control):
  ✅ Only certs YOU signed can attest → you control who can be a VM agent
  ✅ Rogue agents cannot forge certificates without your CA key

Let's Encrypt (public CA):
  ❌ ANYONE in the world can get a Let's Encrypt certificate
  ❌ If SPIRE Server trusts the Let's Encrypt root CA, any Let's Encrypt
     certificate holder could attest as a VM agent → COMPLETE SECURITY BREACH
```

You must use a **private CA that you control** so that only certificates you intentionally sign can pass attestation.

### 3.4 Certificate Type Mismatch

| Requirement | Let's Encrypt Certs | x509pop Needs |
|---|---|---|
| Key Usage | `serverAuth` (TLS servers) | `digitalSignature` (signing challenges) |
| Subject | Domain name (CN/SAN) | VM name (CN) |
| Validity | 90 days | Any (1 year recommended) |
| Issuance | Automated via ACME | Via your private CA |
| Trust scope | Public (anyone can get one) | Private (only your VMs) |

### 3.5 What to Use Instead

| Option | Best For | Complexity |
|---|---|---|
| **OpenSSL self-signed CA** | PoC, small deployments | Low |
| **cert-manager with self-signed issuer** | Production on OpenShift/K8s | Medium |
| **HashiCorp Vault PKI** | Enterprise with existing Vault | Medium-High |
| **Red Hat IdM / FreeIPA** | Environments with existing IdM | Medium |
| **AWS Private CA / GCP CAS** | Cloud-native deployments | Medium |

For this PoC, **OpenSSL self-signed CA** is recommended. For production, **cert-manager** is ideal since it already runs on OpenShift and can auto-renew certificates.

---

## 4. Feasibility Assessment: Can We Use x509pop for KubeVirt VMs?

> Sections 5 onwards contain the hands-on implementation steps — continue reading from section 4.

**Yes. x509pop is fully feasible for KubeVirt VMs.**

### Requirements

x509pop requires each VM agent to have:
1. A **unique X.509 leaf certificate** (one per VM)
2. The corresponding **private key**
3. Optionally, **intermediate certificates** if the CA chain has intermediates

The SPIRE Server needs:
1. The **CA bundle** that signed the VM certificates

### Can We Meet These Requirements?

| Requirement | How to Meet It in KubeVirt | Feasible? |
|---|---|---|
| Unique cert per VM | Generate via cert-manager, custom CA, or Kubernetes CSR API | Yes |
| Private key in VM | Inject via cloud-init (Secret reference) or ConfigMap | Yes |
| CA bundle on server | Mount CA cert into SPIRE Server pod | Yes |
| Certificate persistence | Store on VM filesystem, survives reboots | Yes |

### Does This Eliminate the Need for a Custom KubeVirt Attestor?

**For most use cases, yes.** x509pop provides:
- Re-attestation support
- No custom plugin development
- Production-grade security
- Works with the existing SPIRE binary

A custom KubeVirt attestor would still be more "native" (the VM proves identity via the KubeVirt API without pre-provisioned certs), but x509pop is a strong intermediate solution that avoids the 3-4 weeks of custom plugin development.

The trade-off is that x509pop requires an **out-of-band certificate provisioning mechanism**, whereas a KubeVirt attestor would derive identity directly from the platform. In practice, cert provisioning can be fully automated with cert-manager + cloud-init, making this trade-off acceptable.

---

## 5. Architecture

### Certificate Provisioning Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│  OpenShift Cluster (Control Plane)                                  │
│                                                                     │
│  ┌──────────────────┐     ┌──────────────────────────────────────┐ │
│  │  cert-manager     │     │  Kubernetes Secret                   │ │
│  │  (or custom CA)   │────▶│  vm-<name>-spire-cert                │ │
│  │                   │     │    tls.crt: <leaf cert>              │ │
│  │  Issues unique    │     │    tls.key: <private key>            │ │
│  │  cert per VM      │     │    ca.crt:  <CA bundle>             │ │
│  └──────────────────┘     └───────────────┬──────────────────────┘ │
│                                            │                        │
│                              cloud-init    │  (Secret mounted       │
│                              injects cert  │   into VM via          │
│                              into VM       │   cloudInitNoCloud)    │
│                                            ▼                        │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  KubeVirt VM                                                  │  │
│  │                                                               │  │
│  │  /opt/spire/agent-cert.pem  ◀── leaf certificate             │  │
│  │  /opt/spire/agent-key.pem   ◀── private key                  │  │
│  │  /opt/spire/bundle.pem      ◀── SPIRE trust bundle           │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  SPIRE Agent (NodeAttestor "x509pop")                   │ │  │
│  │  │  Presents cert + proves private key possession          │ │  │
│  │  └────────────────────────┬────────────────────────────────┘ │  │
│  │                           │ TCP → socat → VSOCK               │  │
│  └───────────────────────────┼───────────────────────────────────┘  │
│                              │                                      │
│  ┌───────────────────────────▼───────────────────────────────────┐  │
│  │  SPIRE Server                                                  │  │
│  │  NodeAttestor "x509pop" {                                     │  │
│  │    ca_bundle_path = "/opt/spire/conf/server/vm-ca-bundle.pem" │  │
│  │  }                                                             │  │
│  │                                                                │  │
│  │  1. Verifies cert chains to CA bundle                         │  │
│  │  2. Issues PoP challenge                                      │  │
│  │  3. Assigns SPIFFE ID based on cert fingerprint               │  │
│  └────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### Attestation Flow (Detailed)

```
VM SPIRE Agent                              SPIRE Server
     │                                           │
     │  1. Present X.509 leaf certificate        │
     │──────────────────────────────────────────▶│
     │                                           │  2. Verify cert chains to
     │                                           │     ca_bundle_path
     │                                           │
     │                                           │  3. Cert is valid and unique
     │                                           │
     │  4. Proof-of-Possession challenge         │
     │◀──────────────────────────────────────────│
     │                                           │
     │  5. Sign challenge with private key       │
     │──────────────────────────────────────────▶│
     │                                           │
     │                                           │  6. Verify signature
     │                                           │
     │  7. Agent SVID issued                     │
     │◀──────────────────────────────────────────│
     │                                           │
     │  SPIFFE ID:                               │
     │  spiffe://trust_domain/spire/agent/       │
     │    x509pop/<sha1_fingerprint>             │
     │                                           │

     ── On agent restart or SVID expiry ──

     │  Same flow repeats with same certificate  │
     │  ✅ Re-attestation succeeds               │
```

---

## 6. Implementation Steps

### Prerequisites

Everything from the original PoC remains the same:
- Zero Trust Workload Identity Manager operator installed
- OpenShift Virtualization operator installed
- VSOCK enabled (feature gate + VM annotation)
- socat bridges deployed (host-side and VM-side)

The **only changes** are in certificate provisioning and agent/server configuration.

---

### Step 1: Create a CA for VM Agent Certificates

We need a Certificate Authority to sign the per-VM certificates. There are three options:

#### Option A: Use cert-manager (Recommended for production)

```bash
# Install cert-manager if not already present
# (skip if already installed)
oc apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Wait for cert-manager to be ready
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s
oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s
```

Create a self-signed issuer and a CA:

```yaml
# vm-spire-ca.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vm-spire-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vm-spire-ca
  namespace: zero-trust-workload-identity-manager
spec:
  isCA: true
  commonName: vm-spire-ca
  subject:
    organizations:
      - "SPIRE VM Agents"
  secretName: vm-spire-ca-secret
  duration: 87600h  # 10 years
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: vm-spire-selfsigned
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vm-spire-ca-issuer
  namespace: zero-trust-workload-identity-manager
spec:
  ca:
    secretName: vm-spire-ca-secret
```

```bash
oc apply -f vm-spire-ca.yaml
```

#### Option B: Use OpenSSL (Simpler, good for PoC)

```bash
# Create a CA for signing VM agent certificates
mkdir -p /tmp/vm-spire-ca

# Generate CA private key
openssl ecparam -genkey -name prime256v1 -out /tmp/vm-spire-ca/ca.key

# Generate CA certificate (valid 10 years)
openssl req -new -x509 -key /tmp/vm-spire-ca/ca.key \
  -out /tmp/vm-spire-ca/ca.crt \
  -days 3650 \
  -subj "/C=US/O=SPIRE VM Agents/CN=vm-spire-ca"

echo "CA certificate created:"
openssl x509 -in /tmp/vm-spire-ca/ca.crt -noout -subject -dates
```

#### Option C: Use Kubernetes CSR API

Use `kubectl create csr` with a custom signer. This is more complex and not recommended for initial PoC.

---

### Step 2: Generate a Unique Certificate Per VM

Each VM needs its own certificate. The Common Name or a SAN should identify the VM.

#### Using OpenSSL (PoC approach)

```bash
VM_NAME="rhel9-magenta-gull-92"
VM_NAMESPACE="openshift-cnv"
TRUST_DOMAIN="apps.gcp26feb.gcp.devcluster.openshift.com"

# Generate private key for the VM agent
openssl ecparam -genkey -name prime256v1 \
  -out /tmp/vm-spire-ca/${VM_NAME}.key

# Create CSR with the VM name as CN
openssl req -new \
  -key /tmp/vm-spire-ca/${VM_NAME}.key \
  -out /tmp/vm-spire-ca/${VM_NAME}.csr \
  -subj "/C=US/O=SPIRE VM Agents/CN=${VM_NAME}"

# Sign the certificate with our CA (valid 1 year)
openssl x509 -req \
  -in /tmp/vm-spire-ca/${VM_NAME}.csr \
  -CA /tmp/vm-spire-ca/ca.crt \
  -CAkey /tmp/vm-spire-ca/ca.key \
  -CAcreateserial \
  -out /tmp/vm-spire-ca/${VM_NAME}.crt \
  -days 365 \
  -extensions v3_req \
  -extfile <(cat <<EXTEOF
[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
EXTEOF
)

# Verify the certificate
echo "=== VM Agent Certificate ==="
openssl x509 -in /tmp/vm-spire-ca/${VM_NAME}.crt -noout -subject -issuer -dates
echo ""
echo "=== Fingerprint (will become part of SPIFFE ID) ==="
openssl x509 -in /tmp/vm-spire-ca/${VM_NAME}.crt -noout -fingerprint -sha1
```

**Expected output:**
```
=== VM Agent Certificate ===
subject=C=US, O=SPIRE VM Agents, CN=rhel9-magenta-gull-92
issuer=C=US, O=SPIRE VM Agents, CN=vm-spire-ca
notBefore=Mar 21 00:00:00 2026 GMT
notAfter=Mar 21 00:00:00 2027 GMT

=== Fingerprint (will become part of SPIFFE ID) ===
sha1 Fingerprint=AB:CD:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF:12
```

#### Using cert-manager (Production approach)

```yaml
# vm-agent-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vm-rhel9-magenta-gull-92-spire-agent
  namespace: zero-trust-workload-identity-manager
spec:
  secretName: vm-rhel9-magenta-gull-92-spire-cert
  commonName: rhel9-magenta-gull-92
  subject:
    organizations:
      - "SPIRE VM Agents"
  duration: 8760h  # 1 year
  renewBefore: 720h  # Renew 30 days before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - digital signature
    - client auth
  issuerRef:
    name: vm-spire-ca-issuer
    kind: Issuer
```

```bash
oc apply -f vm-agent-cert.yaml

# Verify the secret was created
oc get secret vm-rhel9-magenta-gull-92-spire-cert \
  -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -dates
```

---

### Step 3: Create a Kubernetes Secret with the VM Certificate

Store the certificate and key in a Secret that cloud-init can reference:

```bash
VM_NAME="rhel9-magenta-gull-92"
VM_NAMESPACE="openshift-cnv"

# If using OpenSSL-generated certs:
oc create secret generic ${VM_NAME}-spire-cert \
  -n ${VM_NAMESPACE} \
  --from-file=agent-cert.pem=/tmp/vm-spire-ca/${VM_NAME}.crt \
  --from-file=agent-key.pem=/tmp/vm-spire-ca/${VM_NAME}.key \
  --from-file=ca-bundle.pem=/tmp/vm-spire-ca/ca.crt
```

---

### Step 4: Configure the SPIRE Server for x509pop

The SPIRE Server needs the CA bundle that signed the VM certificates. Since we are using the Zero Trust Workload Identity Manager operator, we need to either:

**Option A: Mount the CA bundle into the SPIRE Server pod**

```bash
# Create a ConfigMap with the CA bundle in the SPIRE namespace
oc create configmap vm-agent-ca-bundle \
  -n zero-trust-workload-identity-manager \
  --from-file=vm-ca-bundle.pem=/tmp/vm-spire-ca/ca.crt
```

Then patch the SPIRE Server StatefulSet to mount it:

```bash
oc patch statefulset spire-server \
  -n zero-trust-workload-identity-manager \
  --type='json' \
  -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/volumes/-",
      "value": {
        "name": "vm-agent-ca-bundle",
        "configMap": {
          "name": "vm-agent-ca-bundle"
        }
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts/-",
      "value": {
        "name": "vm-agent-ca-bundle",
        "mountPath": "/opt/spire/conf/server/vm-ca-bundle.pem",
        "subPath": "vm-ca-bundle.pem",
        "readOnly": true
      }
    }
  ]'
```

**Option B: Append x509pop config to the SPIRE Server configuration**

Edit the SPIRE Server ConfigMap to add the x509pop NodeAttestor plugin:

```bash
# Get current SPIRE server config
oc get configmap spire-server-config \
  -n zero-trust-workload-identity-manager \
  -o yaml > /tmp/spire-server-config-backup.yaml
```

Add the following plugin block to the SPIRE Server configuration alongside the existing `k8s_psat` attestor:

```hcl
NodeAttestor "x509pop" {
    plugin_data {
        ca_bundle_path = "/opt/spire/conf/server/vm-ca-bundle.pem"

        # Customize agent SPIFFE ID format to include the VM's CN
        agent_path_template = "{{ .PluginName }}/{{ .Subject.CommonName }}"
    }
}
```

With the `agent_path_template` above, the resulting agent SPIFFE ID will be:
```
spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/x509pop/rhel9-magenta-gull-92
```

This is much more readable than the default SHA1 fingerprint format.

**Important**: SPIRE supports multiple NodeAttestor plugins simultaneously. The existing `k8s_psat` attestor for Kubernetes node agents will continue to work alongside `x509pop` for VM agents.

After modifying the ConfigMap, restart the SPIRE Server:

```bash
oc rollout restart statefulset/spire-server -n zero-trust-workload-identity-manager
oc rollout status statefulset/spire-server -n zero-trust-workload-identity-manager
```

---

### Step 5: Inject Certificate into VM via cloud-init

Update the VirtualMachine definition to inject the certificate files using cloud-init:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: rhel9-magenta-gull-92
  namespace: openshift-cnv
spec:
  template:
    spec:
      domain:
        devices:
          autoattachVSOCK: true
          # ... other device config
      volumes:
      - name: spire-agent-cert
        secret:
          secretName: rhel9-magenta-gull-92-spire-cert
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            write_files:
            - path: /opt/spire/conf/agent/agent.conf
              permissions: '0644'
              content: |
                agent {
                    data_dir = "/var/lib/spire/agent"
                    log_level = "DEBUG"
                    server_address = "127.0.0.1"
                    server_port = "8081"
                    socket_path = "/run/spire/sockets/agent.sock"
                    trust_domain = "apps.gcp26feb.gcp.devcluster.openshift.com"
                    trust_bundle_path = "/opt/spire/bundle.pem"
                }
                plugins {
                    NodeAttestor "x509pop" {
                        plugin_data {
                            private_key_path = "/opt/spire/conf/agent/agent-key.pem"
                            certificate_path = "/opt/spire/conf/agent/agent-cert.pem"
                        }
                    }
                    KeyManager "disk" {
                        plugin_data {
                            directory = "/var/lib/spire/agent"
                        }
                    }
                    WorkloadAttestor "unix" {
                        plugin_data {}
                    }
                }
            runcmd:
            - mkdir -p /opt/spire/conf/agent /var/lib/spire/agent /run/spire/sockets
```

If cloud-init secret injection is not straightforward for your VM setup, you can also manually copy the files (for PoC purposes).

---

### Step 6: Manual Certificate Installation in VM (PoC Shortcut)

For the PoC, you can copy the certificate files into the VM manually:

**On workstation — base64 encode the files:**

```bash
VM_NAME="rhel9-magenta-gull-92"

echo "=== Certificate (copy this) ==="
cat /tmp/vm-spire-ca/${VM_NAME}.crt
echo ""
echo "=== Private Key (copy this) ==="
cat /tmp/vm-spire-ca/${VM_NAME}.key
```

**In VM — save the files:**

```bash
# Create directory
sudo mkdir -p /opt/spire/conf/agent

# Paste the certificate
sudo vi /opt/spire/conf/agent/agent-cert.pem
# (paste certificate content and save)

# Paste the private key
sudo vi /opt/spire/conf/agent/agent-key.pem
# (paste private key content and save)

# Secure the private key
sudo chmod 600 /opt/spire/conf/agent/agent-key.pem

# Verify
echo "=== Certificate ==="
openssl x509 -in /opt/spire/conf/agent/agent-cert.pem -noout -subject -dates
echo ""
echo "=== Key matches certificate? ==="
CERT_MD5=$(openssl x509 -in /opt/spire/conf/agent/agent-cert.pem -noout -modulus 2>/dev/null | md5sum)
KEY_MD5=$(openssl ec -in /opt/spire/conf/agent/agent-key.pem -noout -text 2>/dev/null | md5sum)
# For EC keys, verify differently:
openssl ec -in /opt/spire/conf/agent/agent-key.pem -pubout 2>/dev/null | md5sum
openssl x509 -in /opt/spire/conf/agent/agent-cert.pem -pubkey -noout 2>/dev/null | md5sum
# These two md5sums should match
```

---

### Step 7: Configure SPIRE Agent for x509pop

**In VM — create the agent configuration:**

```bash
sudo tee /opt/spire/conf/agent/agent.conf << 'EOF'
agent {
    data_dir = "/var/lib/spire/agent"
    log_level = "DEBUG"

    server_address = "127.0.0.1"
    server_port = "8081"

    socket_path = "/run/spire/sockets/agent.sock"
    trust_domain = "apps.gcp26feb.gcp.devcluster.openshift.com"
    trust_bundle_path = "/opt/spire/bundle.pem"
}

plugins {
    NodeAttestor "x509pop" {
        plugin_data {
            private_key_path = "/opt/spire/conf/agent/agent-key.pem"
            certificate_path = "/opt/spire/conf/agent/agent-cert.pem"
        }
    }

    KeyManager "disk" {
        plugin_data {
            directory = "/var/lib/spire/agent"
        }
    }

    WorkloadAttestor "unix" {
        plugin_data {}
    }
}
EOF
```

Key differences from the join_token configuration:
- `NodeAttestor` changed from `"join_token"` to `"x509pop"`
- `private_key_path` and `certificate_path` added
- No `-joinToken` flag needed when starting the agent

---

### Step 8: Start SPIRE Agent (No Join Token Needed)

```bash
# Ensure prerequisites
sudo mkdir -p /run/spire/sockets /var/lib/spire/agent

# Ensure socat bridge is running
ps aux | grep socat | grep -v grep
# If not running:
# sudo socat TCP-LISTEN:8081,fork,reuseaddr VSOCK-CONNECT:2:8081 &

# Start SPIRE Agent — NO joinToken flag!
sudo /usr/local/bin/spire-agent run \
  -config /opt/spire/conf/agent/agent.conf \
  > /tmp/spire-agent.log 2>&1 &

# Check logs
tail -f /tmp/spire-agent.log
```

**Expected log output (success):**
```
INFO[0000] Starting agent  data_dir=/var/lib/spire/agent version=1.13.3
INFO[0000] Plugin loaded  plugin_name=x509pop plugin_type=NodeAttestor
INFO[0000] Plugin loaded  plugin_name=disk plugin_type=KeyManager
INFO[0000] Plugin loaded  plugin_name=unix plugin_type=WorkloadAttestor
INFO[0000] Bundle loaded  trust_domain_id="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com"
INFO[0000] SVID is not found. Starting node attestation
INFO[0001] Node attestation was successful
INFO[0001] Agent SVID loaded  spiffe_id="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/x509pop/rhel9-magenta-gull-92"
INFO[0001] Starting Workload and SDS APIs  address=/run/spire/sockets/agent.sock
```

Note the SPIFFE ID format: `spiffe://.../spire/agent/x509pop/rhel9-magenta-gull-92` (when using the CN-based template) or `spiffe://.../spire/agent/x509pop/<sha1_fingerprint>` (default).

---

### Step 9: Test Re-Attestation

This is the critical test that differentiates x509pop from join_token.

```bash
# In VM — kill the agent
sudo pkill -9 spire-agent

# Wait a moment
sleep 5

# Restart the agent — same command, NO new token needed
sudo /usr/local/bin/spire-agent run \
  -config /opt/spire/conf/agent/agent.conf \
  > /tmp/spire-agent.log 2>&1 &

# Check logs — should show successful re-attestation
tail -20 /tmp/spire-agent.log
```

**Expected output:**
```
INFO[0000] Starting agent  data_dir=/var/lib/spire/agent version=1.13.3
INFO[0000] Plugin loaded  plugin_name=x509pop plugin_type=NodeAttestor
INFO[0000] Node attestation was successful           ← RE-ATTESTATION WORKS!
INFO[0001] Agent SVID loaded  spiffe_id="spiffe://...x509pop/rhel9-magenta-gull-92"
INFO[0001] Starting Workload and SDS APIs
```

With join_token, this restart would have **failed** because the token was already consumed. With x509pop, the agent uses the same persistent certificate and successfully re-attests.

---

### Step 10: Create Registration Entries

Registration entries work the same way as in the join_token PoC. The only difference is the parent ID format.

```bash
export KUBECONFIG=/home/rausingh/Documents/gcp_cluster/26Feb2026/auth/kubeconfig

# List agents — find the x509pop agent
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server agent list
```

**Expected output will show:**
```
SPIFFE ID         : spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/x509pop/rhel9-magenta-gull-92
Attestation type  : x509pop
Can re-attest     : true       ← KEY DIFFERENCE: true instead of false!
```

**Create registration entries using the new agent ID:**

```bash
# With CN-based template
AGENT_ID="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/x509pop/rhel9-magenta-gull-92"

# Or with default SHA1 fingerprint template — get it from agent list output
# AGENT_ID="spiffe://apps.gcp26feb.gcp.devcluster.openshift.com/spire/agent/x509pop/<fingerprint>"

APP_DOMAIN="apps.gcp26feb.gcp.devcluster.openshift.com"
VM_NAME="rhel9-magenta-gull-92"

echo "Creating entry for Redis (UID 994)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://$APP_DOMAIN/vm/$VM_NAME/redis \
    -selector unix:uid:994 \
    -x509SVIDTTL 120

echo ""
echo "Creating entry for Postgres (UID 26)..."
oc exec -n zero-trust-workload-identity-manager spire-server-0 -- \
  ./spire-server entry create \
    -parentID "$AGENT_ID" \
    -spiffeID spiffe://$APP_DOMAIN/vm/$VM_NAME/postgres \
    -selector unix:uid:26 \
    -x509SVIDTTL 180
```

---

### Step 11: Verify SVID Issuance and Rotation

Same as the original PoC:

```bash
# In VM
sudo -u redis /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock

sudo -u postgres /usr/local/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock
```

Expected output is identical to the join_token PoC — workloads receive their SVIDs.

---

## 7. Configuration Reference

### Agent Configuration (x509pop)

```hcl
agent {
    data_dir = "/var/lib/spire/agent"
    log_level = "DEBUG"
    server_address = "127.0.0.1"
    server_port = "8081"
    socket_path = "/run/spire/sockets/agent.sock"
    trust_domain = "apps.gcp26feb.gcp.devcluster.openshift.com"
    trust_bundle_path = "/opt/spire/bundle.pem"
}

plugins {
    NodeAttestor "x509pop" {
        plugin_data {
            private_key_path = "/opt/spire/conf/agent/agent-key.pem"
            certificate_path = "/opt/spire/conf/agent/agent-cert.pem"
            # intermediates_path = "/opt/spire/conf/agent/intermediates.pem"  # if needed
        }
    }

    KeyManager "disk" {
        plugin_data {
            directory = "/var/lib/spire/agent"
        }
    }

    WorkloadAttestor "unix" {
        plugin_data {}
    }
}
```

### Server Configuration (x509pop — add alongside existing k8s_psat)

```hcl
NodeAttestor "x509pop" {
    plugin_data {
        ca_bundle_path = "/opt/spire/conf/server/vm-ca-bundle.pem"

        # Recommended: use CN-based SPIFFE IDs for readability
        agent_path_template = "{{ .PluginName }}/{{ .Subject.CommonName }}"

        # Defaults (usually fine as-is)
        # max_intermediates = 4
        # max_rsa_key_size = 8192
    }
}
```

### Server Selectors Available for x509pop Agents

When creating registration entries, you can use these selectors for x509pop-attested agents:

| Selector | Example | Description |
|---|---|---|
| `x509pop:subject:cn` | `x509pop:subject:cn:rhel9-magenta-gull-92` | Match by certificate Common Name |
| `x509pop:ca:fingerprint` | `x509pop:ca:fingerprint:<hex>` | Match by CA fingerprint |
| `x509pop:serialnumber` | `x509pop:serialnumber:<hex>` | Match by leaf cert serial number |

These selectors can be used on the **server side** to create node-level registration entries that are automatically inherited by workload entries. For example, you could create a parent entry matching all VMs signed by a specific CA.

---

## 8. Comparison: join_token vs x509pop vs KubeVirt Attestor

| Feature | join_token (original PoC) | x509pop (this PoC) | KubeVirt Attestor (future) |
|---|---|---|---|
| **Re-attestation** | No | Yes | Yes |
| **Agent survives restart** | No (~30 min limit) | Yes (indefinitely) | Yes |
| **Manual step per attestation** | Generate token | None (after initial cert) | None |
| **Custom plugin needed** | No | No | Yes (3-4 weeks) |
| **Certificate provisioning** | N/A | Required (one-time per VM) | N/A |
| **Security model** | Shared secret (token) | PKI (certificate + key) | Platform identity |
| **Production-grade** | No | Yes | Yes |
| **Automation potential** | Low | High (cert-manager + cloud-init) | Highest |
| **Agent SPIFFE ID format** | `.../join_token/<uuid>` | `.../x509pop/<CN or fingerprint>` | `.../kubevirt/<vm-uid>` |
| **Selectors available** | None | CN, CA fingerprint, serial | VM name, namespace, labels |
| **Upstream support** | Built-in | Built-in | Must be contributed upstream |
| **Development effort** | None | None | 3-4 weeks |

---

## 9. Certificate Lifecycle Management

### Certificate Rotation

The x509pop identity certificate is **not** the workload SVID. It is only used for agent-to-server attestation. The lifecycle is:

| Concern | Strategy |
|---|---|
| **Initial provisioning** | cloud-init + Kubernetes Secret (or manual for PoC) |
| **Certificate validity** | Set long validity (1 year+); not a security-sensitive credential since SPIRE issues short-lived SVIDs on top |
| **Certificate renewal** | cert-manager auto-renews; for manual CA, regenerate before expiry |
| **Private key protection** | File permissions 600; accessible only to root (SPIRE agent runs as root) |
| **Revocation** | Delete the agent entry from SPIRE Server; agent cannot re-attest with revoked cert |

### Automating Certificate Provisioning for Multiple VMs

For multiple VMs, automate certificate generation with a script:

```bash
#!/bin/bash
# generate-vm-cert.sh — Generate and store a SPIRE agent certificate for a VM

VM_NAME=$1
VM_NAMESPACE=${2:-openshift-cnv}
CA_DIR="/tmp/vm-spire-ca"

if [ -z "$VM_NAME" ]; then
  echo "Usage: $0 <vm-name> [namespace]"
  exit 1
fi

# Generate key
openssl ecparam -genkey -name prime256v1 -out ${CA_DIR}/${VM_NAME}.key 2>/dev/null

# Generate CSR
openssl req -new \
  -key ${CA_DIR}/${VM_NAME}.key \
  -out ${CA_DIR}/${VM_NAME}.csr \
  -subj "/C=US/O=SPIRE VM Agents/CN=${VM_NAME}" 2>/dev/null

# Sign with CA
openssl x509 -req \
  -in ${CA_DIR}/${VM_NAME}.csr \
  -CA ${CA_DIR}/ca.crt \
  -CAkey ${CA_DIR}/ca.key \
  -CAcreateserial \
  -out ${CA_DIR}/${VM_NAME}.crt \
  -days 365 \
  -extensions v3_req \
  -extfile <(printf "[v3_req]\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = clientAuth") 2>/dev/null

# Create Kubernetes secret
oc create secret generic ${VM_NAME}-spire-cert \
  -n ${VM_NAMESPACE} \
  --from-file=agent-cert.pem=${CA_DIR}/${VM_NAME}.crt \
  --from-file=agent-key.pem=${CA_DIR}/${VM_NAME}.key \
  --from-file=ca-bundle.pem=${CA_DIR}/ca.crt \
  --dry-run=client -o yaml | oc apply -f -

echo "Certificate created for VM: ${VM_NAME}"
echo "  Secret: ${VM_NAME}-spire-cert in namespace ${VM_NAMESPACE}"
echo "  SPIFFE ID will be: spiffe://<trust_domain>/spire/agent/x509pop/${VM_NAME}"
```

Usage:
```bash
./generate-vm-cert.sh rhel9-magenta-gull-92
./generate-vm-cert.sh rhel9-another-vm-01
./generate-vm-cert.sh rhel9-another-vm-02
```

---

## 10. What Changes from the Original PoC

### Changes Required

| Component | Original PoC (join_token) | This PoC (x509pop) |
|---|---|---|
| **SPIRE Server config** | Only `k8s_psat` attestor | Add `x509pop` attestor alongside `k8s_psat` |
| **SPIRE Server volume** | No extra volumes | Mount CA bundle ConfigMap |
| **Agent config** | `NodeAttestor "join_token"` | `NodeAttestor "x509pop"` with cert/key paths |
| **Agent start command** | `spire-agent run ... -joinToken $TOKEN` | `spire-agent run ...` (no token flag) |
| **Per-VM setup** | Generate token, pass to VM | Generate cert+key, inject into VM |
| **Certificate files in VM** | Only trust bundle | Trust bundle + agent cert + agent key |

### What Stays the Same

Everything else from the original PoC is unchanged:
- VSOCK feature gate and VM enablement
- socat bridge pods (host-side and VM-side)
- SPIRE Agent binary installation
- Trust bundle distribution
- WorkloadAttestor "unix" configuration
- Registration entry creation (only parent ID format changes)
- SVID fetch and rotation behavior

---

## 11. Potential Issues and Mitigations

### Issue 1: Certificate Must Have `digitalSignature` KeyUsage

The x509pop plugin requires the leaf certificate to have `digitalSignature` in its KeyUsage extension. Without it, the proof-of-possession challenge will fail.

**Mitigation**: Always include `-extensions v3_req` with `keyUsage = critical, digitalSignature` when generating certificates (shown in Step 2).

### Issue 2: Leaf Certificate Must Be Unique Per Node

SPIRE Server rejects attestation if two agents present the same leaf certificate. Each VM must have its own certificate.

**Mitigation**: The certificate generation script (Step 2) uses the VM name as CN, ensuring uniqueness. For production, cert-manager enforces this through separate Certificate resources per VM.

### Issue 3: SPIRE Server Must Be Configured Before Agent Starts

If the SPIRE Server doesn't have the x509pop plugin configured when the agent attempts attestation, it will fail with an error like `unknown attestation type "x509pop"`.

**Mitigation**: Configure and restart the SPIRE Server (Step 4) before starting any VM agents.

### Issue 4: CA Bundle Must Include the Correct CA

If the CA bundle mounted in the SPIRE Server doesn't contain the CA that signed the VM certificate, attestation will fail with a chain verification error.

**Mitigation**: Always use the same CA for signing and for the server's `ca_bundle_path`. Verify with:
```bash
openssl verify -CAfile /path/to/ca-bundle.pem /path/to/agent-cert.pem
```

### Issue 5: Agent Path Template Must Be Configured Consistently

If you use `agent_path_template = "{{ .PluginName }}/{{ .Subject.CommonName }}"`, the SPIFFE ID will be based on the CN. Registration entries must use this exact SPIFFE ID as the parent ID.

**Mitigation**: After first attestation, always check `spire-server agent list` to get the exact SPIFFE ID to use as parent ID in registration entries.

---

## 12. Summary

### Is x509pop Feasible? — Yes

x509pop is a **built-in, production-grade** SPIRE node attestor that works with the existing SPIRE binaries. It requires no custom plugin development and solves the critical limitations of join_token (re-attestation, agent longevity, manual token management).

### Does It Eliminate the Need for a Custom KubeVirt Attestor? — Mostly Yes

For most practical purposes, x509pop with automated certificate provisioning (cert-manager + cloud-init) provides equivalent functionality to what a custom KubeVirt attestor would offer. The remaining gap is:

| x509pop | KubeVirt Attestor |
|---|---|
| Requires pre-provisioned certificate (automatable) | Zero pre-provisioning; identity derived from platform |
| Certificate-based identity | KubeVirt API-based identity |
| Works today with no code changes | Requires 3-4 weeks development + upstream contribution |

**Recommendation**: Use x509pop as the production attestation mechanism. Only pursue a custom KubeVirt attestor if there is a specific requirement that x509pop cannot meet (e.g., dynamic VM identity based on KubeVirt labels/annotations).

### What the PoC Will Prove

1. x509pop attestation works for VMs over VSOCK
2. Agent can re-attest after restart (critical improvement over join_token)
3. Certificate provisioning can be automated via cloud-init
4. No custom SPIRE plugin development is needed
5. Multiple attestor types coexist (k8s_psat for nodes, x509pop for VMs)

---

## Appendix A: Quick Reference — Differences from Original PoC

```diff
# Agent configuration
- NodeAttestor "join_token" {
-     plugin_data {}
- }
+ NodeAttestor "x509pop" {
+     plugin_data {
+         private_key_path = "/opt/spire/conf/agent/agent-key.pem"
+         certificate_path = "/opt/spire/conf/agent/agent-cert.pem"
+     }
+ }

# Starting the agent
- sudo /usr/local/bin/spire-agent run \
-   -config /opt/spire/conf/agent/agent.conf \
-   -joinToken $JOIN_TOKEN
+ sudo /usr/local/bin/spire-agent run \
+   -config /opt/spire/conf/agent/agent.conf

# Agent SPIFFE ID
- spiffe://.../spire/agent/join_token/3611a3f7-837f-40c5-ac59-1cccfb3e6f64
+ spiffe://.../spire/agent/x509pop/rhel9-magenta-gull-92

# Re-attestation
- Can re-attest: false
+ Can re-attest: true
```

## Appendix B: Files Required in VM

```
/usr/local/bin/spire-agent                    # SPIRE agent binary (same as before)
/opt/spire/conf/agent/agent.conf              # Agent config (updated for x509pop)
/opt/spire/conf/agent/agent-cert.pem          # NEW: VM-specific leaf certificate
/opt/spire/conf/agent/agent-key.pem           # NEW: VM-specific private key
/opt/spire/bundle.pem                         # SPIRE server trust bundle (same as before)
/var/lib/spire/agent/                         # Agent data directory (same as before)
/run/spire/sockets/agent.sock                 # Workload API socket (same as before)
```

## Appendix C: Files Required on SPIRE Server

```
/opt/spire/conf/server/vm-ca-bundle.pem       # NEW: CA bundle that signed VM certs
```

The server config must include the `x509pop` NodeAttestor plugin block (see Section 6).
