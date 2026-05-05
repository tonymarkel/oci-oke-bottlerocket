# Plan: Bottlerocket OKE Integration

## Context

Oracle Kubernetes Engine (OKE) supports custom OS nodes via user-provided userdata. Standard OKE nodes run Oracle Linux and use cloud-init to fetch and run `oke-install.sh`, which configures kubelet and joins the cluster. The reference technique (tonymarkel/oci-oke-custom-os) shows how to do this with Ubuntu/RHEL by supplying a cloud-init script that calls `oke-install.sh`.

Bottlerocket is an immutable OS — it cannot run shell scripts at boot via cloud-init. Instead it uses:
- **TOML userdata** sent to its settings API (`early-boot-config`)
- **Bootstrap containers**: privileged OCI containers that run _before_ kubelet starts and can call `apiclient` to configure Bottlerocket settings dynamically

The integration approach: a bootstrap container fetches OKE's `oke_init_script` from the OCI Instance Metadata Service (IMDS), parses the API endpoint, cluster CA cert, and bootstrap token out of it, then applies those via `apiclient set` — enabling Bottlerocket's built-in kubelet to join the OKE cluster exactly as a normal node would.

**User choices:**
- OKE Managed Node Pool (IMDS-based bootstrap)
- Bootstrap container image: `ghcr.io/tonymarkel/oke-bottlerocket-bootstrap`
- Full-stack Terraform (VCN + OKE cluster + node pool)

---

## Repository Structure

```
oci-oke-bottlerocket/
├── README.md
├── .github/
│   └── workflows/
│       └── bootstrap-container.yml   # Build + push bootstrap image to ghcr.io
├── bootstrap/
│   ├── Dockerfile                    # Alpine-based, includes curl + jq
│   └── bootstrap.sh                  # Core bootstrap logic
├── terraform/
│   ├── main.tf                       # Provider, versions, data sources
│   ├── variables.tf
│   ├── outputs.tf
│   ├── vcn.tf                        # VCN, subnets, internet/NAT gateways, security lists
│   ├── oke.tf                        # OKE cluster resource
│   ├── image.tf                      # Import Bottlerocket image from Object Storage
│   └── node-pool.tf                  # Node pool with Bottlerocket + TOML userdata
├── userdata/
│   └── bottlerocket.toml.tpl         # Bottlerocket userdata template
└── scripts/
    └── prepare-image.sh              # Download Bottlerocket .img.lz4, decompress, upload to OCI
```

---

## Critical Files and Their Contents

### `bootstrap/bootstrap.sh`

Core logic: fetch `oke_init_script` from IMDS, parse cluster parameters, apply via `apiclient`.

```bash
#!/bin/bash
set -euo pipefail

log() { echo "[oke-bootstrap] $*"; }

log "Fetching OKE init script from IMDS..."
OKE_SCRIPT=$(curl -sf \
  --retry 5 --retry-delay 2 \
  -H "Authorization: Bearer Oracle" \
  "http://169.254.169.254/opc/v2/instance/metadata/oke_init_script" \
  | base64 -d)

# Extract cluster parameters from the oke-install.sh invocation in the script
extract_arg() {
  local arg="$1"
  echo "$OKE_SCRIPT" | grep -oP "(?<=--${arg} ['\"]?)[^'\" ]+" | head -1
}

API_ENDPOINT=$(extract_arg "apiserver-endpoint")
CA_CERT=$(extract_arg "kubelet-ca-cert")
CLUSTER_DNS=$(extract_arg "cluster-dns" || echo "10.96.5.5")
BOOTSTRAP_TOKEN=$(extract_arg "bootstrap-token" || true)

[[ -z "$API_ENDPOINT" ]] && { log "ERROR: could not extract --apiserver-endpoint"; exit 1; }
[[ -z "$CA_CERT" ]]      && { log "ERROR: could not extract --kubelet-ca-cert"; exit 1; }

log "Configuring Bottlerocket kubernetes settings..."
apiclient set \
  "kubernetes.api-server=https://${API_ENDPOINT}" \
  "kubernetes.cluster-certificate=${CA_CERT}" \
  "kubernetes.cluster-dns-ip=${CLUSTER_DNS}"

if [[ -n "${BOOTSTRAP_TOKEN:-}" ]]; then
  apiclient set "kubernetes.bootstrap-token=${BOOTSTRAP_TOKEN}"
fi

# Propagate node labels from OKE (pool name, AZ, etc.)
INSTANCE_META=$(curl -sf -H "Authorization: Bearer Oracle" \
  "http://169.254.169.254/opc/v2/instance/")
AD=$(echo "$INSTANCE_META" | jq -r '.availabilityDomain')
apiclient set "kubernetes.node-labels.topology.kubernetes.io/zone=${AD}"

log "Bootstrap complete — kubelet will start now."
```

