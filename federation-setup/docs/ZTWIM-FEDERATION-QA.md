# ZTWIM federation: short Q&A

Short answers on Spire CR `spec.federation.federatesWith`, ClusterFederatedTrustDomain, `trustDomainBundle` source, and `className`.

---

## 1. What is `spec.federation.federatesWith` in the Spire CR for?

**Purpose:** It is the **operator-driven way to configure SPIRE server’s `federates_with`** (bundle endpoint URL and profile) in the generated server config.

- ZTWIM reads `spec.federation.federatesWith` from the SpireServer CR and **writes it into the SPIRE server config** (ConfigMap) as the `federation.federates_with` section.
- It tells SPIRE **which trust domains to federate with** and **where to fetch their bundles** (URL, profile, and for `https_spiffe`, `endpointSpiffeId`).
- It **does not** provide an initial/bootstrap trust bundle. It only configures the list of federated domains and their endpoints.

**When to use it:** Use it to declare federation relationships in the Spire CR so the operator keeps the SPIRE server config in sync (same effect as editing `federates_with` in the server config file by hand).

---

## 2. How is `spec.federation.federatesWith` different from ClusterFederatedTrustDomain?

| | Spire CR `spec.federation.federatesWith` | ClusterFederatedTrustDomain |
|---|------------------------------------------|-----------------------------|
| **What it configures** | SPIRE server config file (`federates_with`) | SPIRE datastore (via Trust Domain API) |
| **Who applies it** | ZTWIM operator (into server ConfigMap) | spire-controller-manager (into SPIRE API) |
| **Initial bundle** | No | Yes — `spec.trustDomainBundle` |
| **Required for https_spiffe?** | No (you can use only ClusterFederatedTrustDomain) | **Yes** for bootstrap — only way to provide initial trust bundle |

**Summary:** For **https_spiffe**, ClusterFederatedTrustDomain is effectively **required** because it is the only way to supply the **bootstrap** trust bundle (`trustDomainBundle`). The Spire CR `federatesWith` only sets URL/profile in the server config; it cannot set the initial bundle. You can use both (e.g. URL/profile in Spire CR and bootstrap in ClusterFederatedTrustDomain) or use **only** ClusterFederatedTrustDomain (with URL, profile, and `trustDomainBundle`).

---

## 3. What should `trustDomainBundle` be? Does `curl -k https://federation...` work?

**Both work.** Using the output of `curl -k https://federation.apps.cluster2.example.com` as `trustDomainBundle` **does work**, and so does using the output of **`spire-server bundle show -format spiffe`** on the remote cluster. The **content** is the same; the difference is **how you obtain it** (and security on first fetch).

### Why curl output works (evidence from SPIRE repo)

1. **What the federation bundle endpoint serves**  
   The SPIRE server’s federation bundle endpoint returns **this server’s own trust domain’s bundle** (the same bundle that contains the X.509 roots and JWT keys for that trust domain).

   - **Code:** `spire/pkg/server/endpoints/config.go` configures the bundle endpoint Getter as:
     ```go
     Getter: bundle.GetterFunc(func(ctx context.Context) (*spiffebundle.Bundle, error) {
         commonBundle, err := ds.FetchBundle(dscache.WithCache(ctx), c.TrustDomain.IDString())
         ...
         return bundleutil.SPIFFEBundleFromProto(commonBundle)
     }),
     ```
     So it serves `FetchBundle(..., c.TrustDomain)` — **this server’s trust domain’s bundle** (`spire/pkg/server/endpoints/bundle/config.go` lines 143–152).

   - **Code:** `spire/pkg/server/endpoints/bundle/server.go` `serveHTTP` (lines 103–122) calls `s.c.Getter.GetBundle(req.Context())` and writes the result as JSON. So `GET https://federation.cluster2.com/` returns **cluster2’s trust bundle** (same as `spire-server bundle show` on cluster2).

2. **What the endpoint’s TLS certificate is**  
   When the bundle endpoint uses the **https_spiffe** profile, it uses **SPIFFE auth**: the TLS certificate is the **server’s SVID** (SPIRE-issued), which is signed by **this server’s CA**. That CA is part of **this server’s trust domain bundle** — the same bundle the endpoint serves.

   So: the response body from `curl -k https://federation.cluster2.com` **is** the bundle that contains the roots used to sign the endpoint’s TLS certificate. It is the **same** bootstrap bundle you would get from `spire-server bundle show -format spiffe` on cluster2.

