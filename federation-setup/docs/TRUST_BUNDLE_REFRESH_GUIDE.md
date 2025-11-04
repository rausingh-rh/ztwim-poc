# 🔄 Trust Bundle Refresh - Complete Guide

## 📊 Quick Reference

| Question | Answer |
|----------|--------|
| **Default Refresh Interval** | **5 minutes (300 seconds)** |
| **Minimum Refresh Interval** | **1 minute (60 seconds)** |
| **Your Current Setup** | **300 seconds** (as seen in curl outputs) |
| **Actual Polling Frequency** | **~75 seconds** (5 minutes ÷ 4 attempts) |
| **Configuration Location** | SPIRE server config: `federation.bundle_endpoint.refresh_hint` |

---

## 🔍 How Trust Bundle Refresh Works

### 1️⃣ The Refresh Mechanism

SPIRE uses a **multi-layered refresh strategy**:

```
Federation Endpoint (Server Side)
    ↓ publishes bundle with refresh_hint: 300
    ↓
Bundle Client (Consuming Side)
    ↓ reads refresh_hint from endpoint
    ↓ divides by 4 (attemptsPerRefreshHint)
    ↓ polls every 75 seconds
```

**Why divide by 4?**  
To be resilient to temporary failures. SPIRE attempts 4 times within the refresh hint period, so if one attempt fails, it has 3 more chances before the hint expires.

### 2️⃣ Refresh Intervals Explained

From the code (`spire/pkg/server/bundle/client/manager.go`):

```go
const (
    // Number of refresh attempts within the refresh hint period
    attemptsPerRefreshHint = 4
    
    // Config reload interval (how often to check for new federation configs)
    configRefreshInterval = time.Second * 10
    
    // Default if endpoint doesn't provide refresh_hint
    defaultRefreshInterval = time.Minute * 5
)
```

**Calculation Example:**
```
Refresh Hint from Endpoint: 300 seconds (5 minutes)
÷ 4 attempts
= 75 seconds between each polling attempt
```

### 3️⃣ Configuration Options

In your SPIRE server config:

```json
"federation": {
  "bundle_endpoint": {
    "address": "0.0.0.0",
    "port": 8443,
    "refresh_hint": "5m"  // ← Controls the hint sent to consumers
  },
  "federates_with": {
    "other-trust-domain.com": {
      "bundle_endpoint_url": "https://...",
      ...
    }
  }
}
```

**Valid Values:**
- Minimum: `1m` (anything lower will be clamped to 1 minute)
- Default: `5m` (if not specified)
- Maximum: No hard limit, but values ≥ 24h trigger a warning

---

## 📡 How It Reflects in Federation Endpoint JSON

### Your Current Federation Endpoint Responses

Looking at your curl outputs, both clusters return:

```json
{
    "keys": [
        {
            "use": "x509-svid",
            "kty": "RSA",
            "n": "...",
            "e": "AQAB",
            "x5c": ["..."]
        },
        {
            "use": "jwt-svid",
            "kty": "RSA",
            "kid": "...",
            "n": "...",
            "e": "AQAB"
        }
    ],
    "spiffe_sequence": 1,
    "spiffe_refresh_hint": 300  ← THIS IS THE KEY FIELD!
}
```

### Understanding the JSON Fields

| Field | Purpose | Your Value |
|-------|---------|------------|
| `keys` | Public keys for X.509 and JWT SVIDs | RSA keys |
| `spiffe_sequence` | Bundle version number (increments on changes) | 1 |
| `spiffe_refresh_hint` | **How often to poll (in seconds)** | **300** |

### The `spiffe_refresh_hint` Field

This is the **critical field** that tells federated clusters when to check back:

- **Unit**: Seconds
- **Meaning**: "Check back for updates approximately every 300 seconds"
- **Server generates it** based on:
  1. Configured `refresh_hint` in server config (if set)
  2. OR 1/10th of the shortest certificate lifetime (if no config)
  3. Clamped to minimum of 60 seconds

### How to Test Changes to Refresh Hint

```bash
# Current value
curl -k https://federation-endpoint.cluster1.com:8443/ | jq '.spiffe_refresh_hint'
# Returns: 300

# To change it, modify SPIRE server config and restart
```

---

## 🔭 How to See Trust Bundle Getting Refreshed

### Method 1: Real-Time Monitoring (Recommended)

Watch bundle refreshes as they happen:

```bash
# Cluster 1 watching Cluster 2's bundle
kubectl --kubeconfig /path/to/cluster1/kubeconfig \
  logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh"
```

**Expected Output** (appears every ~75 seconds):
```
time="2025-10-22T10:15:23Z" level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=apps.cluster-2.devcluster.openshift.com
time="2025-10-22T10:16:38Z" level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=apps.cluster-2.devcluster.openshift.com
time="2025-10-22T10:17:53Z" level=info msg="Bundle refreshed" subsystem_name=bundle_client trust_domain=apps.cluster-2.devcluster.openshift.com
```

### Method 2: Check Historical Refreshes

See past refresh events:

```bash
# Last 10 refresh events
kubectl --kubeconfig /path/to/cluster1/kubeconfig \
  logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 | \
  grep "Bundle refreshed" | tail -10
```