**Key notes:**
- `apiclient` is bind-mounted into bootstrap containers by Bottlerocket — no need to install it
- `essential = true` means a non-zero exit halts the boot, preventing a broken node from joining
- The exact argument names in `oke_init_script` (`--apiserver-endpoint`, `--kubelet-ca-cert`, `--bootstrap-token`) need to be validated against a real OKE cluster; OKE may use different flag names or embed values differently

### `bootstrap/Dockerfile`

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache bash curl jq
COPY bootstrap.sh /bootstrap.sh
RUN chmod +x /bootstrap.sh
ENTRYPOINT ["/bootstrap.sh"]
```

### `userdata/bottlerocket.toml.tpl`

Minimal TOML that wires in the bootstrap container. Kubernetes settings are intentionally left empty — the bootstrap container fills them in before kubelet starts.

```toml
[settings.bootstrap-containers.oke-init]
source = "ghcr.io/tonymarkel/oke-bottlerocket-bootstrap:${bootstrap_image_tag}"
mode = "once"
essential = true

[settings.host-containers.admin]
enabled = false

[settings.kubernetes]
cluster-name = "${cluster_name}"

[settings.ntp]
time-servers = ["169.254.169.254"]
```

### `terraform/image.tf`

```hcl
resource "oci_core_image" "bottlerocket" {
  compartment_id = var.compartment_id
  display_name   = "bottlerocket-metal-k8s-${var.kubernetes_version}-${var.bottlerocket_version}"

  image_source_details {
    source_type       = "objectStorageTuple"
    namespace_name    = data.oci_objectstorage_namespace.ns.namespace
    bucket_name       = var.bottlerocket_image_bucket
    object_name       = var.bottlerocket_image_object
    source_image_type = "RAW"
  }

  launch_mode = "PARAVIRTUALIZED"

  timeouts {
    create = "30m"
  }
}
```

### `terraform/node-pool.tf`

```hcl
locals {
  bottlerocket_userdata = base64encode(templatefile(
    "${path.module}/../userdata/bottlerocket.toml.tpl",
    {
      cluster_name        = var.cluster_name
      bootstrap_image_tag = var.bootstrap_image_tag
    }
  ))
}

resource "oci_containerengine_node_pool" "bottlerocket" {
  cluster_id         = oci_containerengine_cluster.oke.id
  compartment_id     = var.compartment_id
  name               = "${var.cluster_name}-bottlerocket"
  kubernetes_version = "v${var.kubernetes_version}"

  node_shape = var.node_shape

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = oci_core_image.bottlerocket.id
    boot_volume_size_in_gbs = 20
  }

  node_config_details {
    size = var.node_count

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.worker.id
    }

    node_pool_pod_network_option_details {
      cni_type = "FLANNEL_OVERLAY"
    }
  }

  node_metadata = {
    user_data = local.bottlerocket_userdata
  }

  # No initial_node_labels — labels are applied by the bootstrap container from IMDS metadata
}
```

### `terraform/oke.tf`

```hcl
resource "oci_containerengine_cluster" "oke" {
  compartment_id     = var.compartment_id
  name               = var.cluster_name
  kubernetes_version = "v${var.kubernetes_version}"
  vcn_id             = oci_core_vcn.vcn.id

  endpoint_config {
    is_public_ip_enabled = false
    subnet_id            = oci_core_subnet.control_plane.id
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.lb.id]
    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
  }
}
```

### `terraform/vcn.tf`

Standard 3-subnet layout:
- `control_plane`: private, for OKE API server endpoint
- `worker`: private, for Bottlerocket nodes (needs NAT for IMDS + ghcr.io pull)
- `lb`: public, for load balancer services

Outbound internet via NAT gateway (workers need it to pull ghcr.io bootstrap image).

### `terraform/variables.tf` — key variables

```hcl
variable "compartment_id"          {}
variable "cluster_name"            { default = "oke-bottlerocket" }
variable "kubernetes_version"      { default = "1.31" }
variable "bottlerocket_version"    { default = "1.21.0" }
variable "node_shape"              { default = "VM.Standard.E4.Flex" }
variable "node_ocpus"              { default = 2 }
variable "node_memory_gbs"         { default = 16 }
variable "node_count"              { default = 2 }
variable "bootstrap_image_tag"     { default = "latest" }
variable "bottlerocket_image_bucket" {}
variable "bottlerocket_image_object" {}
```

### `scripts/prepare-image.sh`

```bash
#!/bin/bash
# Usage: ./prepare-image.sh <k8s-version> <br-version> <oci-namespace> <bucket>
K8S_VERSION="${1:-1.31}"
BR_VERSION="${2:-1.21.0}"
NAMESPACE="$3"
BUCKET="$4"

