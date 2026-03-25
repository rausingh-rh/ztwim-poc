# SPIRE on KubeVirt: Q&A Guide

Simple questions and answers explaining the challenges and solutions for deploying SPIRE with OpenShift Virtualization / KubeVirt.

---

## The Challenge Questions

### Q1: Why is the workload API not available for VM workloads?

**A**: The virt-launcher pod has the VM running inside it. The pod can access the workload API when the SPIFFE-CSI-Driver mounts the unix socket inside the pod, but the VM cannot. The VM has its own kernel and filesystem - the `/run` directory inside the VM is completely separate from the `/run` directory in the pod or on the host. Even though the pod can mount the host's Unix socket, the VM guest operating system cannot see it.

---

### Q2: Why not just copy the Unix socket file into the VM's disk?

**A**: Unix sockets are not just files - they're endpoints connected to a running process. A Unix socket = File + Kernel State + Connection to Process. When a client connects, the kernel mediates the connection to the server process, and data flows through kernel memory, not through disk. You cannot copy a socket to a different computer, move it to a different kernel, or share it across the VM boundary because the VM has a different kernel.

---

### Q3: Why can't we use the same approach as pods?

**A**: Containers share the host's kernel, so they can access host files via volume mounts. VMs have their own kernel and cannot access host files directly. A VM is like a complete computer inside another computer - it has its own operating system, filesystem, and network stack that are completely isolated from the host.

---

### Q4: Can't we just use network-based communication instead of Unix sockets?

**A**: Yes, but it's less secure. Network-based communication means SPIRE traffic is visible on the pod network and can potentially be intercepted or sniffed. Unix sockets provide better isolation and security. The ideal solution uses VSOCK (virtual sockets) which provides socket-like communication specifically designed for host-guest VM communication, combining security with functionality.

---

### Q5: What is VSOCK and why do we need it?

**A**: VSOCK (Virtual Socket) is a special socket type designed for communication between a hypervisor host and guest VMs. Instead of IP addresses, it uses CID (Context ID) - CID 2 is always the host, CID 3+ are guest VMs. VSOCK traffic is isolated from the network, cannot be intercepted, and provides fast, secure host-guest communication. It's the missing piece that solves the VM isolation problem.

---

### Q6: How does VSOCK solve the communication problem?

**A**: VMs can create VSOCK sockets and connect to the host (CID 2). A bridge process on the host listens on VSOCK and forwards traffic to SPIRE Server via TCP. This creates a secure path: `VM → VSOCK → Host bridge → TCP → SPIRE Server`. The bridge can be implemented with standard tools like socat (`socat VSOCK-LISTEN:8081,fork TCP:spire-server:8081`) or a custom lightweight proxy.

---

### Q7: Should the bridge run on the host or inside the VM?

**A**: Host-side is better. Running the bridge in the virt-launcher pod (host-side) means no VM image modifications are needed, it's centrally managed by the operator, and updates are easier. Running it inside the VM would require installing and configuring socat in every VM image, which is more complex operationally.

---

### Q8: How does SPIRE know which VM is connecting?

**A**: The VM sends attestation data including its namespace, name, UID, and CID (Context ID). SPIRE Server validates this by querying the KubeVirt API to verify the VM exists and the metadata matches. This direct validation ensures only legitimate VMs managed by KubeVirt can get identities. The VM's CID is kernel-assigned and cannot be spoofed.

---

### Q9: If all apps run in the same VM, do they share the same identity?

**A**: No! Each application gets a unique identity using two-level attestation. First, the VM itself gets a "node SVID" (like a Kubernetes node). Then, each application inside the VM gets its own "workload SVID" based on its process UID and executable path. For example: nginx gets `spiffe://.../vm/my-vm/nginx`, postgres gets `spiffe://.../vm/my-vm/postgres` - completely separate identities.

---

### Q10: How does SPIRE identify individual applications inside a VM?

**A**: SPIRE uses the Unix workload attestor (standard SPIRE component). When an application connects to the SPIRE Agent socket, the agent reads the caller's process ID via SO_PEERCRED socket option, then reads `/proc/<PID>/` to get the UID, executable path, and other metadata. These characteristics (UID, path) are matched against registration entries to issue the correct identity.

---

### Q11: What are registration entries and why do we need them?

**A**: Registration entries are policies that define "if a workload matches these characteristics, give it this identity." For example: "if UID is 70 and path is /usr/bin/postgres, give identity spiffe://.../postgres." They must be created explicitly - they tell SPIRE which workloads should get which identities. Without registration entries, no identities can be issued.

---

### Q12: How do we create registration entries for VMs?

