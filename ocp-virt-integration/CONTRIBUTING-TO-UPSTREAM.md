# Contributing VM Support to spire-controller-manager

This guide explains how to contribute KubeVirt VM support to the upstream spire-controller-manager project using a **separate CRD** (`ClusterVMSPIFFEID`) that avoids introducing a kubevirt.io dependency.

---

## Why Contribute Upstream?

### Separation of Concerns

```
┌─────────────────────────────────────────────────────────────┐
│  spire-controller-manager (upstream)                        │
│  ────────────────────────────────────────────────────────   │
│  Responsibility: SPIRE Registration Entry Management        │
│                                                             │
│  Handles:                                                   │
│  ✅ Creating registration entries for Pods (ClusterSPIFFEID)│
│  ✅ Creating registration entries for VMs (ClusterVMSPIFFEID)
│  ✅ Watching Kubernetes resources                           │
│  ✅ Rendering templates                                     │
│  ✅ Reconciling with SPIRE Server                          │
│                                                             │
│  Does NOT handle:                                           │
│  ❌ Deploying SPIRE Server                                  │
│  ❌ Deploying SPIRE Agent                                   │
│  ❌ Infrastructure management                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  zero-trust-workload-identity-manager (your operator)       │
│  ────────────────────────────────────────────────────────   │
│  Responsibility: SPIRE Component Lifecycle Management       │
│                                                             │
│  Handles:                                                   │
│  ✅ Deploying SPIRE Server                                  │
│  ✅ Deploying SPIRE Agent                                   │
│  ✅ Managing configurations                                 │
│  ✅ Injecting VSOCK proxy                                   │
│  ✅ Upgrading components                                    │
│                                                             │
│  Does NOT handle:                                           │
│  ❌ Creating SPIRE registration entries                     │
│     (delegates to spire-controller-manager)                │
└─────────────────────────────────────────────────────────────┘

Clear boundaries! ✅
```

### Benefits

1. **Community Maintenance**: Not just you maintaining VM support
2. **Broader Adoption**: All KubeVirt users can benefit
3. **Better Testing**: Community testing across various environments
4. **Standard Approach**: One canonical way to register VMs
5. **Long-term Support**: Part of official SPIRE ecosystem
6. **Expertise Sharing**: Learn from SPIRE maintainers

---

## Why a Separate CRD (Not Extending ClusterSPIFFEID)?

### Problem with Extending ClusterSPIFFEID

The existing `ClusterSPIFFEID` is **tightly coupled to Pods**:

```go
// Current ClusterSPIFFEID API
type ClusterSPIFFEIDSpec struct {
    SPIFFEIDTemplate          string                // Templates use .PodSpec, .NodeSpec
    PodSelector               *metav1.LabelSelector // Pod-specific
    WorkloadSelectorTemplates []string              // Produces k8s: selectors
}

type ClusterSPIFFEIDStats struct {
    PodsSelected           int  // Pod-specific stats
    PodEntryRenderFailures int  // Pod-specific stats
}
```

Adding VM fields (`vmSelector`, `vmWorkloads`) to this CRD would:
- ❌ Mix pod and VM concerns in one API
- ❌ Require a `kubevirt.io/api` dependency (see below)
- ❌ Bloat the CRD with mutually exclusive fields
- ❌ Confuse users about which fields apply to what

### The kubevirt.io Dependency Problem

Importing `kubevirt.io/api` into spire-controller-manager is problematic:

| Concern | Impact |
|---------|--------|
| **Dependency size** | kubevirt.io/api pulls in a large dependency tree |
| **Not universal** | Not all spire-controller-manager users run KubeVirt |
| **Maintenance** | SPIRE maintainers would need to track KubeVirt API changes |
| **Acceptance risk** | Maintainers likely to reject a platform-specific dependency |
| **Binary bloat** | All users pay the cost even if they don't use VMs |

### Fundamental Differences: Pods vs VMs

| Aspect | Pod (ClusterSPIFFEID) | VM (ClusterVMSPIFFEID) |
|--------|----------------------|----------------------|
| **Parent ID** | DaemonSet agent (`k8s_psat`) | VM agent (`join_token` / `kubevirt`) |
| **Workload Selectors** | `k8s:pod-uid`, `k8s:container-image` | `unix:uid`, `unix:gid` |
| **Watched Resource** | v1/Pod | kubevirt.io/v1/VirtualMachineInstance |
| **Agent Location** | Host (DaemonSet) | Inside VM |
| **Entry Lifecycle** | Tied to pod | Tied to VMI |
| **Template Context** | `.PodSpec`, `.NodeSpec` | `.Object` (unstructured) |

These differences justify a **separate CRD with its own controller**.

### Solution: ClusterVMSPIFFEID

A new, focused CRD that:
- ✅ Keeps ClusterSPIFFEID unchanged
- ✅ Uses dynamic/unstructured client (no kubevirt.io import)
- ✅ Has its own reconciler and stats
- ✅ Could support other VM platforms in the future (OpenStack, etc.)

---

## Contribution Plan

### Phase 1: Proposal and Design (Week 1)

#### Step 1: Update GitHub Issue #651

Issue #651 is already open at https://github.com/spiffe/spire-controller-manager/issues/651

The issue body needs to be **replaced** with the corrected approach below (the current body still references the old design of extending ClusterSPIFFEID directly).

**Title**: Add ClusterVMSPIFFEID CRD for Virtual Machine Registration

