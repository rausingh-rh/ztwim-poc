# 🔄 Trust Bundle Refresh - Quick Reference

## ⚡ Quick Answers

| Question | Answer |
|----------|--------|
| **How often does it refresh?** | Every **~75 seconds** |
| **Why 75 seconds?** | 300s (refresh_hint) ÷ 4 (resilience attempts) |
| **Where to see it?** | SPIRE server logs: `"Bundle refreshed"` |
| **How in JSON?** | `"spiffe_refresh_hint": 300` |

---

## 📊 Your Current Setup

```
Refresh Hint (configured):  300 seconds (5 minutes)
Actual Poll Interval:       ~75 seconds  
Refreshes per Hour:         ~48
Refreshes per Day:          ~1,152
Annual Refreshes:           ~420,480
```

---

## 🔍 Quick Commands

### 1. Watch Live Refreshes
```bash
kubectl logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh"
```

### 2. Check Refresh Hint in JSON
```bash
curl -k https://federation-endpoint/ | jq '.spiffe_refresh_hint'
# Returns: 300
```

### 3. View Last 10 Refreshes
```bash
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 \
  -c spire-server --tail=500 | grep "Bundle refreshed" | tail -10
```

### 4. Run Interactive Monitor
```bash
./federation-setup/monitor-bundle-refresh.sh
```

---

## 📡 Federation Endpoint JSON Structure

```json
{
    "keys": [
        {
            "use": "x509-svid",     // X.509 certificate key
            "kty": "RSA",
            "n": "...",
            "e": "AQAB",
            "x5c": ["..."]          // Certificate chain
        },
        {
            "use": "jwt-svid",      // JWT signing key
            "kty": "RSA",
            "kid": "...",
            "n": "...",
            "e": "AQAB"
        }
    ],
    "spiffe_sequence": 1,           // Bundle version number
    "spiffe_refresh_hint": 300      // ← Poll every 300 seconds
}
```

**Key Field**: `spiffe_refresh_hint`
- Unit: Seconds
- Tells clients: "Check back in 300 seconds"
- Client divides by 4: Actual polling = 75 seconds

---

## 🔄 How Refresh Works

```
┌────────────────────────────────────────────────────────┐
│ 1. Server publishes bundle with refresh_hint: 300     │
└──────────────────────┬─────────────────────────────────┘
                       ↓
┌────────────────────────────────────────────────────────┐
│ 2. Client reads hint from federation endpoint         │
└──────────────────────┬─────────────────────────────────┘
                       ↓
┌────────────────────────────────────────────────────────┐
│ 3. Client calculates: 300 ÷ 4 = 75 seconds            │
└──────────────────────┬─────────────────────────────────┘
                       ↓
┌────────────────────────────────────────────────────────┐
│ 4. Client polls endpoint every ~75 seconds            │
└──────────────────────┬─────────────────────────────────┘
                       ↓
┌────────────────────────────────────────────────────────┐
│ 5. If changed → Update datastore & log "refreshed"    │
└────────────────────────────────────────────────────────┘
```

**Why divide by 4?**  
Resilience! If one attempt fails, 3 more chances remain within the refresh period.

---

## 🎯 What to Look For

### ✅ In Logs (every ~75 seconds)
```
time="2025-10-22T10:15:23Z" level=info msg="Bundle refreshed" 
  subsystem_name=bundle_client 
  trust_domain=apps.cluster-2.devcluster.openshift.com
```

### ✅ In Bundle List
```bash
$ kubectl exec spire-server-0 -c spire-server -- ./spire-server bundle list

****************************************
* apps.mykastur14.gcp.devcluster.openshift.com  ← Own bundle
****************************************

****************************************  
* apps.aagnihot-cluster-kdh.devcluster.openshift.com  ← Federated!
****************************************
```

### ✅ In Federation Endpoint
```bash
$ curl -k https://federation-endpoint/
{
  "keys": [...],
  "spiffe_sequence": 1,
  "spiffe_refresh_hint": 300  ← This number!
}
```

---

## ⚙️ Configuration

### Current Config (SPIRE Server)
```json
{
  "federation": {
    "bundle_endpoint": {
      "address": "0.0.0.0",
      "port": 8443,
      "refresh_hint": "5m"  ← Controls the hint (300 seconds)
    },
    "federates_with": {
      "other-trust-domain": {
        "bundle_endpoint_url": "https://...",
        "bundle_endpoint_profile": {
          "https_spiffe": {
            "endpoint_spiffe_id": "spiffe://..."
          }
        }
      }
    }
  }
}
```

