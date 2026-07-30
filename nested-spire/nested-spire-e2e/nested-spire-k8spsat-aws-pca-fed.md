# Manual Verification: AWS PCA (Hub) + Nested SPIRE (Spoke) + Federation (Fed)

**Date:** 2026-07-24  
**Clusters needed:** 3 (Hub + Spoke + Fed)

> **Note:** Cluster hostnames below (e.g., `aws22jul.oaptech.devcluster.openshift.com`, `gcp1784880585...`) are from ephemeral test clusters used during this specific verification run. They will not exist after teardown. Replace with your own cluster domains when reproducing.

---

## Overview

This document validates a 3-cluster SPIRE deployment where:

1. **AWS Private CA** acts as the root of trust for the Hub cluster (via cert-manager + aws-privateca-issuer)
2. **Nested SPIRE** (Hub → Spoke) — The Hub acts as an upstream authority, signing the Spoke's intermediate CA. Both share the same trust domain. The upstream agent uses **k8s_psat attestation** (no certificates required).
3. **Federation** (Hub ↔ Fed) — The Hub and an independent Fed cluster exchange trust bundles via federation endpoints using the **https_spiffe** profile. Each has its own trust domain.


|                     | AWS PCA (Hub)                               | Nested SPIRE (Hub → Spoke)                    | Federation (Hub ↔ Fed)                          |
| ------------------- | ------------------------------------------- | --------------------------------------------- | ----------------------------------------------- |
| Trust domains       | Hub's trust domain                          | Same trust domain                             | Different trust domains                         |
| CA relationship     | AWS PCA signs Hub's intermediate CA         | Hub signs Spoke's intermediate CA             | Independent CAs, no signing relationship        |
| Trust establishment | cert-manager CertificateRequest             | UpstreamAuthority plugin                      | Trust bundle exchange via federation endpoint   |
| Certificate chain   | AWS PCA Root → Hub Intermediate → Workload  | AWS PCA Root → Hub Int → Spoke Int → Workload | Each cluster has its own independent chain      |
| Use case            | HSM-backed root with centralized compliance | Hierarchical CA within one organization       | Cross-cluster/cross-org workload authentication |


The nested SPIRE certificate chain (4 certificates):

```
AWS PCA Root CA (HSM-backed, in AWS)
  → Hub Intermediate CA (signed by AWS PCA, via cert-manager)
    → Spoke Intermediate CA (OU=DOWNSTREAM-1, signed by Hub, via nested SPIRE)
      → Workload SVID (leaf, signed by Spoke intermediate)
```

### Key Characteristics of k8s_psat Attestation


| Aspect                                    | Details                                                                      |
| ----------------------------------------- | ---------------------------------------------------------------------------- |
| How upstream agent proves identity to Hub | Kubernetes Projected Service Account Token                                   |
| What Hub needs to trust                   | Spoke cluster's API server (kubeconfig for TokenReview)                      |
| Agent SPIFFE ID format                    | `spiffe://<td>/spire/agent/k8s_psat/<cluster>/<node-uid>`                    |
| Certificates needed                       | **None** (token-based, zero certificate management)                          |
| Hub server config change                  | Add spoke01 cluster to k8s_psat config + kubeconfig volume                   |
| Hub StatefulSet change                    | Mount spoke-kubeconfig Secret                                                |
| Upstream agent volumes                    | Projected SA token + hub trust bundle                                        |
| Token rotation                            | Automatic (projected tokens are short-lived, SPIRE re-attests automatically) |


### Architecture

```
                          AWS Private CA (HSM-backed root, in AWS cloud)
                            |
                            | signs (via cert-manager + aws-privateca-issuer)
                            |
┌─── Hub Cluster ───────────────────────────────────────────────┐
│  Trust domain: apps.<hub-domain>                               │
│                                                                │
│  SPIRE Server                                                 │
│  ├── UpstreamAuthority: cert-manager (→ AWS PCA)              │
│  ├── NodeAttestor: k8s_psat (clusters: hub01 + spoke01)       │
│  │   └── spoke01: kubeconfig for TokenReview on Spoke API     │
│  ├── gRPC Route (passthrough TLS, port 443)                   │
│  ├── Federation endpoint (port 8443, https_spiffe)            │
│  │   └── Route: federation.apps.<hub-domain>                  │
│  ├── federates_with: apps.<fed-domain>                        │
│  ├── ClusterStaticEntry: downstream=true for spoke server     │
│  └── ClusterFederatedTrustDomain: Fed cluster's bundle        │
│                                                                │
│  Prerequisites:                                               │
│  ├── cert-manager operator                                    │
│  ├── aws-privateca-issuer (Helm)                              │
│  └── AWSPCAClusterIssuer (→ AWS PCA ARN)                      │
│                                                                │
└────────────────────────────────────────────────────────────────┘
      ▲ k8s_psat attestation         ↕ Bidirectional federation
      │ via gRPC Route               ↕ (trust bundle exchange)
      │                              ↕
┌─── Spoke Cluster ─────────┐  ┌─── Fed Cluster ───────────────┐
│  Trust domain:             │  │  Trust domain:                 │
│  apps.<hub-domain> (SAME)  │  │  apps.<fed-domain> (DIFFERENT) │
│                            │  │                                │
│  upstream-agent            │  │  SPIRE Server                  │
│  ├── k8s_psat attestation  │  │  ├── Federation endpoint       │
│  ├── k8s WorkloadAttestor  │  │  │   (port 8443, https_spiffe) │
│  └── hostPath socket       │  │  ├── federates_with:           │
│           │                │  │  │   apps.<hub-domain>          │
│           │ (upstream CSI) │  │  └── ClusterFederatedTrustDomain│
│           ▼                │  │      Hub cluster's bundle       │
│  SPIRE Server              │  │                                │
│  ├── UpstreamAuthority     │  └────────────────────────────────┘
│  └── Intermediate CA       │
│      from Hub              │
│                            │
└────────────────────────────┘
```

---

## Clusters

Set these variables once before starting:

```bash
export HUB_KUBECONFIG=/path/to/hub/kubeconfig
export SPOKE_KUBECONFIG=/path/to/spoke/kubeconfig
export FED_KUBECONFIG=/path/to/fed/kubeconfig
export AWS_ACCOUNT_ID=<your-aws-account-id>
```

| Role  | Kubeconfig         | Platform              | Notes                                                             |
| ----- | ------------------ | --------------------- | ----------------------------------------------------------------- |
| Hub   | `$HUB_KUBECONFIG`  | AWS (IPI, ap-south-1) | OCP 4.20+, uses AWS PCA via cert-manager (static IAM user creds)  |
| Spoke | `$SPOKE_KUBECONFIG`| GCP                   | Nested SPIRE downstream of Hub                                    |
| Fed   | `$FED_KUBECONFIG`  | GCP                   | Independent, federation with Hub                                  |


## Prerequisites