**Updated Issue Body** (copy everything below and replace the current issue body):

---

### Problem

Currently, spire-controller-manager supports automatic registration of Pod workloads via `ClusterSPIFFEID`. However, virtual machines (e.g., KubeVirt `VirtualMachineInstances`) require manual registration entry creation via the SPIRE Server CLI, which doesn't scale.

We have a working PoC on OpenShift Virtualization (KubeVirt) where a SPIRE Agent runs inside a VM and issues SVIDs to workloads (Redis, PostgreSQL) using the built-in Unix attestor. The end-to-end flow works, including VSOCK-based communication and automatic SVID rotation. The missing piece is **automated registration**.

### Why Not Extend ClusterSPIFFEID?

We initially considered adding VM fields to the existing `ClusterSPIFFEID`, but concluded a separate CRD is better:

1. **ClusterSPIFFEID is tightly coupled to Pods.** The spec exposes `.PodSpec` and `.NodeSpec` in templates, uses `podSelector`, and the status tracks pod-specific stats (`PodsSelected`, `PodEntryRenderFailures`). Adding VM-specific fields would mix two unrelated resource types in one API.

2. **It would introduce a kubevirt.io/api dependency.** To watch `VirtualMachineInstance` resources with typed structs, spire-controller-manager would need to import `kubevirt.io/api`. This is a large, platform-specific dependency that not all users need. A dynamic/unstructured client avoids this entirely.

3. **Pods and VMs have different trust models.** Pod entries use `k8s:` workload selectors and a DaemonSet agent as the parent. VM entries use `unix:` workload selectors and a per-VM agent as the parent. These differences are better expressed as a separate CRD with its own reconciler.

### Proposed Solution

Introduce a new CRD: `ClusterVMSPIFFEID`.

**Design principles:**

- **No platform-specific Go dependencies.** The controller uses `k8s.io/client-go/dynamic` and `k8s.io/apimachinery/pkg/apis/meta/v1/unstructured` to watch VM resources. No `kubevirt.io/api` import.
- **Configurable resource type.** A `vmResourceType` field (apiGroup, version, resource) tells the controller what GVR to watch. This works with KubeVirt, and could work with other VM platforms that expose CRDs.
- **Follows existing patterns.** Workload selectors use the same `workloadSelectorTemplates` pattern as `ClusterSPIFFEID` (free-form `type:value` strings). Templates use Go text/template with the VM resource available as `.Object`.
- **Purely additive.** No changes to `ClusterSPIFFEID` or any existing behavior.

**Example:**

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterVMSPIFFEID
metadata:
  name: database-vms
spec:
  vmResourceType:
    apiGroup: "kubevirt.io"
    version: "v1"
    resource: "virtualmachineinstances"

  vmSelector:
    matchLabels:
      app: database

  namespaceSelector:
    matchLabels:
      environment: production

  spiffeIDTemplate: >-
    spiffe://{{ .TrustDomain }}/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}

  workloadEntries:
  - name: postgres
    spiffeIDTemplate: >-
      spiffe://{{ .TrustDomain }}/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}/postgres
    workloadSelectorTemplates:
    - "unix:uid:26"
    ttl: 3600s

  - name: redis
    spiffeIDTemplate: >-
      spiffe://{{ .TrustDomain }}/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}/redis
    workloadSelectorTemplates:
    - "unix:uid:994"
    ttl: 3600s
```

**Controller sketch:**

```go
// Reconciler uses dynamic client - no kubevirt.io import
vmGVR := schema.GroupVersionResource{
    Group:    cr.Spec.VMResourceType.APIGroup,
    Version:  cr.Spec.VMResourceType.Version,
    Resource: cr.Spec.VMResourceType.Resource,
}

vmList, err := dynamicClient.Resource(vmGVR).Namespace(ns).List(ctx, listOpts)

for _, vm := range vmList.Items {
    // vm is *unstructured.Unstructured
    // Render templates with .Object = vm.Object
    // Create SPIRE entries via existing SPIRE API client
}
```

### Context

We are working on SPIRE integration with OpenShift Virtualization (KubeVirt) as part of the [zero-trust-workload-identity-manager](https://github.com/openshift/zero-trust-workload-identity-manager) operator. Our PoC successfully demonstrated:

- SPIRE Agent running inside a KubeVirt VM
- VM-to-host communication via VSOCK (with socat bridges)
- SVID issuance to multiple workloads (Redis UID 994, PostgreSQL UID 26) using the Unix attestor
- Automatic SVID rotation with configurable TTLs

The architecture was discussed in the #spire Slack channel, and Kevin Fox (@kfox1111) confirmed a similar working setup with his [spire-ha-agent helm chart](https://github.com/spiffe/helm-charts-hardened/pull/519).

### Open Questions

1. **Naming**: Is `ClusterVMSPIFFEID` the right name, or would something more generic like `ClusterResourceSPIFFEID` be preferred (to allow future support for other non-Pod resources)?
2. **Parent ID**: How should the parent SPIFFE ID for workload entries be determined? In our PoC, the parent is the VM agent's SPIFFE ID (e.g., `spiffe://trust.domain/spire/agent/join_token/UUID`). Should this be configurable in the CRD, or derived from the VM resource?
3. **Status phase**: Should the controller skip VMs that aren't in a "Running" phase? If so, the phase field path and running value should be configurable (different VM platforms may use different status fields).

I'm happy to implement this and submit a PR if the design direction is acceptable.

---

