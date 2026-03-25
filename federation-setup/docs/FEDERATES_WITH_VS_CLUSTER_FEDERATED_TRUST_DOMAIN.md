# `federates_with` (SPIRE config) vs ClusterFederatedTrustDomain (spire-controller-manager)

This doc summarizes what each mechanism is, how they differ, whether both are required, and how they relate. It is based on the **Spire**, **spire-controller-manager**, and **spiffe** repos in this workspace.

---

## 1. What is `federates_with` (SPIRE server config)?

**Where it lives:** SPIRE server config file (HCL), under `server { federation { ... } }`.

**What it is:** A **static, file-based** list of federation relationships. Each `federates_with "<trust_domain>" { ... }` block tells this SPIRE server:

- **Which foreign trust domain** to federate with (e.g. `domain1.test`).
- **Where to fetch that domain’s bundle**: `bundle_endpoint_url` (HTTPS) and `bundle_endpoint_profile` (`https_web` or `https_spiffe`, and for `https_spiffe`, `endpoint_spiffe_id`).

**Where it’s used in SPIRE:**

- Parsed in `spire/cmd/spire-server/cli/run/run.go` into `federationConfig.FederatesWith` (map of trust domain → bundle endpoint config).
- Passed into `server.Config.Federation.FederatesWith` and then into the **bundle client** as one of the **trust domain config sources** (see `spire/pkg/server/server.go` around 454–457):

  ```go
  Source: bundle_client.MergeTrustDomainConfigSources(
      bundle_client.NewTrustDomainConfigSet(s.config.Federation.FederatesWith),
      bundle_client.DataStoreTrustDomainConfigSource(log, cat.GetDataStore()),
  ),
  ```

So: **`federates_with` in the config file is used only to drive “which trust domains to fetch bundles from.”** It is **not** stored in the SPIRE datastore. It is applied at server startup and does not change until the config file is edited and the server is restarted (or reconfigured, if supported).

**Docs:** `spire/doc/spire_server.md` (e.g. “Configuration options for `federation.federates_with`”).

---

## 2. What is ClusterFederatedTrustDomain?

**Where it lives:** Kubernetes API, as a **cluster-scoped CRD** managed by **spire-controller-manager**.

**What it is:** A Kubernetes resource that **declares** a federation relationship for this cluster’s SPIRE server:

- **trustDomain** – foreign trust domain name (required, unique per resource).
- **bundleEndpointURL** – HTTPS URL of that domain’s bundle endpoint (required).
- **bundleEndpointProfile** – `https_web` or `https_spiffe` (and for `https_spiffe`, **endpointSPIFFEID**).
- **trustDomainBundle** – optional initial bundle (e.g. for `https_spiffe` bootstrap).
- **className** – optional controller class.

**How it’s used:**

- The **federation relationship reconciler** in spire-controller-manager (`pkg/spirefederationrelationship/reconciler.go`) lists all `ClusterFederatedTrustDomain` resources (from the cluster and/or static manifest files).
- For each resource it builds a `spireapi.FederationRelationship` (see `api/v1alpha1/clusterfederatedtrustdomain_webhook.go` → `ParseClusterFederatedTrustDomainSpec`).
- It compares desired state (from CRs) to current state by calling the **SPIRE Trust Domain API** (`ListFederationRelationships`).
- It then **Create/Update/Delete** federation relationships on the SPIRE server via:
  - `BatchCreateFederationRelationship`
  - `BatchUpdateFederationRelationship`
  - `BatchDeleteFederationRelationship`

Those API calls **read/write the SPIRE datastore**. So **ClusterFederatedTrustDomain is the Kubernetes/declarative way to manage the same “federation relationship” entity that SPIRE stores in its datastore.**

**Docs:** `spire-controller-manager/docs/clusterfederatedtrustdomain-crd.md`, `spire-controller-manager/README.md` (Federation section).

---

## 3. How do they differ?

| Aspect | `federates_with` (server config) | ClusterFederatedTrustDomain |
|--------|-----------------------------------|------------------------------|
| **Source of truth** | Config file (HCL) on the SPIRE server node | Kubernetes CRs (and/or static YAML manifests) |
| **Storage in SPIRE** | Not stored in datastore; only in memory as a bundle-client source | Stored in SPIRE datastore via Trust Domain API |
| **When applied** | At server startup / config load | Continuously reconciled by spire-controller-manager |
| **Management style** | Static, ops-edited file | Declarative, GitOps/Kubernetes-native |
| **Typical use** | Non-K8s SPIRE, or static relationships you don’t want in K8s | K8s deployments, multi-cluster federation, dynamic updates |

Both end up feeding the **same behavioral outcome**: “SPIRE server should fetch bundles from these foreign trust domains.” The bundle client in SPIRE merges two sources (see below).

---

## 4. How SPIRE combines them (merge order)