- Three OpenShift clusters with `oc` CLI access (Hub on AWS, Spoke + Fed on GCP)
- `operator-sdk` installed (v1.39+)
- The ZTWIM operator source code built and pushed to a registry
- `helm` CLI installed (for aws-privateca-issuer)
- AWS CLI configured with permissions to create/manage Private CA
- An AWS account with IAM access to create policies
- **No certificates needed for nested SPIRE** (k8s_psat is entirely token-based; https_spiffe uses SPIRE's own SVIDs)
- **Static AWS credentials** for a dedicated IAM user with PCA-only permissions (stored as K8s Secret)

---

## Critical Design Constraints

1. **Hub and Spoke MUST share the same trust domain.** The UpstreamAuthority "spire" plugin uses its own server's trust domain to construct the expected upstream server SPIFFE ID (`spiffe://<trust_domain>/spire/server`). If the trust domains differ, the TLS handshake will fail with "unexpected ID".
2. **The Fed cluster MUST have a different trust domain.** Federation connects independent trust domains. If the Fed cluster shared the Hub's trust domain, you'd use nested SPIRE instead.
3. **Federated bundles do NOT propagate from Hub to Spoke.** The UpstreamAuthority plugin only propagates the CA chain (X.509 roots and JWT signing keys), not federated bundles. If Spoke workloads need to authenticate Fed workloads, the Spoke needs its own `ClusterFederatedTrustDomain` CR (see Phase 14).
4. `**issuerGroup: awspca.cert-manager.io` is CRITICAL.** Without this, SPIRE looks for a built-in cert-manager ClusterIssuer and crashes. The aws-privateca-issuer registers its own issuer group.

---

## Step-by-Step Verification

### Phase 1: AWS Infrastructure (One-Time Setup)

This phase creates the AWS Private CA that will serve as the root of trust for the Hub cluster.

#### 1a. Create the AWS Private CA

```bash
export AWS_REGION=ap-south-1

# Create a ROOT CA
aws acm-pca create-certificate-authority \
  --region $AWS_REGION \
  --certificate-authority-configuration \
    "KeyAlgorithm=RSA_2048,SigningAlgorithm=SHA256WITHRSA,Subject={CommonName='SPIRE Upstream Root CA',Organization=RedHat,Country=US}" \
  --certificate-authority-type ROOT \
  --tags Key=Purpose,Value=spire-upstream-ca Key=Scope,Value=multi-cluster \
  --query 'CertificateAuthorityArn' --output text

# Save the ARN
export PCA_ARN="<output-from-above>"
echo "PCA ARN: $PCA_ARN"
```

#### 1b. Activate the Root CA (self-sign its own certificate)

```bash
# Get the CSR
aws acm-pca get-certificate-authority-csr \
  --region $AWS_REGION \
  --certificate-authority-arn "$PCA_ARN" \
  --output text > /tmp/pca-root.csr

# Issue the root certificate (self-signed by the PCA itself, 10-year validity)
ROOT_CERT_ARN=$(aws acm-pca issue-certificate \
  --region $AWS_REGION \
  --certificate-authority-arn "$PCA_ARN" \
  --csr fileb:///tmp/pca-root.csr \
  --signing-algorithm SHA256WITHRSA \
  --template-arn arn:aws:acm-pca:::template/RootCACertificate/V1 \
  --validity Value=3650,Type=DAYS \
  --query 'CertificateArn' --output text)

echo "ROOT_CERT_ARN: $ROOT_CERT_ARN"

# Wait for issuance
sleep 5

# Retrieve the issued certificate
aws acm-pca get-certificate \
  --region $AWS_REGION \
  --certificate-authority-arn "$PCA_ARN" \
  --certificate-arn "$ROOT_CERT_ARN" \
  --query 'Certificate' --output text > /tmp/pca-root-cert.pem

# Import it back into the PCA to activate it
aws acm-pca import-certificate-authority-certificate \
  --region $AWS_REGION \
  --certificate-authority-arn "$PCA_ARN" \
  --certificate fileb:///tmp/pca-root-cert.pem

# Verify status is ACTIVE
aws acm-pca describe-certificate-authority \
  --region $AWS_REGION \
  --certificate-authority-arn "$PCA_ARN" \
  --query 'CertificateAuthority.Status' --output text
# Expected: "ACTIVE"
```

#### 1c. Get the Root CA Fingerprint (for later verification)

```bash
openssl x509 -in /tmp/pca-root-cert.pem -fingerprint -sha256 -noout
# Save this — you'll compare it against Hub's trust bundle later
export PCA_FINGERPRINT="<SHA256 fingerprint>"
```

#### 1d. Create IAM Policy and User for PCA Access

Create a dedicated IAM user with only PCA permissions, scoped to the specific PCA ARN. The worker node role is **not modified** — credentials are provided to the issuer pod via a Kubernetes Secret (Phase 4).

> **Note:** The production-recommended approach is STS tokens via IRSA (IAM Roles for Service Accounts with OIDC federation). Static credentials are used here due to time constraints. Migrating to STS requires enabling STS mode on the cluster (`credentialsMode: Manual` + OIDC provider).

```bash
# Create the IAM policy scoped to the specific PCA
cat > /tmp/pca-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SpirePCAIssuer",
      "Effect": "Allow",
      "Action": [
        "acm-pca:IssueCertificate",
        "acm-pca:GetCertificate",
        "acm-pca:GetCertificateAuthorityCertificate",
        "acm-pca:DescribeCertificateAuthority"
      ],
      "Resource": "$PCA_ARN"
    }
  ]
}
EOF

POLICY_ARN=$(aws iam create-policy \
  --policy-name spire-pca-issuer-policy \
  --policy-document file:///tmp/pca-policy.json \
  --query 'Policy.Arn' --output text)

echo "POLICY_ARN: $POLICY_ARN"

# Create a dedicated IAM user (does NOT modify the worker node role)
aws iam create-user --user-name spire-pca-issuer

aws iam attach-user-policy \
  --user-name spire-pca-issuer \
  --policy-arn "$POLICY_ARN"

# Generate static access keys
aws iam create-access-key --user-name spire-pca-issuer
# Save the output:
export AWS_ACCESS_KEY_ID="<AccessKeyId from output>"
export AWS_SECRET_ACCESS_KEY="<SecretAccessKey from output>"
```

---

### Phase 2: Deploy the Operator on All 3 Clusters

```bash
Deploy ZTWIM 1.1 on all 3 clusters from openshift-marketplace
```

---

### Phase 3: Install cert-manager on Hub

cert-manager is the middleware between SPIRE and AWS PCA. SPIRE creates `CertificateRequest` objects; cert-manager provides the framework that lets external plugins (like aws-privateca-issuer) handle those requests.

```bash
export KUBECONFIG=$HUB_KUBECONFIG

# Install the Red Hat cert-manager operator via OLM
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for cert-manager pods to come up
oc get pods -n cert-manager -w
# Expected: cert-manager, cert-manager-cainjector, cert-manager-webhook all Running

# Verify the CSV is Succeeded
oc get csv -n cert-manager-operator
# Expected: cert-manager-operator.v1.x.x ... Succeeded

echo "cert-manager is ready."
```

---

### Phase 4: Install aws-privateca-issuer on Hub

The aws-privateca-issuer is a cert-manager plugin that acts as a bridge between SPIRE and AWS PCA. It watches for CertificateRequests and sends them to AWS PCA for signing.

Authentication uses the static credentials from the dedicated IAM user created in Phase 1d (the worker node role is not modified).

> **Future improvement:** Migrate to STS tokens via IRSA for credential-less pod authentication. This requires the cluster to have an OIDC provider configured and `credentialsMode: Manual`.

```bash
export KUBECONFIG=$HUB_KUBECONFIG

# 4a. Create namespace and store AWS credentials in a Secret
oc create namespace aws-privateca-issuer --dry-run=client -o yaml | oc apply -f -

oc create secret generic aws-pca-credentials \
  -n aws-privateca-issuer \
  --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"

# 4b. Install via Helm
helm repo add awspca https://cert-manager.github.io/aws-privateca-issuer
helm repo update

helm install aws-pca-issuer awspca/aws-privateca-issuer \
  -n aws-privateca-issuer

# 4c. Inject credentials and region into the controller pod
oc set env deployment/aws-pca-issuer-aws-privateca-issuer \
  -n aws-privateca-issuer \
  AWS_REGION=${AWS_REGION}

oc set env deployment/aws-pca-issuer-aws-privateca-issuer \
  -n aws-privateca-issuer \
  --from=secret/aws-pca-credentials

# 4d. Grant SCC permissions (OpenShift-specific)
oc adm policy add-scc-to-user anyuid \
  -z aws-pca-issuer-aws-privateca-issuer -n aws-privateca-issuer
oc adm policy add-scc-to-user anyuid \
  -z default -n aws-privateca-issuer
oc adm policy add-scc-to-user nonroot-v2 \
  -z aws-pca-issuer-aws-privateca-issuer -n aws-privateca-issuer

oc rollout restart deployment/aws-pca-issuer-aws-privateca-issuer -n aws-privateca-issuer

# 4e. Disable approval check (required for cert-manager v1.3+)
# Without this, the issuer cannot approve its own CertificateRequests
oc patch deployment aws-pca-issuer-aws-privateca-issuer \
  -n aws-privateca-issuer --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args","value":["--disable-approved-check"]}
]'

# 4f. Verify the plugin is running
oc get pods -n aws-privateca-issuer
# Expected: 1/1 Running (or 2 replicas depending on Helm defaults)

echo "aws-privateca-issuer is ready."
```

---

### Phase 5: Create AWSPCAClusterIssuer on Hub

The AWSPCAClusterIssuer is cluster-scoped and references the AWS PCA ARN. The aws-privateca-issuer controller uses its environment variables (injected in Phase 4c) for AWS authentication.

**Critical:** The `pcaTemplate.defaultTemplateName` must be `SubordinateCACertificate_PathLen1/V1` (not PathLen0) because nested SPIRE requires the Hub's intermediate CA to sign the Spoke's CA. With PathLen0, the chain `PCA Root → Hub Intermediate (pathLen=0) → Spoke CA → SVID` violates the path length constraint.

```bash
export KUBECONFIG=$HUB_KUBECONFIG

oc apply -f - <<EOF
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAClusterIssuer
metadata:
  name: aws-pca-cluster-issuer
spec:
  arn: ${PCA_ARN}
  region: ${AWS_REGION}
  pcaTemplate:
    defaultTemplateName: SubordinateCACertificate_PathLen1/V1
EOF

# Verify the issuer is ready
sleep 10
oc get awspcaclusterissuer aws-pca-cluster-issuer -o yaml | grep -A 5 "conditions"
# Expected:
#   conditions:
#   - message: Issuer verified
#     reason: Verified
#     status: "True"
#     type: Ready
```

`**Ready: True` means the plugin successfully connected to AWS PCA and verified its existence.**

---

### Phase 6: Deploy Operands on All 3 Clusters

**Important:**

- Hub and Spoke use the **same trust domain** (the Hub's `apps.<hub-domain>`)
- Fed uses its **own trust domain** (`apps.<fed-domain>`)
- Hub includes **both** `upstreamAuthority.certManager` and `federation` in the SpireServer CR from the start
- Fed includes `federation` from the start

#### Hub cluster (with AWS PCA upstream authority + federation)

```bash
export KUBECONFIG=$HUB_KUBECONFIG
export APP_DOMAIN=apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
export CLUSTER_NAME=hub01
export FED_APP_DOMAIN=apps.$(KUBECONFIG=$FED_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')

echo "Hub trust domain: $APP_DOMAIN"
echo "Fed trust domain: $FED_APP_DOMAIN"

oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: $APP_DOMAIN
  clusterName: $CLUSTER_NAME
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  caSubject:
    commonName: $APP_DOMAIN
    country: "US"
    organization: "RH"
  persistence:
    size: "2Gi"
    accessMode: ReadWriteOnce
  datastore:
    databaseType: sqlite3
    connectionString: "/run/spire/data/datastore.sqlite3"
  jwtIssuer: https://oidc-discovery.$APP_DOMAIN
  upstreamAuthority:
    certManager:
      namespace: cert-manager
      issuerName: aws-pca-cluster-issuer
      issuerKind: ClusterIssuer
      issuerGroup: awspca.cert-manager.io
  federation:
    bundleEndpoint:
      profile: https_spiffe
      refreshHint: 300
    federatesWith:
      - trustDomain: $FED_APP_DOMAIN
        bundleEndpointUrl: https://federation.$FED_APP_DOMAIN
        bundleEndpointProfile: https_spiffe
        endpointSpiffeId: spiffe://$FED_APP_DOMAIN/spire/server
    managedRoute: "true"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: "auto"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec: {}
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  jwtIssuer: https://oidc-discovery.$APP_DOMAIN
EOF
```

#### Fed cluster (with federation)

```bash
export KUBECONFIG=$FED_KUBECONFIG
export FED_APP_DOMAIN=apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
export CLUSTER_NAME=fed01
export HUB_APP_DOMAIN=apps.$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')

echo "Fed trust domain: $FED_APP_DOMAIN"
echo "Hub trust domain: $HUB_APP_DOMAIN"

oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: $FED_APP_DOMAIN
  clusterName: $CLUSTER_NAME
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  caSubject:
    commonName: $FED_APP_DOMAIN
    country: "US"
    organization: "RH"
  persistence:
    size: "2Gi"
    accessMode: ReadWriteOnce
  datastore:
    databaseType: sqlite3
    connectionString: "/run/spire/data/datastore.sqlite3"
  jwtIssuer: https://oidc-discovery.$FED_APP_DOMAIN
  federation:
    bundleEndpoint:
      profile: https_spiffe
      refreshHint: 300
    federatesWith:
      - trustDomain: $HUB_APP_DOMAIN
        bundleEndpointUrl: https://federation.$HUB_APP_DOMAIN
        bundleEndpointProfile: https_spiffe
        endpointSpiffeId: spiffe://$HUB_APP_DOMAIN/spire/server
    managedRoute: "true"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: "auto"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec: {}
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  jwtIssuer: https://oidc-discovery.$FED_APP_DOMAIN
EOF
```

#### Spoke cluster (no federation, no upstream authority, Hub's trust domain)

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG
export HUB_APP_DOMAIN=apps.$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')
export CLUSTER_NAME=spoke01

oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: $HUB_APP_DOMAIN
  clusterName: $CLUSTER_NAME
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  caSubject:
    commonName: $HUB_APP_DOMAIN
    country: "US"
    organization: "RH"
  persistence:
    size: "2Gi"
    accessMode: ReadWriteOnce
  datastore:
    databaseType: sqlite3
    connectionString: "/run/spire/data/datastore.sqlite3"
  jwtIssuer: https://oidc-discovery.$HUB_APP_DOMAIN
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: "auto"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec: {}
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  jwtIssuer: https://oidc-discovery.$HUB_APP_DOMAIN
EOF
```

#### Verification

```bash
# On each cluster:
oc exec spire-server-0 -c spire-server -- /spire-server healthcheck
# Expected: "Server is healthy."

# On Hub and Fed: verify federation routes were created by the operator
export KUBECONFIG=$HUB_KUBECONFIG
oc get route spire-server-federation -n zero-trust-workload-identity-manager
# Expected: federation.<hub-domain> with passthrough TLS

export KUBECONFIG=$FED_KUBECONFIG
oc get route spire-server-federation -n zero-trust-workload-identity-manager
# Expected: federation.<fed-domain> with passthrough TLS

# Test federation endpoints are accessible
HUB_APP_DOMAIN=apps.$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')
FED_APP_DOMAIN=apps.$(KUBECONFIG=$FED_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')

curl -sk "https://federation.${HUB_APP_DOMAIN}" | python3 -m json.tool | head -5
curl -sk "https://federation.${FED_APP_DOMAIN}" | python3 -m json.tool | head -5
# Expected: JSON bundle with "keys", "spiffe_sequence", "spiffe_refresh_hint"
```

---

### Phase 7: Verify AWS PCA Integration on Hub

This phase confirms that the Hub's SPIRE server is using AWS PCA as its upstream authority (not a self-signed CA).

```bash
export KUBECONFIG=$HUB_KUBECONFIG

# Check server logs for upstream authority activation
oc logs spire-server-0 -c spire-server -n zero-trust-workload-identity-manager | grep "X509 CA"
# Expected: "X509 CA activated" ... self_signed=false ... upstream_authority_id=<non-empty>

# Verify the trust bundle root matches the AWS PCA fingerprint
oc get configmap spire-bundle -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.bundle\.crt}' > /tmp/hub-bundle-root.pem

# Extract the root certificate (last cert in the bundle)
csplit -z -f /tmp/bundle-cert- /tmp/hub-bundle-root.pem '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null
LAST_CERT=$(ls /tmp/bundle-cert-* | tail -1)

echo "=== Hub Trust Bundle Root CA ==="
openssl x509 -in "$LAST_CERT" -noout -subject -issuer -fingerprint -sha256

echo ""
echo "=== AWS PCA Root CA Fingerprint (should match) ==="
echo "$PCA_FINGERPRINT"

# Cleanup
rm -f /tmp/bundle-cert-* /tmp/hub-bundle-root.pem
```

**If `self_signed=false` appears and the fingerprint matches your AWS PCA root, the integration is working.**

---

### Phase 8: Bootstrap Federation Trust (Hub ↔ Fed)

For `https_spiffe` profile, the initial trust handshake is a chicken-and-egg problem: each side needs the other's trust bundle to validate the federation endpoint's TLS certificate (which is the server's own SVID). The `ClusterFederatedTrustDomain` CR solves this by providing the initial trust bundle.

The SPIRE controller-manager watches these CRs and pushes the bundles to the SPIRE server, which then keeps them updated automatically via the federation endpoint.

#### Step 1: Fetch trust bundles from both federation endpoints

```bash
HUB_APP_DOMAIN=apps.$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')
FED_APP_DOMAIN=apps.$(KUBECONFIG=$FED_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')

echo "Fetching Hub bundle..."
curl -sk "https://federation.${HUB_APP_DOMAIN}" > /tmp/hub-federation-bundle.json
python3 -m json.tool /tmp/hub-federation-bundle.json | head -5

echo ""
echo "Fetching Fed bundle..."
curl -sk "https://federation.${FED_APP_DOMAIN}" > /tmp/fed-federation-bundle.json
python3 -m json.tool /tmp/fed-federation-bundle.json | head -5
```

**Why `-k` (insecure)?** On the very first fetch, you don't yet trust the remote server's SVID certificate. The `-k` flag skips TLS verification for this one-time bootstrap. After the `ClusterFederatedTrustDomain` is created with the bundle, SPIRE handles all subsequent bundle refreshes with proper mTLS verification.

#### Step 2: Create ClusterFederatedTrustDomain on Hub (trusting Fed)

```bash
export KUBECONFIG=$HUB_KUBECONFIG

FED_BUNDLE=$(cat /tmp/fed-federation-bundle.json)

oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: hub-to-fed-federation
spec:
  className: zero-trust-workload-identity-manager-spire
  trustDomain: ${FED_APP_DOMAIN}
  bundleEndpointURL: https://federation.${FED_APP_DOMAIN}
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://${FED_APP_DOMAIN}/spire/server
  trustDomainBundle: |
$(echo "$FED_BUNDLE" | sed 's/^/    /')
EOF
```

#### Step 3: Create ClusterFederatedTrustDomain on Fed (trusting Hub)

```bash
export KUBECONFIG=$FED_KUBECONFIG

HUB_BUNDLE=$(cat /tmp/hub-federation-bundle.json)

oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: fed-to-hub-federation
spec:
  className: zero-trust-workload-identity-manager-spire
  trustDomain: ${HUB_APP_DOMAIN}
  bundleEndpointURL: https://federation.${HUB_APP_DOMAIN}
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://${HUB_APP_DOMAIN}/spire/server
  trustDomainBundle: |
$(echo "$HUB_BUNDLE" | sed 's/^/    /')
EOF
```

---

### Phase 9: Verify Federation Is Working

```bash
# Check ClusterFederatedTrustDomains
echo "=== Hub ==="
KUBECONFIG=$HUB_KUBECONFIG oc get clusterfederatedtrustdomains
echo ""
echo "=== Fed ==="
KUBECONFIG=$FED_KUBECONFIG oc get clusterfederatedtrustdomains
# Expected: one entry on each showing the remote trust domain

# On Hub: verify the Fed cluster's bundle is known
export KUBECONFIG=$HUB_KUBECONFIG
oc exec spire-server-0 -c spire-server -n zero-trust-workload-identity-manager -- \
  /spire-server bundle list 2>&1
# Expected: lists both local trust domain AND federated trust domain

# On Fed: verify the Hub's bundle is known
export KUBECONFIG=$FED_KUBECONFIG
oc exec spire-server-0 -c spire-server -n zero-trust-workload-identity-manager -- \
  /spire-server bundle list 2>&1
# Expected: lists both local trust domain AND federated trust domain

# Check controller-manager logs for bundle sync
export KUBECONFIG=$HUB_KUBECONFIG
oc logs spire-server-0 -c spire-controller-manager -n zero-trust-workload-identity-manager --tail=20 | grep -i "feder"
```

---

### Phase 10: Enable CREATE_ONLY_MODE on Hub and Spoke

**What this does:** Tells the operator to stop reconciling (updating) existing resources. This lets you manually patch the ConfigMap and StatefulSet without the operator reverting your changes.

**Why not on Fed?** The Fed cluster doesn't need any manual patches — federation was handled automatically by the operator in Phase 6.

```bash
# Hub
export KUBECONFIG=$HUB_KUBECONFIG
oc patch subscription openshift-zero-trust-workload-identity-manager \
  -n zero-trust-workload-identity-manager \
  --type merge \
  -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'

# Spoke
export KUBECONFIG=$SPOKE_KUBECONFIG
oc patch subscription openshift-zero-trust-workload-identity-manager \
  -n zero-trust-workload-identity-manager \
  --type merge \
  -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'

# Wait for operator pods to restart (~15-20s each)
```

---

### Phase 11: Create Cross-Cluster Token Validation (k8s_psat-Specific)

#### 11a. Create TokenReview ServiceAccount on Spoke

**What this does:** Creates a ServiceAccount on the Spoke cluster that the Hub's SPIRE server will use to validate Projected Service Account Tokens from the Spoke. The SA needs:

1. `system:auth-delegator` — to call the TokenReview API
2. Pod/Node read access — the k8s_psat plugin queries pod metadata during attestation

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG

oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-hub-token-reviewer
  namespace: zero-trust-workload-identity-manager
---
apiVersion: v1
kind: Secret
metadata:
  name: spire-hub-token-reviewer
  namespace: zero-trust-workload-identity-manager
  annotations:
    kubernetes.io/service-account.name: spire-hub-token-reviewer
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-hub-token-reviewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: spire-hub-token-reviewer
  namespace: zero-trust-workload-identity-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-hub-token-reviewer-pods
rules:
- apiGroups: [""]
  resources: ["pods", "nodes"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-hub-token-reviewer-pods
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spire-hub-token-reviewer-pods
subjects:
- kind: ServiceAccount
  name: spire-hub-token-reviewer
  namespace: zero-trust-workload-identity-manager
EOF

# Wait for token to be populated
sleep 5
```

**Why pod/node read access?** The k8s_psat plugin doesn't just validate the token — it also queries the Spoke's API server for pod metadata (labels, namespace, service account) to generate attestation selectors. Without this, attestation fails with `403 Forbidden` on the pods API.

#### 11b. Generate Kubeconfig for Hub-to-Spoke Access

**What this does:** Creates a kubeconfig file that the Hub's SPIRE server uses to reach the Spoke's API server for TokenReview and pod/node queries.

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG

SPOKE_TOKEN=$(oc get secret spire-hub-token-reviewer -n zero-trust-workload-identity-manager -o jsonpath='{.data.token}' | base64 -d)
SPOKE_CA=$(oc get secret spire-hub-token-reviewer -n zero-trust-workload-identity-manager -o jsonpath='{.data.ca\.crt}')
SPOKE_API_SERVER=$(oc whoami --show-server)

cat > /tmp/spoke-kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${SPOKE_CA}
    server: ${SPOKE_API_SERVER}
  name: spoke
contexts:
- context:
    cluster: spoke
    user: spire-hub-token-reviewer
  name: spoke
current-context: spoke
users:
- name: spire-hub-token-reviewer
  user:
    token: ${SPOKE_TOKEN}
EOF

# Verify the kubeconfig works
KUBECONFIG=/tmp/spoke-kubeconfig.yaml kubectl auth can-i create tokenreviews --all-namespaces
# Expected: "yes"
```

---

### Phase 12: Configure the Hub for Nested SPIRE with k8s_psat

#### 12a. Create gRPC Passthrough Route

```bash
export KUBECONFIG=$HUB_KUBECONFIG
HUB_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
GRPC_HOST="spire-server-grpc-zero-trust-workload-identity-manager.apps.${HUB_DOMAIN}"

oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-grpc
  namespace: zero-trust-workload-identity-manager
spec:
  host: ${GRPC_HOST}
  to:
    kind: Service
    name: spire-server
    weight: 100
  port:
    targetPort: grpc
  tls:
    termination: passthrough
    insecureEdgeTerminationPolicy: Redirect
EOF
```

#### 12b. Create spoke-kubeconfig Secret on Hub

```bash
export KUBECONFIG=$HUB_KUBECONFIG

oc create secret generic spoke-kubeconfig \
  -n zero-trust-workload-identity-manager \
  --from-file=kubeconfig=/tmp/spoke-kubeconfig.yaml
```

#### 12c. Add spoke01 Cluster to Hub's k8s_psat Config

**What this does:** Adds the Spoke cluster as a second trusted cluster in the Hub's k8s_psat NodeAttestor plugin. This tells the Hub to also accept PSAT tokens from the Spoke cluster, validated via the kubeconfig.

```bash
# Get current config
oc get configmap spire-server -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.server\.conf}' > /tmp/hub-config.json

# Use Python/jq to add spoke01 cluster to the "clusters" array in k8s_psat:
# Add this to the NodeAttestor.k8s_psat.plugin_data.clusters array:
#   {
#     "spoke01": {
#       "allowed_node_label_keys": [],
#       "allowed_pod_label_keys": [],
#       "audience": ["spire-server"],
#       "service_account_allow_list": [
#         "zero-trust-workload-identity-manager:spire-agent-upstream"
#       ],
#       "kube_config_file": "/run/spire/spoke-kubeconfig/kubeconfig"
#     }
#   }

# Apply the updated config:
oc patch configmap spire-server -n zero-trust-workload-identity-manager \
  --type merge -p '{"data":{"server.conf":"<full-updated-config>"}}'
```

The final k8s_psat clusters array should look like:

```json
{
  "clusters": [
    {
      "hub01": {
        "allowed_node_label_keys": [],
        "allowed_pod_label_keys": [],
        "audience": ["spire-server"],
        "service_account_allow_list": ["zero-trust-workload-identity-manager:spire-agent"]
      }
    },
    {
      "spoke01": {
        "allowed_node_label_keys": [],
        "allowed_pod_label_keys": [],
        "audience": ["spire-server"],
        "service_account_allow_list": ["zero-trust-workload-identity-manager:spire-agent-upstream"],
        "kube_config_file": "/run/spire/spoke-kubeconfig/kubeconfig"
      }
    }
  ]
}
```

#### 12d. Mount spoke-kubeconfig in Hub StatefulSet

```bash
oc patch statefulset spire-server -n zero-trust-workload-identity-manager --type json -p '[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{
    "name":"spoke-kubeconfig",
    "secret":{"secretName":"spoke-kubeconfig"}
  }},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{
    "name":"spoke-kubeconfig",
    "mountPath":"/run/spire/spoke-kubeconfig",
    "readOnly":true
  }}
]'
# StatefulSet will rolling-restart the pod
```

#### Verification

```bash
# Check k8s_psat plugin loaded:
oc logs spire-server-0 -c spire-server | grep k8s_psat
# Expected: "Plugin loaded" plugin_name=k8s_psat plugin_type=NodeAttestor

