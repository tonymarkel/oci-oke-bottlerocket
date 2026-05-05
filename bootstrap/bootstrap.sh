#!/bin/bash
set -euo pipefail

log() { echo "[oke-bootstrap] $*" >&2; }

log "Fetching OKE init script from IMDS..."
OKE_SCRIPT=$(curl -sf \
  --retry 5 --retry-delay 2 \
  -H "Authorization: Bearer Oracle" \
  "http://169.254.169.254/opc/v2/instance/metadata/oke_init_script" \
  | base64 -d)

if [[ -z "$OKE_SCRIPT" ]]; then
  log "ERROR: oke_init_script is empty — is this an OKE managed node pool?"
  exit 1
fi

# Extract a named argument value from the oke-install.sh invocation.
# Handles both quoted and unquoted values: --flag "value" or --flag value
extract_arg() {
  local flag="$1"
  echo "$OKE_SCRIPT" \
    | grep -oP "(?<=--${flag} ['\"]?)[^'\" ]+" \
    | head -1
}

API_ENDPOINT=$(extract_arg "apiserver-endpoint")
CA_CERT=$(extract_arg "kubelet-ca-cert")
CLUSTER_DNS=$(extract_arg "cluster-dns" || true)
BOOTSTRAP_TOKEN=$(extract_arg "bootstrap-token" || true)

[[ -z "$API_ENDPOINT" ]] && { log "ERROR: could not extract --apiserver-endpoint from oke_init_script"; exit 1; }
[[ -z "$CA_CERT" ]]      && { log "ERROR: could not extract --kubelet-ca-cert from oke_init_script"; exit 1; }

CLUSTER_DNS="${CLUSTER_DNS:-10.96.5.5}"

log "API endpoint:  ${API_ENDPOINT}"
log "Cluster DNS:   ${CLUSTER_DNS}"
log "Bootstrap token present: $([[ -n "${BOOTSTRAP_TOKEN:-}" ]] && echo yes || echo no)"

log "Applying kubernetes settings via apiclient..."
apiclient set \
  "kubernetes.api-server=https://${API_ENDPOINT}" \
  "kubernetes.cluster-certificate=${CA_CERT}" \
  "kubernetes.cluster-dns-ip=${CLUSTER_DNS}"

if [[ -n "${BOOTSTRAP_TOKEN:-}" ]]; then
  apiclient set "kubernetes.bootstrap-token=${BOOTSTRAP_TOKEN}"
fi

# Apply topology label from OCI availability domain so the k8s scheduler
# can use zone-aware scheduling.
INSTANCE_META=$(curl -sf \
  --retry 3 --retry-delay 2 \
  -H "Authorization: Bearer Oracle" \
  "http://169.254.169.254/opc/v2/instance/")
AD=$(echo "$INSTANCE_META" | jq -r '.availabilityDomain // empty')
if [[ -n "$AD" ]]; then
  log "Setting zone label: ${AD}"
  apiclient set "kubernetes.node-labels.topology.kubernetes.io/zone=${AD}"
fi

log "Bootstrap complete — Bottlerocket will start kubelet now."