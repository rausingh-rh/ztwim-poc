# Trust Bundle Refresh - Quick Start

## 📚 What's New

Three new resources to help you understand and monitor trust bundle refresh:

1. **[TRUST_BUNDLE_REFRESH_GUIDE.md](./TRUST_BUNDLE_REFRESH_GUIDE.md)** - Complete documentation
2. **[BUNDLE_REFRESH_CHEATSHEET.md](./BUNDLE_REFRESH_CHEATSHEET.md)** - Quick reference
3. **[monitor-bundle-refresh.sh](./monitor-bundle-refresh.sh)** - Interactive monitoring tool

---

## ⚡ Quick Answers

### How often does it refresh?
**Every ~75 seconds**

### Why 75 seconds?
```
Refresh Hint: 300 seconds (from federation endpoint)
÷ 4 (resilience attempts)
= 75 seconds actual polling interval
```

### How to see it?
```bash
# Option 1: Real-time log watching
kubectl logs -f -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | \
  grep --line-buffered "Bundle refresh"

# Option 2: Interactive monitor (recommended)
./monitor-bundle-refresh.sh
```

### How in JSON?
```bash
curl -k https://federation-endpoint/ | jq '.spiffe_refresh_hint'
# Returns: 300
```

---

## 🚀 Try It Now

### 1. Run the Interactive Monitor
```bash
cd /home/rausingh/Documents/oape/ztwim-poc/federation-setup
./monitor-bundle-refresh.sh
```

Choose from menu:
1. Show Current Refresh Configuration
2. Watch Real-Time Bundle Refreshes ⭐ **Start here!**
3. View Refresh History
4. Calculate Refresh Interval
5. Test Federation Endpoint
6. Monitor Both Clusters
7. Show Next Scheduled Refresh
8. Run Full Diagnostics

### 2. Quick Verification
```bash
# One-liner to verify everything
curl -sk https://$(kubectl get route federation -n zero-trust-workload-identity-manager -o jsonpath='{.spec.host}') | \
  jq '{refresh_hint: .spiffe_refresh_hint, sequence: .spiffe_sequence}' && \
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=500 | \
  grep "Bundle refreshed" | tail -3
```

---

## 📖 Documentation Structure

### For Quick Reference
→ **[BUNDLE_REFRESH_CHEATSHEET.md](./BUNDLE_REFRESH_CHEATSHEET.md)**
- One-page quick reference
- Common commands
- Key concepts
- Troubleshooting

### For Deep Understanding
→ **[TRUST_BUNDLE_REFRESH_GUIDE.md](./TRUST_BUNDLE_REFRESH_GUIDE.md)**
- Complete explanation
- How refresh works
- Configuration options
- Advanced topics
- Full examples

### For Monitoring
→ **[monitor-bundle-refresh.sh](./monitor-bundle-refresh.sh)**
- Interactive menu system
- Real-time monitoring
- Historical analysis
- Diagnostics

---

## 🎯 What You'll Learn

### From the Guide
- How SPIRE calculates refresh intervals
- Why it divides by 4
- Where refresh_hint comes from
- How to change refresh rates
- Federation endpoint JSON structure
- Bundle refresh lifecycle

### From the Monitor
- Real-time refresh events
- Actual vs expected intervals
- Federation endpoint testing
- Bundle history analysis
- Multi-cluster monitoring

---

## 📊 Your Current Setup

```yaml
Configuration:
  Refresh Hint: 300 seconds (5 minutes)
  Poll Interval: ~75 seconds
  Refreshes/Hour: ~48
  
Federation Endpoint JSON:
  spiffe_refresh_hint: 300
  spiffe_sequence: 1
  keys: 2 (x509-svid + jwt-svid)

Status:
  ✅ Both clusters refreshing automatically
  ✅ ~75 second interval (as expected)
  ✅ Zero manual intervention
  ✅ Production-ready
```

---

## 🔧 Common Tasks

### Watch Next Refresh
```bash
# Wait for and capture the next refresh event
START=$(date +%s)
kubectl logs -f spire-server-0 -c spire-server -n zero-trust-workload-identity-manager | \
  grep --line-buffered -m 1 "Bundle refreshed"
END=$(date +%s)
echo "Refresh after $((END - START)) seconds"
```

### Check Bundle List
```bash
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  ./spire-server bundle list
```

Expected output:
```
****************************************
* apps.cluster-1.devcluster.openshift.com  ← Own bundle
****************************************

****************************************
* apps.cluster-2.devcluster.openshift.com  ← Federated bundle ✅
****************************************
```

### Verify Refresh Rate
```bash
# Last 5 refresh events with timestamps
kubectl logs spire-server-0 -c spire-server -n zero-trust-workload-identity-manager --tail=500 | \
  grep "Bundle refreshed" | tail -5
```

---

## 🎓 Key Concepts

### Refresh Hint
- **What**: Server tells clients "poll me every X seconds"
- **Where**: `spiffe_refresh_hint` in federation endpoint JSON
- **Your value**: 300 seconds

### Poll Interval
- **What**: How often client actually polls
- **Calculation**: `refresh_hint ÷ 4`
- **Your value**: ~75 seconds

### Why ÷ 4?
- **Resilience**: 4 attempts within refresh period
- **Benefit**: Tolerant to transient failures
- **Example**: If 1st poll fails, 3 more chances

---

## 🔍 Troubleshooting

### No "Bundle refreshed" logs?

**Check 1**: Federation configured?
```bash
kubectl exec spire-server-0 -c spire-server -- cat /run/spire/config/server.conf | \
  grep -A 10 "federates_with"
```

**Check 2**: Can reach endpoint?
```bash
kubectl exec spire-server-0 -c spire-server -- \
  curl -k https://federation-endpoint/
```

**Fix**: Restart SPIRE
```bash
kubectl rollout restart statefulset/spire-server -n zero-trust-workload-identity-manager
```

### Wrong interval?

**Expected**: ~75 seconds (for refresh_hint=300)

**Check actual**:
```bash
./monitor-bundle-refresh.sh
# Choose option 4: Calculate Refresh Interval
```

---

## 📚 Related Documentation

- [DOCUMENTATION_INDEX.md](../DOCUMENTATION_INDEX.md) - All documentation
- [PROOF_OF_WORKING_FEDERATION.md](./PROOF_OF_WORKING_FEDERATION.md) - Federation verification
- [TEST_COMMANDS.md](./TEST_COMMANDS.md) - Testing commands

---

## 💡 Pro Tips

1. **Use the interactive monitor** - It's the easiest way to explore
2. **Keep cheatsheet handy** - Quick reference for commands
3. **Check the guide** - When you need deep understanding
4. **Monitor both clusters** - See bidirectional refresh in action

---

## ✅ Quick Verification Checklist

- [ ] Can see refresh_hint in federation endpoint JSON (300)
- [ ] See "Bundle refreshed" logs every ~75 seconds
- [ ] Both clusters show federated bundles in `bundle list`
- [ ] Monitor tool runs successfully
- [ ] Understand why it's 75 seconds (300 ÷ 4)

---

**Created:** October 22, 2025  
**Your Setup:** Production-ready with automatic 75-second refresh ✅

**Start here**: `./monitor-bundle-refresh.sh` 🚀

