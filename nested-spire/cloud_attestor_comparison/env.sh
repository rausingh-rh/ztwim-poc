#!/usr/bin/env bash
# Source this file before applying manifests:
#   source env.sh
#
# Then apply a manifest with envsubst:
#   envsubst < k8s-psat/06-parent-server-configmap.yaml | oc apply -f -

# --- Required: set these for your clusters ---
export PARENT_CLUSTER_DOMAIN=""   # e.g. gcp1793008166.gcp.devcluster.openshift.com
export CHILD_CLUSTER_DOMAIN=""    # e.g. gcp1793009109.gcp.devcluster.openshift.com
export GCP_PROJECT=""             # e.g. openshift-gce-devel (gcp_iit only)

export PARENT_KUBECONFIG=""       # path to parent cluster kubeconfig
export CHILD_KUBECONFIG=""        # path to child cluster kubeconfig

# --- Derived: do not edit ---
export TRUST_DOMAIN="apps.${PARENT_CLUSTER_DOMAIN}"
export NS="zero-trust-workload-identity-manager"