3. **How it’s used after you set trustDomainBundle**  
   When you create a ClusterFederatedTrustDomain with `trustDomainBundle` set to that JSON:

   - **Code:** `spire/pkg/server/datastore/sqlstore/sqlstore.go` `createFederationRelationship` (lines 4253–4258): if `fr.TrustDomainBundle != nil`, it calls `setBundle(tx, fr.TrustDomainBundle)`, so the bundle is **stored in the datastore** for that trust domain.

   - **Code:** `spire/pkg/server/bundle/client/updater.go` `newClient` (lines 121–134): for https_spiffe, the bundle client gets RootCAs from `fetchBundleIfExists(ctx, u.ds, trustDomain)` (the datastore). It builds the TLS client with those roots. The remote endpoint’s cert is signed by the same CA in that bundle, so **TLS verification succeeds**.

So **curl output works** because the federation URL **serves that trust domain’s bundle**, and that bundle **is** the one that contains the roots for the endpoint’s TLS cert. There is no chicken-and-egg: the **payload** is correct; you just obtained it without verifying the connection when using `curl -k`.

### Recommended source and security caveat

- **When you have CLI access** to the remote SPIRE server (e.g. `kubectl exec` into the pod, or SSH to the host): prefer **`spire-server bundle show -format spiffe`** there (or a trusted copy). You get the bundle out-of-band with no unverified fetch.
- **When you have no CLI access** to the remote SPIRE server (e.g. the other cluster is managed by another team, or only the federation HTTPS route is exposed): **`curl -k https://federation...`** is the practical way to obtain the bundle. The content is correct and federation will work. The caveat: **`-k`** disables TLS verification for that first fetch, so you are not authenticating the server when you download the bundle (theoretical MITM risk on that one request). After the bundle is stored, all subsequent connections by the bundle client are properly verified.

**Summary:** `trustDomainBundle` must be the **remote trust domain’s bundle** (bootstrap roots). Use **`spire-server bundle show -format spiffe`** on the remote cluster when you have CLI access; use **`curl -k https://federation...`** when the federation endpoint is the only way you can reach the remote bundle (e.g. no exec/CLI to the other cluster).

---

## 4. Do the docs need to say to use `spire-server bundle show` instead of `curl` for `trustDomainBundle`?

**Recommendation, not a hard “wrong”.** Docs can say that **either** source is valid:
- **`curl -k https://federation...`** — works; same content; useful when there is **no CLI access** to the remote SPIRE server (only the federation route is available). First fetch is unverified.
- **`spire-server bundle show -format spiffe`** (on the remote cluster) — preferred when you **do have** CLI/exec access for out-of-band, verified bootstrap.

If a doc only mentions curl, adding a note that `spire-server bundle show` is the preferred alternative is useful. If it only mentions `spire-server bundle show`, noting that curl to the federation URL returns the same bundle (with the `-k` caveat) is also accurate.

---

## 5. ClusterFederatedTrustDomain and `className` for ZTWIM

For **ZTWIM** to reconcile a ClusterFederatedTrustDomain, the CR **must** include:

```yaml
spec:
  className: zero-trust-workload-identity-manager-spire
```

Without this, the spire-controller-manager instance run by ZTWIM will ignore the CR (class filtering).

**Docs to update:** Any ZTWIM or federation doc that shows a ClusterFederatedTrustDomain example should include **`className: zero-trust-workload-identity-manager-spire`** so users get a working example. The upstream spire-controller-manager sample does not set `className` because it is generic; ZTWIM-specific docs and examples should.

---

## Summary table

| Topic | Short answer |
|-------|--------------|
| **spec.federation.federatesWith** | Operator-managed “federates_with” in SPIRE config (URL + profile). No bootstrap bundle. |
| **vs ClusterFederatedTrustDomain** | Spire CR → config file. ClusterFederatedTrustDomain → datastore + can set `trustDomainBundle`. For https_spiffe, ClusterFederatedTrustDomain is required for bootstrap. |
| **trustDomainBundle value** | Must be the **remote** trust domain’s bundle (bootstrap roots). Use **`spire-server bundle show -format spiffe`** when you have CLI access to the remote server; use **`curl -k https://federation...`** when the federation endpoint is the only way to get the bundle (e.g. no exec/CLI). |
| **className** | ZTWIM examples must set **`className: zero-trust-workload-identity-manager-spire`** on ClusterFederatedTrustDomain so ZTWIM reconciles it. Docs should be updated. |