# Verify kubeconfig is mounted:
oc describe pod spire-server-0 | grep -A5 "spoke-kubeconfig"

# Confirm AWS PCA upstream authority is still active after restart:
oc logs spire-server-0 -c spire-server | grep "X509 CA"
# Expected: "X509 CA activated" ... self_signed=false
```

---

### Phase 13: Deploy Upstream Agent on Spoke (k8s_psat)

#### 13a. Create Upstream Agent ServiceAccount + SCC + RBAC

**What this does:** Creates a ServiceAccount for the upstream agent with:

1. A **separate SCC** (for `hostPID` + `hostPath`)
2. Pod/node read access (for the k8s WorkloadAttestor to resolve PIDs to pods)

> **Why a separate SCC instead of patching `spire-agent`?**  
> The operator's SpireAgent controller reconciles the `spire-agent` SCC on every loop and it is **not gated by CREATE_ONLY_MODE**. The desired state hardcodes `.users` to only `[spire-agent]`, so any manually added users will be reconciled away within seconds.

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG

oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-agent-upstream
  namespace: zero-trust-workload-identity-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-agent-upstream
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "nodes/proxy"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-agent-upstream
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spire-agent-upstream
subjects:
- kind: ServiceAccount
  name: spire-agent-upstream
  namespace: zero-trust-workload-identity-manager
---
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: spire-agent-upstream
readOnlyRootFilesystem: true
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: MustRunAs
fsGroup:
  type: MustRunAs
users:
- system:serviceaccount:zero-trust-workload-identity-manager:spire-agent-upstream
volumes:
- configMap
- hostPath
- projected
- secret
- emptyDir
allowHostDirVolumePlugin: true
allowHostIPC: false
allowHostNetwork: false
allowHostPID: true
allowHostPorts: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities: []
defaultAddCapabilities: []
requiredDropCapabilities:
- ALL
groups: []
EOF
```