**What is the bundle client?** In SPIRE, the **bundle client** is the server-side subsystem (package `spire/pkg/server/bundle/client`) that **fetches trust bundles from remote (federated) trust domains**. It acts as the *client* of the remote SPIFFE bundle endpoints (HTTPS servers that serve bundles). The bundle client periodically polls each configured federated trust domain’s bundle endpoint, downloads the bundle, and stores it in the local SPIRE datastore. It gets the list of “which trust domains to federate with” and their bundle endpoint URLs/profiles from the merged config sources below. So when we say “config file vs ClusterFederatedTrustDomain,” both are inputs to this same bundle client.

SPIRE’s bundle client uses **two** trust-domain config sources:

1. **Config file** – `NewTrustDomainConfigSet(s.config.Federation.FederatesWith)`
2. **Datastore** – `DataStoreTrustDomainConfigSource(...)` (lists federation relationships from the datastore, i.e. what was created/updated via the Trust Domain API, e.g. by spire-controller-manager)

They are merged with:

```go
MergeTrustDomainConfigSources(
    bundle_client.NewTrustDomainConfigSet(s.config.Federation.FederatesWith),
    bundle_client.DataStoreTrustDomainConfigSource(log, cat.GetDataStore()),
)
```

In `spire/pkg/server/bundle/client/sources.go`, **merge is done in reverse order**: the **datastore** is merged first, then the **config file**. So for a given trust domain, **the config file overrides the datastore** if both define that trust domain.

---

## 5. Can federation work without the other? Are both required?

**No, both are not required.** You can use either one alone, **with an important caveat for `https_spiffe`** (see §6).

- **Federation with only `federates_with` (config file):**  
  Yes for **`https_web`**. Put the federation relationship in the server config; no ClusterFederatedTrustDomain needed. No initial bundle is required — TLS uses Web PKI.  
  For **`https_spiffe`**, config-only works only **after** the federated trust domain’s bundle is already in the SPIRE datastore (see §6).

- **Federation with only ClusterFederatedTrustDomain (no `federates_with` in config):**  
  Yes. Do not configure `federation.federates_with`. Create ClusterFederatedTrustDomain resources; the controller syncs them to the SPIRE datastore via the Trust Domain API. The bundle client uses `DataStoreTrustDomainConfigSource`. For `https_spiffe` you can set **`trustDomainBundle`** on the CR to bootstrap the initial bundle.

So: **you only need one of the two** for a given relationship. Using both for the same trust domain is possible but redundant; the config file overrides the datastore for that trust domain due to the merge order.

---

## 6. Initial trust bundle bootstrapping (when using only `federates_with`)

Behavior depends on the **bundle endpoint profile**.

### `https_web` profile

- **No bootstrap needed.** The bundle client uses the default HTTP transport and verifies the remote server’s TLS certificate with **Web PKI** (system / public CAs).
- So with only `federates_with` and `bundle_endpoint_profile "https_web"`, the server can connect and fetch the federated bundle as soon as it starts.

### `https_spiffe` profile

- **Bootstrap is required.** The bundle client authenticates the bundle endpoint using the **federated trust domain’s** X.509 roots: it needs `RootCAs` for that trust domain to build the TLS client (`spire/pkg/server/bundle/client/client.go`, `updater.go`).
- Those roots come from the **local datastore** only: `fetchBundleIfExists(ctx, u.ds, trustDomain)`. If no bundle exists for that trust domain, the code returns: *"can't perform SPIFFE Authentication: local copy of bundle not found"* (`updater.go`).
- The **server config file does not support** providing an initial/trust domain bundle for `federates_with`. The HCL only has `bundle_endpoint_url` and `bundle_endpoint_profile` (and for `https_spiffe`, `endpoint_spiffe_id`). There is no field for bundle contents or path.
- So with **only** config-file `federates_with` and `https_spiffe`, you have a chicken-and-egg: you need the bundle in the datastore to connect, but the only way to get it is to connect.

**Ways to bootstrap for `https_spiffe`:**

1. **Trust Domain API**  
   Create (or update) the federation relationship **once** with an initial bundle, e.g.:
   - `spire-server federation create` (or equivalent) with `trust_domain_bundle` / `trustDomainBundle`, or  
   - Any client that calls the SPIRE Trust Domain API `BatchCreateFederationRelationship` with `TrustDomainBundle` set.

2. **ClusterFederatedTrustDomain**  
   Create a ClusterFederatedTrustDomain with **`spec.trustDomainBundle`** set to the other domain’s bundle (e.g. PEM or JSON). The controller creates the federation relationship and stores the bundle in the datastore; after that, bundle refresh works.

3. **Pre-load the bundle**  
   Ensure the federated trust domain’s bundle is already in the SPIRE datastore by some other means (e.g. manual API call, migration, or a one-off job). Then config-file `federates_with` with `https_spiffe` can be used for URL/profile only.

**Summary:** Using only `federates_with` **works for `https_web`** without any extra bootstrap. For **`https_spiffe`**, config-only does **not** provide a way to bootstrap the initial bundle; you must supply it via the API (e.g. ClusterFederatedTrustDomain with `trustDomainBundle`) or by pre-loading the bundle into the datastore.