**Analysis Script:**
```bash
# Calculate average interval between refreshes
kubectl logs spire-server-0 -c spire-server -n zero-trust-workload-identity-manager --tail=500 | \
  grep "Bundle refreshed" | \
  awk '{print $1}' | \
  sed 's/time="//;s/"$//' | \
  while read -r line; do
    if [ -n "$prev" ]; then
      diff=$(($(date -d "$line" +%s) - $(date -d "$prev" +%s)))
      echo "Interval: $diff seconds"
    fi
    prev=$line
  done
```

### Method 3: Check Next Scheduled Refresh

```bash
# See when next refresh is scheduled
kubectl logs spire-server-0 -c spire-server -n zero-trust-workload-identity-manager --tail=50 | \
  grep "Scheduling next bundle refresh"
```

**Expected Output:**
```
time="..." level=debug msg="Scheduling next bundle refresh" at="2025-10-22T10:18:08Z" ...
```

### Method 4: Monitor Both Clusters Simultaneously

```bash
#!/bin/bash
echo "🔄 Monitoring both clusters for bundle refreshes..."
echo "Press Ctrl+C to stop"
echo ""

kubectl --kubeconfig /path/to/cluster1/kubeconfig logs -f \
  -n zero-trust-workload-identity-manager spire-server-0 -c spire-server 2>/dev/null | \
  grep --line-buffered "Bundle refresh" | \
  while read line; do
    echo "[CLUSTER-1] $(date '+%H:%M:%S') - $line"
  done &

kubectl --kubeconfig /path/to/cluster2/kubeconfig logs -f \
  -n zero-trust-workload-identity-manager spire-server-0 -c spire-server 2>/dev/null | \
  grep --line-buffered "Bundle refresh" | \
  while read line; do
    echo "[CLUSTER-2] $(date '+%H:%M:%S') - $line"
  done &

wait
```

---

## 🧪 Testing Bundle Refresh Behavior

### Test 1: Verify Current Refresh Hint

```bash
# Check Cluster 1's federation endpoint
curl -k https://$(kubectl --kubeconfig /path/to/cluster1/kubeconfig \
  get route federation -n zero-trust-workload-identity-manager -o jsonpath='{.spec.host}') | \
  jq '.spiffe_refresh_hint'
```

**Expected**: `300`

### Test 2: Watch a Complete Refresh Cycle

```bash
# This will wait for the next refresh and show timing
START=$(date +%s)
echo "Waiting for next bundle refresh..."

kubectl logs -f spire-server-0 -c spire-server -n zero-trust-workload-identity-manager | \
  grep --line-buffered -m 1 "Bundle refreshed"

END=$(date +%s)
echo "Refresh detected after $((END - START)) seconds"
```

### Test 3: Verify Bundle Content Changes

```bash
# Capture bundle at two different times
kubectl exec spire-server-0 -c spire-server -n zero-trust-workload-identity-manager -- \
  ./spire-server bundle list > /tmp/bundle1.txt

sleep 90  # Wait for next refresh

kubectl exec spire-server-0 -c spire-server -n zero-trust-workload-identity-manager -- \
  ./spire-server bundle list > /tmp/bundle2.txt

# Compare
diff /tmp/bundle1.txt /tmp/bundle2.txt
```

### Test 4: Trigger Manual Refresh

You can force an immediate refresh using the SPIRE API (if enabled):

```bash
# Using spire-server CLI
kubectl exec spire-server-0 -c spire-server -n zero-trust-workload-identity-manager -- \
  ./spire-server bundle refresh -trustDomain apps.cluster-2.devcluster.openshift.com
```

---

## 🔢 Understanding the Numbers in Your Setup

### Current Configuration Analysis

Based on your curl outputs showing `spiffe_refresh_hint: 300`:

| Metric | Value | Calculation |
|--------|-------|-------------|
| Configured Hint | 300 seconds | From server config |
| Actual Poll Interval | 75 seconds | 300 ÷ 4 |
| Refreshes per Hour | ~48 | 3600 ÷ 75 |
| Refreshes per Day | ~1,152 | 48 × 24 |
| Annual Refreshes | ~420,480 | 1,152 × 365 |

### Why 75 Seconds in Your Logs?

From your `PROOF_OF_WORKING_FEDERATION.md`:
```
Refresh Interval: ~75 seconds (1 min 15 sec)
```

This is **CORRECT** behavior:
```
300 seconds (refresh_hint from endpoint)
÷ 4 (attemptsPerRefreshHint constant)
= 75 seconds actual polling interval
```

---

## ⚙️ Advanced: Changing Refresh Intervals

### To Change the Refresh Hint

1. **Edit SPIRE Server ConfigMap**:

```bash
kubectl edit configmap spire-server -n zero-trust-workload-identity-manager
```

2. **Find and modify the federation section**:

```json
"federation": {
  "bundle_endpoint": {
    "address": "0.0.0.0",
    "port": 8443,
    "refresh_hint": "2m"  // Change from 5m to 2m for faster refresh
  }
}
```

3. **Restart SPIRE server**:

```bash
kubectl rollout restart statefulset/spire-server -n zero-trust-workload-identity-manager
```

4. **Verify the change**:

```bash
# Wait 30 seconds for server to restart, then:
curl -k https://federation-endpoint/ | jq '.spiffe_refresh_hint'
# Should now return: 120 (2 minutes)

# New polling interval will be: 120 ÷ 4 = 30 seconds
```

### Recommended Values

| Use Case | Refresh Hint | Poll Interval | Reasoning |
|----------|--------------|---------------|-----------|
| **Production** | `5m` | ~75 sec | ✅ Current (balanced) |
| **High Security** | `2m` | ~30 sec | Faster detection of revocations |
| **Low Traffic** | `10m` | ~150 sec | Reduce API calls |
| **Development** | `1m` | ~15 sec | Fastest legal refresh |

**⚠️ Caution**: Lower values increase:
- Network traffic
- CPU usage
- API calls to federation endpoints

---

## 🐛 Troubleshooting Refresh Issues

### Issue 1: Bundles Not Refreshing

**Symptoms:**
```bash
# No recent refresh events
kubectl logs spire-server-0 -c spire-server --tail=500 | grep "Bundle refreshed"
# Returns: (empty)
```

**Causes & Solutions:**

1. **Missing `federates_with` config**
   ```bash
   # Check if configured
   kubectl exec spire-server-0 -c spire-server -- cat /run/spire/config/server.conf | \
     grep -A 10 "federates_with"
   ```

2. **Federation endpoint unreachable**
   ```bash
   # Test connectivity
   kubectl exec spire-server-0 -c spire-server -- curl -k https://federation-endpoint/
   ```

3. **SPIRE server not restarted after config change**
   ```bash
   kubectl rollout restart statefulset/spire-server -n zero-trust-workload-identity-manager
   ```

### Issue 2: Refresh Interval Seems Wrong

**Verification:**
```bash
# Check configured refresh_hint
curl -k https://federation-endpoint/ | jq '.spiffe_refresh_hint'

# Check actual polling interval from logs
kubectl logs spire-server-0 -c spire-server --tail=100 | grep "Bundle refreshed" | \
  tail -2 | awk '{print $1}' # Compare timestamps
```

**Expected**: Actual interval should be ~1/4 of refresh_hint

### Issue 3: Refresh Hint Not Appearing in JSON

**Check:**
```bash
curl -k https://federation-endpoint/ | jq 'keys'
```

If `spiffe_refresh_hint` is missing:
- Server may not have the config set
- Bundle marshaling may have failed
- Check server logs for errors

---

## 📚 Key Takeaways

### ✅ What You Should See

1. **In Federation Endpoint JSON:**
   ```json
   "spiffe_refresh_hint": 300
   ```

2. **In SPIRE Server Logs (every ~75 seconds):**
   ```
   level=info msg="Bundle refreshed"
   ```

3. **In Bundle List Output:**
   ```bash
   kubectl exec ... -- ./spire-server bundle list
   # Shows: * apps.cluster-2.devcluster.openshift.com
   ```

### 🔄 Refresh Lifecycle

```
1. Server publishes bundle with refresh_hint
   ↓
2. Client reads refresh_hint from endpoint
   ↓
3. Client calculates poll interval (hint ÷ 4)
   ↓
4. Client polls endpoint every ~75 seconds
   ↓
5. If bundle changed → Update datastore
   ↓
6. Log "Bundle refreshed"
   ↓
7. Workloads automatically get new bundle
```

### 🎯 Your Setup Status

Based on your configuration:
- ✅ Refresh hint: **300 seconds** (optimal)
- ✅ Actual polling: **~75 seconds** (correct calculation)
- ✅ Both clusters refreshing independently
- ✅ Zero manual intervention required
- ✅ Production-ready configuration

---

## 📖 Related Documentation

- **Code References:**
  - `spire/pkg/server/bundle/client/manager.go` - Refresh logic
  - `spire/pkg/common/bundleutil/refreshhint.go` - Hint calculation
  - `spire/pkg/server/endpoints/bundle/server.go` - Endpoint serving

- **Your Setup Docs:**
  - [PROOF_OF_WORKING_FEDERATION.md](./PROOF_OF_WORKING_FEDERATION.md)
  - [TEST_RESULTS.md](./TEST_RESULTS.md)
  - [TEST_COMMANDS.md](./TEST_COMMANDS.md)

---

## 🚀 Quick Commands Reference

```bash
# Watch real-time refreshes
kubectl logs -f spire-server-0 -c spire-server -n zero-trust-workload-identity-manager | \
  grep --line-buffered "Bundle refresh"

# Check current refresh hint
curl -k https://federation-endpoint/ | jq '.spiffe_refresh_hint'

# View refresh history
kubectl logs spire-server-0 -c spire-server --tail=500 | \
  grep "Bundle refreshed" | tail -10

# List all bundles (including federated)
kubectl exec spire-server-0 -c spire-server -- ./spire-server bundle list
```

---

**Last Updated:** October 22, 2025  
**Status:** Production-ready federation with automatic 75-second refresh ✅

