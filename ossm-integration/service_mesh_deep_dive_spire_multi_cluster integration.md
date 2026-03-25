# OpenShift Service Mesh + SPIRE Multi-Cluster Integration: Complete Technical Deep Dive

**Version:** 1.0  
**Date:** February 2026  
**Author:** Technical Implementation Guide  
**Environment:** OpenShift 4.x, OSSM 3.x (Istio v1.24.3), ZTWIM Operator

---

## Table of Contents

1. [Introduction and Motivation](#1-introduction-and-motivation)
2. [Understanding the Components](#2-understanding-the-components)
3. [Certificate Authority Management: Istiod vs SPIRE](#3-certificate-authority-management-istiod-vs-spire)
4. [Single-Cluster vs Multi-Cluster Architecture](#4-single-cluster-vs-multi-cluster-architecture)
5. [SPIRE Federation Deep Dive](#5-spire-federation-deep-dive)
6. [The Integration Architecture](#6-the-integration-architecture)
7. [Step-by-Step Implementation](#7-step-by-step-implementation)
8. [Issues Encountered and Solutions](#8-issues-encountered-and-solutions)
9. [What ZTWIM Operator Should Handle Automatically](#9-what-ztwim-operator-should-handle-automatically)
10. [Configuration Reference](#10-configuration-reference)
11. [Troubleshooting Guide](#11-troubleshooting-guide)
12. [Appendix](#12-appendix)

---

## 1. Introduction and Motivation

### 1.1 What is This About?

This document describes the complete integration of:
- **OpenShift Service Mesh (OSSM)** - Red Hat's distribution of Istio service mesh
- **SPIRE** - The SPIFFE Runtime Environment for workload identity
- **ZTWIM** - Zero Trust Workload Identity Manager (Red Hat's operator for SPIRE)

The goal is to replace Istio's built-in Certificate Authority (CA) with SPIRE for issuing workload certificates, enabling:
- SPIFFE-based workload identity
- Short-lived certificates with automatic rotation
- Cross-cluster mutual TLS (mTLS) via federation
- Zero-trust security model

### 1.2 Why Replace Istio's CA with SPIRE?

#### Istio's Built-in CA (Citadel/istiod)

Istio includes its own Certificate Authority that:
- Issues X.509 certificates to workloads
- Manages certificate rotation
- Provides mTLS between services

**Limitations:**
- Certificates are tied to Istio's trust domain
- No native federation support across different Istio deployments
- Certificate format is Istio-specific
- Limited integration with external identity systems

#### SPIRE's Advantages

SPIRE provides:
- **SPIFFE Standard Compliance**: Industry-standard workload identity (SPIFFE IDs)
- **Federation**: Native support for trust bundle exchange between clusters
- **Short-lived Certificates**: Default 1-hour TTL with automatic rotation
- **Attestation**: Strong workload identity verification via Kubernetes attestation
- **Interoperability**: Works with any SPIFFE-compatible system

### 1.3 The End Goal

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           CROSS-CLUSTER mTLS with SPIRE                         │
│                                                                                 │
│   CLUSTER 1                                          CLUSTER 2                  │
│   Trust Domain: cluster1.example.com                 Trust Domain: cluster2.example.com
│                                                                                 │
│   ┌─────────────────┐                               ┌─────────────────┐        │
│   │ curl Pod        │                               │ helloworld-v2   │        │
│   │                 │                               │                 │        │
│   │ Certificate:    │                               │ Certificate:    │        │
│   │ spiffe://       │         mTLS                  │ spiffe://       │        │
│   │ cluster1.../    │◄───────────────────────────►  │ cluster2.../    │        │
│   │ ns/test/sa/curl │    (via E/W Gateway)          │ ns/test/sa/hello│        │
│   │                 │                               │                 │        │
│   │ Trusts:         │                               │ Trusts:         │        │
│   │ - cluster1 CA ✓ │                               │ - cluster1 CA ✓ │        │
│   │ - cluster2 CA ✓ │                               │ - cluster2 CA ✓ │        │
│   └─────────────────┘                               └─────────────────┘        │
│                                                                                 │
│   Both workloads have SPIRE-issued certificates and trust each other's CAs     │
│   through SPIRE Federation                                                      │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Understanding the Components

### 2.1 OpenShift Service Mesh (OSSM)

OSSM is Red Hat's supported distribution of Istio, providing:

#### Core Components

| Component | Description |
|-----------|-------------|
| **Istiod** | Control plane that manages configuration, certificates, and service discovery |
| **Envoy Proxy** | Sidecar proxy injected into each pod for traffic management |
| **Istio CNI** | Container Network Interface plugin for transparent traffic interception |
| **Ingress/Egress Gateway** | Edge proxies for north-south traffic |
| **East-West Gateway** | Gateway for cross-cluster (east-west) traffic |

#### OSSM 3.x vs Previous Versions

OSSM 3.x uses the **Sail Operator** with different CRDs:
- `Istio` CR (replaces `ServiceMeshControlPlane`)
- `IstioCNI` CR
- Uses Kubernetes Gateway API (`Gateway` CR)

### 2.2 SPIRE (SPIFFE Runtime Environment)

SPIRE is the reference implementation of the SPIFFE specification.

#### SPIRE Components

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              SPIRE ARCHITECTURE                                  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                           SPIRE SERVER                                   │  │
│   │                                                                         │  │
│   │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │  │
│   │  │ Certificate     │  │ Registration    │  │ Federation      │         │  │
│   │  │ Authority       │  │ Entries DB      │  │ Manager         │         │  │
│   │  │                 │  │                 │  │                 │         │  │
│   │  │ Signs X.509     │  │ Stores SPIFFE   │  │ Exchanges trust │         │  │
│   │  │ certificates    │  │ ID templates    │  │ bundles         │         │  │
│   │  └─────────────────┘  └─────────────────┘  └─────────────────┘         │  │
│   │                                                                         │  │
│   │  Runs as StatefulSet in zero-trust-workload-identity-manager namespace  │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                    │                                            │
│                                    │ gRPC (port 8081)                           │
│                                    ▼                                            │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                        SPIRE AGENT (DaemonSet)                          │  │
│   │                                                                         │  │
│   │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │  │
│   │  │ Workload        │  │ SVID Cache      │  │ SDS Server      │         │  │
│   │  │ Attestation     │  │                 │  │                 │         │  │
│   │  │                 │  │ Caches issued   │  │ Serves certs to │         │  │
│   │  │ Verifies pod    │  │ certificates    │  │ Envoy via gRPC  │         │  │
│   │  │ identity via    │  │ and trust       │  │ over Unix socket│         │  │
│   │  │ Kubelet API     │  │ bundles         │  │                 │         │  │
│   │  └─────────────────┘  └─────────────────┘  └─────────────────┘         │  │
│   │                                                                         │  │
│   │  Runs on every node, exposes Unix Domain Socket for workloads           │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                    │                                            │
│                                    │ Unix Socket via CSI Driver                 │
│                                    ▼                                            │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                         WORKLOAD POD                                     │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    Envoy Sidecar (istio-proxy)                   │   │  │
│   │  │                                                                   │   │  │
│   │  │  Connects to SPIRE Agent socket, receives:                        │   │  │
│   │  │  - "default" secret: X.509 SVID (workload certificate)           │   │  │
│   │  │  - "ROOTCA" secret: Trust bundles (all trusted CAs)              │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### SPIFFE ID Format

SPIFFE IDs follow a URI format:
```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

Example:
```
spiffe://apps.cluster1.example.com/ns/istio-test/sa/helloworld
```

### 2.3 ZTWIM (Zero Trust Workload Identity Manager)

ZTWIM is Red Hat's operator for managing SPIRE deployments on OpenShift.

#### What ZTWIM Manages

| Resource | Description |
|----------|-------------|
| `ZeroTrustWorkloadIdentityManager` | Top-level CR that defines trust domain and cluster settings |
| `SpireServer` | Configuration for SPIRE Server (CA settings, federation, JWT issuer) |
| `SpireAgent` | Configuration for SPIRE Agent DaemonSet |
| `ClusterSPIFFEID` | Templates for generating SPIFFE IDs for workloads |
| `ClusterFederatedTrustDomain` | Configuration for trusting remote SPIRE deployments |

#### ZTWIM Deployment Model

```yaml
# Example ZeroTrustWorkloadIdentityManager CR
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: apps.cluster1.example.com
  clusterName: cluster1
  bundleConfigMap: spire-bundle
  labels:
    environment: production
```

### 2.4 SPIFFE CSI Driver

The CSI (Container Storage Interface) driver enables pods to access the SPIRE Agent socket.

#### How It Works

1. Pod spec includes CSI volume:
   ```yaml
   volumes:
   - name: workload-socket
     csi:
       driver: "csi.spiffe.io"
       readOnly: true
   ```

2. CSI driver mounts a directory into the pod
3. Inside this directory, a Unix socket is created
4. This socket connects to the SPIRE Agent on the node
5. Envoy connects to this socket to receive certificates

---

## 3. Certificate Authority Management: Istiod vs SPIRE

### 3.1 How Istiod Manages Certificates (Default Behavior)

#### The Default Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    DEFAULT ISTIO CERTIFICATE MANAGEMENT                         │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                              ISTIOD                                      │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    Citadel (built-in CA)                         │   │  │
│   │  │                                                                   │   │  │
│   │  │  - Self-signed root CA or plugged-in CA                          │   │  │
│   │  │  - Issues workload certificates                                   │   │  │
│   │  │  - Manages certificate rotation                                   │   │  │
│   │  │  - Signs certificates with O=<trust-domain>                       │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                              │                                          │  │
│   │                              │ SDS API (port 15012)                     │  │
│   │                              ▼                                          │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                         WORKLOAD POD                                     │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    pilot-agent (istio-proxy)                     │   │  │
│   │  │                                                                   │   │  │
│   │  │  1. Starts and connects to Istiod                                 │   │  │
│   │  │  2. Sends CSR (Certificate Signing Request)                       │   │  │
│   │  │  3. Receives signed certificate from Istiod's CA                  │   │  │
│   │  │  4. Creates local SDS server for Envoy                            │   │  │
│   │  │  5. Serves certificates to Envoy                                  │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                              │                                          │  │
│   │                              │ Local SDS (Unix socket)                  │  │
│   │                              ▼                                          │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                         Envoy                                     │   │  │
│   │  │                                                                   │   │  │
│   │  │  - Receives certificates via SDS from pilot-agent                 │   │  │
│   │  │  - Uses certificates for mTLS with other workloads                │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Certificate Characteristics (Istiod-issued)

```
Certificate:
    Issuer: O=cluster.local  (or configured trust domain)
    Subject: (empty)
    Subject Alternative Name:
        URI: spiffe://cluster.local/ns/default/sa/myapp
    Validity: 24 hours (default)
    
Key Points:
- Issuer Organization is the trust domain
- Subject is typically empty
- SPIFFE ID is in SAN (Subject Alternative Name)
- Certificate format follows Istio conventions
```

#### Pilot-Agent's Role

Pilot-agent (the init/sidecar process in istio-proxy) performs:

1. **Certificate Fetching**: Requests certificates from Istiod
2. **SDS Server**: Creates a local SDS (Secret Discovery Service) server
3. **Certificate Serving**: Serves certificates to Envoy via Unix socket
4. **Certificate Rotation**: Automatically refreshes certificates before expiry

The default SDS socket path:
```
/var/run/secrets/workload-spiffe-uds/socket
```

### 3.2 How SPIRE Manages Certificates

#### The SPIRE Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      SPIRE CERTIFICATE MANAGEMENT                                │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                           SPIRE SERVER                                   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    Certificate Authority                          │   │  │
│   │  │                                                                   │   │  │
│   │  │  - Self-signed CA with configurable subject                       │   │  │
│   │  │  - Issues X.509 SVIDs (SPIFFE Verifiable Identity Documents)      │   │  │
│   │  │  - Short TTL (1 hour default)                                     │   │  │
│   │  │  - Signs with O=SPIRE (configurable)                              │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    Registration Entries                           │   │  │
│   │  │                                                                   │   │  │
│   │  │  - ClusterSPIFFEID defines SPIFFE ID templates                    │   │  │
│   │  │  - Attestation selectors (namespace, service account, labels)     │   │  │
│   │  │  - federatesWith: list of trusted remote trust domains            │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                              │                                          │  │
│   │                              │ gRPC (attested channel)                  │  │
│   │                              ▼                                          │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                    SPIRE AGENT (on each node)                           │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    Workload Attestation                           │   │  │
│   │  │                                                                   │   │  │
│   │  │  When a workload connects:                                        │   │  │
│   │  │  1. Agent queries Kubelet API for pod info                        │   │  │
│   │  │  2. Extracts: namespace, service account, pod UID, labels         │   │  │
│   │  │  3. Matches against registration entries                          │   │  │
│   │  │  4. Requests SVID from SPIRE Server                               │   │  │
│   │  │  5. Returns SVID + trust bundles to workload                      │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    SDS Server                                     │   │  │
│   │  │                                                                   │   │  │
│   │  │  Exposes Unix socket at: /tmp/spire-agent/public/socket           │   │  │
│   │  │  Serves:                                                          │   │  │
│   │  │  - "default" secret: workload SVID (certificate + key)            │   │  │
│   │  │  - "ROOTCA" secret: combined trust bundles                        │   │  │
│   │  │  - Individual bundles: "spiffe://<trust-domain>"                  │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                              │                                          │  │
│   │                              │ Unix Socket via CSI Driver               │  │
│   │                              ▼                                          │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                         WORKLOAD POD                                     │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    Envoy (istio-proxy)                            │   │  │
│   │  │                                                                   │   │  │
│   │  │  - Connects DIRECTLY to SPIRE Agent socket (via CSI mount)        │   │  │
│   │  │  - Receives SPIRE-issued certificates                             │   │  │
│   │  │  - Receives federated trust bundles                               │   │  │
│   │  │  - Uses SPIFFE certificate validator for verification             │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Certificate Characteristics (SPIRE-issued)

```
Certificate:
    Issuer: C=US, O=RH, CN=SPIRE Server CA  (configurable via caSubject)
    Subject: C=US, O=SPIRE
    Subject Alternative Name:
        URI: spiffe://apps.cluster1.example.com/ns/istio-test/sa/helloworld
    Validity: 1 hour (default, short-lived)
    
Key Points:
- Issuer contains custom organization and CN
- Subject has O=SPIRE
- SPIFFE ID in SAN follows SPIFFE standard
- Very short TTL for better security
```

### 3.3 The Integration: Making Envoy Use SPIRE Instead of Istiod

#### The Challenge

By default:
- pilot-agent creates its own SDS server
- pilot-agent fetches certificates from Istiod
- Envoy connects to pilot-agent's SDS server

We need:
- Envoy to connect directly to SPIRE Agent's SDS server
- Bypass pilot-agent's certificate fetching from Istiod
- Use SPIRE-issued certificates instead

#### The Solution: CREDENTIAL_SOCKET_EXISTS

When `CREDENTIAL_SOCKET_EXISTS=true` is set:

1. pilot-agent checks if an SDS socket already exists at the expected path
2. If socket exists: pilot-agent does NOT create its own SDS server
3. Envoy connects directly to the existing socket (SPIRE Agent)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    SPIRE INTEGRATION WITH ISTIO                                  │
│                                                                                 │
│                         CREDENTIAL_SOCKET_EXISTS=true                            │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                         WORKLOAD POD                                     │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                    pilot-agent                                    │   │  │
│   │  │                                                                   │   │  │
│   │  │  On startup:                                                      │   │  │
│   │  │  1. Checks CREDENTIAL_SOCKET_EXISTS=true                          │   │  │
│   │  │  2. Looks for socket at /var/run/secrets/workload-spiffe-uds/socket│  │  │
│   │  │  3. Finds SPIRE socket (mounted via CSI)                          │   │  │
│   │  │  4. Logs: "Existing workload SDS socket found..."                 │   │  │
│   │  │  5. Does NOT start its own SDS server                             │   │  │
│   │  │  6. Does NOT fetch certificates from Istiod                       │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │  CSI Mount: /var/run/secrets/workload-spiffe-uds/                 │   │  │
│   │  │                                                                   │   │  │
│   │  │  Contains: socket  (Unix socket connected to SPIRE Agent)         │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                              │                                          │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │                         Envoy                                     │   │  │
│   │  │                                                                   │   │  │
│   │  │  sds-grpc cluster configured to connect to:                       │   │  │
│   │  │  ./var/run/secrets/workload-spiffe-uds/socket                     │   │  │
│   │  │                                                                   │   │  │
│   │  │  Receives from SPIRE:                                             │   │  │
│   │  │  - "default" secret: SPIRE-issued SVID                            │   │  │
│   │  │  - "ROOTCA" secret: Federated trust bundles                       │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                              │                                                  │
│                              │ CSI connects to SPIRE Agent                      │
│                              ▼                                                  │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                    SPIRE AGENT (on node)                                 │  │
│   │                                                                         │  │
│   │  Socket: /tmp/spire-agent/public/socket                                  │  │
│   │  (CSI driver connects pod's socket to this agent socket)                 │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Critical Configuration Requirements

For this to work, several things must align:

| Requirement | Details |
|-------------|---------|
| **SPIRE Agent socket filename** | Must be `socket` (not `spire-agent.sock`) |
| **SPIRE Agent socket path** | `/tmp/spire-agent/public/socket` |
| **CSI mount path in pod** | `/run/secrets/workload-spiffe-uds` (same as `/var/run/secrets/workload-spiffe-uds`) |
| **Volume name** | Must be `workload-socket` (Istio's expected name) |
| **Environment variable** | `CREDENTIAL_SOCKET_EXISTS=true` |

---

## 4. Single-Cluster vs Multi-Cluster Architecture

### 4.1 Single-Cluster SPIRE + OSSM

In a single-cluster setup:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    SINGLE-CLUSTER ARCHITECTURE                                   │
│                                                                                 │
│   Trust Domain: apps.cluster1.example.com                                        │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                    SPIRE (single trust domain)                           │  │
│   │                                                                         │  │
│   │  - One CA for the entire cluster                                        │  │
│   │  - All workloads get certificates from the same CA                      │  │
│   │  - All workloads trust the same CA                                      │  │
│   │  - No federation needed                                                 │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                    ISTIOD                                                │  │
│   │                                                                         │  │
│   │  - Knows about all services in the cluster                              │  │
│   │  - Pushes xDS configuration to all Envoy proxies                        │  │
│   │  - Single mesh, single network                                          │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                    WORKLOADS                                             │  │
│   │                                                                         │  │
│   │  Service A ◄──────────────► Service B                                   │  │
│   │  (SPIRE cert)      mTLS      (SPIRE cert)                               │  │
│   │                                                                         │  │
│   │  Both services:                                                          │  │
│   │  - Have certificates from the same SPIRE CA                             │  │
│   │  - Trust the same SPIRE CA                                              │  │
│   │  - Communicate directly via pod IPs                                     │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Single-Cluster Configuration Summary

| Component | Configuration |
|-----------|---------------|
| **ClusterSPIFFEID** | No `federatesWith` needed |
| **SpireServer** | No `federation` block needed |
| **Istio CR** | No `trustDomainAliases` needed |
| **Istio CR** | No `meshNetworks` needed |
| **E/W Gateway** | Not needed |
| **Remote Secrets** | Not needed |

### 4.2 Multi-Cluster SPIRE + OSSM

In a multi-cluster setup:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    MULTI-CLUSTER ARCHITECTURE                                    │
│                                                                                 │
│   CLUSTER 1                                         CLUSTER 2                   │
│   Trust Domain: cluster1.example.com                Trust Domain: cluster2.example.com
│                                                                                 │
│   ┌─────────────────────┐                          ┌─────────────────────┐     │
│   │ SPIRE Server        │                          │ SPIRE Server        │     │
│   │ (CA 1)              │◄────── Federation ──────►│ (CA 2)              │     │
│   │                     │    (bundle exchange)      │                     │     │
│   │ Has: CA1 + CA2      │                          │ Has: CA1 + CA2      │     │
│   └─────────────────────┘                          └─────────────────────┘     │
│                                                                                 │
│   ┌─────────────────────┐                          ┌─────────────────────┐     │
│   │ Istiod              │                          │ Istiod              │     │
│   │                     │◄── Remote Secret ───────►│                     │     │
│   │ Knows C1 + C2 svcs  │    (service discovery)   │ Knows C1 + C2 svcs  │     │
│   └─────────────────────┘                          └─────────────────────┘     │
│                                                                                 │
│   ┌─────────────────────┐                          ┌─────────────────────┐     │
│   │ E/W Gateway         │                          │ E/W Gateway         │     │
│   │ (LoadBalancer)      │◄────── Internet ────────►│ (LoadBalancer)      │     │
│   │ Port 15443          │                          │ Port 15443          │     │
│   └─────────────────────┘                          └─────────────────────┘     │
│                                                                                 │
│   ┌─────────────────────┐                          ┌─────────────────────┐     │
│   │ Service A           │                          │ Service B           │     │
│   │ (network1)          │────── via E/W GW ───────►│ (network2)          │     │
│   │ Cert: CA1           │        mTLS              │ Cert: CA2           │     │
│   │ Trusts: CA1 + CA2   │                          │ Trusts: CA1 + CA2   │     │
│   └─────────────────────┘                          └─────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 4.3 What Changes for Multi-Cluster

#### SPIRE Changes

| Component | Single-Cluster | Multi-Cluster |
|-----------|----------------|---------------|
| **SpireServer.federation** | Not needed | Required - enables bundle endpoint and federatesWith |
| **ClusterFederatedTrustDomain** | Not needed | Required - defines remote trust domain and bundle URL |
| **ClusterSPIFFEID.federatesWith** | Not needed | Required - includes federated CAs in issued SVIDs |
| **ClusterSPIFFEID.className** | Optional | **Required** when using federatesWith |
| **SPIRE Agent SDS config** | Basic | Needs `default_all_bundles_name: ROOTCA` |

#### Istio Changes

| Component | Single-Cluster | Multi-Cluster |
|-----------|----------------|---------------|
| **global.network** | Not needed | Required - identifies cluster's network |
| **global.meshNetworks** | Not needed | Required - defines gateway addresses for each network |
| **meshConfig.trustDomainAliases** | Not needed | Required - accepts certs from federated domains |
| **East-West Gateway** | Not needed | Required - routes cross-cluster traffic |
| **Remote Secrets** | Not needed | Required - enables cross-cluster service discovery |
| **Gateway.tls.mode** | N/A | Must be `Passthrough` for mTLS |

### 4.4 Multi-Cluster Traffic Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    CROSS-CLUSTER REQUEST FLOW                                    │
│                                                                                 │
│   1. curl pod makes request to helloworld.istio-test:5000                       │
│                                                                                 │
│   2. Request intercepted by local Envoy sidecar                                 │
│                                                                                 │
│   3. Envoy looks up helloworld.istio-test in its cluster config                 │
│      (pushed by Istiod which knows about both clusters via Remote Secrets)      │
│                                                                                 │
│   4. Envoy sees two endpoints:                                                  │
│      - 10.128.x.x (Cluster 1, network1) - local                                │
│      - 10.131.x.x (Cluster 2, network2) - remote                               │
│                                                                                 │
│   5. Load balancer picks remote endpoint (Cluster 2)                            │
│                                                                                 │
│   6. Envoy checks meshNetworks config:                                          │
│      "For network2, use gateway: 34.47.177.52:15443"                            │
│                                                                                 │
│   7. Envoy connects to local E/W Gateway with SNI:                              │
│      SNI: outbound_.5000_._.helloworld.istio-test.svc.cluster.local             │
│                                                                                 │
│   8. Local E/W Gateway (TLS Passthrough) forwards to remote E/W Gateway         │
│                                                                                 │
│   9. Remote E/W Gateway (TLS Passthrough) routes to destination pod by SNI      │
│                                                                                 │
│  10. mTLS handshake between curl's Envoy and helloworld's Envoy:                │
│      - curl presents: spiffe://cluster1/ns/istio-test/sa/curl (signed by CA1)   │
│      - helloworld verifies: CA1 is in my ROOTCA trust bundle ✓                  │
│      - helloworld presents: spiffe://cluster2/ns/istio-test/sa/helloworld (CA2) │
│      - curl verifies: CA2 is in my ROOTCA trust bundle ✓                        │
│                                                                                 │
│  11. Encrypted channel established, request flows through                       │
│                                                                                 │
│  12. Response: "Hello version: v2" returns through same path                    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. SPIRE Federation Deep Dive

### 5.1 What is SPIRE Federation?

Federation allows different SPIRE trust domains to trust each other by exchanging CA certificates (trust bundles).

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         BEFORE FEDERATION                                        │
│                                                                                 │
│   Cluster 1                                      Cluster 2                      │
│   Trust Domain: cluster1.example.com             Trust Domain: cluster2.example.com
│                                                                                 │
│   ┌─────────────────────┐                       ┌─────────────────────┐        │
│   │ SPIRE CA 1          │                       │ SPIRE CA 2          │        │
│   │                     │                       │                     │        │
│   │ Trust Bundle:       │                       │ Trust Bundle:       │        │
│   │ - CA 1 cert ✓       │                       │ - CA 2 cert ✓       │        │
│   │                     │                       │                     │        │
│   │ Can verify: only    │     ❌ Cannot         │ Can verify: only    │        │
│   │ cluster1 workloads  │     verify each       │ cluster2 workloads  │        │
│   └─────────────────────┘     other's certs     └─────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────┐
│                         AFTER FEDERATION                                         │
│                                                                                 │
│   Cluster 1                                      Cluster 2                      │
│                                                                                 │
│   ┌─────────────────────┐     Bundle Exchange    ┌─────────────────────┐        │
│   │ SPIRE CA 1          │◄─────────────────────►│ SPIRE CA 2          │        │
│   │                     │                        │                     │        │
│   │ Trust Bundle:       │                        │ Trust Bundle:       │        │
│   │ - CA 1 cert ✓       │                        │ - CA 1 cert ✓       │        │
│   │ - CA 2 cert ✓       │                        │ - CA 2 cert ✓       │        │
│   │                     │                        │                     │        │
│   │ Can verify: BOTH    │      ✓ Full cross-     │ Can verify: BOTH    │        │
│   │ cluster1 AND        │      cluster trust     │ cluster1 AND        │        │
│   │ cluster2 workloads  │                        │ cluster2 workloads  │        │
│   └─────────────────────┘                        └─────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Federation Endpoint

Each SPIRE Server exposes a federation endpoint:

```
https://federation.<trust-domain>
```

This HTTPS endpoint:
- Serves the local trust bundle (CA certificate)
- Is secured with the SPIRE Server's own SVID
- Can be exposed via OpenShift Route (managedRoute: "true")

### 5.3 Bundle Endpoint Profile: https_spiffe

The `https_spiffe` profile means:
- The federation endpoint is protected by TLS
- The server certificate is a SPIFFE SVID
- Clients verify the server using its SPIFFE ID

```yaml
# SpireServer federation configuration
spec:
  federation:
    bundleEndpoint:
      profile: https_spiffe      # Use SPIFFE-authenticated HTTPS
      refreshHint: 300           # Suggest clients refresh every 5 minutes
    federatesWith:
      - trustDomain: cluster2.example.com
        bundleEndpointUrl: https://federation.cluster2.example.com
        bundleEndpointProfile: https_spiffe
        endpointSpiffeId: spiffe://cluster2.example.com/spire/server
```

### 5.4 Trust Bundle Format

SPIRE trust bundles are in JWKS (JSON Web Key Set) format:

```json
{
  "keys": [
    {
      "kty": "RSA",
      "use": "x509-svid",
      "n": "...",
      "e": "AQAB",
      "x5c": ["<base64-encoded-certificate>"]
    }
  ],
  "spiffe_refresh_hint": 300
}
```

### 5.5 ClusterFederatedTrustDomain Resource

This CR tells SPIRE where to find remote trust bundles:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster2-federation
spec:
  trustDomain: cluster2.example.com
  bundleEndpointURL: https://federation.cluster2.example.com
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://cluster2.example.com/spire/server
  trustDomainBundle: |
    <initial-bundle-for-bootstrapping>
```

### 5.6 Bootstrap Problem and Solution

**Problem:** To fetch the remote bundle via HTTPS, you need to trust the remote server's certificate. But the remote server's certificate is signed by the remote CA, which you don't have yet!

**Solution:** Bootstrap with initial bundle:

1. Extract remote cluster's bundle manually
2. Add it to `trustDomainBundle` in ClusterFederatedTrustDomain
3. Now SPIRE can verify the federation endpoint and fetch updates

```bash
# Extract bundle from Cluster 2
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle show -format spiffe -socketPath /tmp/spire-server/private/api.sock

# OR manually load bundle
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle set -id spiffe://cluster2.example.com \
  -path /tmp/federated-ca.pem \
  -socketPath /tmp/spire-server/private/api.sock
```

### 5.7 How federatesWith Works in ClusterSPIFFEID

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-test-spiffeid
spec:
  className: zero-trust-workload-identity-manager-spire  # REQUIRED!
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels: {}
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: istio-test
  federatesWith:
    - cluster2.example.com   # Include CA2 in trust bundles for these workloads
```

When `federatesWith` is specified:
1. SPIRE creates registration entries with `federates_with` field
2. When issuing SVIDs to these workloads, SPIRE includes federated trust bundles
3. The workload's ROOTCA contains both local and federated CAs

**Critical:** The `className` field is REQUIRED for `federatesWith` to work. Without it, the SPIRE controller ignores the `federatesWith` field.

### 5.8 SPIRE Agent SDS Configuration for Federation

The SPIRE Agent must be configured to serve federated bundles:

```json
{
  "agent": {
    "socket_path": "/tmp/spire-agent/public/socket",
    "trust_domain": "cluster1.example.com",
    "sds": {
      "default_bundle_name": "null",
      "default_all_bundles_name": "ROOTCA"
    }
  }
}
```

| Setting | Description |
|---------|-------------|
| `default_bundle_name: "null"` | Don't serve individual bundle as default |
| `default_all_bundles_name: "ROOTCA"` | Serve ALL bundles (local + federated) under "ROOTCA" name |

When Envoy requests "ROOTCA", it receives a combined trust bundle containing all trusted CAs.

---

## 6. The Integration Architecture

### 6.1 Complete System Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    COMPLETE MULTI-CLUSTER ARCHITECTURE                                          │
│                                                                                                                 │
│     CLUSTER 1 (network1)                                              CLUSTER 2 (network2)                      │
│     Trust Domain: apps.cluster1.example.com                           Trust Domain: apps.cluster2.example.com   │
│                                                                                                                 │
│     ┌─────────────────────────────────────────────┐                   ┌─────────────────────────────────────────────┐
│     │         SPIRE CONTROL PLANE                 │                   │         SPIRE CONTROL PLANE                 │
│     │                                             │                   │                                             │
│     │  ┌─────────────────────────────────────┐   │                   │  ┌─────────────────────────────────────┐   │
│     │  │ SPIRE Server (StatefulSet)          │   │                   │  │ SPIRE Server (StatefulSet)          │   │
│     │  │                                     │   │                   │  │                                     │   │
│     │  │ - CA for cluster1                   │   │                   │  │ - CA for cluster2                   │   │
│     │  │ - Federation endpoint               │◄──┼───────────────────┼──┤ - Federation endpoint               │   │
│     │  │ - Has CA1 + CA2 (federated)         │   │   Bundle          │  │ - Has CA1 + CA2 (federated)         │   │
│     │  └─────────────────────────────────────┘   │   Exchange        │  └─────────────────────────────────────┘   │
│     │                                             │                   │                                             │
│     │  ┌─────────────────────────────────────┐   │                   │  ┌─────────────────────────────────────┐   │
│     │  │ SPIRE Agent (DaemonSet)             │   │                   │  │ SPIRE Agent (DaemonSet)             │   │
│     │  │                                     │   │                   │  │                                     │   │
│     │  │ - Runs on each node                 │   │                   │  │ - Runs on each node                 │   │
│     │  │ - Exposes SDS socket                │   │                   │  │ - Exposes SDS socket                │   │
│     │  │ - Serves SVIDs + federated bundles  │   │                   │  │ - Serves SVIDs + federated bundles  │   │
│     │  └─────────────────────────────────────┘   │                   │  └─────────────────────────────────────┘   │
│     │                                             │                   │                                             │
│     │  ┌─────────────────────────────────────┐   │                   │  ┌─────────────────────────────────────┐   │
│     │  │ SPIFFE CSI Driver (DaemonSet)       │   │                   │  │ SPIFFE CSI Driver (DaemonSet)       │   │
│     │  │                                     │   │                   │  │                                     │   │
│     │  │ - Mounts Agent socket into pods     │   │                   │  │ - Mounts Agent socket into pods     │   │
│     │  └─────────────────────────────────────┘   │                   │  └─────────────────────────────────────┘   │
│     └─────────────────────────────────────────────┘                   └─────────────────────────────────────────────┘
│                                                                                                                 │
│     ┌─────────────────────────────────────────────┐                   ┌─────────────────────────────────────────────┐
│     │         ISTIO CONTROL PLANE                 │                   │         ISTIO CONTROL PLANE                 │
│     │                                             │                   │                                             │
│     │  ┌─────────────────────────────────────┐   │                   │  ┌─────────────────────────────────────┐   │
│     │  │ Istiod                               │   │                   │  │ Istiod                               │   │
│     │  │                                     │   │                   │  │                                     │   │
│     │  │ - Service discovery                 │◄──┼───────────────────┼──┤ - Service discovery                 │   │
│     │  │ - xDS config push                   │   │   Remote          │  │ - xDS config push                   │   │
│     │  │ - Knows cluster1 + cluster2 svcs    │   │   Secrets         │  │ - Knows cluster1 + cluster2 svcs    │   │
│     │  │ - meshNetworks: gateway addresses   │   │                   │  │ - meshNetworks: gateway addresses   │   │
│     │  │ - trustDomainAliases: cluster2      │   │                   │  │ - trustDomainAliases: cluster1      │   │
│     │  └─────────────────────────────────────┘   │                   │  └─────────────────────────────────────┘   │
│     │                                             │                   │                                             │
│     │  ┌─────────────────────────────────────┐   │                   │  ┌─────────────────────────────────────┐   │
│     │  │ East-West Gateway                   │   │                   │  │ East-West Gateway                   │   │
│     │  │                                     │   │                   │  │                                     │   │
│     │  │ - LoadBalancer :15443               │◄──┼───────────────────┼──┤ - LoadBalancer :15443               │   │
│     │  │ - TLS Passthrough                   │   │   Internet        │  │ - TLS Passthrough                   │   │
│     │  │ - Routes by SNI                     │   │                   │  │ - Routes by SNI                     │   │
│     │  │ - Uses SPIRE cert (via CSI)         │   │                   │  │ - Uses SPIRE cert (via CSI)         │   │
│     │  └─────────────────────────────────────┘   │                   │  └─────────────────────────────────────┘   │
│     └─────────────────────────────────────────────┘                   └─────────────────────────────────────────────┘
│                                                                                                                 │
│     ┌─────────────────────────────────────────────┐                   ┌─────────────────────────────────────────────┐
│     │         APPLICATION PODS                    │                   │         APPLICATION PODS                    │
│     │                                             │                   │                                             │
│     │  ┌───────────────────┐ ┌───────────────┐   │                   │  ┌───────────────────────────────────┐   │
│     │  │ curl Pod          │ │ helloworld-v1 │   │                   │  │ helloworld-v2                     │   │
│     │  │                   │ │               │   │                   │  │                                   │   │
│     │  │ ┌───────────────┐ │ │ ┌───────────┐ │   │                   │  │ ┌───────────────────────────┐     │   │
│     │  │ │ Envoy         │ │ │ │ Envoy     │ │   │                   │  │ │ Envoy                     │     │   │
│     │  │ │               │ │ │ │           │ │   │                   │  │ │                           │     │   │
│     │  │ │ SVID: CA1     │ │ │ │ SVID: CA1 │ │   │                   │  │ │ SVID: CA2                 │     │   │
│     │  │ │ ROOTCA:       │ │ │ │ ROOTCA:   │ │   │                   │  │ │ ROOTCA:                   │     │   │
│     │  │ │ - CA1 ✓       │ │ │ │ - CA1 ✓   │ │   │                   │  │ │ - CA1 ✓                   │     │   │
│     │  │ │ - CA2 ✓       │ │ │ │ - CA2 ✓   │ │   │                   │  │ │ - CA2 ✓                   │     │   │
│     │  │ └───────────────┘ │ │ └───────────┘ │   │                   │  │ └───────────────────────────┘     │   │
│     │  │        │          │ │       ▲       │   │                   │  │             ▲                     │   │
│     │  │        │ CSI      │ │       │ CSI   │   │                   │  │             │ CSI                 │   │
│     │  │        ▼          │ │       │       │   │                   │  │             │                     │   │
│     │  │   SPIRE Agent     │ │ SPIRE Agent   │   │                   │  │       SPIRE Agent               │   │
│     │  └───────────────────┘ └───────────────┘   │                   │  └───────────────────────────────────┘   │
│     └─────────────────────────────────────────────┘                   └─────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Data Flow: Certificate Issuance

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    CERTIFICATE ISSUANCE FLOW                                     │
│                                                                                 │
│   1. Pod created with CSI volume and Envoy sidecar                              │
│                                                                                 │
│   2. CSI driver creates Unix socket in pod at:                                  │
│      /run/secrets/workload-spiffe-uds/socket                                    │
│                                                                                 │
│   3. This socket connects to SPIRE Agent on the node                            │
│                                                                                 │
│   4. Envoy starts and connects to sds-grpc cluster pointing to:                 │
│      ./var/run/secrets/workload-spiffe-uds/socket                               │
│      (which is the SPIRE Agent socket)                                          │
│                                                                                 │
│   5. Envoy sends SDS request for "default" secret                               │
│                                                                                 │
│   6. SPIRE Agent receives request and:                                          │
│      a. Queries Kubelet API for pod info (namespace, SA, labels)                │
│      b. Matches against ClusterSPIFFEID registration entries                    │
│      c. Sends attestation request to SPIRE Server                               │
│                                                                                 │
│   7. SPIRE Server:                                                              │
│      a. Verifies attestation                                                    │
│      b. Generates SPIFFE ID from template                                       │
│      c. Signs X.509 certificate (SVID)                                          │
│      d. If entry has federatesWith: includes federated CAs in trust bundle      │
│      e. Returns SVID + trust bundles to Agent                                   │
│                                                                                 │
│   8. SPIRE Agent returns to Envoy via SDS:                                      │
│      - "default" secret: X.509 SVID (certificate + private key)                 │
│      - "ROOTCA" secret: SPIFFE cert validator with all trust domains            │
│                                                                                 │
│   9. Envoy now has certificates and can perform mTLS                            │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Data Flow: Cross-Cluster mTLS Handshake

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    mTLS HANDSHAKE FLOW                                           │
│                                                                                 │
│   curl (Cluster 1) ──────────────────────────────► helloworld-v2 (Cluster 2)    │
│                                                                                 │
│   1. curl's Envoy initiates TLS handshake                                       │
│                                                                                 │
│   2. curl's Envoy sends ClientHello to helloworld's Envoy                       │
│      (via E/W Gateways)                                                         │
│                                                                                 │
│   3. helloworld's Envoy responds with ServerHello + Certificate:                │
│      Certificate contains:                                                      │
│      - SPIFFE ID: spiffe://cluster2.example.com/ns/istio-test/sa/helloworld     │
│      - Signed by: Cluster 2 SPIRE CA                                            │
│                                                                                 │
│   4. curl's Envoy verifies helloworld's certificate:                            │
│      a. Extracts SPIFFE ID from SAN                                             │
│      b. Looks up trust domain: cluster2.example.com                             │
│      c. Finds CA in ROOTCA (SPIFFE cert validator has cluster2 bundle)          │
│      d. Verifies signature ✓                                                    │
│                                                                                 │
│   5. curl's Envoy sends its certificate:                                        │
│      Certificate contains:                                                      │
│      - SPIFFE ID: spiffe://cluster1.example.com/ns/istio-test/sa/curl           │
│      - Signed by: Cluster 1 SPIRE CA                                            │
│                                                                                 │
│   6. helloworld's Envoy verifies curl's certificate:                            │
│      a. Extracts SPIFFE ID from SAN                                             │
│      b. Looks up trust domain: cluster1.example.com                             │
│      c. Finds CA in ROOTCA (SPIFFE cert validator has cluster1 bundle)          │
│      d. Verifies signature ✓                                                    │
│                                                                                 │
│   7. Both sides verified - encrypted channel established                        │
│                                                                                 │
│   8. Application request flows through encrypted channel                        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 6.4 The SPIFFE Certificate Validator

When using SPIRE with federation, Envoy uses a special certificate validator:

```json
{
  "name": "ROOTCA",
  "secret": {
    "validation_context": {
      "custom_validator_config": {
        "name": "envoy.tls.cert_validator.spiffe",
        "typed_config": {
          "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.SPIFFECertValidatorConfig",
          "trust_domains": [
            {
              "name": "apps.cluster1.example.com",
              "trust_bundle": {
                "inline_bytes": "<CA1-cert-base64>"
              }
            },
            {
              "name": "apps.cluster2.example.com",
              "trust_bundle": {
                "inline_bytes": "<CA2-cert-base64>"
              }
            }
          ]
        }
      }
    }
  }
}
```

This validator:
- Extracts trust domain from SPIFFE ID in certificate
- Looks up the correct CA bundle for that trust domain
- Verifies the certificate signature against the correct CA

---

## 7. Step-by-Step Implementation

### 7.1 Prerequisites

- Two OpenShift clusters (4.x)
- Network connectivity between clusters on port 15443
- ZTWIM Operator installed on both clusters
- OSSM Operator (servicemeshoperator3) installed on both clusters
- `oc` CLI with access to both clusters
- DNS resolution between clusters

### 7.2 Phase 1: Deploy ZTWIM on Both Clusters

#### 7.2.1 Enable CREATE_ONLY_MODE

This prevents the operator from overwriting manual ConfigMap changes:

```bash
oc -n zero-trust-workload-identity-manager patch subscription openshift-zero-trust-workload-identity-manager \
  --type='merge' -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'
```

#### 7.2.2 Deploy ZTWIM Resources

```yaml
# Cluster 1
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: apps.cluster1.example.com
  clusterName: cluster1
  bundleConfigMap: spire-bundle
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  caSubject:
    commonName: "SPIRE Server CA"
    country: "US"
    organization: "MyOrg"
  jwtIssuer: https://oidc-discovery.apps.cluster1.example.com
  federation:
    bundleEndpoint:
      profile: https_spiffe
      refreshHint: 300
    federatesWith:
      - trustDomain: apps.cluster2.example.com
        bundleEndpointUrl: https://spire-server-federation.apps.cluster2.example.com
        bundleEndpointProfile: https_spiffe
        endpointSpiffeId: spiffe://apps.cluster2.example.com/spire/server
    managedRoute: "true"
```

### 7.3 Phase 2: Configure SPIRE Agent

#### 7.3.1 Patch SPIRE Agent ConfigMap

**Critical:** The socket filename must be `socket` and SDS must serve all bundles as ROOTCA:

```bash
oc get cm spire-agent -n zero-trust-workload-identity-manager -o json | jq '
  .data["agent.conf"] = (.data["agent.conf"] | fromjson | 
    .agent.socket_path = "/tmp/spire-agent/public/socket" |
    .agent.sds.default_bundle_name = "null" |
    .agent.sds.default_all_bundles_name = "ROOTCA" |
    tojson)
' | oc apply -f -
```

#### 7.3.2 Restart SPIRE Agents

```bash
oc delete pod -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent
```

### 7.4 Phase 3: Configure SPIRE Federation

#### 7.4.1 Extract and Exchange Trust Bundles

```bash
# On Cluster 1
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle show -format spiffe -socketPath /tmp/spire-server/private/api.sock \
  > cluster1-bundle.json

# On Cluster 2
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle show -format spiffe -socketPath /tmp/spire-server/private/api.sock \
  > cluster2-bundle.json
```

#### 7.4.2 Create ClusterFederatedTrustDomain

```yaml
# On Cluster 1
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster2-federation
spec:
  trustDomain: apps.cluster2.example.com
  bundleEndpointURL: https://spire-server-federation.apps.cluster2.example.com
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://apps.cluster2.example.com/spire/server
  trustDomainBundle: |
    <contents-of-cluster2-bundle.json>
```

#### 7.4.3 Manually Load Federated Bundle (if needed)

```bash
# Extract CA from bundle
echo '<bundle-json>' | jq -r '.keys[] | select(.use == "x509-svid") | .x5c[0]' | \
  base64 -d > /tmp/remote-ca.der
openssl x509 -in /tmp/remote-ca.der -inform DER -out /tmp/remote-ca.pem

# Copy and load
oc cp /tmp/remote-ca.pem zero-trust-workload-identity-manager/spire-server-0:/tmp/
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle set \
  -id spiffe://apps.cluster2.example.com \
  -path /tmp/remote-ca.pem \
  -socketPath /tmp/spire-server/private/api.sock
```

### 7.5 Phase 4: Deploy OSSM Components

#### 7.5.1 Create Namespaces

```bash
oc create namespace istio-cni
oc create namespace istio-system
```

#### 7.5.2 Deploy IstioCNI

```yaml
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
  namespace: istio-cni
spec:
  namespace: istio-cni
  version: v1.24.3
```

#### 7.5.3 Deploy Istio CR with SPIRE Integration

```yaml
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  namespace: istio-system
  version: v1.24.3
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1
      meshNetworks:
        network1:
          endpoints:
            - fromRegistry: cluster1
          gateways:
            - address: <CLUSTER1_EW_GATEWAY_IP>
              port: 15443
        network2:
          endpoints:
            - fromRegistry: cluster2
          gateways:
            - address: <CLUSTER2_EW_GATEWAY_IP>
              port: 15443
    meshConfig:
      trustDomain: apps.cluster1.example.com
      trustDomainAliases:
        - apps.cluster2.example.com
    sidecarInjectorWebhook:
      templates:
        spire: |
          spec:
            containers:
            - name: istio-proxy
              env:
              - name: CREDENTIAL_SOCKET_EXISTS
                value: "true"
              - name: ISTIO_META_TLS_CLIENT_ROOT_CERT
                value: ""
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
            - name: workload-socket
              csi:
                driver: "csi.spiffe.io"
                readOnly: true
        spire-gateway: |
          spec:
            containers:
            - name: istio-proxy
              env:
              - name: CREDENTIAL_SOCKET_EXISTS
                value: "true"
              - name: ISTIO_META_TLS_CLIENT_ROOT_CERT
                value: ""
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
            - name: workload-socket
              csi:
                driver: "csi.spiffe.io"
                readOnly: true
```

### 7.6 Phase 5: Deploy East-West Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: istio-system
  labels:
    topology.istio.io/network: network1
  annotations:
    networking.istio.io/service-type: LoadBalancer
    inject.istio.io/templates: "gateway,spire-gateway"
spec:
  gatewayClassName: istio
  listeners:
  - name: cross-network
    port: 15443
    protocol: TLS
    tls:
      mode: Passthrough
    allowedRoutes:
      namespaces:
        from: All
```

### 7.7 Phase 6: Create Remote Secrets

Remote Secrets enable cross-cluster service discovery:

```bash
# Get kubeconfig for cluster2 and create secret in cluster1
# First, create a service account with read access in cluster2
cat <<EOF | oc apply -f - --kubeconfig=$KUBECONFIG_CLUSTER2
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istiod-reader
  namespace: istio-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istiod-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
- kind: ServiceAccount
  name: istiod-reader
  namespace: istio-system
EOF

# Create token
TOKEN=$(oc create token istiod-reader -n istio-system --duration=8760h --kubeconfig=$KUBECONFIG_CLUSTER2)

# Create kubeconfig for remote access
cat <<EOF > /tmp/cluster2-kubeconfig
apiVersion: v1
kind: Config
clusters:
- name: cluster2
  cluster:
    server: https://api.cluster2.example.com:6443
    certificate-authority-data: <CA_DATA>
contexts:
- name: cluster2
  context:
    cluster: cluster2
    user: istiod-reader
current-context: cluster2
users:
- name: istiod-reader
  user:
    token: $TOKEN
EOF

# Create secret in cluster1
oc create secret generic istio-remote-secret-cluster2 \
  -n istio-system \
  --from-file=cluster2=/tmp/cluster2-kubeconfig \
  --kubeconfig=$KUBECONFIG_CLUSTER1

oc label secret istio-remote-secret-cluster2 \
  -n istio-system \
  istio/multiCluster=true \
  --kubeconfig=$KUBECONFIG_CLUSTER1
```

### 7.8 Phase 7: Create ClusterSPIFFEID with Federation

```yaml
# For istio-system namespace
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-system-spiffeid
spec:
  className: zero-trust-workload-identity-manager-spire  # REQUIRED!
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels: {}
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: istio-system
  federatesWith:
    - apps.cluster2.example.com

---
# For application namespace
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-test-spiffeid
spec:
  className: zero-trust-workload-identity-manager-spire  # REQUIRED!
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels: {}
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: istio-test
  federatesWith:
    - apps.cluster2.example.com
```

### 7.9 Phase 8: Deploy Test Workloads

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: istio-test
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: helloworld
  namespace: istio-test
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: curl
  namespace: istio-test
---
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  namespace: istio-test
spec:
  ports:
  - port: 5000
    name: http
  selector:
    app: helloworld
---
# Deploy v1 on Cluster 1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld-v1
  namespace: istio-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: helloworld
      version: v1
  template:
    metadata:
      labels:
        app: helloworld
        version: v1
      annotations:
        inject.istio.io/templates: "sidecar,spire"
    spec:
      serviceAccountName: helloworld
      containers:
      - name: helloworld
        image: docker.io/istio/examples-helloworld-v1
        ports:
        - containerPort: 5000
---
# Deploy curl client on Cluster 1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl
  namespace: istio-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl
  template:
    metadata:
      labels:
        app: curl
      annotations:
        inject.istio.io/templates: "sidecar,spire"
    spec:
      serviceAccountName: curl
      containers:
      - name: curl
        image: docker.io/curlimages/curl:latest
        command: ["sleep", "infinity"]
```

---

## 8. Issues Encountered and Solutions

### 8.1 Issue: Variable Substitution in YAML

**Symptom:**
```
ZeroTrustWorkloadIdentityManager.operator.openshift.io "cluster" is invalid: 
spec.clusterName: Invalid value: "$CLUSTER_NAME"
```

**Cause:** YAML files contained literal `$VARIABLE` placeholders that `oc apply` doesn't substitute.

**Solution:** Manually substitute variables before applying, or use `envsubst`:
```bash
envsubst < template.yaml | oc apply -f -
```

### 8.2 Issue: Missing https:// Prefix for jwtIssuer

**Symptom:**
```
SpireServer.operator.openshift.io "cluster" is invalid: 
spec.jwtIssuer: Invalid value: "oidc-discovery.apps..."
```

**Cause:** The `jwtIssuer` field requires a full URL with `https://` prefix.

**Solution:**
```yaml
spec:
  jwtIssuer: https://oidc-discovery.apps.cluster1.example.com  # Include https://
```

### 8.3 Issue: Namespace Doesn't Exist for Istio Components

**Symptom:**
```
error reconciling resource: validation error: namespace "istio-cni" doesn't exist
```

**Cause:** Istio CRs require pre-existing namespaces.

**Solution:**
```bash
oc create namespace istio-cni
oc create namespace istio-system
```

### 8.4 Issue: Duplicate Container in Pod Spec

**Symptom:**
```
Pod "test-app-..." is invalid: 
spec.containers[1].image: Required value
spec.initContainers[1].name: Duplicate value: "istio-proxy"
```

**Cause:** Using `inject.istio.io/templates: "sidecar,spire"` with an Istio CR template that conflicts with the default sidecar template in Istio v1.27.3+.

**Solution for v1.27.3+:** Use pod annotations instead of templates:
```yaml
metadata:
  annotations:
    sidecar.istio.io/userVolume: '[{"name":"workload-socket","csi":{"driver":"csi.spiffe.io","readOnly":true}}]'
    sidecar.istio.io/userVolumeMount: '[{"name":"workload-socket","mountPath":"/run/secrets/workload-spiffe-uds","readOnly":true}]'
```

**Solution for v1.24.3:** The template approach works - ensure the Istio CR template is correctly defined.

### 8.5 Issue: SDS Server Failed - Read-Only File System

**Symptom:**
```
error	sds	SDS grpc server for workload proxies failed to set up UDS: 
failed to remove unix://var/run/secrets/workload-spiffe-uds/socket: 
remove var/run/secrets/workload-spiffe-uds/socket: read-only file system
```

**Cause:** pilot-agent is trying to create its own SDS server at the same path where the CSI volume is mounted. The CSI volume is read-only.

**Root Cause Analysis:**

1. Istio's default injection adds a volumeMount at `/var/run/secrets/workload-spiffe-uds` for a volume named `workload-socket`
2. Our template creates `workload-socket` as a CSI volume (read-only)
3. pilot-agent tries to create a socket at that path
4. CSI is read-only → failure

**Solution:** Ensure the CSI socket is already present so pilot-agent detects it and skips creating its own SDS server:

1. SPIRE Agent socket filename must be `socket` (not `spire-agent.sock`)
2. CSI must be mounted at `/run/secrets/workload-spiffe-uds`
3. pilot-agent will log: "Existing workload SDS socket found... Default Istio SDS Server won't be started"

### 8.6 Issue: Wrong Socket Filename

**Symptom:**
```
StreamSecrets gRPC config stream closed: immediate connect error: 
No such file or directory|remote address:./var/run/secrets/workload-spiffe-uds/socket
```

**Cause:** SPIRE Agent creates socket named `spire-agent.sock`, but Envoy expects `socket`.

**Solution:** Update SPIRE Agent ConfigMap:
```bash
oc get cm spire-agent -n zero-trust-workload-identity-manager -o json | jq '
  .data["agent.conf"] = (.data["agent.conf"] | fromjson | 
    .agent.socket_path = "/tmp/spire-agent/public/socket" |
    tojson)
' | oc apply -f -
```

### 8.7 Issue: Only Local CA in ROOTCA (No Federation)

**Symptom:** Cross-cluster traffic fails. Checking ROOTCA shows only local trust domain.

**Cause:** Multiple possible causes:

1. SPIRE Agent not configured with `default_all_bundles_name: ROOTCA`
2. ClusterSPIFFEID missing `className` field
3. ClusterSPIFFEID `federatesWith` not taking effect
4. SPIRE Server doesn't have federated bundle loaded

**Diagnosis:**
```bash
# Check SPIRE entries have federation
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -output json -socketPath /tmp/spire-server/private/api.sock | \
  jq '.entries[] | {path: .spiffe_id.path, federates_with}'

# Check bundles in SPIRE server
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list -socketPath /tmp/spire-server/private/api.sock
```

**Solution:**

1. Add `className: zero-trust-workload-identity-manager-spire` to ClusterSPIFFEID
2. Ensure SPIRE Agent ConfigMap has correct SDS settings
3. Restart SPIRE Agents after ConfigMap changes
4. Verify bundles are loaded in SPIRE Server

### 8.8 Issue: pilot-agent Fetching from Istiod Instead of SPIRE

**Symptom:** Certificates show Istiod as issuer, not SPIRE.

**Cause:** pilot-agent is not finding the SPIRE socket and creating its own SDS server.

**Diagnosis:**
```bash
# Check logs for this message
oc logs -n istio-test <pod> -c istio-proxy | grep "SDS socket"

# Should see:
# "Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket. 
#  Default Istio SDS Server won't be started"

# If you see this instead, SPIRE is not working:
# "Starting default Istio SDS Server"
# "CA Endpoint istiod.istio-system.svc:15012, provider Citadel"
```

**Solution:** Ensure all of these are correct:

1. SPIRE Agent socket path: `/tmp/spire-agent/public/socket`
2. CSI mount path: `/run/secrets/workload-spiffe-uds`
3. Volume name: `workload-socket`
4. `CREDENTIAL_SOCKET_EXISTS=true` in environment

### 8.9 Issue: East-West Gateway Not Using SPIRE Certificates

**Symptom:** E/W Gateway can't establish TLS with remote gateway.

**Cause:** Gateway deployment not using the spire-gateway template.

**Solution:** Ensure Gateway CR has the template annotation:
```yaml
metadata:
  annotations:
    inject.istio.io/templates: "gateway,spire-gateway"
```

Or manually patch the gateway deployment to add CSI volume.

### 8.10 Issue: Cross-Cluster Traffic Only Goes to Local Endpoints

**Symptom:** All requests go to v1 (local), never to v2 (remote).

**Causes:**
1. Remote secrets not configured
2. meshNetworks not configured
3. Istiod not synced with remote cluster

**Diagnosis:**
```bash
# Check Envoy knows about remote endpoints
oc exec -n istio-test $CURL_POD -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep helloworld

# Check remote secret exists
oc get secrets -n istio-system -l istio/multiCluster=true
```

**Solution:** Create remote secrets and verify meshNetworks configuration.

---

## 9. What ZTWIM Operator Should Handle Automatically

This section provides insights for the ZTWIM operator development team on what could be automated.

### 9.1 Current Manual Steps That Should Be Automated

| Manual Step | Why It Should Be Automated | Suggested Implementation |
|-------------|---------------------------|--------------------------|
| **Socket path configuration** | Users consistently get this wrong. The socket must be named `socket` for Istio compatibility. | Operator should set `socket_path: /tmp/spire-agent/public/socket` by default |
| **SDS bundle configuration** | Required for federation to work. Users often miss this. | Operator should automatically add `sds.default_all_bundles_name: ROOTCA` when federation is enabled |
| **className in ClusterSPIFFEID** | Required for federatesWith but not documented. Silent failure otherwise. | Operator should automatically inject className, or validation should fail if federatesWith without className |
| **CREATE_ONLY_MODE** | Users need this to prevent operator from reverting ConfigMap changes | This is a workaround - operator should preserve user customizations in specific fields |
| **Federation bundle bootstrap** | Complex manual process to extract and exchange bundles | Operator should auto-fetch and load bundles when ClusterFederatedTrustDomain is created |
| **Federation route creation** | Manual when managedRoute doesn't work | Operator should reliably create the federation route |

### 9.2 Suggested Operator Enhancements

#### 9.2.1 Auto-Configure for Istio Integration

When detecting OSSM/Istio is installed, ZTWIM should:

```yaml
# Automatic when Istio detected
agent:
  socket_path: "/tmp/spire-agent/public/socket"  # Istio-compatible filename
  sds:
    default_bundle_name: "null"
    default_all_bundles_name: "ROOTCA"
```

#### 9.2.2 Validate ClusterSPIFFEID Configuration

```go
// Pseudo-code for validation
func ValidateClusterSPIFFEID(spec ClusterSPIFFEIDSpec) error {
    if len(spec.FederatesWith) > 0 && spec.ClassName == "" {
        return fmt.Errorf("className is required when federatesWith is specified")
    }
    return nil
}
```

#### 9.2.3 Auto-Bootstrap Federation

```go
// When ClusterFederatedTrustDomain is created
func (r *Reconciler) ReconcileFederation(cftd ClusterFederatedTrustDomain) error {
    // 1. Check if bundle is already loaded
    bundles := r.spireClient.ListBundles()
    if !containsBundle(bundles, cftd.Spec.TrustDomain) {
        // 2. If trustDomainBundle provided, load it
        if cftd.Spec.TrustDomainBundle != "" {
            r.spireClient.SetBundle(cftd.Spec.TrustDomain, cftd.Spec.TrustDomainBundle)
        } else {
            // 3. Otherwise, try to fetch from bundleEndpointURL
            bundle, err := r.fetchBundle(cftd.Spec.BundleEndpointURL)
            if err != nil {
                return fmt.Errorf("could not bootstrap federation: %v", err)
            }
            r.spireClient.SetBundle(cftd.Spec.TrustDomain, bundle)
        }
    }
    return nil
}
```

#### 9.2.4 Status Reporting for Federation

The operator should report federation status:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: cluster2-federation
spec:
  trustDomain: cluster2.example.com
  ...
status:
  bundleLoaded: true
  lastBundleRefresh: "2026-02-03T07:00:00Z"
  bundleExpiry: "2026-02-04T07:00:00Z"
  conditions:
  - type: Ready
    status: "True"
    message: "Federation bundle loaded and valid"
  - type: BundleRefreshable
    status: "True"
    message: "Can reach federation endpoint"
```

#### 9.2.5 Integration-Aware Defaults

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: apps.cluster1.example.com
  clusterName: cluster1
  integrations:
    istio:
      enabled: true
      # Automatically configures:
      # - Socket path compatible with Istio
      # - SDS bundle settings for ROOTCA
      # - Creates ClusterSPIFFEID for istio-system
    multiCluster:
      enabled: true
      federatesWith:
        - trustDomain: apps.cluster2.example.com
          bundleEndpointURL: https://federation.apps.cluster2.example.com
      # Automatically:
      # - Enables federation on SpireServer
      # - Creates ClusterFederatedTrustDomain
      # - Adds className to ClusterSPIFFEIDs
      # - Adds federatesWith to ClusterSPIFFEIDs
```

### 9.3 Documentation Improvements Needed

| Topic | Current State | Needed |
|-------|---------------|--------|
| **Socket path for Istio** | Not documented | Must be `/tmp/spire-agent/public/socket` |
| **SDS configuration** | Not documented | `default_all_bundles_name: ROOTCA` required |
| **className requirement** | Not documented | Required for federatesWith |
| **Federation bootstrap** | Partially documented | Step-by-step bundle extraction and loading |
| **CREATE_ONLY_MODE** | Not documented | When and why to use it |
| **Istio version compatibility** | Not documented | Template vs annotation approaches |

---

## 10. Configuration Reference

### 10.1 SPIRE Agent ConfigMap

```json
{
  "agent": {
    "data_dir": "/var/lib/spire",
    "log_format": "text",
    "log_level": "info",
    "retry_bootstrap": true,
    "server_address": "spire-server.zero-trust-workload-identity-manager",
    "server_port": "443",
    "socket_path": "/tmp/spire-agent/public/socket",
    "trust_bundle_path": "/run/spire/bundle/bundle.crt",
    "trust_domain": "apps.cluster1.example.com",
    "sds": {
      "default_bundle_name": "null",
      "default_all_bundles_name": "ROOTCA"
    }
  },
  "plugins": {
    "NodeAttestor": [
      {
        "k8s_psat": {
          "plugin_data": {
            "cluster": "cluster1"
          }
        }
      }
    ],
    "WorkloadAttestor": [
      {
        "k8s": {
          "plugin_data": {
            "node_name_env": "MY_NODE_NAME"
          }
        }
      }
    ]
  }
}
```

### 10.2 SpireServer CR for Federation

```yaml
apiVersion: spire.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
  namespace: zero-trust-workload-identity-manager
spec:
  caSubject:
    commonName: "SPIRE Server CA"
    country: "US"
    organization: "MyOrg"
  jwtIssuer: https://oidc-discovery.apps.cluster1.example.com
  federation:
    bundleEndpoint:
      profile: https_spiffe
      refreshHint: 300
    federatesWith:
      - trustDomain: apps.cluster2.example.com
        bundleEndpointUrl: https://spire-server-federation.apps.cluster2.example.com
        bundleEndpointProfile: https_spiffe
        endpointSpiffeId: spiffe://apps.cluster2.example.com/spire/server
    managedRoute: "true"
```

### 10.3 Istio CR for SPIRE Integration

```yaml
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  namespace: istio-system
  version: v1.24.3
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1
      meshNetworks:
        network1:
          endpoints:
            - fromRegistry: cluster1
          gateways:
            - address: <CLUSTER1_EW_GATEWAY_IP>
              port: 15443
        network2:
          endpoints:
            - fromRegistry: cluster2
          gateways:
            - address: <CLUSTER2_EW_GATEWAY_IP>
              port: 15443
    meshConfig:
      trustDomain: apps.cluster1.example.com
      trustDomainAliases:
        - apps.cluster2.example.com
    sidecarInjectorWebhook:
      templates:
        spire: |
          spec:
            containers:
            - name: istio-proxy
              env:
              - name: CREDENTIAL_SOCKET_EXISTS
                value: "true"
              - name: ISTIO_META_TLS_CLIENT_ROOT_CERT
                value: ""
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
            - name: workload-socket
              csi:
                driver: "csi.spiffe.io"
                readOnly: true
        spire-gateway: |
          spec:
            containers:
            - name: istio-proxy
              env:
              - name: CREDENTIAL_SOCKET_EXISTS
                value: "true"
              - name: ISTIO_META_TLS_CLIENT_ROOT_CERT
                value: ""
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
            - name: workload-socket
              csi:
                driver: "csi.spiffe.io"
                readOnly: true
```

### 10.4 ClusterSPIFFEID with Federation

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-test-spiffeid
spec:
  className: zero-trust-workload-identity-manager-spire  # REQUIRED!
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels: {}
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: istio-test
  federatesWith:
    - apps.cluster2.example.com
```

### 10.5 East-West Gateway CR

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: istio-system
  labels:
    topology.istio.io/network: network1
  annotations:
    networking.istio.io/service-type: LoadBalancer
    # NOTE: inject.istio.io/templates: "gateway,spire-gateway" is NOT required
    # for TLS Passthrough mode because the gateway doesn't terminate TLS
spec:
  gatewayClassName: istio
  listeners:
  - name: cross-network
    port: 15443
    protocol: TLS
    tls:
      mode: Passthrough  # Gateway is transparent, doesn't need SPIRE certs
    allowedRoutes:
      namespaces:
        from: All
```

> **Note:** For TLS Passthrough mode, the E/W Gateway does NOT need SPIRE certificates.
> The gateway only routes encrypted traffic by SNI - the actual mTLS handshake happens
> end-to-end between the workload Envoys. SPIRE certificates would only be needed if
> the gateway was using TLS Terminate or mTLS mode.

---

## 11. Troubleshooting Guide

### 11.1 Diagnostic Commands

#### Check SPIRE Server Status
```bash
# List all registration entries
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -output json -socketPath /tmp/spire-server/private/api.sock | \
  jq '.entries[] | {spiffe_id: .spiffe_id.path, federates_with: .federates_with}'

# List all bundles (including federated)
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list -socketPath /tmp/spire-server/private/api.sock

# Check federation status
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server federation list -socketPath /tmp/spire-server/private/api.sock
```

#### Check SPIRE Agent Status
```bash
# Check agent health
oc exec -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent -- \
  curl -s localhost:9982/ready

# Check agent logs
oc logs -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent | tail -50
```

#### Check Workload Certificates
```bash
# Get certificate from Envoy
oc exec -n istio-test $POD -c istio-proxy -- \
  curl -s localhost:15000/config_dump | \
  jq -r '.configs[] | select(.["@type"] | contains("SecretsConfigDump")) | 
    .dynamic_active_secrets[] | select(.name == "default") | 
    .secret.tls_certificate.certificate_chain.inline_bytes' | \
  base64 -d | openssl x509 -noout -text

# Check SPIFFE ID
oc exec -n istio-test $POD -c istio-proxy -- \
  curl -s localhost:15000/config_dump | \
  jq -r '.configs[] | select(.["@type"] | contains("SecretsConfigDump")) | 
    .dynamic_active_secrets[] | select(.name == "default") | 
    .secret.tls_certificate.certificate_chain.inline_bytes' | \
  base64 -d | openssl x509 -noout -ext subjectAltName
```

#### Check Trust Bundles in Envoy
```bash
# Check ROOTCA configuration
oc exec -n istio-test $POD -c istio-proxy -- \
  curl -s localhost:15000/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("SecretsConfigDump")) | 
    .dynamic_active_secrets[] | select(.name == "ROOTCA") | 
    .secret.validation_context.custom_validator_config.typed_config.trust_domains[].name'
```

#### Check Envoy Cluster Stats
```bash
# Check upstream cluster stats for remote endpoints
oc exec -n istio-test $POD -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep -E "helloworld.*cx_|rq_"

# Check for connection failures
oc exec -n istio-test $POD -c istio-proxy -- \
  curl -s localhost:15000/clusters | grep "cx_connect_fail"
```

### 11.2 Common Issues Checklist

| Issue | Check | Solution |
|-------|-------|----------|
| Pods stuck in init | `oc get istiocni` | Deploy IstioCNI |
| Envoy not starting | `oc logs $POD -c istio-proxy` | Check for SDS errors |
| No SPIRE cert | Check for "Existing workload SDS socket found" log | Fix socket path |
| Only local CA | Check SPIRE entries have `federates_with` | Add className to ClusterSPIFFEID |
| Cross-cluster fails | Check meshNetworks, Remote Secrets | Configure multi-cluster settings |
| TLS handshake fails | Check both sides have federated bundles | Verify federation on both clusters |

---

## 12. Appendix

### 12.1 Version Compatibility Matrix

| OSSM Version | Istio Version | Template Approach | userVolume Annotations |
|-------------|---------------|-------------------|----------------------|
| OSSM 3.2.1 | v1.24.3 | ✅ Works | ✅ Works |
| OSSM 3.3.x | v1.27.3 | ❌ Broken | ✅ Required |

### 12.2 Key Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `CREDENTIAL_SOCKET_EXISTS` | `"true"` | Tell pilot-agent to use external SDS |
| `SPIFFE_ENDPOINT_SOCKET` | `"unix:///path/to/socket"` | Custom socket path (optional) |
| `ISTIO_META_TLS_CLIENT_ROOT_CERT` | `""` | Clear default root cert |

### 12.3 Key File Paths

| Path | Purpose |
|------|---------|
| `/tmp/spire-agent/public/socket` | SPIRE Agent SDS socket (host) |
| `/run/secrets/workload-spiffe-uds/socket` | CSI-mounted socket in pod |
| `/var/run/secrets/workload-spiffe-uds/socket` | Same as above (symlink) |
| `/tmp/spire-server/private/api.sock` | SPIRE Server admin socket |

### 12.4 Useful Commands Quick Reference

```bash
# Restart SPIRE Agents
oc delete pod -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent

# Check federation bundle
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list -socketPath /tmp/spire-server/private/api.sock

# Load federated bundle manually
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle set -id spiffe://remote.domain -path /tmp/bundle.pem \
  -socketPath /tmp/spire-server/private/api.sock

# Test cross-cluster traffic
for i in $(seq 1 10); do
  oc exec -n istio-test $CURL_POD -c curl -- curl -s helloworld.istio-test:5000/hello
done

# Check Istiod knows about remote cluster
oc exec -n istio-system deploy/istiod -- curl -s localhost:15014/debug/clusterz
```

### 12.5 Architecture Decision Records

#### ADR-001: Socket Path Must Be "socket"

**Context:** Envoy's bootstrap configuration in Istio hardcodes the SDS socket path as `./var/run/secrets/workload-spiffe-uds/socket`.

**Decision:** SPIRE Agent must create socket named `socket` (not `spire-agent.sock`).

**Consequences:** Requires patching the SPIRE Agent ConfigMap, which is overwritten by the operator unless CREATE_ONLY_MODE is enabled.

#### ADR-002: CSI Mount at /run/secrets/workload-spiffe-uds

**Context:** For pilot-agent to detect the existing SDS socket and skip creating its own, the socket must be at the expected path.

**Decision:** Mount CSI volume at `/run/secrets/workload-spiffe-uds`.

**Consequences:** The volume name must be `workload-socket` to match Istio's expected volume name.

#### ADR-003: className Required for federatesWith

**Context:** The SPIRE controller ignores `federatesWith` if `className` is not specified.

**Decision:** Always include `className: zero-trust-workload-identity-manager-spire` when using `federatesWith`.

**Consequences:** This is a non-obvious requirement that should be enforced by validation.

---

## Summary

This document has covered the complete integration of OpenShift Service Mesh with SPIRE via ZTWIM for multi-cluster mTLS. The key takeaways are:

1. **SPIRE replaces Istiod's CA** for workload certificates, providing SPIFFE-based identity and federation support.

2. **Federation enables cross-cluster trust** by exchanging CA certificates between SPIRE deployments.

3. **Critical configuration** includes:
   - Socket path: `/tmp/spire-agent/public/socket`
   - CSI mount: `/run/secrets/workload-spiffe-uds`
   - SDS config: `default_all_bundles_name: ROOTCA`
   - ClusterSPIFFEID: `className` + `federatesWith`

4. **Multi-cluster requires additional components**:
   - East-West Gateways for cross-cluster traffic
   - Remote Secrets for service discovery
   - meshNetworks configuration
   - trustDomainAliases configuration

5. **The ZTWIM operator could be enhanced** to automate many manual steps, particularly around Istio integration and federation bootstrap.

---

## 13. Deep Dive: Technical Internals and FAQs

This section provides detailed explanations for common questions about the integration internals.

### 13.0 What is SDS (Secret Discovery Service)?

**SDS = Secret Discovery Service** - an Envoy API for dynamically discovering and rotating TLS certificates and keys.

#### The Problem SDS Solves

Before SDS, certificates were configured statically in Envoy:

```yaml
# OLD WAY: Static certificate configuration
static_resources:
  clusters:
  - name: my_cluster
    transport_socket:
      name: envoy.transport_sockets.tls
      typed_config:
        common_tls_context:
          tls_certificates:
          - certificate_chain:
              filename: "/etc/certs/cert.pem"    # Static file path
            private_key:
              filename: "/etc/certs/key.pem"     # Static file path
          validation_context:
            trusted_ca:
              filename: "/etc/certs/ca.pem"      # Static file path
```

**Problems with static certificates:**
- **Certificate rotation requires Envoy restart** - downtime!
- **Files must exist before Envoy starts** - ordering dependencies
- **No dynamic updates** - can't change certs at runtime
- **No federation support** - can't dynamically add new trust bundles

#### How SDS Works

SDS is a gRPC API that allows Envoy to:
1. **Request** certificates dynamically at startup
2. **Receive** certificates from an SDS server
3. **Get updates** when certificates change (push-based)
4. **Rotate automatically** without restart

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           SDS PROTOCOL FLOW                                      │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                              ENVOY                                       │  │
│   │                                                                         │  │
│   │  1. On startup, Envoy's sds-grpc cluster connects to SDS server         │  │
│   │                                                                         │  │
│   │  2. Sends DiscoveryRequest:                                             │  │
│   │     {                                                                   │  │
│   │       "resource_names": ["default", "ROOTCA"],  // What we want         │  │
│   │       "type_url": "type.googleapis.com/envoy...Secret"                  │  │
│   │     }                                                                   │  │
│   │                                                                         │  │
│   │  3. Receives DiscoveryResponse:                                         │  │
│   │     {                                                                   │  │
│   │       "resources": [                                                    │  │
│   │         {                                                               │  │
│   │           "name": "default",                                            │  │
│   │           "tls_certificate": { cert, key }  // Workload cert            │  │
│   │         },                                                              │  │
│   │         {                                                               │  │
│   │           "name": "ROOTCA",                                             │  │
│   │           "validation_context": { trusted_ca }  // Trust bundle         │  │
│   │         }                                                               │  │
│   │       ]                                                                 │  │
│   │     }                                                                   │  │
│   │                                                                         │  │
│   │  4. When certs change, SDS server pushes new DiscoveryResponse          │  │
│   │     Envoy updates certs in-memory - NO RESTART NEEDED!                  │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### SDS Secret Names in Istio/SPIRE

| Secret Name | Contents | Purpose |
|-------------|----------|---------|
| `default` | X.509 certificate + private key | Workload's own identity certificate (SVID) |
| `ROOTCA` | Trust bundle (CA certificates) | CAs to trust for verifying peer certificates |
| `spiffe://<trust-domain>` | Individual trust bundle | CA for a specific trust domain (federation) |

#### SDS Server Implementations

There are multiple SDS server implementations:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    SDS SERVER IMPLEMENTATIONS                                    │
│                                                                                 │
│   1. ISTIOD'S BUILT-IN SDS (port 15012)                                         │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  - Istiod runs an SDS server on port 15012                               │  │
│   │  - pilot-agent connects to get CSRs signed                               │  │
│   │  - Returns Citadel-signed certificates                                   │  │
│   │  - Used for initial certificate issuance                                 │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   2. PILOT-AGENT'S LOCAL SDS (Unix socket)                                      │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  - pilot-agent creates a local SDS server in each pod                    │  │
│   │  - Listens on: /var/run/secrets/workload-spiffe-uds/socket               │  │
│   │  - Gets certs from Istiod, serves them to Envoy                          │  │
│   │  - Acts as a proxy/cache between Envoy and Istiod                        │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   3. SPIRE AGENT'S SDS (Unix socket)                                            │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  - SPIRE Agent runs an SDS server on each node                           │  │
│   │  - Listens on: /tmp/spire-agent/public/socket                            │  │
│   │  - Serves SPIRE-issued certificates directly                             │  │
│   │  - Includes federated trust bundles in ROOTCA                            │  │
│   │  - This is what we use to REPLACE pilot-agent's SDS                      │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### SDS Configuration in Envoy Bootstrap

Envoy's bootstrap configuration defines how to connect to the SDS server:

```json
{
  "static_resources": {
    "clusters": [
      {
        "name": "sds-grpc",
        "type": "STATIC",
        "http2_protocol_options": {},
        "load_assignment": {
          "cluster_name": "sds-grpc",
          "endpoints": [{
            "lb_endpoints": [{
              "endpoint": {
                "address": {
                  "pipe": {
                    "path": "./var/run/secrets/workload-spiffe-uds/socket"
                  }
                }
              }
            }]
          }]
        }
      }
    ]
  },
  "dynamic_resources": {
    "cds_config": { ... },
    "lds_config": { ... }
  }
}
```

The `sds-grpc` cluster is a special static cluster that:
- Uses a Unix socket (`pipe.path`) instead of TCP
- Envoy connects here to fetch secrets
- All dynamic TLS contexts reference this cluster

#### Why SDS is Critical for SPIRE Integration

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    WHY SDS MATTERS FOR SPIRE                                     │
│                                                                                 │
│   WITHOUT SDS:                                                                   │
│   - SPIRE would need to write certificate files to disk                         │
│   - Envoy would need to be restarted to pick up new certs                       │
│   - No way to dynamically add federated trust bundles                           │
│   - Certificate rotation would cause downtime                                    │
│                                                                                 │
│   WITH SDS:                                                                      │
│   - SPIRE Agent serves certs via gRPC - no files needed                         │
│   - Envoy receives certs at startup via SDS protocol                            │
│   - When SPIRE rotates certs, it pushes new ones to Envoy                       │
│   - Envoy updates in-memory - zero downtime                                     │
│   - Federated bundles are served under "ROOTCA" - dynamic trust                 │
│                                                                                 │
│   The SDS protocol is what makes the SPIRE integration seamless!                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### SDS Request/Response Example

```
Envoy → SPIRE Agent (SDS Request):
{
  "version_info": "",
  "node": { "id": "sidecar~10.128.0.5~helloworld-abc.istio-test~istio-test.svc.cluster.local" },
  "resource_names": ["default", "ROOTCA"],
  "type_url": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"
}

SPIRE Agent → Envoy (SDS Response):
{
  "version_info": "1234",
  "resources": [
    {
      "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret",
      "name": "default",
      "tls_certificate": {
        "certificate_chain": { "inline_bytes": "<base64-cert>" },
        "private_key": { "inline_bytes": "<base64-key>" }
      }
    },
    {
      "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret",
      "name": "ROOTCA",
      "validation_context": {
        "custom_validator_config": {
          "name": "envoy.tls.cert_validator.spiffe",
          "typed_config": {
            "trust_domains": [
              { "name": "cluster1.example.com", "trust_bundle": { ... } },
              { "name": "cluster2.example.com", "trust_bundle": { ... } }
            ]
          }
        }
      }
    }
  ]
}
```

#### Summary

| Aspect | Description |
|--------|-------------|
| **What is SDS?** | Envoy API for dynamic certificate discovery |
| **Protocol** | gRPC streaming (bidirectional) |
| **Transport** | Typically Unix socket (can be TCP) |
| **Key benefit** | Zero-downtime certificate rotation |
| **Secret names** | `default` (workload cert), `ROOTCA` (trust bundle) |
| **For SPIRE** | SPIRE Agent implements SDS server, Envoy connects directly |

---

### 13.1 Can We Use SPIRE Federation Without Service Mesh?

**Short Answer:** Yes, but you lose traffic management, routing, and observability.

#### What SPIRE Federation Alone Provides

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    SPIRE FEDERATION ONLY (NO SERVICE MESH)                      │
│                                                                                 │
│   CLUSTER 1                                         CLUSTER 2                   │
│                                                                                 │
│   ┌─────────────────────┐                          ┌─────────────────────┐     │
│   │ SPIRE Server        │◄────── Federation ──────►│ SPIRE Server        │     │
│   │ (CA 1 + CA 2)       │    (bundle exchange)     │ (CA 1 + CA 2)       │     │
│   └─────────────────────┘                          └─────────────────────┘     │
│                                                                                 │
│   ┌─────────────────────┐                          ┌─────────────────────┐     │
│   │ App A               │                          │ App B               │     │
│   │                     │                          │                     │     │
│   │ Has SPIRE cert      │       Direct mTLS?       │ Has SPIRE cert      │     │
│   │ Trusts CA1 + CA2    │◄─────────────────────────┤ Trusts CA1 + CA2    │     │
│   │                     │                          │                     │     │
│   │ ❓ But how does     │                          │                     │     │
│   │    App A know       │                          │                     │     │
│   │    App B exists?    │                          │                     │     │
│   │    And where is it? │                          │                     │     │
│   └─────────────────────┘                          └─────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

With SPIRE Federation alone:
- ✅ Workloads can get certificates
- ✅ Trust bundles are exchanged
- ✅ Workloads CAN verify each other's certificates
- ❌ **No service discovery** - how does App A find App B?
- ❌ **No traffic routing** - how does traffic reach App B across clusters?
- ❌ **No load balancing** - which instance of App B to use?
- ❌ **No traffic encryption** - the app itself must implement mTLS

#### What Service Mesh Adds

| Capability | Without Service Mesh | With Service Mesh (Istio) |
|------------|---------------------|---------------------------|
| **Service Discovery** | App must know exact IP/hostname | Istiod discovers services via Kubernetes API + Remote Secrets |
| **Cross-Cluster Routing** | App must implement | E/W Gateway + meshNetworks handles it |
| **mTLS Implementation** | App code must do TLS | Envoy sidecar does it transparently |
| **Load Balancing** | App must implement | Envoy handles it |
| **Traffic Management** | None | VirtualServices, DestinationRules |
| **Observability** | None | Metrics, traces, access logs |
| **Policy Enforcement** | None | AuthorizationPolicy |

#### When You Might Use SPIRE Without Service Mesh

1. **Non-HTTP workloads** that can't use Envoy (e.g., databases, message queues)
2. **Direct SPIFFE integration** - app uses SPIFFE SDK to get certificates directly
3. **Legacy apps** that already implement mTLS and just need certificates

#### Example: Direct SPIFFE SDK Usage (No Envoy)

```go
// App directly uses SPIRE Workload API
import "github.com/spiffe/go-spiffe/v2/workloadapi"

func main() {
    ctx := context.Background()
    
    // Connect to SPIRE Agent socket
    source, err := workloadapi.NewX509Source(ctx,
        workloadapi.WithClientOptions(
            workloadapi.WithAddr("unix:///run/spire/sockets/agent.sock"),
        ),
    )
    
    // Get X509-SVID (certificate)
    svid, err := source.GetX509SVID()
    
    // Get trust bundle (all trusted CAs including federated)
    bundle, err := source.GetX509BundleForTrustDomain(trustDomain)
    
    // Use certificates for mTLS
    tlsConfig := tlsconfig.MTLSClientConfig(svid, bundle, ...)
    
    // Make mTLS connection
    conn, err := tls.Dial("tcp", "app-b.cluster2:443", tlsConfig)
}
```

**Problem:** The app still needs to know `app-b.cluster2:443` exists and is reachable!

#### Why Service Mesh is Needed for Most Use Cases

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    WITH SERVICE MESH                                             │
│                                                                                 │
│   App A just calls: "helloworld.istio-test:5000"                                │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                           ISTIOD                                         │  │
│   │                                                                         │  │
│   │  1. Knows ALL services in ALL clusters (via Remote Secrets)             │  │
│   │  2. Pushes endpoint list to Envoy:                                      │  │
│   │     - helloworld @ 10.128.x.x (cluster1)                                │  │
│   │     - helloworld @ 10.131.x.x (cluster2, via gateway 34.47.x.x:15443)   │  │
│   │  3. Configures routing rules (meshNetworks)                             │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                         ENVOY SIDECAR                                    │  │
│   │                                                                         │  │
│   │  1. Intercepts App A's request to helloworld:5000                       │  │
│   │  2. Looks up endpoints (from Istiod config)                             │  │
│   │  3. Load balances between local and remote                              │  │
│   │  4. Routes remote traffic through E/W Gateway                           │  │
│   │  5. Performs mTLS using SPIRE certificates                              │  │
│   │  6. All transparent to App A!                                           │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Summary:** SPIRE provides the **identity and trust**. Service Mesh provides **discovery, routing, and transparent mTLS**.

---

### 13.2 SPIRE Server ↔ Agent Communication: Direction and Ports

This is a common point of confusion. Let's clarify exactly how SPIRE Server and Agent communicate.

#### Communication Direction

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│              SPIRE SERVER ↔ AGENT COMMUNICATION                                  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                        SPIRE SERVER                                      │  │
│   │                     (StatefulSet: spire-server-0)                        │  │
│   │                                                                         │  │
│   │  Listens on:                                                            │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Port 8081 (gRPC) - Agent API                                     │   │  │
│   │  │   - Agents connect HERE to:                                      │   │  │
│   │  │     • Attest themselves (node attestation)                       │   │  │
│   │  │     • Fetch SVIDs for workloads                                  │   │  │
│   │  │     • Get trust bundles                                          │   │  │
│   │  │   - mTLS authenticated (agents have node SVID)                   │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Unix Socket: /tmp/spire-server/private/api.sock                  │   │  │
│   │  │   - Admin API for CLI commands                                   │   │  │
│   │  │   - Used by: spire-server entry show, bundle list, etc.          │   │  │
│   │  │   - Only accessible within the server pod                        │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Port 8443 (HTTPS) - Federation Endpoint                          │   │  │
│   │  │   - Serves trust bundle to federated SPIRE servers               │   │  │
│   │  │   - Exposed via OpenShift Route                                  │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                         ▲                                       │
│                                         │                                       │
│                           gRPC over mTLS (port 8081)                            │
│                           AGENT INITIATES CONNECTION                            │
│                                         │                                       │
│                                         │                                       │
│   ┌─────────────────────────────────────┴───────────────────────────────────┐  │
│   │                        SPIRE AGENT                                       │  │
│   │                     (DaemonSet: spire-agent-xxxxx)                       │  │
│   │                                                                         │  │
│   │  Connects TO Server:                                                    │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Outbound connection to spire-server:8081                         │   │  │
│   │  │   - Agent INITIATES the connection (not server)                  │   │  │
│   │  │   - Uses bootstrap trust bundle to verify server                 │   │  │
│   │  │   - First connection: node attestation                           │   │  │
│   │  │   - Subsequent: fetch SVIDs, sync bundles                        │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  Listens FOR Workloads:                                                 │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Unix Socket: /tmp/spire-agent/public/socket                      │   │  │
│   │  │   - Workload API (SDS for Envoy)                                 │   │  │
│   │  │   - Workloads connect HERE to get certificates                   │   │  │
│   │  │   - CSI driver exposes this socket into pods                     │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Key Points

| Aspect | Details |
|--------|---------|
| **Who initiates?** | **Agent initiates** connection TO Server (not the other way) |
| **Server port** | 8081 (gRPC) - Agent API |
| **Protocol** | gRPC over mTLS |
| **Authentication** | Agent uses node SVID (obtained via node attestation) |
| **In Kubernetes** | Agent connects to `spire-server.zero-trust-workload-identity-manager:8081` |
| **In ZTWIM config** | `server_address: spire-server.zero-trust-workload-identity-manager`, `server_port: "443"` (Service port, maps to 8081) |

#### Agent Configuration for Server Connection

```json
{
  "agent": {
    "server_address": "spire-server.zero-trust-workload-identity-manager",
    "server_port": "443",  // Kubernetes Service port (maps to container port 8081)
    "trust_bundle_path": "/run/spire/bundle/bundle.crt",  // Bootstrap trust
    ...
  }
}
```

#### Why Agent Initiates (Not Server)?

1. **Scalability**: Thousands of nodes, one server - easier for agents to connect out
2. **Firewall-friendly**: Outbound connections are typically easier to allow
3. **NAT-friendly**: Agents behind NAT can reach server
4. **Dynamic nodes**: Agents can come and go without server knowing

---

### 13.3 The CSI Volume Deep Dive: What It Is and How It Works

The CSI volume is one of the most misunderstood parts of the integration.

#### What is a CSI Volume?

**CSI = Container Storage Interface** - a standard for exposing storage to containers.

The **SPIFFE CSI Driver** (`csi.spiffe.io`) is a special CSI driver that:
- Does NOT provide traditional storage (no files, no persistence)
- Instead, creates a **Unix domain socket** inside the mounted directory
- This socket connects to the SPIRE Agent running on the same node

#### The CSI Volume Specification

```yaml
volumes:
- name: workload-socket          # Volume name (must match volumeMount)
  csi:
    driver: "csi.spiffe.io"      # The SPIFFE CSI driver
    readOnly: true               # Socket is read-only (can only connect, not modify)
```

And the corresponding mount:

```yaml
volumeMounts:
- name: workload-socket
  mountPath: /run/secrets/workload-spiffe-uds   # Where to mount in the container
  readOnly: true
```

#### How the CSI Driver Creates the Socket

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    CSI DRIVER SOCKET CREATION                                    │
│                                                                                 │
│   STEP 1: Pod is scheduled to a node                                           │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  Kubernetes Scheduler: "Pod xyz goes to node-1"                          │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                         │                                       │
│                                         ▼                                       │
│   STEP 2: Kubelet sees CSI volume, calls CSI driver                            │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  Kubelet: "Hey csi.spiffe.io driver, mount volume for pod xyz"           │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                         │                                       │
│                                         ▼                                       │
│   STEP 3: CSI driver creates mount directory                                   │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  CSI Driver creates: /var/lib/kubelet/pods/<pod-uid>/volumes/            │  │
│   │                      kubernetes.io~csi/workload-socket/mount/            │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                         │                                       │
│                                         ▼                                       │
│   STEP 4: CSI driver creates Unix socket in that directory                     │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  CSI Driver creates socket: .../mount/socket                             │  │
│   │                                                                         │  │
│   │  This socket is connected to the SPIRE Agent's socket on the host:      │  │
│   │  /tmp/spire-agent/public/socket                                         │  │
│   │                                                                         │  │
│   │  Technical detail: CSI driver uses socat/proxy to bridge the sockets    │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                         │                                       │
│                                         ▼                                       │
│   STEP 5: Kubelet mounts the directory into the container                      │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  In container: /run/secrets/workload-spiffe-uds/socket                   │  │
│   │  Points to: SPIRE Agent on the host                                      │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                         │                                       │
│                                         ▼                                       │
│   STEP 6: Envoy connects to the socket                                         │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  Envoy (inside container): connect("/run/secrets/workload-spiffe-uds/    │  │
│   │                                     socket")                             │  │
│   │  → Traffic flows to SPIRE Agent on host                                  │  │
│   │  → Agent returns certificates via SDS protocol                           │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Which Pods Need the CSI Volume?

| Pod Type | Needs CSI? | Why? |
|----------|------------|------|
| **Application pods with Envoy sidecar** | ✅ YES | Envoy needs SPIRE certs |
| **Istiod** | ❌ NO | Uses its own CA (we're not replacing control plane certs) |
| **E/W Gateway** | ⚠️ DEPENDS | Only if TLS Terminate mode (not needed for Passthrough) |
| **Istio CNI** | ❌ NO | Doesn't need certificates |
| **SPIRE Agent** | ❌ NO | Agent IS the source, doesn't need to connect to itself |
| **SPIRE Server** | ❌ NO | Server has its own certs |

#### Who Adds the CSI Volume to Pods?

The CSI volume is added via the **Istio sidecar injector** using the **spire template** we defined:

```yaml
# In Istio CR
sidecarInjectorWebhook:
  templates:
    spire: |
      spec:
        containers:
        - name: istio-proxy
          volumeMounts:
          - name: workload-socket
            mountPath: /run/secrets/workload-spiffe-uds
            readOnly: true
        volumes:
        - name: workload-socket
          csi:
            driver: "csi.spiffe.io"
            readOnly: true
```

When a pod has the annotation:
```yaml
annotations:
  inject.istio.io/templates: "sidecar,spire"
```

Istio's mutating webhook:
1. Injects the `istio-proxy` sidecar container
2. Applies the `spire` template, adding the CSI volume and mount

#### Why the Socket Filename Matters

The SPIRE Agent creates a socket with a specific filename based on its config:

```json
{
  "agent": {
    "socket_path": "/tmp/spire-agent/public/socket"  // Filename is "socket"
  }
}
```

The CSI driver mirrors this filename in the pod. If SPIRE Agent uses `spire-agent.sock`, the pod gets `spire-agent.sock`. If it uses `socket`, the pod gets `socket`.

Envoy expects `socket` (hardcoded in Istio), so SPIRE Agent MUST use `socket`.

---

### 13.4 Citadel Port 15012: What Is It?

**Citadel** is the historical name for Istio's built-in Certificate Authority. In modern Istio, Citadel is integrated into Istiod.

#### Port 15012: The CA/SDS Port

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           ISTIOD PORTS                                           │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                            ISTIOD                                        │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Port 15010 - xDS (plaintext, deprecated)                         │   │  │
│   │  │   - Envoy config distribution (insecure)                         │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Port 15012 - xDS over mTLS + CA/SDS                              │   │  │
│   │  │                                                                   │   │  │
│   │  │   TWO functions on this port:                                     │   │  │
│   │  │                                                                   │   │  │
│   │  │   1. XDS CONFIG DISTRIBUTION                                      │   │  │
│   │  │      - Envoy proxies connect here for config                     │   │  │
│   │  │      - Clusters, routes, listeners, endpoints                    │   │  │
│   │  │      - Authenticated via mTLS or JWT                             │   │  │
│   │  │                                                                   │   │  │
│   │  │   2. CERTIFICATE AUTHORITY (Citadel)                              │   │  │
│   │  │      - pilot-agent connects here to get certificates             │   │  │
│   │  │      - Sends CSR (Certificate Signing Request)                   │   │  │
│   │  │      - Receives signed certificate                               │   │  │
│   │  │      - This is what we BYPASS when using SPIRE                   │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Port 15014 - Debug/Metrics                                        │   │  │
│   │  │   - Prometheus metrics                                           │   │  │
│   │  │   - Debug endpoints                                              │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   │                                                                         │  │
│   │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│   │  │ Port 15017 - Webhook                                              │   │  │
│   │  │   - Sidecar injection webhook                                    │   │  │
│   │  │   - Validation webhook                                           │   │  │
│   │  └─────────────────────────────────────────────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### What Happens on Port 15012 (Default Istio)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    DEFAULT FLOW (NO SPIRE)                                       │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                       pilot-agent (in pod)                               │  │
│   │                                                                         │  │
│   │  On startup:                                                            │  │
│   │  1. Connect to istiod.istio-system.svc:15012                            │  │
│   │  2. Send CSR (Certificate Signing Request)                              │  │
│   │  3. Istiod's Citadel CA signs the certificate                           │  │
│   │  4. Receive signed certificate                                          │  │
│   │  5. Create local SDS server at /var/run/secrets/.../socket              │  │
│   │  6. Serve certificate to Envoy                                          │  │
│   │                                                                         │  │
│   │  Log shows: "CA Endpoint istiod.istio-system.svc:15012, provider Citadel"│  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### What Happens with SPIRE (Bypassing 15012 for Certs)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    SPIRE FLOW (BYPASSING CITADEL)                               │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │                       pilot-agent (in pod)                               │  │
│   │                                                                         │  │
│   │  On startup (with CREDENTIAL_SOCKET_EXISTS=true):                       │  │
│   │  1. Check if socket exists at /var/run/secrets/.../socket               │  │
│   │  2. Socket EXISTS (SPIRE CSI mounted it)                                │  │
│   │  3. Log: "Existing workload SDS socket found... Default SDS won't start"│  │
│   │  4. Do NOT connect to istiod:15012 for certificates                     │  │
│   │  5. Do NOT create local SDS server                                      │  │
│   │  6. Envoy connects directly to SPIRE socket                             │  │
│   │                                                                         │  │
│   │  STILL connects to istiod:15012 for xDS config (routes, clusters, etc.) │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Important:** Even with SPIRE, the connection to `istiod:15012` still happens for **xDS configuration** (routing rules, service endpoints, etc.). Only the **certificate fetching** is bypassed.

---

### 13.5 pilot-agent's Local SDS Server vs Port 15012

This is a crucial distinction that causes confusion.

#### Two Different SDS Servers

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    TWO SDS SERVERS - DON'T CONFUSE THEM!                        │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  SDS SERVER #1: ISTIOD (port 15012)                                      │  │
│   │                                                                         │  │
│   │  Location: Istiod pod, accessible at istiod.istio-system.svc:15012      │  │
│   │  Purpose: Issue certificates (Citadel CA)                               │  │
│   │  Protocol: gRPC over mTLS                                               │  │
│   │  Clients: pilot-agents connecting from all pods                         │  │
│   │                                                                         │  │
│   │  Flow:                                                                  │  │
│   │  pilot-agent ──[CSR]──► istiod:15012 ──[Signed Cert]──► pilot-agent     │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  SDS SERVER #2: pilot-agent (local Unix socket)                          │  │
│   │                                                                         │  │
│   │  Location: Inside each pod at /var/run/secrets/workload-spiffe-uds/socket│  │
│   │  Purpose: Serve certificates TO Envoy                                   │  │
│   │  Protocol: gRPC over Unix socket                                        │  │
│   │  Clients: Envoy in the same pod                                         │  │
│   │                                                                         │  │
│   │  Flow:                                                                  │  │
│   │  Envoy ──[SDS request]──► pilot-agent socket ──[Cert]──► Envoy          │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  WITH SPIRE: SDS SERVER #3 replaces #2                                   │  │
│   │                                                                         │  │
│   │  Location: SPIRE Agent socket mounted via CSI                           │  │
│   │  Purpose: Serve SPIRE certificates TO Envoy                             │  │
│   │  Protocol: gRPC over Unix socket                                        │  │
│   │  Clients: Envoy in the pod                                              │  │
│   │                                                                         │  │
│   │  Flow:                                                                  │  │
│   │  Envoy ──[SDS request]──► SPIRE Agent socket ──[SPIRE Cert]──► Envoy    │  │
│   │                                                                         │  │
│   │  pilot-agent sees existing socket, doesn't create #2, doesn't use #1    │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Summary Table

| SDS Server | Location | Who Creates It | Who Connects | Purpose |
|------------|----------|----------------|--------------|---------|
| Istiod CA | istiod:15012 | Istiod | pilot-agents | Issue certs |
| pilot-agent local | `/var/run/.../socket` | pilot-agent | Envoy | Serve certs to Envoy |
| SPIRE Agent | `/tmp/spire-agent/.../socket` | SPIRE Agent | Envoy (via CSI) | Serve SPIRE certs |

---

### 13.6 The Socket Path: Where Does `/var/run/secrets/workload-spiffe-uds/socket` Come From?

This path is **hardcoded in multiple places** in Istio. Let's trace its origin.

#### The Hardcoding Chain

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    SOCKET PATH HARDCODING                                        │
│                                                                                 │
│   1. ENVOY BOOTSTRAP CONFIGURATION (generated by pilot-agent)                   │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  File: /etc/istio/proxy/envoy-rev.json (inside istio-proxy container)    │  │
│   │                                                                         │  │
│   │  {                                                                      │  │
│   │    "static_resources": {                                                │  │
│   │      "clusters": [                                                      │  │
│   │        {                                                                │  │
│   │          "name": "sds-grpc",                                            │  │
│   │          "load_assignment": {                                           │  │
│   │            "endpoints": [{                                              │  │
│   │              "lb_endpoints": [{                                         │  │
│   │                "endpoint": {                                            │  │
│   │                  "address": {                                           │  │
│   │                    "pipe": {                                            │  │
│   │                      "path": "./var/run/secrets/workload-spiffe-uds/socket"
│   │                    }           ▲                                        │  │
│   │                  }             │                                        │  │
│   │                }               │ HARDCODED HERE!                        │  │
│   │              }]                │                                        │  │
│   │            }]                  │                                        │  │
│   │          }                                                              │  │
│   │        }                                                                │  │
│   │      ]                                                                  │  │
│   │    }                                                                    │  │
│   │  }                                                                      │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   2. PILOT-AGENT SDS SERVER PATH                                                │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  Istio source code: pilot/pkg/bootstrap/sds.go                          │  │
│   │                                                                         │  │
│   │  const (                                                                │  │
│   │      // WorkloadIdentitySocketPath is the default path for the workload │  │
│   │      // identity socket                                                 │  │
│   │      WorkloadIdentitySocketPath = "./var/run/secrets/workload-spiffe-uds/socket"
│   │  )                             ▲                                        │  │
│   │                                │                                        │  │
│   │                                │ HARDCODED IN ISTIO SOURCE!             │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   3. WHY THE "./" PREFIX?                                                       │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  The "./" makes it a RELATIVE path from Envoy's working directory       │  │
│   │                                                                         │  │
│   │  Envoy working directory: / (root)                                      │  │
│   │  Relative path: ./var/run/secrets/workload-spiffe-uds/socket            │  │
│   │  Absolute path: /var/run/secrets/workload-spiffe-uds/socket             │  │
│   │                                                                         │  │
│   │  On Linux: /run is symlinked to /var/run                                │  │
│   │  So: /run/secrets/... = /var/run/secrets/...                            │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
│   4. THE FILENAME "socket"                                                      │
│   ┌─────────────────────────────────────────────────────────────────────────┐  │
│   │  The filename is also hardcoded as "socket"                              │  │
│   │                                                                         │  │
│   │  If SPIRE Agent creates "spire-agent.sock" instead of "socket":         │  │
│   │  - Path becomes: /var/run/secrets/workload-spiffe-uds/spire-agent.sock  │  │
│   │  - Envoy looks for: /var/run/secrets/workload-spiffe-uds/socket         │  │
│   │  - MISMATCH! Envoy fails with "No such file or directory"               │  │
│   │                                                                         │  │
│   │  This is why SPIRE Agent config MUST have:                              │  │
│   │  socket_path: "/tmp/spire-agent/public/socket"  (ends with "socket")    │  │
│   └─────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Can We Change This Path?

**In theory:** Yes, using `SPIFFE_ENDPOINT_SOCKET` environment variable.

```yaml
env:
- name: SPIFFE_ENDPOINT_SOCKET
  value: "unix:///custom/path/to/socket"
```

**In practice:** This causes issues because:
1. Envoy's bootstrap is generated at container start with the default path
2. Changing mid-flight requires complex config
3. Some Istio versions don't fully honor this variable

**Recommendation:** Just use the expected path. It's easier.

#### Summary: The Path Requirements

| Component | Path | Why |
|-----------|------|-----|
| **SPIRE Agent socket** | `/tmp/spire-agent/public/socket` | Filename must be `socket` |
| **CSI mount in pod** | `/run/secrets/workload-spiffe-uds` | Matches `/var/run/secrets/workload-spiffe-uds` |
| **Envoy expects** | `./var/run/secrets/workload-spiffe-uds/socket` | Hardcoded in Istio |

---

### 13.7 Complete Communication Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    COMPLETE COMMUNICATION FLOW                                                          │
│                                                                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐  │
│   │                                          CLUSTER                                                                 │  │
│   │                                                                                                                 │  │
│   │   ┌───────────────────────────────────────────────────────────────────────────────────────────────────────┐    │  │
│   │   │                                    SPIRE SERVER POD                                                    │    │  │
│   │   │                                                                                                       │    │  │
│   │   │   ┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐                        │    │  │
│   │   │   │ Registration    │         │ Certificate     │         │ Federation      │                        │    │  │
│   │   │   │ Entries DB      │         │ Authority       │         │ Endpoint        │                        │    │  │
│   │   │   │                 │         │                 │         │ :8443           │◄────── From remote     │    │  │
│   │   │   │ ClusterSPIFFEID │         │ Signs SVIDs     │         │                 │        SPIRE servers   │    │  │
│   │   │   │ → entries       │         │                 │         │                 │                        │    │  │
│   │   │   └─────────────────┘         └─────────────────┘         └─────────────────┘                        │    │  │
│   │   │                                       │                                                               │    │  │
│   │   │                                       │ :8081 (Agent API)                                             │    │  │
│   │   │                                       │                                                               │    │  │
│   │   └───────────────────────────────────────┼───────────────────────────────────────────────────────────────┘    │  │
│   │                                           │                                                                     │  │
│   │                                           │ ❶ Agents CONNECT to server                                         │  │
│   │                                           │    (node attestation, SVID fetch)                                   │  │
│   │                                           │                                                                     │  │
│   │   ┌───────────────────────────────────────▼───────────────────────────────────────────────────────────────┐    │  │
│   │   │                                    NODE (Worker)                                                       │    │  │
│   │   │                                                                                                       │    │  │
│   │   │   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐    │    │  │
│   │   │   │                              SPIRE AGENT POD (DaemonSet)                                     │    │    │  │
│   │   │   │                                                                                             │    │    │  │
│   │   │   │   ┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐              │    │    │  │
│   │   │   │   │ Workload        │         │ SVID Cache      │         │ SDS Server      │              │    │    │  │
│   │   │   │   │ Attestor        │         │                 │         │                 │              │    │    │  │
│   │   │   │   │                 │         │ Caches certs    │         │ Unix Socket:    │              │    │    │  │
│   │   │   │   │ Queries Kubelet │         │ from server     │         │ /tmp/spire-     │              │    │    │  │
│   │   │   │   │ for pod info    │         │                 │         │ agent/public/   │              │    │    │  │
│   │   │   │   └─────────────────┘         └─────────────────┘         │ socket          │              │    │    │  │
│   │   │   │                                                           └────────┬────────┘              │    │    │  │
│   │   │   │                                                                    │                        │    │    │  │
│   │   │   └────────────────────────────────────────────────────────────────────┼────────────────────────┘    │    │  │
│   │   │                                                                        │                              │    │  │
│   │   │                                                                        │ ❷ CSI driver bridges         │    │  │
│   │   │                                                                        │    socket into pods          │    │  │
│   │   │                                                                        │                              │    │  │
│   │   │   ┌────────────────────────────────────────────────────────────────────┼────────────────────────┐    │    │  │
│   │   │   │                              WORKLOAD POD                          │                         │    │    │  │
│   │   │   │                                                                    │                         │    │    │  │
│   │   │   │   ┌─────────────────────────────────────────────────────────┐     │                         │    │    │  │
│   │   │   │   │                    istio-proxy container                 │     │                         │    │    │  │
│   │   │   │   │                                                         │     │                         │    │    │  │
│   │   │   │   │   ┌─────────────────┐         ┌─────────────────┐      │     │                         │    │    │  │
│   │   │   │   │   │ pilot-agent     │         │ Envoy           │      │     │                         │    │    │  │
│   │   │   │   │   │                 │         │                 │      │     │                         │    │    │  │
│   │   │   │   │   │ Sees existing   │         │ sds-grpc:       │      │     │                         │    │    │  │
│   │   │   │   │   │ socket, skips   │         │ connects to     ├──────┼─────┘                         │    │    │  │
│   │   │   │   │   │ SDS server      │         │ /var/run/.../   │      │ ❸ Envoy gets certs           │    │    │  │
│   │   │   │   │   │ creation        │         │ socket          │      │    from SPIRE via SDS        │    │    │  │
│   │   │   │   │   └─────────────────┘         └─────────────────┘      │                               │    │    │  │
│   │   │   │   │                                       │                 │                               │    │    │  │
│   │   │   │   │                                       │ ❹ Still connects to Istiod                    │    │    │  │
│   │   │   │   │                                       │    for xDS config (not certs)                  │    │    │  │
│   │   │   │   │                                       ▼                 │                               │    │    │  │
│   │   │   │   └───────────────────────────────────────┼─────────────────┘                               │    │    │  │
│   │   │   │                                           │                                                  │    │    │  │
│   │   │   │   ┌───────────────────────────────────────┼───────────────────────────────────────────┐     │    │    │  │
│   │   │   │   │                    app container      │                                            │     │    │    │  │
│   │   │   │   │                                       │                                            │     │    │    │  │
│   │   │   │   │   Traffic to/from app is intercepted by Envoy                                      │     │    │    │  │
│   │   │   │   │   mTLS happens transparently using SPIRE certs                                     │     │    │    │  │
│   │   │   │   │                                                                                    │     │    │    │  │
│   │   │   │   └────────────────────────────────────────────────────────────────────────────────────┘     │    │    │  │
│   │   │   │                                                                                              │    │    │  │
│   │   │   └──────────────────────────────────────────────────────────────────────────────────────────────┘    │    │  │
│   │   │                                                                                                        │    │  │
│   │   └────────────────────────────────────────────────────────────────────────────────────────────────────────┘    │  │
│   │                                                                                                                  │  │
│   │   ┌──────────────────────────────────────────────────────────────────────────────────────────────────────────┐  │  │
│   │   │                                        ISTIOD POD                                                         │  │  │
│   │   │                                                                                                          │  │  │
│   │   │   :15012 - xDS + CA (CA bypassed when using SPIRE)                                                       │  │  │
│   │   │   :15014 - Debug/metrics                                                                                 │  │  │
│   │   │   :15017 - Webhooks                                                                                      │  │  │
│   │   │                                                                                                          │  │  │
│   │   │   Provides: Service discovery, routing config, policy                                                    │  │  │
│   │   │   Does NOT provide: Certificates (SPIRE does that now)                                                   │  │  │
│   │   │                                                                                                          │  │  │
│   │   └──────────────────────────────────────────────────────────────────────────────────────────────────────────┘  │  │
│   │                                                                                                                  │  │
│   └──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Detailed Step-by-Step Explanation

This section explains each component in the communication flow, its responsibilities, actions, and required configurations.

---

##### Component 1: SPIRE Server

**What it is:**  
The SPIRE Server is the central authority in a SPIRE deployment. It runs as a StatefulSet (typically `spire-server-0`) in the `zero-trust-workload-identity-manager` namespace.

**Responsibilities:**
| Responsibility | Description |
|----------------|-------------|
| **Certificate Authority** | Signs X.509 certificates (SVIDs) for workloads |
| **Registration Database** | Stores ClusterSPIFFEID entries that define which workloads get which SPIFFE IDs |
| **Agent Authentication** | Verifies and authenticates SPIRE Agents via node attestation |
| **Federation** | Exchanges trust bundles with remote SPIRE servers |

**Actions it performs:**
1. Accepts connections from SPIRE Agents on port 8081 (gRPC)
2. Validates agent identity via node attestation (using Kubernetes PSAT tokens)
3. Looks up registration entries matching the workload being attested
4. Signs SVIDs for workloads when requested by agents
5. Fetches and stores federated trust bundles from remote SPIRE servers
6. Serves its own trust bundle on the federation endpoint (port 8443)

**Required Configurations:**

```yaml
# SpireServer CR
apiVersion: spire.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  # CA configuration - how certificates are signed
  caSubject:
    commonName: "SPIRE Server CA"
    country: "US"
    organization: "MyOrg"
  
  # JWT issuer for OIDC federation (must have https://)
  jwtIssuer: https://oidc-discovery.apps.cluster1.example.com
  
  # Federation configuration (for multi-cluster)
  federation:
    bundleEndpoint:
      profile: https_spiffe       # Expose bundle endpoint
      refreshHint: 300            # Suggest 5-minute refresh
    federatesWith:
      - trustDomain: apps.cluster2.example.com
        bundleEndpointUrl: https://spire-server-federation.apps.cluster2.example.com
        bundleEndpointProfile: https_spiffe
        endpointSpiffeId: spiffe://apps.cluster2.example.com/spire/server
    managedRoute: "true"          # Auto-create OpenShift Route
```

---

##### Component 2: SPIRE Agent

**What it is:**  
The SPIRE Agent runs as a DaemonSet on every node in the cluster. It acts as the intermediary between workloads and the SPIRE Server.

**Responsibilities:**
| Responsibility | Description |
|----------------|-------------|
| **Node Attestation** | Proves its identity to the SPIRE Server using Kubernetes PSAT |
| **Workload Attestation** | Identifies workloads by querying the Kubelet API for pod metadata |
| **SVID Caching** | Caches certificates obtained from the SPIRE Server |
| **SDS Server** | Exposes a Unix socket that workloads (Envoy) connect to for certificates |

**Actions it performs:**
1. On startup, connects to SPIRE Server on port 8081
2. Performs node attestation using its Kubernetes service account token
3. Receives a node SVID (certificate for the agent itself)
4. Creates a Unix socket at `/tmp/spire-agent/public/socket`
5. When a workload connects to the socket:
   - Queries Kubelet API to get pod namespace, service account, labels
   - Matches against registration entries
   - Requests SVID from SPIRE Server
   - Returns SVID + trust bundles to workload via SDS protocol

**Required Configurations:**

```json
// spire-agent ConfigMap (agent.conf)
{
  "agent": {
    // CRITICAL: Socket filename must be "socket" for Istio compatibility
    "socket_path": "/tmp/spire-agent/public/socket",
    
    // Connection to SPIRE Server
    "server_address": "spire-server.zero-trust-workload-identity-manager",
    "server_port": "443",
    
    // Trust domain
    "trust_domain": "apps.cluster1.example.com",
    
    // Bootstrap trust bundle location
    "trust_bundle_path": "/run/spire/bundle/bundle.crt",
    
    // SDS configuration - CRITICAL for federation
    "sds": {
      "default_bundle_name": "null",
      "default_all_bundles_name": "ROOTCA"  // Serve ALL bundles as ROOTCA
    }
  },
  "plugins": {
    "NodeAttestor": [{
      "k8s_psat": {
        "plugin_data": { "cluster": "cluster1" }
      }
    }],
    "WorkloadAttestor": [{
      "k8s": {
        "plugin_data": { "node_name_env": "MY_NODE_NAME" }
      }
    }]
  }
}
```

**Why `default_all_bundles_name: ROOTCA`?**  
When Envoy requests "ROOTCA", the agent serves ALL trust bundles (local + federated) combined. This is essential for cross-cluster mTLS because Envoy needs to trust certificates from both clusters.

---

##### Component 3: SPIFFE CSI Driver

**What it is:**  
A Container Storage Interface (CSI) driver that creates Unix sockets inside pods, connecting them to the SPIRE Agent on the host.

**Responsibilities:**
| Responsibility | Description |
|----------------|-------------|
| **Socket Bridging** | Creates a socket inside the pod that connects to the SPIRE Agent socket on the host |
| **Volume Management** | Implements CSI interface so Kubernetes can mount the socket as a volume |

**Actions it performs:**
1. When a pod with CSI volume is scheduled:
   - Kubelet calls the CSI driver's `NodePublishVolume` method
   - Driver creates a directory in the pod's volume path
   - Driver creates a Unix socket in that directory
   - This socket proxies to the SPIRE Agent's socket on the host
2. When pod is deleted:
   - Kubelet calls `NodeUnpublishVolume`
   - Driver cleans up the socket and directory

**Required Configurations:**

```yaml
# CSI volume specification in pod template (via Istio injection)
volumes:
- name: workload-socket
  csi:
    driver: "csi.spiffe.io"    # The SPIFFE CSI driver
    readOnly: true              # Socket is read-only

# Volume mount in istio-proxy container
volumeMounts:
- name: workload-socket
  mountPath: /run/secrets/workload-spiffe-uds    # Where Envoy expects it
  readOnly: true
```

**The CSI driver is deployed by ZTWIM automatically as a DaemonSet.**

---

##### Component 4: Workload Pod (istio-proxy container)

**What it is:**  
An application pod with an Envoy sidecar (istio-proxy) injected by Istio's mutating webhook.

**Components inside the container:**

| Component | Role |
|-----------|------|
| **pilot-agent** | Process manager for Envoy, handles bootstrap and health |
| **Envoy** | The actual proxy that handles all traffic and mTLS |

**Actions performed by pilot-agent:**
1. On startup, checks if `CREDENTIAL_SOCKET_EXISTS=true`
2. Checks if socket exists at `/var/run/secrets/workload-spiffe-uds/socket`
3. If socket exists (SPIRE CSI volume): **skips creating local SDS server**
4. Generates Envoy bootstrap configuration
5. Starts Envoy process
6. Still connects to Istiod for xDS configuration (routes, clusters, etc.)

**Actions performed by Envoy:**
1. Reads bootstrap config, finds `sds-grpc` cluster pointing to the socket
2. Connects to the socket (which goes to SPIRE Agent via CSI)
3. Sends SDS request for "default" (workload cert) and "ROOTCA" (trust bundle)
4. Receives SPIRE-issued certificate and federated trust bundles
5. Uses certificates for all mTLS connections
6. Connects to Istiod on port 15012 for xDS config (CDS, LDS, EDS, RDS)
7. Intercepts all application traffic and performs mTLS

**Required Configurations:**

```yaml
# Pod annotations for SPIRE integration
metadata:
  annotations:
    inject.istio.io/templates: "sidecar,spire"   # Use both sidecar and spire templates

# OR if using userVolume approach:
metadata:
  annotations:
    sidecar.istio.io/userVolume: '[{"name":"workload-socket","csi":{"driver":"csi.spiffe.io","readOnly":true}}]'
    sidecar.istio.io/userVolumeMount: '[{"name":"workload-socket","mountPath":"/run/secrets/workload-spiffe-uds","readOnly":true}]'
```

**Istio CR template that adds SPIRE integration:**

```yaml
# In Istio CR spec.values.sidecarInjectorWebhook.templates
spire: |
  spec:
    containers:
    - name: istio-proxy
      env:
      - name: CREDENTIAL_SOCKET_EXISTS    # Tell pilot-agent to use existing socket
        value: "true"
      - name: ISTIO_META_TLS_CLIENT_ROOT_CERT
        value: ""                         # Clear default root cert
      volumeMounts:
      - name: workload-socket
        mountPath: /run/secrets/workload-spiffe-uds
        readOnly: true
    volumes:
    - name: workload-socket
      csi:
        driver: "csi.spiffe.io"
        readOnly: true
```

---

##### Component 5: Istiod

**What it is:**  
The Istio control plane that manages service mesh configuration.

**Responsibilities:**
| Responsibility | Description |
|----------------|-------------|
| **Service Discovery** | Watches Kubernetes API for services and endpoints |
| **xDS Config Server** | Pushes configuration to Envoy proxies (CDS, LDS, EDS, RDS) |
| **Certificate Authority** | Signs certificates for workloads (BYPASSED when using SPIRE) |
| **Sidecar Injection** | Mutating webhook that injects Envoy sidecars |
| **Multi-Cluster Discovery** | Uses Remote Secrets to discover services in other clusters |

**Actions it performs (with SPIRE):**
1. **Does NOT do:** Issue certificates to workloads (SPIRE does this)
2. **Still does:**
   - Watch Kubernetes API for services, deployments, pods
   - Watch Remote Secrets for multi-cluster service discovery
   - Push xDS configuration to all Envoy proxies
   - Inject sidecars into pods via webhook
   - Enforce routing rules (VirtualServices, DestinationRules)

**Required Configurations:**

```yaml
# Istio CR
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1    # Cluster name for multi-cluster
      network: network1          # Network identifier
      
      # Gateway addresses for cross-cluster routing
      meshNetworks:
        network1:
          endpoints:
            - fromRegistry: cluster1
          gateways:
            - address: 34.100.205.164    # E/W Gateway IP
              port: 15443
        network2:
          endpoints:
            - fromRegistry: cluster2
          gateways:
            - address: 34.47.177.52      # Remote E/W Gateway IP
              port: 15443
    
    meshConfig:
      trustDomain: apps.cluster1.example.com
      trustDomainAliases:                 # Accept certs from federated domains
        - apps.cluster2.example.com
    
    # Sidecar injection templates for SPIRE
    sidecarInjectorWebhook:
      templates:
        spire: |
          # ... (as shown above)
```

---

##### Component 6: ClusterSPIFFEID

**What it is:**  
A Custom Resource that defines how SPIFFE IDs are generated for workloads.

**Responsibilities:**
| Responsibility | Description |
|----------------|-------------|
| **SPIFFE ID Template** | Defines the pattern for generating SPIFFE IDs |
| **Workload Selection** | Specifies which pods/namespaces get these IDs |
| **Federation Config** | Lists which remote trust domains to include in bundles |

**Required Configurations:**

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-test-spiffeid
spec:
  # CRITICAL: Required when using federatesWith
  className: zero-trust-workload-identity-manager-spire
  
  # SPIFFE ID template using Go templating
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  
  # Which pods to match
  podSelector:
    matchLabels: {}    # All pods
  
  # Which namespaces to match
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: istio-test
  
  # CRITICAL for multi-cluster: Include remote CA in trust bundles
  federatesWith:
    - apps.cluster2.example.com
```

**Why is `className` required?**  
The SPIRE controller only processes ClusterSPIFFEID resources that have `className: zero-trust-workload-identity-manager-spire`. Without it, the `federatesWith` field is silently ignored.

---

#### Complete Flow Summary

Here's the numbered sequence of what happens when a workload pod starts:

| Step | Component | Action | Configuration Involved |
|------|-----------|--------|----------------------|
| 1 | **Kubelet** | Schedules pod with CSI volume | Pod annotation: `inject.istio.io/templates: "sidecar,spire"` |
| 2 | **CSI Driver** | Creates socket in pod, bridges to SPIRE Agent | CSI volume spec: `driver: csi.spiffe.io` |
| 3 | **pilot-agent** | Sees existing socket, skips local SDS creation | Env: `CREDENTIAL_SOCKET_EXISTS=true` |
| 4 | **pilot-agent** | Generates Envoy bootstrap with sds-grpc cluster | Hardcoded path: `./var/run/secrets/workload-spiffe-uds/socket` |
| 5 | **Envoy** | Starts and connects to sds-grpc cluster (SPIRE socket) | Bootstrap config |
| 6 | **SPIRE Agent** | Receives SDS request, queries Kubelet for pod info | Agent config: `socket_path` |
| 7 | **SPIRE Agent** | Matches pod against ClusterSPIFFEID entries | ClusterSPIFFEID: `namespaceSelector`, `podSelector` |
| 8 | **SPIRE Agent** | Requests SVID from SPIRE Server | Agent→Server connection on port 8081 |
| 9 | **SPIRE Server** | Signs certificate using its CA | SpireServer: `caSubject` |
| 10 | **SPIRE Server** | Includes federated bundles based on entry's `federates_with` | ClusterSPIFFEID: `federatesWith` |
| 11 | **SPIRE Agent** | Returns SVID + ROOTCA to Envoy via SDS | Agent config: `sds.default_all_bundles_name: ROOTCA` |
| 12 | **Envoy** | Stores certificates, ready for mTLS | Envoy dynamic secrets |
| 13 | **Envoy** | Connects to Istiod for xDS config | Istiod: port 15012 |
| 14 | **Istiod** | Pushes service endpoints, routing rules | Istio CR: `meshNetworks`, Remote Secrets |
| 15 | **Envoy** | Intercepts app traffic, performs mTLS | SPIRE certs + Istiod routing |

---

#### Verification Commands

After setup, verify each component is working:

```bash
# 1. Verify SPIRE Server has registration entries with federation
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -output json -socketPath /tmp/spire-server/private/api.sock | \
  jq '.entries[] | {spiffe_id: .spiffe_id.path, federates_with}'

# 2. Verify SPIRE Agent is running and has the correct socket path
oc get cm spire-agent -n zero-trust-workload-identity-manager -o jsonpath='{.data.agent\.conf}' | jq '.agent.socket_path'

# 3. Verify CSI driver is running
oc get pods -n zero-trust-workload-identity-manager -l app=spiffe-csi-driver

# 4. Verify workload pod has CSI volume mounted
oc get pod -n istio-test <pod-name> -o jsonpath='{.spec.volumes[?(@.name=="workload-socket")]}'

# 5. Verify pilot-agent found existing SDS socket (should see this in logs)
oc logs -n istio-test <pod-name> -c istio-proxy | grep "Existing workload SDS socket"

# 6. Verify Envoy has SPIRE certificate
oc exec -n istio-test <pod-name> -c istio-proxy -- \
  curl -s localhost:15000/config_dump | \
  jq -r '.configs[] | select(.["@type"] | contains("SecretsConfigDump")) | 
    .dynamic_active_secrets[] | select(.name == "default") | 
    .secret.tls_certificate.certificate_chain.inline_bytes' | \
  base64 -d | openssl x509 -noout -issuer -subject

# 7. Verify ROOTCA has federated trust domains
oc exec -n istio-test <pod-name> -c istio-proxy -- \
  curl -s localhost:15000/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("SecretsConfigDump")) | 
    .dynamic_active_secrets[] | select(.name == "ROOTCA") | 
    .secret.validation_context.custom_validator_config.typed_config.trust_domains[].name'

# 8. Verify Istiod knows about remote cluster
oc exec -n istio-system deploy/istiod -- curl -s localhost:15014/debug/clusterz
```

---

*Document generated from hands-on implementation experience. Last updated: February 2026.*