#### Step 2: Engage Community

- Join SPIFFE Slack (#spire-controller-manager channel)
- Discuss design with maintainers
- Get feedback on approach, especially the open questions
- Refine proposal based on input

---

### Phase 2: Implementation (Week 2-3)

#### Step 1: Fork and Branch

```bash
git clone https://github.com/YOUR-USERNAME/spire-controller-manager
cd spire-controller-manager
git checkout -b feature/cluster-vm-spiffeid
```

#### Step 2: Define ClusterVMSPIFFEID CRD

**File**: `api/v1alpha1/clustervmspiffeid_types.go`

```go
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ClusterVMSPIFFEIDSpec defines the desired state of ClusterVMSPIFFEID
type ClusterVMSPIFFEIDSpec struct {
	// VMResourceType identifies the VM resource to watch.
	// Uses dynamic client discovery - no platform-specific imports needed.
	// Example: {apiGroup: "kubevirt.io", version: "v1", resource: "virtualmachineinstances"}
	// +kubebuilder:validation:Required
	VMResourceType VMResourceType `json:"vmResourceType"`

	// VMSelector selects VMs by label.
	// +kubebuilder:validation:Optional
	VMSelector *metav1.LabelSelector `json:"vmSelector,omitempty"`

	// NamespaceSelector selects namespaces to scope VM selection.
	// +kubebuilder:validation:Optional
	NamespaceSelector *metav1.LabelSelector `json:"namespaceSelector,omitempty"`

	// SPIFFEIDTemplate is the SPIFFE ID template for the VM itself.
	// The VM resource is available as .Object (unstructured).
	// Additional variables: .TrustDomain, .ClusterName, .ClusterDomain
	// +kubebuilder:validation:Required
	SPIFFEIDTemplate string `json:"spiffeIDTemplate"`

	// WorkloadEntries defines workloads running inside the VM that should
	// receive their own SPIFFE IDs.
	// +kubebuilder:validation:Optional
	WorkloadEntries []VMWorkloadEntry `json:"workloadEntries,omitempty"`

	// TTL indicates an upper-bound time-to-live for X509 SVIDs minted for the
	// VM entry. If unset, a default will be chosen.
	// +kubebuilder:validation:Optional
	TTL metav1.Duration `json:"ttl,omitempty"`

	// JWTTTL indicates an upper-bound time-to-live for JWT SVIDs.
	// +kubebuilder:validation:Optional
	JWTTTL metav1.Duration `json:"jwtTtl,omitempty"`

	// FederatesWith is a list of trust domains that VM workloads
	// will federate with.
	// +kubebuilder:validation:Optional
	FederatesWith []string `json:"federatesWith,omitempty"`

	// ClassName selects which controller instance acts on this object.
	// +kubebuilder:validation:Optional
	ClassName string `json:"className,omitempty"`

	// VMStatusPhaseField is the JSON path within the VM resource's status
	// that indicates whether the VM is running. Only VMs with this field
	// set to VMStatusPhaseRunning will be processed.
	// Default: ".status.phase"
	// +kubebuilder:validation:Optional
	// +kubebuilder:default=".status.phase"
	VMStatusPhaseField string `json:"vmStatusPhaseField,omitempty"`

	// VMStatusPhaseRunning is the value of the phase field that indicates
	// the VM is running. Default: "Running"
	// +kubebuilder:validation:Optional
	// +kubebuilder:default="Running"
	VMStatusPhaseRunning string `json:"vmStatusPhaseRunning,omitempty"`
}

// VMResourceType identifies the GroupVersionResource for VM objects.
type VMResourceType struct {
	// APIGroup is the API group (e.g., "kubevirt.io")
	// +kubebuilder:validation:Required
	APIGroup string `json:"apiGroup"`

	// Version is the API version (e.g., "v1")
	// +kubebuilder:validation:Required
	Version string `json:"version"`

	// Resource is the resource name (e.g., "virtualmachineinstances")
	// +kubebuilder:validation:Required
	Resource string `json:"resource"`
}

// VMWorkloadEntry defines a workload running inside a VM.
type VMWorkloadEntry struct {
	// Name identifies this workload entry (used for status tracking).
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	Name string `json:"name"`

	// SPIFFEIDTemplate is the SPIFFE ID template for this workload.
	// Same template variables as the parent VM template.
	// +kubebuilder:validation:Required
	SPIFFEIDTemplate string `json:"spiffeIDTemplate"`

	// WorkloadSelectorTemplates produce selectors that the SPIRE Agent uses
	// to match this workload. Format: "type:value" (e.g., "unix:uid:994").
	// The VM resource is available as .Object in templates.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinItems=1
	WorkloadSelectorTemplates []string `json:"workloadSelectorTemplates"`

	// TTL for this workload's X509 SVID. Overrides the parent TTL.
	// +kubebuilder:validation:Optional
	TTL metav1.Duration `json:"ttl,omitempty"`

	// JWTTTL for this workload's JWT SVID.
	// +kubebuilder:validation:Optional
	JWTTTL metav1.Duration `json:"jwtTtl,omitempty"`

	// FederatesWith overrides the parent's federation list for this workload.
	// +kubebuilder:validation:Optional
	FederatesWith []string `json:"federatesWith,omitempty"`
}

// ClusterVMSPIFFEIDStatus defines the observed state of ClusterVMSPIFFEID
type ClusterVMSPIFFEIDStatus struct {
	// Stats produced by the last reconciliation run.
	// +kubebuilder:validation:Optional
	Stats ClusterVMSPIFFEIDStats `json:"stats"`
}

// ClusterVMSPIFFEIDStats contain VM entry reconciliation statistics.
type ClusterVMSPIFFEIDStats struct {
	// How many namespaces were selected.
	NamespacesSelected int `json:"namespacesSelected"`

	// How many namespaces were ignored (based on configuration).
	NamespacesIgnored int `json:"namespacesIgnored"`

	// How many VMs were selected.
	VMsSelected int `json:"vmsSelected"`

	// How many VMs were in running state.
	VMsRunning int `json:"vmsRunning"`

	// How many failures were encountered rendering entries.
	EntryRenderFailures int `json:"entryRenderFailures"`

	// How many entries are to be set.
	EntriesToSet int `json:"entriesToSet"`

	// How many entries failed to create/update.
	EntryFailures int `json:"entryFailures"`
}

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status
//+kubebuilder:resource:scope=Cluster

// ClusterVMSPIFFEID is the Schema for VM workload identity registration.
// It watches VM resources (e.g., KubeVirt VirtualMachineInstances) and
// automatically creates SPIRE registration entries for VMs and their workloads.
type ClusterVMSPIFFEID struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ClusterVMSPIFFEIDSpec   `json:"spec,omitempty"`
	Status ClusterVMSPIFFEIDStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true

// ClusterVMSPIFFEIDList contains a list of ClusterVMSPIFFEID
type ClusterVMSPIFFEIDList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ClusterVMSPIFFEID `json:"items"`
}

func init() {
	SchemeBuilder.Register(&ClusterVMSPIFFEID{}, &ClusterVMSPIFFEIDList{})
}
```

**Key Design Choices:**

1. **`VMResourceType`** - Generic GVR identifier instead of importing kubevirt.io types
2. **`WorkloadSelectorTemplates`** - Reuses the free-form template pattern from ClusterSPIFFEID instead of hardcoding UID/path fields
3. **`.Object`** - Template context uses unstructured data, no typed KubeVirt objects
4. **Phase detection** - Configurable fields to detect "Running" state across different VM platforms

#### Step 3: Implement VMI Controller

**File**: `internal/controller/clustervm_spiffeid_controller.go`

```go
package controller

import (
	"context"
	"fmt"
	"text/template"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	spirev1alpha1 "github.com/spiffe/spire-controller-manager/api/v1alpha1"
	"github.com/spiffe/spire-controller-manager/pkg/spireapi"
)

// ClusterVMSPIFFEIDReconciler reconciles ClusterVMSPIFFEID objects.
// It uses a dynamic client to watch VM resources, avoiding any
// platform-specific API imports.
type ClusterVMSPIFFEIDReconciler struct {
	client.Client
	DynamicClient    dynamic.Interface
	SPIREClient      spireapi.Client
	TrustDomain      string
	ClusterName      string
	ClusterDomain    string
	IgnoreNamespaces []string
}

func (r *ClusterVMSPIFFEIDReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := log.FromContext(ctx)

	// Get ClusterVMSPIFFEID
	cr := &spirev1alpha1.ClusterVMSPIFFEID{}
	if err := r.Get(ctx, req.NamespacedName, cr); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Build GVR from spec (no kubevirt.io import!)
	vmGVR := schema.GroupVersionResource{
		Group:    cr.Spec.VMResourceType.APIGroup,
		Version:  cr.Spec.VMResourceType.Version,
		Resource: cr.Spec.VMResourceType.Resource,
	}

	// Get matching namespaces
	namespaces, err := r.getSelectedNamespaces(ctx, cr.Spec.NamespaceSelector)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("listing namespaces: %w", err)
	}

	stats := spirev1alpha1.ClusterVMSPIFFEIDStats{
		NamespacesSelected: len(namespaces),
	}

	// List VMs across selected namespaces using dynamic client
	for _, ns := range namespaces {
		if r.isIgnoredNamespace(ns) {
			stats.NamespacesIgnored++
			continue
		}

		// List VMs in this namespace
		listOpts := r.buildListOptions(cr.Spec.VMSelector)
		vmList, err := r.DynamicClient.Resource(vmGVR).Namespace(ns).List(ctx, listOpts)
		if err != nil {
			log.V(1).Info("Failed to list VMs in namespace", "namespace", ns, "error", err)
			continue
		}

		for i := range vmList.Items {
			vm := &vmList.Items[i]
			stats.VMsSelected++

			// Check if VM is in running phase
			if !r.isVMRunning(vm, cr.Spec.VMStatusPhaseField, cr.Spec.VMStatusPhaseRunning) {
				continue
			}
			stats.VMsRunning++

			// Reconcile entries for this VM
			if err := r.reconcileVMEntries(ctx, vm, cr); err != nil {
				log.Error(err, "Failed to reconcile VM entries",
					"vm", vm.GetNamespace()+"/"+vm.GetName())
				stats.EntryRenderFailures++
				continue
			}

			stats.EntriesToSet += 1 + len(cr.Spec.WorkloadEntries)
		}
	}

	// Update status
	cr.Status.Stats = stats
	if err := r.Status().Update(ctx, cr); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating status: %w", err)
	}

	return ctrl.Result{}, nil
}

// reconcileVMEntries creates SPIRE entries for a VM and its workloads.
func (r *ClusterVMSPIFFEIDReconciler) reconcileVMEntries(
	ctx context.Context,
	vm *unstructured.Unstructured,
	cr *spirev1alpha1.ClusterVMSPIFFEID,
) error {
	// Build template context from unstructured VM data
	templateCtx := map[string]interface{}{
		"TrustDomain":   r.TrustDomain,
		"ClusterName":   r.ClusterName,
		"ClusterDomain": r.ClusterDomain,
		"Object":        vm.Object, // Full VM as unstructured map
	}

	// Render VM SPIFFE ID
	vmSpiffeID, err := renderTemplate(cr.Spec.SPIFFEIDTemplate, templateCtx)
	if err != nil {
		return fmt.Errorf("rendering VM SPIFFE ID: %w", err)
	}

	// Determine parent ID (the SPIRE Server for node entries)
	parentID := fmt.Sprintf("spiffe://%s/spire/server", r.TrustDomain)

	// Create VM node entry
	vmEntry := &spireapi.Entry{
		ParentID:  parentID,
		SpiffeID:  vmSpiffeID,
		Selectors: r.buildVMNodeSelectors(vm),
	}
	if cr.Spec.TTL.Duration > 0 {
		vmEntry.X509SVIDTTL = int32(cr.Spec.TTL.Duration.Seconds())
	}
	if err := r.SPIREClient.CreateOrUpdateEntry(ctx, vmEntry); err != nil {
		return fmt.Errorf("creating VM node entry: %w", err)
	}

	// Create workload entries
	for _, workload := range cr.Spec.WorkloadEntries {
		workloadSpiffeID, err := renderTemplate(workload.SPIFFEIDTemplate, templateCtx)
		if err != nil {
			return fmt.Errorf("rendering workload %s SPIFFE ID: %w", workload.Name, err)
		}

		// Render workload selectors from templates
		var selectors []string
		for _, selectorTmpl := range workload.WorkloadSelectorTemplates {
			rendered, err := renderTemplate(selectorTmpl, templateCtx)
			if err != nil {
				return fmt.Errorf("rendering selector for %s: %w", workload.Name, err)
			}
			selectors = append(selectors, rendered)
		}

		workloadEntry := &spireapi.Entry{
			ParentID:  vmSpiffeID, // VM is the parent
			SpiffeID:  workloadSpiffeID,
			Selectors: selectors,
		}
		if workload.TTL.Duration > 0 {
			workloadEntry.X509SVIDTTL = int32(workload.TTL.Duration.Seconds())
		}
		if err := r.SPIREClient.CreateOrUpdateEntry(ctx, workloadEntry); err != nil {
			return fmt.Errorf("creating workload entry %s: %w", workload.Name, err)
		}
	}

	return nil
}

// isVMRunning checks the phase field of the unstructured VM resource.
func (r *ClusterVMSPIFFEIDReconciler) isVMRunning(
	vm *unstructured.Unstructured,
	phaseField, runningValue string,
) bool {
	// Default: .status.phase == "Running"
	phase, found, _ := unstructured.NestedString(vm.Object, "status", "phase")
	if !found {
		return false
	}
	return phase == runningValue
}

// buildVMNodeSelectors builds selectors for the VM node entry from
// unstructured VM metadata.
func (r *ClusterVMSPIFFEIDReconciler) buildVMNodeSelectors(
	vm *unstructured.Unstructured,
) []string {
	return []string{
		fmt.Sprintf("vm:namespace:%s", vm.GetNamespace()),
		fmt.Sprintf("vm:name:%s", vm.GetName()),
		fmt.Sprintf("vm:uid:%s", vm.GetUID()),
	}
}

func (r *ClusterVMSPIFFEIDReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&spirev1alpha1.ClusterVMSPIFFEID{}).
		Complete(r)
}
```

**Key implementation details:**

1. **No kubevirt.io import** - Uses `dynamic.Interface` and `unstructured.Unstructured`
2. **GVR from spec** - The `vmResourceType` tells the controller what to watch
3. **Template context uses `.Object`** - Unstructured map, not typed struct
4. **Phase detection is configurable** - Works with any VM platform

#### Step 4: Add Dynamic VM Watcher

The controller above reconciles `ClusterVMSPIFFEID` objects. We also need to watch the actual VM resources and trigger reconciliation when VMs change:

**File**: `internal/controller/vm_watcher.go`

```go
package controller

import (
	"context"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/client-go/tools/cache"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log"

	spirev1alpha1 "github.com/spiffe/spire-controller-manager/api/v1alpha1"
)

// VMWatcher watches VM resources and triggers ClusterVMSPIFFEID reconciliation.
type VMWatcher struct {
	DynamicClient dynamic.Interface
	Reconciler    *ClusterVMSPIFFEIDReconciler
}

// Start begins watching VM resources referenced by ClusterVMSPIFFEID objects.
func (w *VMWatcher) Start(ctx context.Context, vmspiffeids []spirev1alpha1.ClusterVMSPIFFEID) error {
	log := log.FromContext(ctx)

	// Collect unique GVRs from all ClusterVMSPIFFEID objects
	gvrs := make(map[schema.GroupVersionResource]bool)
	for _, cr := range vmspiffeids {
		gvr := schema.GroupVersionResource{
			Group:    cr.Spec.VMResourceType.APIGroup,
			Version:  cr.Spec.VMResourceType.Version,
			Resource: cr.Spec.VMResourceType.Resource,
		}
		gvrs[gvr] = true
	}

	// Set up dynamic informers for each GVR
	factory := dynamicinformer.NewDynamicSharedInformerFactory(w.DynamicClient, 30*time.Second)

	for gvr := range gvrs {
		log.Info("Watching VM resource", "gvr", gvr.String())

		informer := factory.ForResource(gvr).Informer()
		informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
			AddFunc: func(obj interface{}) {
				w.triggerReconciliation(ctx)
			},
			UpdateFunc: func(oldObj, newObj interface{}) {
				w.triggerReconciliation(ctx)
			},
			DeleteFunc: func(obj interface{}) {
				w.triggerReconciliation(ctx)
			},
		})
	}

	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())

	return nil
}

func (w *VMWatcher) triggerReconciliation(ctx context.Context) {
	// Trigger reconciliation of all ClusterVMSPIFFEID objects
	// Implementation depends on controller-runtime patterns
}
```

---

### Phase 3: Testing (Week 3)

#### Unit Tests

**File**: `internal/controller/clustervm_spiffeid_controller_test.go`

```go
func TestClusterVMSPIFFEIDReconciler(t *testing.T) {
	tests := []struct {
		name     string
		cr       *spirev1alpha1.ClusterVMSPIFFEID
		vms      []*unstructured.Unstructured
		wantIDs  []string // Expected SPIFFE IDs
	}{
		{
			name: "KubeVirt VM with two workloads",
			cr: &spirev1alpha1.ClusterVMSPIFFEID{
				Spec: spirev1alpha1.ClusterVMSPIFFEIDSpec{
					VMResourceType: spirev1alpha1.VMResourceType{
						APIGroup: "kubevirt.io",
						Version:  "v1",
						Resource: "virtualmachineinstances",
					},
					VMSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{"app": "database"},
					},
					SPIFFEIDTemplate: "spiffe://example.org/vm/{{ .Object.metadata.name }}",
					WorkloadEntries: []spirev1alpha1.VMWorkloadEntry{
						{
							Name:             "postgres",
							SPIFFEIDTemplate: "spiffe://example.org/vm/{{ .Object.metadata.name }}/postgres",
							WorkloadSelectorTemplates: []string{"unix:uid:26"},
						},
						{
							Name:             "redis",
							SPIFFEIDTemplate: "spiffe://example.org/vm/{{ .Object.metadata.name }}/redis",
							WorkloadSelectorTemplates: []string{"unix:uid:994"},
						},
					},
				},
			},
			vms: []*unstructured.Unstructured{
				makeVM("database-vm", "production", map[string]string{"app": "database"}, "Running"),
			},
			wantIDs: []string{
				"spiffe://example.org/vm/database-vm",
				"spiffe://example.org/vm/database-vm/postgres",
				"spiffe://example.org/vm/database-vm/redis",
			},
		},
		{
			name: "VM not running - skip",
			cr: &spirev1alpha1.ClusterVMSPIFFEID{
				Spec: spirev1alpha1.ClusterVMSPIFFEIDSpec{
					VMResourceType: spirev1alpha1.VMResourceType{
						APIGroup: "kubevirt.io",
						Version:  "v1",
						Resource: "virtualmachineinstances",
					},
					SPIFFEIDTemplate: "spiffe://example.org/vm/{{ .Object.metadata.name }}",
				},
			},
			vms: []*unstructured.Unstructured{
				makeVM("stopped-vm", "production", nil, "Stopped"),
			},
			wantIDs: nil, // No entries for non-running VMs
		},
		{
			name: "VM labels don't match selector - skip",
			cr: &spirev1alpha1.ClusterVMSPIFFEID{
				Spec: spirev1alpha1.ClusterVMSPIFFEIDSpec{
					VMResourceType: spirev1alpha1.VMResourceType{
						APIGroup: "kubevirt.io",
						Version:  "v1",
						Resource: "virtualmachineinstances",
					},
					VMSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{"app": "database"},
					},
					SPIFFEIDTemplate: "spiffe://example.org/vm/{{ .Object.metadata.name }}",
				},
			},
			vms: []*unstructured.Unstructured{
				makeVM("web-vm", "production", map[string]string{"app": "web"}, "Running"),
			},
			wantIDs: nil, // Labels don't match
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Test implementation...
		})
	}
}

// Helper to create unstructured VM objects for testing
func makeVM(name, namespace string, labels map[string]string, phase string) *unstructured.Unstructured {
	vm := &unstructured.Unstructured{}
	vm.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "kubevirt.io",
		Version: "v1",
		Kind:    "VirtualMachineInstance",
	})
	vm.SetName(name)
	vm.SetNamespace(namespace)
	vm.SetLabels(labels)
	vm.SetUID("test-uid-" + name)
	unstructured.SetNestedField(vm.Object, phase, "status", "phase")
	return vm
}
```

---

### Phase 4: Documentation (Week 4)

#### CRD Documentation

**File**: `docs/clustervmspiffeid-crd.md`

```markdown
# ClusterVMSPIFFEID

ClusterVMSPIFFEID enables automatic SPIRE registration of workloads running
inside virtual machines.

## Overview

While ClusterSPIFFEID targets Kubernetes Pods, ClusterVMSPIFFEID targets
virtual machines managed by CRDs like KubeVirt VirtualMachineInstance.

Key differences from ClusterSPIFFEID:
- Watches VM resources instead of Pods
- Uses unix: selectors instead of k8s: selectors
- Parent ID is the VM's SPIRE agent, not the DaemonSet agent
- No platform-specific dependencies (uses dynamic client)

## Spec Fields

### vmResourceType (required)

Identifies the Kubernetes resource that represents VMs:

| Field | Description | Example |
|-------|-------------|---------|
| apiGroup | API group | "kubevirt.io" |
| version | API version | "v1" |
| resource | Resource name | "virtualmachineinstances" |

### vmSelector (optional)

Standard Kubernetes label selector for filtering VMs.

### namespaceSelector (optional)

Standard Kubernetes label selector for filtering namespaces.

### spiffeIDTemplate (required)

Go template for the VM's SPIFFE ID. Available variables:

| Variable | Description |
|----------|-------------|
| .TrustDomain | SPIRE trust domain |
| .ClusterName | Kubernetes cluster name |
| .ClusterDomain | Kubernetes cluster domain |
| .Object | VM resource as unstructured map (access with .Object.metadata.name, etc.) |

### workloadEntries (optional)

Array of workloads running inside the VM. Each entry has:

| Field | Description |
|-------|-------------|
| name | Identifier for this workload |
| spiffeIDTemplate | SPIFFE ID template (same variables as above) |
| workloadSelectorTemplates | Selectors for the SPIRE agent (e.g., "unix:uid:994") |
| ttl | Optional X509 SVID TTL |

## Examples

### KubeVirt with Redis and Postgres

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterVMSPIFFEID
metadata:
  name: database-vms
spec:
  vmResourceType:
    apiGroup: "kubevirt.io"
    version: "v1"
    resource: "virtualmachineinstances"
  vmSelector:
    matchLabels:
      tier: database
  namespaceSelector:
    matchLabels:
      environment: production
  spiffeIDTemplate: >-
    spiffe://{{ .TrustDomain }}/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}
  workloadEntries:
  - name: postgres
    spiffeIDTemplate: >-
      spiffe://{{ .TrustDomain }}/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}/postgres
    workloadSelectorTemplates:
    - "unix:uid:26"
    ttl: 1h
  - name: redis
    spiffeIDTemplate: >-
      spiffe://{{ .TrustDomain }}/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}/redis
    workloadSelectorTemplates:
    - "unix:uid:994"
    ttl: 1h
```

### OpenStack VM (hypothetical)

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterVMSPIFFEID
metadata:
  name: openstack-vms
spec:
  vmResourceType:
    apiGroup: "openstack.org"
    version: "v1beta1"
    resource: "virtualmachines"
  vmStatusPhaseField: ".status.state"
  vmStatusPhaseRunning: "ACTIVE"
  spiffeIDTemplate: >-
    spiffe://{{ .TrustDomain }}/vm/{{ .Object.metadata.name }}
  workloadEntries:
  - name: app
    spiffeIDTemplate: >-
      spiffe://{{ .TrustDomain }}/vm/{{ .Object.metadata.name }}/app
    workloadSelectorTemplates:
    - "unix:uid:1000"
```
```

---

### Phase 5: Pull Request (Week 4-5)

#### Submit PR

**Title**: "Add ClusterVMSPIFFEID CRD for Virtual Machine Registration"

**Description**:
```markdown
## Description

This PR adds a new CRD (`ClusterVMSPIFFEID`) for automatic SPIRE registration
of workloads running inside virtual machines.

## Why a Separate CRD?

1. ClusterSPIFFEID is tightly coupled to Pods (templates, selectors, stats)
2. VM entries use different selectors (unix: instead of k8s:)
3. VM entries have different parent IDs (VM agent, not DaemonSet agent)
4. **Avoids kubevirt.io dependency** - uses dynamic/unstructured client

## Changes

### New CRD
- `ClusterVMSPIFFEID` with `vmResourceType`, `vmSelector`, `workloadEntries`
- `VMResourceType` - generic GVR (no platform imports)
- `VMWorkloadEntry` - uses `workloadSelectorTemplates` pattern
- `ClusterVMSPIFFEIDStats` - VM-specific stats

### New Controller
- `ClusterVMSPIFFEIDReconciler` - uses dynamic client
- `VMWatcher` - watches VM resources dynamically

### No Changes To
- ClusterSPIFFEID (existing CRD unchanged)
- Pod reconciler (existing controller unchanged)
- Any existing APIs or behavior

## Design Highlights

- **No kubevirt.io dependency** - uses `k8s.io/client-go/dynamic`
- **Platform agnostic** - works with KubeVirt, OpenStack, Harvester, etc.
- **Follows existing patterns** - uses `workloadSelectorTemplates` like ClusterSPIFFEID
- **Configurable phase detection** - not hardcoded to KubeVirt status fields

## Backward Compatibility

✅ Purely additive. No changes to existing APIs or behavior.

## Testing

- Unit tests for reconciler
- Tests for template rendering
- Tests for phase detection
- Tests for selector matching

## Checklist

- [x] Tests added
- [x] Documentation added
- [x] CRD documented with examples
- [x] No kubevirt.io dependency
- [x] Backward compatible
- [x] Follows existing code patterns
```

---

## Integration with Your Operator

### Updated Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Your Operator: zero-trust-workload-identity-manager    │
│  ───────────────────────────────────────────────────     │
│  Responsibilities:                                       │
│  ✅ Deploy SPIRE Server                                  │
│  ✅ Deploy SPIRE Agent (DaemonSet)                       │
│  ✅ Deploy spire-controller-manager                      │
│  ✅ Inject VSOCK proxy into virt-launcher pods           │
│  ✅ Manage lifecycle and updates                         │
│                                                          │
│  Does NOT handle:                                        │
│  ❌ Creating registration entries                        │
│     (delegated to spire-controller-manager)            │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│  spire-controller-manager (upstream, enhanced)           │
│  ───────────────────────────────────────────────────     │
│  Responsibilities:                                       │
│  ✅ ClusterSPIFFEID → Pod entries (existing)             │
│  ✅ ClusterVMSPIFFEID → VM + workload entries (NEW!)     │
│  ✅ Entry lifecycle management                           │
│                                                          │
│  Key: No kubevirt.io dependency! Uses dynamic client.   │
└──────────────────────────────────────────────────────────┘

Clean separation of concerns! ✅
```

### Usage After Upstream Merge

```yaml
# 1. Deploy your operator
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: example.org
  clusterName: my-cluster

---
# 2. Pod workloads (existing ClusterSPIFFEID - unchanged)
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: backend-pods
spec:
  podSelector:
    matchLabels:
      tier: backend
  spiffeIDTemplate: "spiffe://example.org/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"

---
# 3. VM workloads (NEW ClusterVMSPIFFEID)
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterVMSPIFFEID
metadata:
  name: database-vms
spec:
  vmResourceType:
    apiGroup: "kubevirt.io"
    version: "v1"
    resource: "virtualmachineinstances"
  vmSelector:
    matchLabels:
      app: database
  spiffeIDTemplate: "spiffe://example.org/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}"
  workloadEntries:
  - name: postgres
    spiffeIDTemplate: "spiffe://example.org/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}/postgres"
    workloadSelectorTemplates:
    - "unix:uid:26"
  - name: redis
    spiffeIDTemplate: "spiffe://example.org/ns/{{ .Object.metadata.namespace }}/vm/{{ .Object.metadata.name }}/redis"
    workloadSelectorTemplates:
    - "unix:uid:994"

---
# 4. VMs (as usual, with label for selector matching)
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: database-vm-1
  labels:
    app: database  # Matches vmSelector!
spec:
  # ... VM spec ...
```

**Result**: Fully declarative, GitOps-friendly, automatic! ✅

---

## Timeline

### Realistic Timeline

```
Week 1: Proposal
  • Create GitHub issue with ClusterVMSPIFFEID design
  • Community discussion
  • Design refinement

Week 2-3: Implementation
  • CRD types
  • Dynamic client reconciler
  • Unit tests

Week 4: Documentation & Testing
  • Integration tests
  • CRD documentation
  • Usage examples

Week 5: Pull Request
  • Submit PR
  • Address review comments

Week 6-8: Review & Iteration
  • Maintainer feedback
  • Changes requested
  • Re-review

Week 9-10: Merge & Release
  • PR merged
  • Next release includes feature

Total: 2-3 months from proposal to release
```

### Interim Solution

While waiting for upstream:

```
Short term (now):
  Manual registration via CLI:
  spire-server entry create -parentID ... -spiffeID ... -selector unix:uid:994

Medium term (1-2 months):
  Implement VM registration controller in YOUR operator
  using dynamic client (same code, just different home)

Long term (3-6 months):
  Migrate to upstream ClusterVMSPIFFEID
  Remove custom controller from your operator
  Pure separation of concerns ✅
```

---

## Contribution Best Practices

### 1. Start with the Issue

- Don't code first - propose the design
- Get buy-in from maintainers on the separate CRD approach
- Discuss naming: `ClusterVMSPIFFEID` vs `ClusterResourceSPIFFEID`

### 2. Emphasize No New Dependencies

The biggest selling point is:
- ✅ No kubevirt.io import
- ✅ Uses standard k8s.io/client-go/dynamic
- ✅ Works with any VM platform
- ✅ Minimal binary size impact

### 3. Follow Existing Patterns

- `workloadSelectorTemplates` pattern (not custom UID/path fields)
- Template rendering approach (`.Object` for unstructured data)
- Stats/status pattern (mirror ClusterSPIFFEIDStats style)
- CRD naming convention (Cluster-scoped, SPIFFEID suffix)

### 4. Make It Easy to Review

- Small, focused commits
- Comprehensive tests
- Clear documentation
- Working examples for multiple VM platforms

---

## Summary

### The Contribution

**What**: New `ClusterVMSPIFFEID` CRD for VM workload registration  
**Why**: Clean separation from pod-centric ClusterSPIFFEID, no kubevirt.io dependency  
**How**: Dynamic client, unstructured types, configurable GVR  
**When**: 2-3 months from proposal to release  

### Key Design Decision: Separate CRD

```
❌ Extending ClusterSPIFFEID:
  - Mixes pod and VM concerns
  - Requires kubevirt.io dependency
  - Bloats existing API

✅ New ClusterVMSPIFFEID:
  - Clean separation
  - No platform dependencies
  - Platform agnostic (KubeVirt, OpenStack, etc.)
  - Follows existing patterns
```

### The Path Forward

```
Immediate (now):
  Manual registration via CLI

Short-term (1-2 months):
  Custom controller in your operator (bridge solution)

Long-term (3-6 months):
  Upstream ClusterVMSPIFFEID in spire-controller-manager
  Remove custom controller
  Pure separation of concerns ✅
```

---

**Next Steps**:
1. Create GitHub issue in spire-controller-manager with the design
2. Implement interim solution in your operator while waiting
3. Submit PR after design approval
4. Contribute back to community!