**A**: There are two approaches: **Manual** - use spire-server CLI to create entries for each VM and workload (works immediately but doesn't scale). **Automatic** - extend spire-controller-manager to watch VMs and create entries automatically from declarative configuration (requires upstream contribution but scales to 1000+ VMs). For production, automatic registration via spire-controller-manager is recommended.

---

### Q13: Do registration entries need to be created for both pods and VMs?

**A**: Yes, but for pods it's already automated by spire-controller-manager using ClusterSPIFFEID resources. For VMs, this automation doesn't exist yet - that's what needs to be added. The registration layer is independent of whether you use socat or custom proxy for communication. Both approaches need registration automation for production scale.

---

### Q14: What is the parent-child relationship in registration entries?

**A**: Registration entries form a hierarchy. The VM's entry has parent `spiffe://example.org/spire/server` (the root). Each workload's entry has parent equal to the VM's SPIFFE ID (e.g., `spiffe://.../vm/my-vm`). This creates the chain: SPIRE Server → VM → Workloads. Security benefit: a VM can only request identities for its own workloads, not for workloads in other VMs.

---

### Q15: How is the bridge automatically added to VMs?

**A**: A Kubernetes mutating webhook intercepts virt-launcher pod creation and automatically injects the bridge as a sidecar container. The operator configures the webhook, so when any VM starts, it automatically gets the communication bridge. No manual configuration needed - fully automatic.

---

## The Solution Questions

### Q16: What components are needed for the complete solution?

**A**: Four components:
1. **VSOCK bridge** (socat on host) - Communication path
2. **KubeVirt attestor plugin** (SPIRE Server) - Validates VMs via API
3. **KubeVirt attestor plugin** (SPIRE Agent in VM) - Generates VM attestation
4. **spire-controller-manager enhancement** (upstream) - Automates registration

The first three enable the technical functionality. The fourth makes it operationally scalable.

---

### Q17: Why use socat instead of a custom proxy?

**A**: socat is a standard Unix tool that requires zero custom code - just one command: `socat VSOCK-LISTEN:8081,fork TCP:spire-server:8081`. It's well-tested, widely known, and smaller than custom solutions. A custom proxy offers better logging and metrics but requires maintaining custom code. For most deployments, socat's simplicity wins.

---

### Q18: Why create a custom attestor instead of using standard SPIRE attestors?

**A**: Standard SPIRE attestors (like x509pop) require complex delegation patterns and experimental HA agent features. The custom KubeVirt attestor directly queries the KubeVirt API to validate VMs - this is production-ready, uses stable Kubernetes APIs, and provides stronger security through direct validation. It's worth the small amount of custom code (~300 lines).

---

### Q19: How does the complete flow work end-to-end?

**A**: 
1. VM boots, SPIRE Agent inside connects via VSOCK to host bridge
2. Bridge forwards to SPIRE Server over TCP
3. SPIRE Server validates VM via KubeVirt API, issues VM's SVID
4. Application starts in VM, connects to VM's SPIRE Agent (local Unix socket)
5. VM's Agent identifies the app (UID, path), queries SPIRE Server via VSOCK
6. SPIRE Server finds matching registration entry, issues app's unique SVID
7. Application can now do mTLS with other services

Total time: ~1 second from app start to identity received.

---

### Q20: What happens during VM attestation?

**A**: VM's SPIRE Agent sends metadata (namespace, name, UID, CID) via VSOCK. SPIRE Server's KubeVirt attestor plugin queries the Kubernetes API: `GET /apis/kubevirt.io/v1/namespaces/<ns>/virtualmachineinstances/<name>`. It validates the UID matches, CID matches, and VM is running. Only if all checks pass does SPIRE issue the VM's node SVID. This direct API validation prevents VM spoofing.

---

### Q21: Can one VM impersonate another VM?

**A**: No. The VM must prove its identity with metadata that SPIRE validates against the KubeVirt API. The CID (Context ID) is kernel-assigned and cannot be faked. Even if a rogue VM sends fake metadata, SPIRE's query to KubeVirt API will return the real VM's information, and the mismatch will be detected. Only legitimate VMs managed by KubeVirt can attest.

---

### Q22: Can one application steal another application's identity in the same VM?

**A**: No. When an app connects to the SPIRE Agent socket, the kernel provides the caller's PID via SO_PEERCRED - this cannot be faked from userspace. The agent reads `/proc/<PID>/` to get the UID and executable path. These kernel-enforced properties uniquely identify the process. If nginx (UID 33) tries to get postgres's identity (UID 70), the selector mismatch prevents it.

---

## Implementation Questions

### Q23: How long does implementation take?

**A**: Phased approach: Month 1 - proof of concept with 3 test VMs. Month 2 - production pilot with 10-20 VMs using manual registration. Months 3-6 - automated registration via spire-controller-manager contribution, scaling to 100+ VMs. Critical functionality works in 4-6 weeks; full automation takes 6 months.

---

### Q24: What needs to be built vs what's standard?

**A**: 
**Standard components** (use as-is): socat, SPIRE Server/Agent, Unix workload attestor, Kubernetes APIs.
**Custom components** (need to build): KubeVirt attestor plugins (~300 lines Go), operator webhook for bridge injection (~150 lines), spire-controller-manager enhancement (upstream contribution).
Total custom code: ~500-600 lines, which is minimal for the functionality gained.

---

### Q25: How do we test this quickly?

**A**: Use Helm charts for rapid iteration (30 second deployments vs 10 minute operator deployments). Deploy SPIRE with custom images via Helm, update configurations in values.yaml, and test immediately. This enables testing multiple approaches and configurations quickly before committing to production deployment patterns.

---

### Q26: What changes are needed to VM images?

**A**: None! The bridge runs on the host (injected into virt-launcher pod), and the SPIRE Agent can be installed via cloud-init or baked into VM images. Standard cloud images (Fedora, Ubuntu, RHEL) work as-is. Only requirement: enable VSOCK in the VM specification (`autoattachVSOCK: true` in KubeVirt VMI spec).

---

### Q27: How much overhead does this add?

**A**: Minimal. The VSOCK bridge uses ~50MB RAM and 0.05 CPU per VM. SPIRE Agent in VM uses ~100MB RAM. Latency overhead is ~40-100ms for identity operations, which happens once per SVID lifetime (typically 1 hour). For a cluster with 100 VMs, total overhead is ~15GB RAM, which is less than 1% on a typical production cluster.

---

### Q28: How do we manage this in production?

**A**: The operator manages SPIRE component lifecycle (deployment, upgrades, configuration). The VSOCK bridge is automatically injected by webhook (no manual steps). Registration entries are created either manually (short-term) via provided scripts or automatically (long-term) via spire-controller-manager once the upstream contribution is merged. Day-to-day operations are minimal.

---

### Q29: What if the upstream contribution to spire-controller-manager isn't accepted?

**A**: We have a fallback: implement the registration controller in your operator temporarily. It watches VMs and creates entries automatically based on VM annotations. Once the approach proves valuable, the community is more likely to accept it upstream. The architecture and implementation remain the same - only which component hosts the registration controller changes.

---

### Q30: Can pods and VM workloads communicate with mTLS?

**A**: Yes! That's the key benefit. Both pods and VMs are in the same trust domain with SPIFFE identities. A pod workload with identity `spiffe://.../sa/api-gateway` can establish mTLS with a VM workload with identity `spiffe://.../vm/database-vm/postgres`. The trust bundle is shared, certificates are mutually validated, and mTLS "just works" across the hybrid environment.

---

## Approach Comparison Questions

### Q31: What are the different approaches to solve this?

**A**: **Communication**: socat on host (recommended - simple, no VM changes) vs custom proxy (more control) vs socat in VM (requires VM modifications). **Attestation**: KubeVirt API attestor (recommended - production-ready, direct validation) vs x509pop delegation (experimental). **Registration**: Manual scripts (short-term) vs spire-controller-manager automation (long-term recommended).

---

### Q32: Why is socat on the host better than inside the VM?

**A**: Host-side requires no VM image modifications - it works with any standard VM image. The operator automatically injects socat into the virt-launcher pod, so it's centrally managed and easier to update. VM-side would require installing socat in every VM image and managing per-VM configurations, which is more complex operationally.

---

### Q33: Why use a custom KubeVirt attestor instead of standard attestors?

**A**: The custom KubeVirt attestor directly validates VMs by querying the KubeVirt API - the authoritative source. It checks VM existence, UID, CID, and running status in one API call. Standard attestors like x509pop require delegation through a special HA agent (more complex) and are experimental. Direct validation is production-ready and provides stronger security with fewer moving parts.

---

### Q34: What is spire-controller-manager and why do we need it?

**A**: spire-controller-manager is a SPIRE component that automatically creates registration entries for pods based on ClusterSPIFFEID resources (declarative configuration). Currently it only works for pods. For VMs, we need to extend it to watch VirtualMachineInstance resources and create entries automatically. This makes registration scalable (GitOps-friendly, handles 1000+ VMs) instead of manual.

---

### Q35: Why contribute to upstream instead of building in our operator?

**A**: Separation of concerns. Your operator should manage SPIRE component *deployment* (lifecycle), while spire-controller-manager manages *registration* (entry creation). This keeps clear boundaries, benefits the entire SPIRE+KubeVirt community, and ensures long-term community maintenance. The contribution also validates your architecture and gains community expertise.

---

## Security Questions

### Q36: How secure is VSOCK communication?

**A**: Very secure. VSOCK traffic is completely isolated from the pod network - it cannot be sniffed or intercepted by network tools. The CID (Context ID) is kernel-assigned and cannot be spoofed. VSOCK connections are kernel-mediated, providing isolation comparable to Unix sockets but across the VM boundary.

---

### Q37: What prevents a compromised VM from attacking other VMs?

**A**: Multiple security layers: (1) Each VM has a unique CID assigned by the kernel (cannot be spoofed). (2) SPIRE validates VM metadata against KubeVirt API (cannot fake). (3) Each VM only gets identities for its own workloads (parent-child enforcement). (4) Compromised VM cannot query KubeVirt API (RBAC protected). Even if one VM is fully compromised, it cannot impersonate other VMs or their workloads.

---

### Q38: What if someone compromises an application inside a VM?

**A**: The blast radius is limited to that application only. The Unix workload attestor uses kernel-enforced properties (PID, UID) that cannot be faked. A compromised nginx (UID 33) cannot get postgres's identity (UID 70) because the UID check will fail. Each application can only get its own identity based on selectors that the kernel enforces.

---

### Q39: How does credential rotation work?

**A**: Automatic. SPIRE issues SVIDs with configurable TTL (typically 1 hour). At 50% of lifetime, the SPIRE Agent automatically fetches a new SVID. When the old SVID expires, the new one is already in use. Applications using SPIRE libraries get rotated credentials seamlessly without restart. This eliminates long-lived credentials and reduces security risk.

---

## Operational Questions

### Q40: How do we register a new VM?

**A**: **Short-term (manual)**: Run `./deploy/register-vm-workloads.sh <namespace> <vm-name>` which interactively creates the VM node entry and workload entries. Takes 2-3 minutes per VM. **Long-term (automatic)**: Annotate the VM with workload definitions or create a ClusterSPIFFEID resource - the controller creates all entries automatically. Zero manual commands needed.

---

### Q41: What happens when a VM is deleted?

**A**: The registration controller (when automated) detects the VMI deletion and removes the associated entries from SPIRE. Existing SVIDs remain valid until expiry (grace period), then cannot be renewed. This automatic cleanup prevents stale entries and maintains security hygiene.

---

### Q42: How do we troubleshoot if a VM can't get identity?

**A**: Check in order: (1) Is VSOCK enabled? (`autoattachVSOCK: true` in VMI spec). (2) Is bridge running? (check virt-launcher pod logs). (3) Can VM connect to host? (test with `nc -v vsock://2:8081` inside VM). (4) Does registration entry exist? (query SPIRE Server). (5) Do selectors match? (check app's UID and path match entry). Most issues are configuration mismatches.

---

### Q43: Can this work with any VM operating system?

**A**: Yes, any OS with VSOCK support. Linux VMs work out-of-the-box (kernel 4.8+). Windows VMs require VSOCK drivers but are supported. SPIRE Agent runs on Linux, Windows, and other platforms. The architecture is OS-agnostic - the VSOCK and SPIRE components are cross-platform.

---

### Q44: Does this work with live migration?

**A**: Yes. During live migration, the VM moves to a different node but keeps its identity. The SPIRE Agent in the VM maintains its connection (may reconnect via new host's bridge), and the SVID remains valid. Workloads continue operating with their identities. The VM's SPIFFE ID doesn't change during migration - only the underlying node changes.

---

### Q45: How does this scale to hundreds of VMs?

**A**: With automation (spire-controller-manager), registration is declarative - one ClusterSPIFFEID can cover hundreds of VMs with matching labels. The VSOCK bridge is lightweight (~50MB per VM). SPIRE Server can handle thousands of agents. The architecture is designed for scale - tested concepts from standard SPIRE deployments apply.

---

## Summary

**Core Challenge**: VMs are isolated (different kernel/filesystem), so standard SPIRE approaches don't work.

**Core Solution**: VSOCK bridges the isolation gap, custom attestor validates VMs via KubeVirt API, standard Unix attestor identifies apps, and automation makes it scalable.

**Result**: Each application in every VM gets a unique, automatically-rotated cryptographic identity - true zero-trust for legacy workloads.

---

**For technical deep-dive, see**: `PROBLEM-AND-SOLUTION.md`  
**For stakeholder presentation, see**: `STAKEHOLDER-PRESENTATION.md`  
**For visual flows, see**: `FLOW-DIAGRAMS.md`