**Why `nodes/proxy` access?** The k8s WorkloadAttestor contacts the kubelet API at `https://<node>:10250/pods` to resolve PIDs to pods. This requires access to the node's proxy subresource. Without it, the attestor returns 403 Forbidden, yields empty selectors, and the Hub rejects the workload with "no identity issued".

#### 13b. Create Hub Trust Bundle Secret

```bash
# Get Hub's trust bundle (now contains AWS PCA root)
export KUBECONFIG=$HUB_KUBECONFIG
oc get configmap spire-bundle -n zero-trust-workload-identity-manager \
  -o jsonpath='{.data.bundle\.crt}' > /tmp/hub-bundle.crt

# Create Secret on Spoke
export KUBECONFIG=$SPOKE_KUBECONFIG
oc create secret generic hub-trust-bundle \
  -n zero-trust-workload-identity-manager \
  --from-file=bundle.crt=/tmp/hub-bundle.crt
```

#### 13c. Create Upstream Agent ConfigMap

**What this does:** Configures the upstream agent with k8s_psat attestation. Key fields:

- `NodeAttestor: k8s_psat` — uses projected SA token for node attestation
- `token_path: /var/run/secrets/tokens/spire-agent` — reads the projected SA token from the volume
- `cluster: spoke01` — must match the cluster name configured in the Hub's k8s_psat plugin
- `WorkloadAttestor: k8s` — identifies callers by their pod metadata (namespace, SA, labels)
- `node_name_env: MY_NODE_NAME` — required for the k8s attestor to reach the kubelet API

```bash
HUB_DOMAIN=$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')
HUB_GRPC_HOST="spire-server-grpc-zero-trust-workload-identity-manager.apps.${HUB_DOMAIN}"
HUB_TRUST_DOMAIN="apps.${HUB_DOMAIN}"

export KUBECONFIG=$SPOKE_KUBECONFIG

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-agent-upstream
  namespace: zero-trust-workload-identity-manager
data:
  agent.conf: |
    {
      "agent": {
        "data_dir": "/run/spire/data",
        "log_level": "debug",
        "server_address": "${HUB_GRPC_HOST}",
        "server_port": "443",
        "socket_path": "/run/spire/agent-sockets-upstream/spire-agent.sock",
        "trust_bundle_path": "/run/spire/bundle/bundle.crt",
        "trust_domain": "${HUB_TRUST_DOMAIN}"
      },
      "plugins": {
        "NodeAttestor": [{"k8s_psat": {"plugin_data": {
          "cluster": "spoke01",
          "token_path": "/var/run/secrets/tokens/spire-agent"
        }}}],
        "KeyManager": [{"disk": {"plugin_data": {"directory": "/run/spire/data"}}}],
        "WorkloadAttestor": [{"k8s": {"plugin_data": {
          "node_name_env": "MY_NODE_NAME",
          "skip_kubelet_verification": true
        }}}]
      }
    }
EOF
```

#### 13d. Create Upstream Agent Deployment

**What this does:** Deploys a single SPIRE agent pod that uses k8s_psat attestation. Key features:

- `projected.sources.serviceAccountToken` with `audience: spire-server` — Kubernetes automatically creates and rotates this token
- `expirationSeconds: 7200` — token refreshed every 2 hours (SPIRE re-attests automatically since `can_re_attest: true` for k8s_psat)
- `hostPID: true` — required for the k8s WorkloadAttestor to resolve PIDs to pods
- `podAffinity` — ensures the upstream agent runs on the same node as spire-server (so the hostPath socket is accessible)

```bash
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spire-agent-upstream
  namespace: zero-trust-workload-identity-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: spire-agent-upstream
  template:
    metadata:
      labels:
        app.kubernetes.io/name: spire-agent-upstream
    spec:
      serviceAccountName: spire-agent-upstream
      hostPID: true
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/name: spire-server
            topologyKey: kubernetes.io/hostname
      containers:
      - name: spire-agent
        image: ghcr.io/spiffe/spire-agent:1.14.7
        args: ["-config", "/run/spire/config/agent.conf"]
        env:
        - name: MY_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: config
          mountPath: /run/spire/config
          readOnly: true
        - name: spire-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
        - name: hub-trust-bundle
          mountPath: /run/spire/bundle
          readOnly: true
        - name: agent-sockets-upstream
          mountPath: /run/spire/agent-sockets-upstream
        - name: agent-data
          mountPath: /run/spire/data
      volumes:
      - name: config
        configMap:
          name: spire-agent-upstream
      - name: spire-token
        projected:
          sources:
          - serviceAccountToken:
              path: spire-agent
              expirationSeconds: 7200
              audience: spire-server
      - name: hub-trust-bundle
        secret:
          secretName: hub-trust-bundle
      - name: agent-sockets-upstream
        hostPath:
          path: /run/spire/agent-sockets-upstream
          type: DirectoryOrCreate
      - name: agent-data
        emptyDir: {}
EOF
```

#### Verification

```bash
# Check upstream agent attested to Hub:
oc logs -l app.kubernetes.io/name=spire-agent-upstream | grep "Node attestation was successful"
# Expected: "Node attestation was successful" reattestable=true
#   spiffe_id="spiffe://.../spire/agent/k8s_psat/spoke01/<node-uid>"

# On Hub, confirm agent appears:
export KUBECONFIG=$HUB_KUBECONFIG
oc exec spire-server-0 -c spire-server -- /spire-server agent list | grep spoke01
# Expected: k8s_psat/spoke01/<node-uid> with can_re_attest=true
```

**Now proceed to Phase 14** to create the ClusterStaticEntry using the attested agent's SPIFFE ID, then Phase 15 for the upstream CSI driver.

---

### Phase 14: Create Registration Entry for Downstream on Hub

```bash
export KUBECONFIG=$HUB_KUBECONFIG
HUB_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
TRUST_DOMAIN="apps.${HUB_DOMAIN}"

# Get the upstream agent's SPIFFE ID from agent list
AGENT_ID=$(oc exec spire-server-0 -c spire-server -- /spire-server agent list 2>&1 | grep "k8s_psat/spoke01" | head -1 | awk '{print $NF}')

oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterStaticEntry
metadata:
  name: downstream-spoke-spire-server
spec:
  className: zero-trust-workload-identity-manager-spire
  parentID: "${AGENT_ID}"
  spiffeID: "spiffe://${TRUST_DOMAIN}/spoke/spire-server"
  selectors:
  - "k8s:ns:zero-trust-workload-identity-manager"
  - "k8s:sa:spire-server"
  downstream: true
  x509SVIDTTL: "1h"
EOF
```

**Why ClusterStaticEntry and not ClusterSPIFFEID?** ClusterSPIFFEID cannot be used because:

1. Its `parentIDTemplate` is hard-coded to local k8s_psat agents (configured in controller-manager config)
2. The target workload (spoke's spire-server) is not a pod on the Hub cluster
3. ClusterStaticEntry supports explicit `parentID`, `selectors`, and `downstream` fields

---

### Phase 15: Deploy Upstream CSI Driver on Spoke

#### What this does

Creates a second CSI driver (`upstream.csi.spiffe.io`) that serves the upstream agent's socket directory to any pod that requests it via a CSI ephemeral volume. This is how the spire-server pod gets access to the upstream agent's Workload API socket without needing elevated privileges itself.

The CSI driver:

1. Reads the socket from the hostPath (`/run/spire/agent-sockets-upstream`)
2. Bind-mounts it into requesting pods
3. Runs an init container with `chcon -Rvt container_file_t` to set the correct SELinux context

The `security.openshift.io/csi-ephemeral-volume-profile: restricted` label on the CSIDriver object tells OpenShift that pods using this CSI driver don't need elevated privileges (the CSI driver itself is privileged, but the consumer pods remain restricted).

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG

oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: upstream.csi.spiffe.io
  labels:
    security.openshift.io/csi-ephemeral-volume-profile: restricted
spec:
  attachRequired: false
  podInfoOnMount: true
  volumeLifecycleModes:
  - Ephemeral
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-spiffe-csi-driver-upstream
  namespace: zero-trust-workload-identity-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: spire-csi-upstream-use-privileged-scc
  namespace: zero-trust-workload-identity-manager
subjects:
- kind: ServiceAccount
  name: spire-spiffe-csi-driver-upstream
  namespace: zero-trust-workload-identity-manager
roleRef:
  kind: ClusterRole
  name: system:openshift:scc:privileged
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-spiffe-csi-driver-upstream
  namespace: zero-trust-workload-identity-manager
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: spire-spiffe-csi-driver-upstream
  template:
    metadata:
      labels:
        app.kubernetes.io/name: spire-spiffe-csi-driver-upstream
    spec:
      serviceAccountName: spire-spiffe-csi-driver-upstream
      initContainers:
      - name: set-context
        image: registry.access.redhat.com/ubi9:latest
        command: [chcon, -Rvt, container_file_t, spire-agent-socket/]
        volumeMounts:
        - name: spire-agent-socket-dir
          mountPath: /spire-agent-socket
        securityContext:
          privileged: true
      containers:
      - name: spiffe-csi-driver
        image: ghcr.io/spiffe/spiffe-csi-driver:0.2.8
        args:
        - "-workload-api-socket-dir"
        - "/spire-agent-socket"
        - "-plugin-name"
        - "upstream.csi.spiffe.io"
        - "-csi-socket-path"
        - "/spiffe-csi/csi.sock"
        env:
        - name: MY_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: spire-agent-socket-dir
          mountPath: /spire-agent-socket
        - name: spiffe-csi-socket-dir
          mountPath: /spiffe-csi
        - name: mountpoint-dir
          mountPath: /var/lib/kubelet/pods
          mountPropagation: Bidirectional
        securityContext:
          privileged: true
      - name: node-driver-registrar
        image: registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0
        args:
        - "-csi-address"
        - "/spiffe-csi/csi.sock"
        - "-kubelet-registration-path"
        - "/var/lib/kubelet/plugins/upstream.csi.spiffe.io/csi.sock"
        - "-health-port"
        - "9810"
        volumeMounts:
        - name: spiffe-csi-socket-dir
          mountPath: /spiffe-csi
        - name: kubelet-plugin-registration-dir
          mountPath: /registration
        securityContext:
          privileged: true
      volumes:
      - name: spire-agent-socket-dir
        hostPath:
          path: /run/spire/agent-sockets-upstream
          type: DirectoryOrCreate
      - name: spiffe-csi-socket-dir
        hostPath:
          path: /var/lib/kubelet/plugins/upstream.csi.spiffe.io
          type: DirectoryOrCreate
      - name: mountpoint-dir
        hostPath:
          path: /var/lib/kubelet/pods
          type: Directory
      - name: kubelet-plugin-registration-dir
        hostPath:
          path: /var/lib/kubelet/plugins_registry
          type: Directory
EOF
```

#### Verification

```bash
oc get pods -l app.kubernetes.io/name=spire-spiffe-csi-driver-upstream -n zero-trust-workload-identity-manager
# Expected: All pods 2/2 Running
```

---

### Phase 16: Patch Spoke SPIRE Server for UpstreamAuthority

#### 16a. Add UpstreamAuthority Plugin to Spoke Server Config

**What this does:** Adds the `UpstreamAuthority "spire"` plugin to the spoke's SPIRE server. This plugin connects to the upstream agent's Workload API socket, gets an SVID, then uses it to request an intermediate CA from the Hub.

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG
HUB_DOMAIN=$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')
HUB_GRPC_HOST="spire-server-grpc-zero-trust-workload-identity-manager.apps.${HUB_DOMAIN}"

# Get current config, add UpstreamAuthority to plugins section:
#   "UpstreamAuthority": [{
#     "spire": {
#       "plugin_data": {
#         "server_address": "<hub-grpc-route-host>",
#         "server_port": "443",
#         "workload_api_socket": "/run/spire/upstream-agent/spire-agent.sock"
#       }
#     }
#   }]

# Apply the updated config:
oc patch configmap spire-server -n zero-trust-workload-identity-manager \
  --type merge -p '{"data":{"server.conf":"<full-updated-config>"}}'
```

#### 16b. Mount CSI Volume in StatefulSet

**What this does:** Adds a CSI ephemeral volume to the spire-server StatefulSet. This volume is served by the `upstream.csi.spiffe.io` CSI driver and makes the upstream agent's Workload API socket available inside the spire-server container.

```bash
oc patch statefulset spire-server -n zero-trust-workload-identity-manager --type json -p '[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{
    "name":"upstream-agent-socket",
    "csi":{"driver":"upstream.csi.spiffe.io","readOnly":true}
  }},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{
    "name":"upstream-agent-socket",
    "mountPath":"/run/spire/upstream-agent",
    "readOnly":true
  }}
]'
```

#### 16c. Clear Old PVC Data (Required)

**Clearing PVC data is ALWAYS required** when adding UpstreamAuthority to an existing server — even if the trust domain hasn't changed. The PVC contains the server's existing self-signed CA in its journal. SPIRE only mints a new CA (via UpstreamAuthority) when no valid CA exists. The existing CA won't expire for 24h, so without clearing, the server ignores the UpstreamAuthority until then.

**How to tell if this step is needed:** If you see `upstream_authority_id=` (empty) in the server logs, the old self-signed CA is still being used.

```bash
oc scale statefulset spire-server -n zero-trust-workload-identity-manager --replicas=0
oc delete pvc spire-data-spire-server-0 -n zero-trust-workload-identity-manager
# Wait for PVC to terminate
oc scale statefulset spire-server -n zero-trust-workload-identity-manager --replicas=1
```

#### Verification

```bash
# Check server started with upstream CA:
oc logs spire-server-0 -c spire-server -n zero-trust-workload-identity-manager | grep "X509 CA"
# Expected: "X509 CA activated" ... self_signed=false ... upstream_authority_id=<non-empty>

oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server healthcheck
# Expected: "Server is healthy."
```

After patching, restart the Spoke agents so they pick up the new trust bundle:

```bash
oc delete pods -l app.kubernetes.io/name=spire-agent -n zero-trust-workload-identity-manager
```

---

### Phase 17: Verify the Full Certificate Chain (4 Certs)

#### What this does

Mints a test SVID on the spoke and examines its certificate chain. With AWS PCA as the Hub's upstream authority, a correct nested SPIRE setup produces a **4-certificate chain**:

1. **AWS PCA Root CA** (HSM-backed, in AWS) — trust anchor
2. **Hub Intermediate CA** (signed by AWS PCA, via cert-manager) — the Hub's active CA
3. **Spoke Intermediate CA** (signed by Hub, `OU=DOWNSTREAM-1`) — the Spoke's active CA
4. **Workload SVID** (leaf, signed by Spoke intermediate) — has the workload's SPIFFE ID

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG
HUB_DOMAIN=$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')
TRUST_DOMAIN="apps.${HUB_DOMAIN}"

# Mint a test SVID and save to a file
oc exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server x509 mint \
  -spiffeID "spiffe://${TRUST_DOMAIN}/test-verify-aws-pca-nested" > /tmp/minted-svid.txt

# Extract all certificates from the output into a PEM file
grep -A100 "BEGIN CERTIFICATE" /tmp/minted-svid.txt | \
  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > /tmp/svid-chain.pem

# Show each certificate in the chain
echo "=== Certificate Chain (expect 4 certs) ==="
csplit -z -f /tmp/cert- /tmp/svid-chain.pem '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null
for cert in /tmp/cert-*; do
  [ -s "$cert" ] || continue
  echo ""
  echo "--- $(basename $cert) ---"
  openssl x509 -in "$cert" -noout -subject -issuer -ext subjectAltName
done

# Count certificates
CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" /tmp/svid-chain.pem)
echo ""
echo "=== Total certificates in chain: $CERT_COUNT (expected: 4) ==="

# Verify the chain: extract leaf and CA certs separately
awk '/-----BEGIN CERTIFICATE-----/{n++} n==1' /tmp/svid-chain.pem > /tmp/leaf.pem
awk '/-----BEGIN CERTIFICATE-----/{n++} n>1' /tmp/svid-chain.pem > /tmp/ca-chain.pem

echo ""
echo "=== Chain Verification ==="
openssl verify -CAfile /tmp/ca-chain.pem /tmp/leaf.pem
# Expected: /tmp/leaf.pem: OK

# Verify the root matches the AWS PCA fingerprint
LAST_CERT=$(ls /tmp/cert-* | tail -1)
echo ""
echo "=== Root CA Fingerprint (should match AWS PCA) ==="
openssl x509 -in "$LAST_CERT" -fingerprint -sha256 -noout

# Cleanup temp files
rm -f /tmp/cert-* /tmp/leaf.pem /tmp/ca-chain.pem /tmp/svid-chain.pem /tmp/minted-svid.txt
```

Expected output:

```
=== Certificate Chain (expect 4 certs) ===

--- cert-00 ---
subject=C=US, O=SPIRE
issuer=C=US, O=RH, OU=DOWNSTREAM-1, CN=<trust-domain>, serialNumber=...
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>/test-verify-aws-pca-nested

--- cert-01 ---
subject=C=US, O=RH, OU=DOWNSTREAM-1, CN=<trust-domain>, serialNumber=...
issuer=C=US, O=RH, CN=<trust-domain>, serialNumber=...
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>

--- cert-02 ---
subject=C=US, O=RH, CN=<trust-domain>, serialNumber=...
issuer=C=US, O=RH, CN=ZTWIM Root CA
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>

--- cert-03 ---
subject=C=US, O=RH, CN=ZTWIM Root CA
issuer=C=US, O=RH, CN=ZTWIM Root CA
(self-signed, this is the AWS PCA root)

=== Total certificates in chain: 4 (expected: 4) ===

=== Chain Verification ===
/tmp/leaf.pem: OK

=== Root CA Fingerprint (should match AWS PCA) ===
sha256 Fingerprint=<matches $PCA_FINGERPRINT from Phase 1c>
```

The chain shows: **AWS PCA Root CA** (self-signed, HSM-backed) → **Hub Intermediate CA** (signed by AWS PCA, via cert-manager) → **Spoke Intermediate CA** (`OU=DOWNSTREAM-1`, signed by Hub) → **Workload SVID** (leaf, signed by Spoke intermediate).

---

### Phase 18: Verify with Live Demo Workload (spiffe-helper)

Deploy an actual workload that fetches a live SVID from the SPIRE agent via the CSI driver. This proves the full end-to-end flow works for real workloads.

#### Step 1: Create ClusterSPIFFEID and Demo Namespace

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG
HUB_DOMAIN=$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')
TRUST_DOMAIN="apps.${HUB_DOMAIN}"

oc create namespace spiffe-demo

oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: spiffe-demo
spec:
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: "spiffe://${TRUST_DOMAIN}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: spiffe-demo
  podSelector:
    matchLabels:
      app: spiffe-demo
EOF
```

#### Step 2: Deploy spiffe-helper Workload

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: demo-workload
  namespace: spiffe-demo
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: spiffe-helper-config
  namespace: spiffe-demo
data:
  helper.conf: |
    agent_address = "/spiffe-workload-api/spire-agent.sock"
    cmd = ""
    cert_dir = "/certs"
    svid_file_name = "svid.pem"
    svid_key_file_name = "svid_key.pem"
    svid_bundle_file_name = "bundle.pem"
    renew_signal = ""
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spiffe-demo
  namespace: spiffe-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: spiffe-demo
  template:
    metadata:
      labels:
        app: spiffe-demo
    spec:
      serviceAccountName: demo-workload
      containers:
      - name: workload
        image: ghcr.io/spiffe/spiffe-helper:0.8.0
        args: ["-config", "/opt/spiffe-helper/helper.conf"]
        volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
        - name: helper-config
          mountPath: /opt/spiffe-helper
          readOnly: true
        - name: certs
          mountPath: /certs
      volumes:
      - name: spiffe-workload-api
        csi:
          driver: csi.spiffe.io
          readOnly: true
      - name: helper-config
        configMap:
          name: spiffe-helper-config
      - name: certs
        emptyDir: {}
EOF
```

#### Step 3: Deploy Debug Pod and Verify Chain

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: spiffe-chain-verify
  namespace: spiffe-demo
  labels:
    app: spiffe-demo
spec:
  serviceAccountName: demo-workload
  containers:
  - name: debug
    image: registry.access.redhat.com/ubi9:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: spiffe-workload-api
      mountPath: /spiffe-workload-api
      readOnly: true
  volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io
      readOnly: true
EOF

# Wait for pod to be ready, then fetch and verify:
oc exec -n spiffe-demo spiffe-chain-verify -- bash -c '
  cd /tmp
  curl -sLO https://github.com/spiffe/spire/releases/download/v1.14.7/spire-1.14.7-linux-amd64-musl.tar.gz
  tar xzf spire-1.14.7-linux-amd64-musl.tar.gz
  mkdir -p /tmp/fetched-certs
  ./spire-1.14.7/bin/spire-agent api fetch x509 \
    -socketPath /spiffe-workload-api/spire-agent.sock \
    -write /tmp/fetched-certs/

  # Count certs in the SVID chain
  CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" /tmp/fetched-certs/svid.0.pem)
  echo "=== Certificates in SVID chain: $CERT_COUNT (expected: 3) ==="
  echo ""

  # Verify chain
  awk "/BEGIN CERTIFICATE/{n++} n==1" /tmp/fetched-certs/svid.0.pem > /tmp/leaf.pem
  awk "/BEGIN CERTIFICATE/{n++} n>1" /tmp/fetched-certs/svid.0.pem > /tmp/intermediates.pem

  echo "=== Workload SVID (leaf) ==="
  openssl x509 -in /tmp/leaf.pem -noout -subject -issuer -ext subjectAltName
  echo ""
  echo "=== Spoke Intermediate CA (OU=DOWNSTREAM-1, signed by Hub) ==="
  # Second cert in chain
  awk "/BEGIN CERTIFICATE/{n++} n==2" /tmp/fetched-certs/svid.0.pem > /tmp/spoke-int.pem
  openssl x509 -in /tmp/spoke-int.pem -noout -subject -issuer -ext subjectAltName
  echo ""
  echo "=== Hub Intermediate CA (signed by AWS PCA) ==="
  # Third cert in chain
  awk "/BEGIN CERTIFICATE/{n++} n==3" /tmp/fetched-certs/svid.0.pem > /tmp/hub-int.pem
  openssl x509 -in /tmp/hub-int.pem -noout -subject -issuer
  echo ""
  echo "=== Root CA (AWS PCA Root, in trust bundle) ==="
  openssl x509 -in /tmp/fetched-certs/bundle.0.pem -noout -subject -issuer -fingerprint -sha256
  echo ""
  echo "=== Chain Verification ==="
  openssl verify -CAfile /tmp/fetched-certs/bundle.0.pem -untrusted /tmp/intermediates.pem /tmp/leaf.pem
'
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "debug" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "debug" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "debug" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "debug" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/spiffe-chain-verify created
error: unable to upgrade connection: container not found ("debug")

```

#### Step 4: Confirm spiffe-helper Receives Updates

```bash
oc logs -n spiffe-demo -l app=spiffe-demo --tail=5
# Expected:
# "Received update" spiffe_id="spiffe://<trust-domain>/ns/spiffe-demo/sa/demo-workload"
# "X.509 certificates updated"
```

#### Cleanup

```bash
oc delete namespace spiffe-demo
oc delete clusterspiffeid spiffe-demo
```

Expected OpenSSL verification:

```
=== Certificates in SVID chain: 3 (expected: 3) ===

=== Workload SVID (leaf) ===
subject=C=US, O=SPIRE
issuer=C=US, O=RH, OU=DOWNSTREAM-1, CN=<trust-domain>
X509v3 Subject Alternative Name:
    URI:spiffe://<trust-domain>/ns/spiffe-demo/sa/demo-workload

=== Spoke Intermediate CA (OU=DOWNSTREAM-1, signed by Hub) ===
subject=C=US, O=RH, OU=DOWNSTREAM-1, CN=<trust-domain>
issuer=C=US, O=RH, CN=<trust-domain>

=== Hub Intermediate CA (signed by AWS PCA) ===
subject=C=US, O=RH, CN=<trust-domain>
issuer=C=US, O=RH, CN=ZTWIM Root CA

=== Root CA (AWS PCA Root, in trust bundle) ===
subject=C=US, O=RH, CN=ZTWIM Root CA
issuer=C=US, O=RH, CN=ZTWIM Root CA  (self-signed, HSM-backed)
sha256 Fingerprint=<matches AWS PCA fingerprint>

=== Chain Verification ===
/tmp/leaf.pem: OK
```

---

### Phase 19 (Optional): Enable Spoke → Fed Trust

Federated bundles do NOT propagate from Hub to Spoke through the UpstreamAuthority mechanism (see [spiffe/spire#4128](https://github.com/spiffe/spire/issues/4128)). If workloads on the Spoke need to authenticate workloads from the Fed cluster, the Spoke needs its own `ClusterFederatedTrustDomain` CR.

Because the Spoke shares the Hub's trust domain, the Fed cluster already trusts Spoke workloads (via the Hub ↔ Fed federation). Only the Spoke → Fed direction needs setup.

```bash
export KUBECONFIG=$SPOKE_KUBECONFIG
FED_APP_DOMAIN=apps.$(KUBECONFIG=$FED_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')

# Reuse the Fed bundle fetched in Phase 8 (or re-fetch it)
FED_BUNDLE=$(cat /tmp/fed-federation-bundle.json)

oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: spoke-to-fed-federation
spec:
  className: zero-trust-workload-identity-manager-spire
  trustDomain: ${FED_APP_DOMAIN}
  bundleEndpointURL: https://federation.${FED_APP_DOMAIN}
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://${FED_APP_DOMAIN}/spire/server
  trustDomainBundle: |
$(echo "$FED_BUNDLE" | sed 's/^/    /')
EOF
```

To make Spoke workloads receive the Fed bundle, their registration entries need `federatesWith`:

```bash
# Create a ClusterSPIFFEID that federates with the Fed domain
oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: spoke-federated-workloads
spec:
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchLabels:
      federation: enabled
  federatesWith:
    - "spiffe://${FED_APP_DOMAIN}"
EOF
```

Pods in namespaces labeled `federation: enabled` will receive both their SVID and the Fed cluster's trust bundle.

---

### Phase 20: Verify Cross-Cluster mTLS (Hub ↔ Fed)

This is the definitive proof that federation works end-to-end: a workload on the Fed cluster acts as a TLS server, and a workload on the Hub cluster connects as a TLS client. Both use their own SPIFFE SVIDs for mTLS, validated via federated trust bundles.

> **Important:** By default, spiffe-helper's `bundle.pem` only includes the **local** trust domain's bundle. To include federated bundles, set `include_federated_domains = true` in the helper config. This makes `bundle.pem` contain ALL trust bundles (local + federated), which is required for cross-cluster mTLS.

```
┌─── Hub Cluster ────────────────────┐       ┌─── Fed Cluster ────────────────────┐
│                                    │       │                                    │
│  mtls-client pod                   │       │  mtls-server pod                   │
│  ├── SVID: spiffe://<hub>/...      │       │  ├── SVID: spiffe://<fed>/...      │
│  ├── Trust: Fed bundle (federated) │──mTLS─│  ├── Trust: Hub bundle (federated) │
│  └── openssl s_client              │  via  │  └── openssl s_server :8443        │
│                                    │ Route │                                    │
└────────────────────────────────────┘       └────────────────────────────────────┘
```

#### Step 1: Deploy mTLS Server on Fed Cluster

```bash
export KUBECONFIG=$FED_KUBECONFIG
HUB_APP_DOMAIN=apps.$(KUBECONFIG=$HUB_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')
FED_APP_DOMAIN=apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')

oc create namespace mtls-demo

# ClusterSPIFFEID with federatesWith so the server gets the Hub's trust bundle
oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: mtls-demo-fed
spec:
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: "spiffe://${FED_APP_DOMAIN}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: mtls-demo
  podSelector:
    matchLabels:
      app: mtls-server
  federatesWith:
    - "spiffe://${HUB_APP_DOMAIN}"
EOF

# Deploy the server pod: spiffe-helper writes certs (with federated bundles), openssl s_server uses them
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mtls-server
  namespace: mtls-demo
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mtls-server-helper-config
  namespace: mtls-demo
data:
  helper.conf: |
    agent_address = "/spiffe-workload-api/spire-agent.sock"
    cmd = ""
    cert_dir = "/certs"
    svid_file_name = "svid.pem"
    svid_key_file_name = "svid_key.pem"
    svid_bundle_file_name = "bundle.pem"
    include_federated_domains = true
    renew_signal = ""
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mtls-server
  namespace: mtls-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mtls-server
  template:
    metadata:
      labels:
        app: mtls-server
    spec:
      serviceAccountName: mtls-server
      containers:
      - name: spiffe-helper
        image: ghcr.io/spiffe/spiffe-helper:0.8.0
        args: ["-config", "/opt/spiffe-helper/helper.conf"]
        volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
        - name: helper-config
          mountPath: /opt/spiffe-helper
          readOnly: true
        - name: certs
          mountPath: /certs
      - name: openssl-server
        image: registry.access.redhat.com/ubi9:latest
        command:
        - bash
        - -c
        - |
          echo "Waiting for certs from spiffe-helper..."
          while [ ! -f /certs/svid.pem ]; do sleep 1; done
          echo "Certs ready."
          echo ""
          echo "=== Server SVID ==="
          openssl x509 -in /certs/svid.pem -noout -subject -ext subjectAltName
          echo ""
          echo "=== Trust bundle (should include BOTH trust domains) ==="
          openssl crl2pkcs7 -nocrl -certfile /certs/bundle.pem | openssl pkcs7 -print_certs -noout | grep "subject="
          echo ""
          echo "Starting openssl s_server on port 8443 (mTLS required)..."
          while true; do
            openssl s_server \
              -cert /certs/svid.pem \
              -key /certs/svid_key.pem \
              -CAfile /certs/bundle.pem \
              -Verify 1 \
              -accept 8443 \
              -www \
              2>&1
            echo "s_server exited, restarting in 2s..."
            sleep 2
          done
        volumeMounts:
        - name: certs
          mountPath: /certs
        ports:
        - containerPort: 8443
          name: mtls
      volumes:
      - name: spiffe-workload-api
        csi:
          driver: csi.spiffe.io
          readOnly: true
      - name: helper-config
        configMap:
          name: mtls-server-helper-config
      - name: certs
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: mtls-server
  namespace: mtls-demo
spec:
  selector:
    app: mtls-server
  ports:
  - port: 8443
    targetPort: 8443
    name: mtls
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mtls-server
  namespace: mtls-demo
spec:
  to:
    kind: Service
    name: mtls-server
    weight: 100
  port:
    targetPort: mtls
  tls:
    termination: passthrough
    insecureEdgeTerminationPolicy: Redirect
EOF

echo "Waiting for server pod to be ready..."
oc wait --for=condition=Available deployment/mtls-server -n mtls-demo --timeout=180s

echo ""
echo "=== mTLS Server Route ==="
MTLS_SERVER_HOST=$(oc get route mtls-server -n mtls-demo -o jsonpath='{.spec.host}')
echo "Host: $MTLS_SERVER_HOST"
```

#### Step 2: Deploy mTLS Client on Hub Cluster

```bash
export KUBECONFIG=$HUB_KUBECONFIG
HUB_APP_DOMAIN=apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
FED_APP_DOMAIN=apps.$(KUBECONFIG=$FED_KUBECONFIG oc get dns cluster -o jsonpath='{.spec.baseDomain}')

# Get the server route host from Fed cluster
MTLS_SERVER_HOST=$(KUBECONFIG=$FED_KUBECONFIG oc get route mtls-server -n mtls-demo -o jsonpath='{.spec.host}')
echo "mTLS server route: $MTLS_SERVER_HOST"

oc create namespace mtls-demo

# ClusterSPIFFEID with federatesWith so the client gets the Fed's trust bundle
oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: mtls-demo-hub
spec:
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: "spiffe://${HUB_APP_DOMAIN}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: mtls-demo
  podSelector:
    matchLabels:
      app: mtls-client
  federatesWith:
    - "spiffe://${FED_APP_DOMAIN}"
EOF

# Deploy the client pod: spiffe-helper writes certs (with federated bundles)
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mtls-client
  namespace: mtls-demo
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mtls-client-helper-config
  namespace: mtls-demo
data:
  helper.conf: |
    agent_address = "/spiffe-workload-api/spire-agent.sock"
    cmd = ""
    cert_dir = "/certs"
    svid_file_name = "svid.pem"
    svid_key_file_name = "svid_key.pem"
    svid_bundle_file_name = "bundle.pem"
    include_federated_domains = true
    renew_signal = ""
---
apiVersion: v1
kind: Pod
metadata:
  name: mtls-client
  namespace: mtls-demo
  labels:
    app: mtls-client
spec:
  serviceAccountName: mtls-client
  containers:
  - name: spiffe-helper
    image: ghcr.io/spiffe/spiffe-helper:0.8.0
    args: ["-config", "/opt/spiffe-helper/helper.conf"]
    volumeMounts:
    - name: spiffe-workload-api
      mountPath: /spiffe-workload-api
      readOnly: true
    - name: helper-config
      mountPath: /opt/spiffe-helper
      readOnly: true
    - name: certs
      mountPath: /certs
  - name: client
    image: registry.access.redhat.com/ubi9:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: certs
      mountPath: /certs
  volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io
      readOnly: true
  - name: helper-config
    configMap:
      name: mtls-client-helper-config
  - name: certs
    emptyDir: {}
EOF

echo "Waiting for client pod to be ready..."
oc wait --for=condition=Ready pod/mtls-client -n mtls-demo --timeout=120s
```

#### Step 3: Run the mTLS Handshake

```bash
export KUBECONFIG=$HUB_KUBECONFIG

# Get the Fed server's route host
MTLS_SERVER_HOST=$(KUBECONFIG=$FED_KUBECONFIG oc get route mtls-server -n mtls-demo -o jsonpath='{.spec.host}')

echo "=== Connecting to mTLS server at $MTLS_SERVER_HOST ==="
echo ""

oc exec -n mtls-demo mtls-client -c client -- bash -c '
  echo "Waiting for certs..."
  while [ ! -f /certs/svid.pem ]; do sleep 1; done
  echo "Certs ready."
  echo ""

  echo "=== Client SVID ==="
  openssl x509 -in /certs/svid.pem -noout -subject -ext subjectAltName
  echo ""

  echo "=== Trust bundle contents (should include BOTH trust domains) ==="
  openssl crl2pkcs7 -nocrl -certfile /certs/bundle.pem | openssl pkcs7 -print_certs -noout | grep "subject="
  echo ""

  echo "=== Attempting mTLS handshake ==="
  echo "Q" | openssl s_client \
    -connect '"$MTLS_SERVER_HOST"':443 \
    -cert /certs/svid.pem \
    -key /certs/svid_key.pem \
    -CAfile /certs/bundle.pem \
    -servername '"$MTLS_SERVER_HOST"' \
    2>&1 | grep -E "Verify return|subject=|issuer=|SSL handshake|^---$|error"
'
```

Expected output:

```
=== Client SVID ===
subject=C=US, O=SPIRE
X509v3 Subject Alternative Name:
    URI:spiffe://<hub-domain>/ns/mtls-demo/sa/mtls-client

=== Trust bundle contents (should include BOTH trust domains) ===
subject=C=US, O=RH, CN=ZTWIM Root CA
subject=C=US, O=RH, CN=<fed-domain>, serialNumber=...

=== Attempting mTLS handshake ===
---
subject=C=US, O=SPIRE
issuer=C=US, O=RH, CN=<fed-domain>, serialNumber=...
---
SSL handshake has read ... bytes and written ... bytes
Verify return code: 0 (ok)
```

`**Verify return code: 0 (ok)**` confirms:

- The Hub client presented its SVID (signed by Hub's CA, which traces back to AWS PCA)
- The Fed server presented its SVID (signed by Fed's own CA)
- The Hub client verified the Fed server's SVID using the **federated** Fed trust bundle
- The Fed server verified the Hub client's SVID using the **federated** Hub trust bundle (which includes the AWS PCA root)
- **Bidirectional cross-trust-domain mTLS succeeded**

#### Cleanup

```bash
# Hub
export KUBECONFIG=$HUB_KUBECONFIG
oc delete namespace mtls-demo
oc delete clusterspiffeid mtls-demo-hub

# Fed
export KUBECONFIG=$FED_KUBECONFIG
oc delete namespace mtls-demo
oc delete clusterspiffeid mtls-demo-fed
```

---

## Key Learnings

### AWS PCA Integration

1. `**issuerGroup: awspca.cert-manager.io` is mandatory** — Without this, SPIRE creates CertificateRequests targeting the default `cert-manager.io` group, which the aws-privateca-issuer controller doesn't watch. The SPIRE server crashes in a loop.
2. `**--disable-approved-check` is required** — For cert-manager v1.3+, the aws-privateca-issuer controller needs this flag to bypass the approval check. Without it, CertificateRequests stay Pending.
3. **Static credentials via dedicated IAM user** — A dedicated `spire-pca-issuer` IAM user with PCA-only permissions provides credentials via a K8s Secret injected as env vars. The worker node role is intentionally not modified (per AWS best practice — node roles are for control-plane operations only). Future: migrate to STS tokens via IRSA.
4. **aws-privateca-issuer lives in its own namespace** — Install it in `aws-privateca-issuer` (not `cert-manager`). The SCC grants are scoped to this namespace.
5. **AWS PCA costs** — AWS PCA charges ~$400/month per CA + $0.75 per certificate issued. SPIRE rotates CAs every 24h by default. Consider increasing `ca_ttl` for cost optimization during extended testing.
6. **4-certificate chain** — With AWS PCA, the Spoke workload chain has 4 certs instead of 3. Verification scripts must account for the extra intermediate.
7. **PathLen1 required for nested SPIRE** — The default PCA template (`SubordinateCACertificate_PathLen0/V1`) only allows direct leaf signing. Nested SPIRE needs the Hub's intermediate to sign the Spoke's CA, requiring `PathLen1`. Without this, the Spoke crashes with: `x509: too many intermediates for path length constraint`.
8. **Trust bundle includes the AWS PCA root** — The Hub's `spire-bundle` ConfigMap will contain the AWS PCA root certificate. Verify by fingerprint comparison.
9. **PVC clearing is still required** — If you add `upstreamAuthority.certManager` after initial deployment, clear the Hub's PVC just like the Spoke's.
10. **SPIRE startup flow with AWS PCA**: SPIRE generates a key pair → creates CertificateRequest in cert-manager namespace → aws-privateca-issuer calls AWS PCA `IssueCertificate` API → PCA signs with HSM key → signed intermediate CA returned → SPIRE publishes PCA root in trust bundle → federation endpoint starts on port 8443.

### Nested SPIRE (k8s_psat)

1. **Hub needs a kubeconfig to reach Spoke's API server** — The k8s_psat plugin on the Hub validates tokens via TokenReview API calls to the Spoke. This requires a kubeconfig with `system:auth-delegator` and pod/node read permissions.
2. **Pod/node read access is required for the Hub's k8s_psat plugin** — Beyond just validating the token, the plugin queries the Spoke's API for pod metadata (labels, namespace, SA). Without this, attestation fails with `403 Forbidden` on the pods API.
3. **Upstream agent SA needs nodes/proxy access** — The k8s WorkloadAttestor on the upstream agent contacts the kubelet API to resolve PIDs to pods. This requires `nodes/proxy` get access. Without it, selectors are empty and the Hub rejects with "no identity issued".
4. **Projected SA token audience must match** — The `audience: spire-server` in the Deployment's projected volume must match the `audience: ["spire-server"]` in the Hub's k8s_psat config.
5. **Same trust domain required** — The UpstreamAuthority "spire" plugin constructs the expected upstream server ID from its own trust domain. Hub and Spoke must share the same trust domain.
6. **No certificates to manage** — k8s_psat requires zero certificate generation. Kubernetes handles token issuance and rotation automatically.
7. **Re-attestation is automatic** — k8s_psat has `can_re_attest: true`, so when the projected token rotates, the agent automatically re-attests without manual intervention.
8. **Spoke agents need restart after UpstreamAuthority switch** — When the Spoke server switches from self-signed to UpstreamAuthority, the trust bundle changes. The Spoke agents have the old bundle cached and need to be restarted.

### Federation (https_spiffe)

1. **Set up federation BEFORE CREATE_ONLY_MODE** — Federation config in the SpireServer CR triggers automatic ConfigMap, Service port (8443), and Route creation by the operator. If CREATE_ONLY_MODE is already on, you must patch all three manually.
2. `**https_spiffe` uses passthrough TLS** — The SPIRE server presents its own SVID as the TLS certificate on the federation endpoint. The Route must use `passthrough` termination.
3. **Initial trust bootstrap requires `curl -sk`** — On the very first bundle fetch, you don't yet trust the remote SVID. Use `curl -k` for this one-time bootstrap; SPIRE handles all subsequent mTLS refreshes.
4. `**ClusterFederatedTrustDomain` requires `className**` — The `className` field must be `zero-trust-workload-identity-manager-spire` to match the controller-manager's configured class. Without it, the CR is ignored.
5. **Federated bundles do NOT propagate downstream** — The UpstreamAuthority plugin only propagates CA chain (X.509 roots, JWT keys), not federated bundles. Each SPIRE server maintains its own federation trust store independently. See [spiffe/spire#4128](https://github.com/spiffe/spire/issues/4128).
6. **Hub can serve both roles simultaneously** — The Hub can be an upstream authority for nested Spoke clusters AND a federation peer for independent clusters. These are orthogonal features.
7. **spiffe-helper requires `include_federated_domains = true` for cross-cluster mTLS** — By default, spiffe-helper's `bundle.pem` only includes the local trust domain's bundle.

---

## Troubleshooting

### AWS PCA


| Symptom                                                       | Likely Cause                                  | Fix                                                                                                                                     |
| ------------------------------------------------------------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| SPIRE server crash loop: "issuer not found"                   | Missing `issuerGroup: awspca.cert-manager.io` | Add `issuerGroup` to SpireServer CR or ConfigMap                                                                                        |
| CertificateRequest stuck in Pending (not approved)            | Missing `--disable-approved-check` flag       | Patch deployment: `--type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--disable-approved-check"]}]'` |
| CertificateRequest stuck in Pending (approved but not signed) | aws-privateca-issuer can't reach AWS PCA      | Check aws-pca-credentials Secret, verify IAM policy, check controller logs in `aws-privateca-issuer` namespace                          |
| CertificateRequest Denied                                     | cert-manager approval policy blocking         | Use `--disable-approved-check` or create a blanket approval policy                                                                      |
| `self_signed=true` despite upstreamAuthority config           | PVC has old self-signed CA                    | Clear PVC: scale to 0, delete PVC, scale to 1                                                                                           |
| aws-privateca-issuer pod CrashLoopBackOff (SCC)               | Missing SCC on OpenShift                      | `oc adm policy add-scc-to-user anyuid -z aws-pca-issuer-aws-privateca-issuer -n aws-privateca-issuer`                                   |
| Trust bundle fingerprint doesn't match AWS PCA                | SPIRE hasn't rotated to new CA yet            | Wait for CA rotation (up to 24h) or clear PVC to force immediate rotation                                                               |
| AWSPCAClusterIssuer status not Ready                          | Controller can't authenticate to AWS          | Verify env vars injected: `oc set env deployment/aws-pca-issuer-aws-privateca-issuer -n aws-privateca-issuer --list`                    |


### Nested SPIRE


| Symptom                                                  | Likely Cause                                              | Fix                                                                                                |
| -------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Upstream agent: "failed to receive attestation response" | Hub's k8s_psat can't validate Spoke's token               | Check spoke-kubeconfig Secret, verify kubeconfig has TokenReview permissions                       |
| Hub: "pods ... is forbidden" during attestation          | Hub's kubeconfig missing pod/node read access             | Add ClusterRole with pods/nodes get/list to the spire-hub-token-reviewer SA                        |
| Upstream agent: "workloadattestor(k8s): 403 Forbidden"   | Upstream agent SA missing nodes/proxy access              | Add ClusterRole with nodes/proxy get to spire-agent-upstream SA                                    |
| Upstream agent pod won't start (SCC denied)              | Patched `spire-agent` SCC but operator reconciled it back | Create separate `spire-agent-upstream` SCC (operator reconciliation not gated by CREATE_ONLY_MODE) |
| Spoke server: `upstream_authority_id=` (empty)           | Old self-signed CA still valid on PVC                     | Clear PVC data: scale to 0, delete PVC, scale to 1                                                 |
| "no identity issued" from upstream agent                 | Empty selectors due to RBAC or no matching entry          | Fix RBAC first, then verify ClusterStaticEntry selectors match                                     |
| Spoke server: "unexpected ID" during UpstreamAuthority   | Trust domains don't match                                 | Both MUST use the same trust domain                                                                |
| Spoke agents: "tls: bad certificate"                     | Agents have old trust bundle after CA switch              | Restart Spoke agents: `oc delete pods -l app.kubernetes.io/name=spire-agent`                       |
| Audience mismatch errors                                 | Projected SA token audience doesn't match config          | Ensure `audience: spire-server` in both Deployment and Hub's k8s_psat config                       |


### Federation


| Symptom                                                            | Likely Cause                                            | Fix                                                                                                                                                                                     |
| ------------------------------------------------------------------ | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Federation endpoint returns connection refused                     | Route not created or SPIRE server not listening on 8443 | Check `oc get route spire-server-federation` and verify `federation` is in the SpireServer CR                                                                                           |
| `curl -sk` returns empty or HTML error                             | Route exists but backend not ready                      | Check `oc logs spire-server-0 -c spire-server` for federation errors                                                                                                                    |
| `ClusterFederatedTrustDomain` has no effect                        | Missing or wrong `className`                            | Ensure `className: zero-trust-workload-identity-manager-spire`                                                                                                                          |
| `spire-server bundle list` doesn't show federated domain           | Controller-manager hasn't reconciled                    | Wait 30s; check `oc logs spire-server-0 -c spire-controller-manager`                                                                                                                    |
| Federation endpoint not accessible after enabling CREATE_ONLY_MODE | Operator didn't add federation port to Service          | Manually patch Service: `oc patch svc spire-server --type json -p '[{"op":"add","path":"/spec/ports/-","value":{"name":"federation","port":8443,"targetPort":8443,"protocol":"TCP"}}]'` |


---

## SCC Summary


| Component                | Namespace            | SCC                                                                 | Why                                                                                                                                     |
| ------------------------ | -------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| upstream-agent pod       | ztwim                | `spire-agent-upstream` (new, identical to `spire-agent`)            | Needs `hostPID` + `hostPath`. Cannot reuse `spire-agent` because operator reconciles its `.users` list (not gated by CREATE_ONLY_MODE). |
| upstream CSI driver      | ztwim                | `privileged` (via RoleBinding to `system:openshift:scc:privileged`) | Needs bind mounts + bidirectional mount propagation                                                                                     |
| spire-server StatefulSet | ztwim                | `restricted` (unchanged)                                            | CSI volume doesn't require elevated privileges                                                                                          |
| aws-privateca-issuer     | aws-privateca-issuer | `anyuid` + `nonroot-v2` (via `oc adm policy`)                       | Controller needs to run as non-root UID; also needs `--disable-approved-check` for cert-manager v1.3+                                   |


---

## RBAC Summary (Additional for k8s_psat)


| SA                         | Cluster | Permissions                                   | Why                                                        |
| -------------------------- | ------- | --------------------------------------------- | ---------------------------------------------------------- |
| `spire-hub-token-reviewer` | Spoke   | `system:auth-delegator` + pods/nodes get/list | Hub's k8s_psat validates tokens + queries pod metadata     |
| `spire-agent-upstream`     | Spoke   | pods/nodes/nodes/proxy get                    | k8s WorkloadAttestor resolves PIDs to pods via kubelet API |


---

## Cost & Operational Notes

1. **AWS PCA pricing** — $400/month per CA + $0.75 per certificate issued. SPIRE rotates the CA every 24h by default, so expect ~30 certs/month for a single Hub. Increase `ca_ttl` to reduce cost.
2. **Credential rotation required** — The static IAM user access keys (`aws-pca-credentials` Secret) should be rotated per your org's policy. Use `aws iam create-access-key` + `oc create secret` to rotate. Future: migrate to STS/IRSA to eliminate static credential management entirely.
3. **PCA deactivation** — When done testing, deactivate the PCA to stop monthly charges: `aws acm-pca update-certificate-authority --certificate-authority-arn $PCA_ARN --status DISABLED`
4. **Cleanup** — To fully delete the PCA: `aws acm-pca delete-certificate-authority --certificate-authority-arn $PCA_ARN --permanent-deletion-time-in-days 7`. Also delete the IAM user: `aws iam delete-access-key --user-name spire-pca-issuer --access-key-id <KEY_ID> && aws iam detach-user-policy --user-name spire-pca-issuer --policy-arn $POLICY_ARN && aws iam delete-user --user-name spire-pca-issuer`

---

## Advantages of This Architecture

1. **HSM-backed root** — The root CA private key never leaves AWS CloudHSM. No risk of key compromise on cluster infrastructure.
2. **Centralized compliance** — All certificate issuance is auditable via AWS CloudTrail. Meets enterprise compliance requirements.
3. **No certificate management for nested SPIRE** — k8s_psat uses Kubernetes-native projected tokens. Zero manual certificate rotation.
4. **Independent failure domains** — The Fed cluster operates independently. AWS PCA outages affect Hub/Spoke issuance but not existing SVIDs (SPIRE caches).
5. **Scalable** — Adding more Spoke clusters only requires a new kubeconfig + k8s_psat cluster entry on the Hub. No new CAs to provision.

