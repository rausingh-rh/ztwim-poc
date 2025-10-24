# SPIRE Agent Non-Root: Complete Guide

## Problem
Running SPIRE agent as uid 1000 fails with: `bind: permission denied`

**Why:** Agent creates UNIX socket via `bind()` → needs WRITE on directory → directory is `root:root 755` → uid 1000 only has READ → fails

---

## Why This Architecture

**Goal:** Deliver workload identities via UNIX socket

```
SPIRE Agent → creates socket → /run/spire/agent-sockets/spire-agent.sock (host)
                                         ↓
CSI Driver → reads socket → mounts to workload pods
                                         ↓  
Workload → connects → gets X.509 certificate
```

**Must use HostPath** (not emptyDir) because CSI driver (separate pod) needs to access agent's socket.

---

## What Didn't Work

| Attempt | Why Failed |
|---------|------------|
| Just set `runAsUser: 1000` | Directory still root:root, can't write |
| Use `fsGroup: 1000` | Ignored for HostPath (bind mount limitation) |
| Change ownership during mount | HostPath doesn't support transformations |
| Use `chmod 777` | Security risk - any pod could tamper with socket |

**Conclusion:** Must change ownership **on host** before mounting.

---

## Solutions

### Solution 1: MachineConfig
```bash
oc apply -f machineconfig-spire-agent-socket.yaml
oc get mcp worker -w  # 15-30 min
```
- ✅ Permanent (survives reboot)
- ✅ Most secure
- ⚠️ Requires node reboot

## FAQ

**Q: Will CSI driver and workloads still work with 1000:1000 ownership?**  
A: Yes! ✅ They need READ to connect, owner has `rwx`, others have `r-x` (sufficient).

**Q: What about 777 permissions instead?**  
A: Works but insecure - any pod could delete/replace socket.

**Q: Can't we change ownership during mount?**  
A: No, HostPath is a bind mount (pass-through), no transformation possible.
