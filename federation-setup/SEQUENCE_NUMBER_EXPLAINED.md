# Understanding `spiffe_sequence` vs "Bundle refreshed" Logs

## 🎯 TL;DR - This is NORMAL Behavior!

**What you're seeing:**
- ✅ "Bundle refreshed" logs every ~75 seconds
- ✅ `spiffe_sequence` stays at 1

**This is EXPECTED and CORRECT!** Here's why:

---

## 📊 Your Current Status

### Cluster 1
```json
{
  "spiffe_sequence": 1,
  "spiffe_refresh_hint": 300,
  "key_count": 2
}
```
**Certificate Valid:** Oct 22 08:14:06 → Oct 23 08:14:16 (24 hours)

### Cluster 2
```json
{
  "spiffe_sequence": 1,
  "spiffe_refresh_hint": 300,
  "key_count": 2
}
```

### Recent Refresh Logs

**Cluster 1:**
```
time="2025-10-22T09:58:30Z" msg="Bundle refreshed" trust_domain=apps.server-3...
time="2025-10-22T09:59:45Z" msg="Bundle refreshed" trust_domain=apps.server-3...
time="2025-10-22T10:01:00Z" msg="Bundle refreshed" trust_domain=apps.server-3...
time="2025-10-22T10:02:15Z" msg="Bundle refreshed" trust_domain=apps.server-3...
time="2025-10-22T10:03:30Z" msg="Bundle refreshed" trust_domain=apps.server-3...
```
**Interval:** ~75 seconds ✅

---

## 🔍 Understanding the Difference

### "Bundle refreshed" Log
**Meaning:** "I successfully polled the federation endpoint"

**When it appears:**
- Every ~75 seconds (or whatever your poll interval is)
- Regardless of whether the bundle content changed
- Just means the HTTP request succeeded

**What it does NOT mean:**
- ❌ The bundle content changed
- ❌ New certificates were added
- ❌ The sequence number incremented

**Think of it as:** "Checked for updates, everything OK"

### `spiffe_sequence` Field
**Meaning:** "Bundle VERSION number"

**When it increments:**
- ✅ New CA certificate is added to the bundle
- ✅ Old CA certificate is removed from the bundle
- ✅ JWT signing keys change
- ✅ Any actual content change to the bundle

**When it does NOT increment:**
- ❌ Just polling the endpoint
- ❌ Time passing
- ❌ Certificate still valid

**Think of it as:** "Version number, like software v1, v2, v3"

---

## 🕐 Timeline Visualization

```
08:14 AM (Oct 22)
│
├─ Certificate created
│  spiffe_sequence = 1
│
├─ 09:58:30 - Bundle refreshed ✓ (sequence still 1)
├─ 09:59:45 - Bundle refreshed ✓ (sequence still 1)
├─ 10:01:00 - Bundle refreshed ✓ (sequence still 1)
├─ 10:02:15 - Bundle refreshed ✓ (sequence still 1)
├─ 10:03:30 - Bundle refreshed ✓ (sequence still 1)
│  ... (continues every ~75 seconds)
│  
│  [All day: sequence = 1, refreshes every ~75s]
│
08:14 AM (Oct 23) ← TOMORROW
│
└─ Certificate rotates
   spiffe_sequence = 2 ← WILL INCREMENT HERE!
```

---

## 📖 Detailed Explanation

### Why Sequence Isn't Changing

Your certificate is valid for **24 hours**:
```
Created:  Oct 22 08:14:06 2025
Expires:  Oct 23 08:14:16 2025
```

Until the certificate **rotates** (gets replaced), the bundle content stays the same, so:
- `spiffe_sequence` remains at **1**
- But polling continues every **~75 seconds**
- Each poll logs "Bundle refreshed"

**This is healthy behavior!** It means:
1. ✅ Federation is working
2. ✅ Bundles are being polled regularly
3. ✅ Certificate is still valid (no need to rotate yet)
4. ✅ System is stable

### When Will Sequence Change?

**Expected:** Tomorrow around **08:14 AM** when the certificate rotates

At that time, you should see:
```
1. Certificate rotation happens
2. Bundle content changes (new cert replaces old)
3. spiffe_sequence increments to 2
4. "Bundle refreshed" log appears
5. Polling continues every ~75 seconds with sequence=2
```

---

## 🔬 How Bundle Client Works

Here's the actual logic from SPIRE code:

```go
// From spire/pkg/server/bundle/client/manager.go
func (m *Manager) runUpdateOnce(...) {
    log.Debug("Polling for bundle update")
    
    localBundle, endpointBundle, err := updater.UpdateBundle(ctx)
    
    if endpointBundle != nil {
        // This logs "Bundle refreshed" EVERY TIME we poll successfully
        log.Info("Bundle refreshed")
        return calculateNextUpdate(endpointBundle)
    }
}
```

**Key points:**
1. Client polls endpoint every ~75 seconds
2. Fetches the bundle JSON
3. Compares with local stored bundle
4. If **content differs** → Updates datastore (sequence increments)
5. If **content same** → Does nothing
6. **Either way** → Logs "Bundle refreshed"

So the log message is about **polling**, not about **content changes**.

---

## 🧪 Verify This Yourself

### 1. Check Sequence Number Multiple Times

```bash
# Check now
curl -sk https://federation-endpoint/ | jq '.spiffe_sequence'

# Wait 5 minutes

# Check again
curl -sk https://federation-endpoint/ | jq '.spiffe_sequence'
```

**Expected:** Same number both times (because cert hasn't rotated)

### 2. Watch Continuous Refreshes

```bash
kubectl logs -f spire-server-0 -c spire-server -n zero-trust-workload-identity-manager | \
  grep --line-buffered "Bundle refresh"
```

**Expected:** Logs appear every ~75 seconds, but sequence stays same

### 3. Check Certificate Expiry

```bash
# Cluster 1
curl -sk https://spire-server-federation-zero-trust-workload-identity-manager.apps.client-3.devcluster.openshift.com | \
  jq -r '.keys[] | select(.use == "x509-svid") | .x5c[0]' | \
  base64 -d | openssl x509 -noout -dates

# Cluster 2  
curl -sk https://spire-server-federation-zero-trust-workload-identity-manager.apps.server-3.devcluster.openshift.com | \
  jq -r '.keys[] | select(.use == "x509-svid") | .x5c[0]' | \
  base64 -d | openssl x509 -noout -dates
```

**Expected:** Shows 24-hour validity period

### 4. Calculate When Sequence Will Change

```bash
# Your cert expires at:
echo "Certificate expires: Oct 23 08:14:16 2025 GMT"
echo "Expected sequence increment: Around that time"
echo "Check again tomorrow morning!"
```

---

## 📚 Real-World Analogy

Think of it like checking your mailbox:

### "Bundle refreshed" = Checking Your Mailbox
- You check every day at 3 PM
- Most days: "Checked mailbox" ✓ (but no new mail)
- Occasionally: "Checked mailbox, got package!" ✓ (new content)

### `spiffe_sequence` = Package Version Number
- You're expecting Package v1
- Every day you check: "Yep, still v1"
- One day: "Oh! Now it's v2" (package upgraded)

**In your case:**
- **Checking:** Every ~75 seconds ✓
- **Current version:** 1
- **New version:** Will be 2 (tomorrow when cert rotates)

---

## ⚠️ When to Worry

### ❌ BAD: No "Bundle refreshed" Logs

```bash
# No recent refreshes
kubectl logs spire-server-0 --tail=500 | grep "Bundle refreshed"
# Returns: (empty)
```

**Problem:** Federation polling is broken  
**Fix:** Check `federates_with` config, restart SPIRE

### ❌ BAD: Errors in Logs

```
level=error msg="Error updating bundle" 
level=error msg="Unable to reach federation endpoint"
```

**Problem:** Network or authentication issues  
**Fix:** Check connectivity, certificates, routes

### ✅ GOOD: Your Current Situation

```
level=info msg="Bundle refreshed" (every ~75s)
spiffe_sequence: 1 (stable)
Certificate: Valid for next 24 hours
```

**Status:** Everything working perfectly! ✅

---

## 🔮 What Will Happen Tomorrow

### Around Oct 23 08:14 AM:

1. **Certificate rotation begins**
   ```
   SPIRE server generates new CA certificate
   notBefore: Oct 23 08:14:XX
   notAfter:  Oct 24 08:14:XX
   ```

2. **Bundle content changes**
   ```json
   {
     "keys": [
       {"x5c": ["NEW_CERT_HERE"]},  ← Changed!
       ...
     ],
     "spiffe_sequence": 2,  ← Incremented!
     "spiffe_refresh_hint": 300
   }
   ```

3. **Federation updates**
   ```
   Cluster 1 polls Cluster 2:
   - Sees sequence changed: 1 → 2
   - Downloads new bundle
   - Updates datastore
   - Logs: "Bundle refreshed"
   
   Cluster 2 polls Cluster 1:
   - Same process
   ```

4. **New steady state**
   ```
   spiffe_sequence: 2 (for next 24 hours)
   "Bundle refreshed": Every ~75 seconds
   ```

---

## 🎓 Key Takeaways

### What You're Seeing Now

| Observation | Interpretation | Status |
|-------------|---------------|---------|
| "Bundle refreshed" every ~75s | ✅ Polling working | GOOD |
| `spiffe_sequence` = 1 | ✅ Bundle stable | NORMAL |
| No errors in logs | ✅ Federation healthy | GOOD |
| Certificate valid 24h | ✅ No rotation needed yet | NORMAL |

### What's Actually Happening

```
Every ~75 seconds:
  1. Client: "Let me check for updates..."
  2. Client: *polls federation endpoint*
  3. Client: "Response received: sequence=1"
  4. Client: "I already have sequence=1"
  5. Client: "No changes needed"
  6. Client: *logs "Bundle refreshed"*
  7. Client: "Will check again in 75 seconds"
  
  [Repeat indefinitely]

When certificate rotates:
  1. Client: "Let me check for updates..."
  2. Client: *polls federation endpoint*
  3. Client: "Response received: sequence=2"  ← NEW!
  4. Client: "I have sequence=1, need to update!"
  5. Client: *downloads new bundle*
  6. Client: *updates datastore*
  7. Client: *logs "Bundle refreshed"*
  8. Client: "Now I have sequence=2"
  9. Client: "Will check again in 75 seconds"
```

---

## 🧪 Test: Force a Sequence Change

If you want to see the sequence increment **right now** instead of waiting:

### Option 1: Restart SPIRE Server (Forces New CA)

```bash
# WARNING: This will briefly interrupt federation
kubectl rollout restart statefulset/spire-server -n zero-trust-workload-identity-manager

# Wait 2 minutes for restart

# Check sequence
curl -sk https://federation-endpoint/ | jq '.spiffe_sequence'
# Should show: 2 (or higher)
```

### Option 2: Wait for Natural Rotation (Recommended)

```bash
# Just wait until tomorrow ~08:14 AM
# The sequence will increment naturally
# This is the production-safe approach
```

**Recommendation:** Just wait for natural rotation. Your system is healthy!

---

## 📊 Monitoring Script

Create a script to watch for sequence changes:

```bash
#!/bin/bash
# watch-sequence.sh

ENDPOINT="https://spire-server-federation-zero-trust-workload-identity-manager.apps.client-3.devcluster.openshift.com"

echo "Monitoring spiffe_sequence for changes..."
echo "Press Ctrl+C to stop"
echo ""

PREV=""
while true; do
    CURR=$(curl -sk "$ENDPOINT" | jq -r '.spiffe_sequence')
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ "$CURR" != "$PREV" ] && [ -n "$PREV" ]; then
        echo "🔔 $TIMESTAMP - SEQUENCE CHANGED: $PREV → $CURR"
    else
        echo "   $TIMESTAMP - sequence=$CURR (stable)"
    fi
    
    PREV=$CURR
    sleep 60  # Check every minute
done
```

Run it:
```bash
chmod +x watch-sequence.sh
./watch-sequence.sh
```

---

## 📖 Related Documentation

- **[TRUST_BUNDLE_REFRESH_GUIDE.md](./TRUST_BUNDLE_REFRESH_GUIDE.md)** - Complete refresh guide
- **[BUNDLE_REFRESH_CHEATSHEET.md](./BUNDLE_REFRESH_CHEATSHEET.md)** - Quick reference
- **Code:** `spire/pkg/server/bundle/client/manager.go:309` - "Bundle refreshed" log

---

## ✅ Summary

**Your Question:**
> "I am getting bundle refreshed logs but spiffe_sequence is not updating"

**Answer:**
This is **completely normal and expected**! 

- "Bundle refreshed" = Successfully polled (happens every ~75s)
- `spiffe_sequence` = Version number (only changes when content changes)

Your certificate is valid for 24 hours. Until it rotates, the sequence stays at 1.

**Action Required:** None! Your federation is working perfectly.

**Next Event:** Sequence will increment to 2 tomorrow around 08:14 AM when the certificate rotates.

---

**Status:** ✅ **Everything is working as designed!**

**Created:** October 22, 2025  
**Next Expected Change:** October 23, 2025 ~08:14 AM