ARCH="x86_64"
VARIANT="metal-k8s-${K8S_VERSION}"
IMAGE="bottlerocket-${VARIANT}-${ARCH}-${BR_VERSION}"
LZ4="${IMAGE}.img.lz4"
RAW="${IMAGE}.img"

echo "Downloading ${LZ4} from GitHub releases..."
curl -fLO "https://github.com/bottlerocket-os/bottlerocket/releases/download/v${BR_VERSION}/${LZ4}"

echo "Decompressing..."
lz4 -d "${LZ4}" "${RAW}"

echo "Uploading to OCI Object Storage (bucket: ${BUCKET})..."
oci os object put \
  --namespace "${NAMESPACE}" \
  --bucket-name "${BUCKET}" \
  --name "${RAW}" \
  --file "${RAW}"

echo ""
echo "Done. Set Terraform variables:"
echo "  bottlerocket_image_bucket = \"${BUCKET}\""
echo "  bottlerocket_image_object = \"${RAW}\""
```

### `.github/workflows/bootstrap-container.yml`

```yaml
name: Bootstrap Container

on:
  push:
    branches: [main]
    paths: [bootstrap/**]
  pull_request:
    paths: [bootstrap/**]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: bootstrap
          push: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}
          tags: |
            ghcr.io/${{ github.repository_owner }}/oke-bottlerocket-bootstrap:latest
            ghcr.io/${{ github.repository_owner }}/oke-bottlerocket-bootstrap:${{ github.sha }}
```

---

## Known Risks and Open Questions

1. **`oke_init_script` format**: The exact flag names (`--apiserver-endpoint`, `--kubelet-ca-cert`, `--bootstrap-token`) need to be verified against a real OKE managed node pool. The bootstrap.sh parsing logic must be adjusted if OKE uses different flag names or a different script structure.

2. **Bootstrap token support**: Bottlerocket's `kubernetes.bootstrap-token` setting exists in the `metal-k8s` variant. If OKE doesn't provide a standard Kubernetes bootstrap token (e.g., it uses a different auth mechanism like OCI instance principal), additional work is needed to configure kubelet auth.

3. **Bottlerocket variant**: The `metal-k8s` variant is the only viable generic option. Verify the exact variant name for the target Kubernetes version at: https://github.com/bottlerocket-os/bottlerocket/releases

4. **ghcr.io pull auth**: Bottlerocket nodes need to pull `ghcr.io/tonymarkel/oke-bottlerocket-bootstrap` before the bootstrap container can run. If the image is private, a `[settings.docker-credentials]` section must be added to the TOML userdata. Making the ghcr.io package public is the simplest solution.

5. **IMDS in bootstrap container**: Bottlerocket bootstrap containers run in a network namespace where IMDS (169.254.169.254) must be reachable. This is standard for OCI compute but should be confirmed.

---

## Verification Steps

1. **Build and push bootstrap image**: `docker build -t ghcr.io/tonymarkel/oke-bottlerocket-bootstrap:test bootstrap/ && docker push ...`

2. **Prepare Bottlerocket image**: `./scripts/prepare-image.sh 1.31 1.21.0 <namespace> <bucket>`

3. **Deploy infrastructure**: `cd terraform && terraform init && terraform apply`

4. **Check node status**: `kubectl get nodes` — Bottlerocket nodes should appear as `Ready` within ~5 minutes

5. **Debug bootstrap**: If a node doesn't join, SSH into a working node's admin container or use OCI console serial console to check:
   ```
   journalctl -u bootstrap-containers@oke-init
   ```

6. **Verify OS**: `kubectl get node <node> -o jsonpath='{.status.nodeInfo.osImage}'` should show `Bottlerocket OS`