---

## 7. Having both: pros and cons

“Having both” can mean:

- **Same trust domain** in both config-file `federates_with` and in ClusterFederatedTrustDomain (or API).  
- **Different trust domains**: some only in config, others only in CRs (mixed management).

Because of the merge order (§4), **for any given trust domain the config file overrides the datastore**. So if the same trust domain is in both, only the config-file definition is used for bundle fetching; the datastore entry is still there (and visible via API) but does not affect bundle client behavior for that trust domain.

### Pros of having both

| Pro | Explanation |
|-----|-------------|
| **Mixed strategy** | Use config for long-lived, rarely changed relationships (e.g. one central domain) and ClusterFederatedTrustDomain for dynamic or per-cluster ones. |
| **Fallback** | If the controller is down or CRs are misconfigured, relationships defined only in the config file still work after server restart. |
| **Bootstrap then hand off** | Use ClusterFederatedTrustDomain (with `trustDomainBundle`) once to bootstrap `https_spiffe`, then optionally move URL/profile to config and delete the CR if you prefer config as the source of truth (datastore entry can remain for the stored bundle). |
| **Gradual migration** | Move relationships one by one from config to CRs (or the reverse) without a big-bang change. |
| **Different lifecycles** | Config is tied to server deploy/restart; CRs can be applied by GitOps or platform automation without touching the SPIRE config. |

### Cons of having both

| Con | Explanation |
|-----|-------------|
| **No single source of truth** | For a given trust domain you must remember whether the active definition is in config or in the datastore (and for “same in both”, config wins). That can confuse operators and automation. |
| **Drift and surprise** | If the same trust domain is in both and you change only the CR (or only the config), the other source still exists and may mislead you about what is actually in use (config wins). |
| **Double maintenance** | When the same relationship is in both places, any change (URL, profile, etc.) must be done in the winning source; the other is redundant but easy to forget to update or remove. |
| **Debugging** | Troubleshooting “which config is used?” requires knowing the merge order and checking both the server config and the Trust Domain API/datastore. |
| **Controller vs config override** | The controller will keep creating/updating federation relationships in the datastore from CRs. For trust domains that are also in the config file, those datastore entries are overridden at read time by the bundle client, so you pay the cost of reconciliation without getting different behavior for that domain. |

### Recommendation

- **Prefer one mechanism per trust domain.** Use either config-file `federates_with` **or** ClusterFederatedTrustDomain (and thus the datastore) for each relationship, not both. That keeps a single source of truth and avoids drift.
- **If you mix**, use **different** trust domains in each: e.g. static/critical ones in config, dynamic/optional ones in CRs. Avoid defining the **same** trust domain in both unless you are intentionally migrating or using config as an override.
- **Document the choice** so operators know where to change federation (config vs CRs) for each environment.

---

## 8. Purpose summary

- **`federates_with` (SPIRE server config):**  
  Static, file-based configuration of “which trust domains to federate with” and where to fetch their bundles. Good when you are not using Kubernetes or when you prefer to manage federation outside the controller (e.g. traditional config management).

- **ClusterFederatedTrustDomain:**  
  Kubernetes-native, declarative way to manage the same federation relationships. The controller syncs CRs into SPIRE via the Trust Domain API (datastore). Good for Kubernetes, multi-cluster setups, and GitOps; allows dynamic updates without editing the SPIRE config file.

Both ultimately configure the **same SPIRE behavior**: which foreign trust domains to pull bundles from and how to reach them (bundle endpoint URL and profile).

---

## 9. Note on “federates_with” on registration entries

In SPIRE protos and datastore you also see **`federates_with` on registration entries** (e.g. `spire/proto/spire/common/common.proto`). That is a **different concept**: it indicates **which trust domains an identity is valid for** when issuing federated SVIDs. It is not the server’s list of federation relationships. This document is only about **server federation configuration** (`federates_with` in server config and ClusterFederatedTrustDomain).

---

## References (in this workspace)

- **Spire:** `spire/doc/spire_server.md`, `spire/cmd/spire-server/cli/run/run.go`, `spire/pkg/server/server.go`, `spire/pkg/server/bundle/client/sources.go`, `spire/pkg/server/api/trustdomain/v1/service.go`, datastore federation relationship APIs in `spire/pkg/server/datastore/`.
- **spire-controller-manager:** `docs/clusterfederatedtrustdomain-crd.md`, `api/v1alpha1/clusterfederatedtrustdomain_types.go`, `api/v1alpha1/clusterfederatedtrustdomain_webhook.go`, `pkg/spirefederationrelationship/reconciler.go`, `pkg/spireapi/trustdomainapi.go`, `README.md`.
- **SPIFFE:** Federation behavior follows the [SPIFFE Federation](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE_Federation.md) standard (referenced from the ClusterFederatedTrustDomain CRD doc).
