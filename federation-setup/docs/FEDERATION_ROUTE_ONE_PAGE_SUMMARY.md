# Federation Endpoint Route Type - One Page Summary

## Bottom Line

**Use PASSTHROUGH route for federation endpoints by default.**  
Only use re-encrypt when corporate policy mandates or specific L7 features are required.

---

## Why Passthrough is Preferred

| Reason | Impact |
|--------|--------|
| **Preserves SPIFFE Authentication** | Maintains mutual TLS + SPIFFE ID validation |
| **End-to-End Encryption** | Router never decrypts traffic (zero trust) |
| **Simpler Operations** | Single CA, automatic rotation, easy troubleshooting |
| **Stronger Security** | No trusted intermediary, no router compromise risk |

### Traffic Flow: Passthrough
```
Client SPIRE ──[Encrypted SPIFFE SVID]──→ Router ──[Forward]──→ Server SPIRE
                                         (No decrypt)
✅ Client validates Server's SPIFFE ID directly
```

---

## When to Use Re-encrypt Instead

Use re-encrypt **ONLY** when you need:

| Use Case | Why Required |
|----------|-------------|
| **Corporate CA Certificates** | Security policy mandates all ingress uses Enterprise CA |
| **WAF Integration** | Must inspect HTTP traffic for security threats |
| **HTTP Header Injection** | Need to add authentication/tracing headers |
| **External L7 Load Balancer** | Integration with existing corporate ingress |

### Traffic Flow: Re-encrypt
```
Client SPIRE ──[TLS #1]──→ Router ──[Decrypt/Inspect]──→ Router ──[TLS #2]──→ Server
                          (Service CA)                              (SPIRE CA)
⚠️  Client sees Service CA cert, not SPIFFE ID
```

### Critical Requirement for Re-encrypt

**Must update SPIRE configuration**:
```json
// Change from this:
"bundle_endpoint_profile": {
  "https_spiffe": { "endpoint_spiffe_id": "..." }
}

// To this:
"bundle_endpoint_profile": {
  "https_web": {}
}
```

**Without this change**: Federation will fail with certificate validation errors.

---

## Trade-offs Comparison

|  | Passthrough ✅ | Re-encrypt ⚠️ |
|---|---|---|
| **SPIFFE Authentication** | ✅ Yes | ❌ No |
| **Mutual TLS** | ✅ Yes | ❌ No |
| **Router Decryption** | ❌ No (secure) | ✅ Yes (trust boundary) |
| **Configuration Steps** | 2 | 4 |
| **Certificate Management** | 1 CA | 2 CAs |
| **HTTP Inspection** | ❌ No | ✅ Yes |
| **WAF Compatible** | ❌ No | ✅ Yes |

---

## Configuration Quick Reference

### Passthrough (Recommended)

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-federation
spec:
  tls:
    termination: passthrough
  to:
    kind: Service
    name: spire-server-federation
  port:
    targetPort: federation  # 8443
```

**SPIRE Config**: Use `https_spiffe` profile  
**Certificate**: SPIRE Internal CA only  
**Authentication**: Mutual TLS + SPIFFE ID

### Re-encrypt (When Required)

```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.alpha.openshift.io/serving-cert-secret-name: federation-cert
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-federation
spec:
  tls:
    termination: reencrypt
    destinationCACertificate: |
      <SPIRE_BUNDLE_CA>  # Required!
```

**SPIRE Config**: Must use `https_web` profile  
**Certificates**: Service CA (edge) + SPIRE CA (backend)  
**Authentication**: Standard HTTPS only

---

## Decision Tree

```
Do you need any of these?
├─ Corporate CA-signed certificates
├─ WAF/L7 inspection
├─ HTTP header injection
└─ External L7 load balancer
    │
    ├─ NO  → Use PASSTHROUGH ✅
    │        (Recommended - stronger security, better performance)
    │
    └─ YES → Use RE-ENCRYPT ⚠️
             (Required by policy - loses SPIFFE auth)
```

---

## Common Mistake

❌ **Using re-encrypt route WITHOUT updating SPIRE config**

**Symptom**: `certificate validation failed: expected SPIFFE ID not found`

**Fix**: Change SPIRE config to `https_web` profile

---

## Testing Commands

```bash
# Check route type
kubectl get route spire-server-federation -o jsonpath='{.spec.tls.termination}'

# Test passthrough (should show SPIFFE ID)
openssl s_client -connect FEDERATION_HOST:443 -showcerts | grep "spiffe://"

# Test re-encrypt (should show Service CA)
openssl s_client -connect FEDERATION_HOST:443 -showcerts | openssl x509 -noout -issuer

# Verify federation works
curl -k https://FEDERATION_HOST/
```

---

## Key Takeaway

**Passthrough = Best Practice**
- Maintains SPIRE's security model
- Better performance and resource efficiency
- Simpler operations

**Re-encrypt = Exception Only**
- Use when specific requirements mandate
- Accept loss of SPIFFE authentication
- Accept increased complexity and overhead

---