### To Change Refresh Rate

1. Edit ConfigMap:
   ```bash
   kubectl edit configmap spire-server -n zero-trust-workload-identity-manager
   ```

2. Change `refresh_hint`:
   ```json
   "refresh_hint": "2m"  // For faster refresh (120s → 30s polling)
   ```

3. Restart:
   ```bash
   kubectl rollout restart statefulset/spire-server -n zero-trust-workload-identity-manager
   ```

4. Verify:
   ```bash
   curl -k https://federation-endpoint/ | jq '.spiffe_refresh_hint'
   # Should show: 120
   ```

---

## 📈 Recommended Values

| Use Case | refresh_hint | Poll Interval | Trade-off |
|----------|--------------|---------------|-----------|
| Development | `1m` | ~15s | Fastest updates, high load |
| High Security | `2m` | ~30s | Fast revocation detection |
| **Production** | **`5m`** | **~75s** | ✅ **Balanced (current)** |
| Low Traffic | `10m` | ~150s | Lower overhead |

**⚠️ Note**: Values below `1m` are clamped to 1 minute minimum.

---

## 🐛 Troubleshooting

### Issue: No "Bundle refreshed" in logs

**Check 1**: Is `federates_with` configured?
```bash
kubectl exec spire-server-0 -c spire-server -- cat /run/spire/config/server.conf | \
  grep -A 10 "federates_with"
```

**Check 2**: Can reach federation endpoint?
```bash
kubectl exec spire-server-0 -c spire-server -- \
  curl -k https://federation-endpoint/
```

**Fix**: Restart SPIRE server
```bash
kubectl rollout restart statefulset/spire-server -n zero-trust-workload-identity-manager
```

### Issue: Wrong interval

**Verify calculation**:
```
Expected: refresh_hint ÷ 4
Your case: 300 ÷ 4 = 75 seconds
```

**Check actual**:
```bash
kubectl logs spire-server-0 -c spire-server --tail=100 | \
  grep "Bundle refreshed" | tail -2
# Compare timestamps manually
```

---

## 🎓 Key Concepts

### 1. Refresh Hint
- **Server-side**: Published in federation endpoint JSON
- **Purpose**: Tells clients how often to poll
- **Unit**: Seconds
- **Your value**: 300

### 2. Poll Interval
- **Client-side**: Calculated from refresh hint
- **Formula**: `refresh_hint ÷ 4`
- **Purpose**: Actual polling frequency
- **Your value**: ~75 seconds

### 3. Why 4 Attempts?
- **Resilience**: Multiple chances within refresh period
- **Example**: If 1st poll fails, 3 more attempts before hint expires
- **Benefit**: Tolerant to transient failures

### 4. Bundle Sequence
- **In JSON**: `spiffe_sequence` field
- **Purpose**: Version number, increments on changes
- **Use**: Helps detect if bundle actually changed

---

## 📚 Related Files

- **[TRUST_BUNDLE_REFRESH_GUIDE.md](./TRUST_BUNDLE_REFRESH_GUIDE.md)** - Full documentation
- **[monitor-bundle-refresh.sh](./monitor-bundle-refresh.sh)** - Interactive monitor tool
- **[PROOF_OF_WORKING_FEDERATION.md](./PROOF_OF_WORKING_FEDERATION.md)** - Your setup verification

---

## 🚀 Quick Verification

Run this one-liner to verify everything is working:

```bash
echo "Federation Endpoints:" && \
curl -sk https://$(kubectl get route federation -n zero-trust-workload-identity-manager -o jsonpath='{.spec.host}') | \
  jq '{refresh_hint: .spiffe_refresh_hint, sequence: .spiffe_sequence, key_count: .keys | length}' && \
echo "" && echo "Recent Refreshes:" && \
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 | \
  grep "Bundle refreshed" | tail -3
```

**Expected Output**:
```json
Federation Endpoints:
{
  "refresh_hint": 300,
  "sequence": 1,
  "key_count": 2
}

Recent Refreshes:
time="..." level=info msg="Bundle refreshed" ...
time="..." level=info msg="Bundle refreshed" ...
time="..." level=info msg="Bundle refreshed" ...
```

✅ If you see this, your federation refresh is working perfectly!

---

**Created:** October 22, 2025  
**Status:** Production-ready with 75-second refresh ✅

