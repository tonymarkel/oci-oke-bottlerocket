# Bottlerocket on Oracle Kubernetes Engine (OKE)

This repository provides everything needed to run [Bottlerocket OS](https://bottlerocket.dev) worker nodes on [Oracle Container Engine for Kubernetes (OKE)](https://www.oracle.com/cloud/cloud-native/container-engine-kubernetes/).

Bottlerocket is an immutable, security-focused Linux distribution from AWS designed specifically for hosting containers. It uses TOML-based configuration instead of cloud-init, which requires a different bootstrap approach compared to standard OKE worker nodes.

## How It Works

Standard OKE nodes boot Oracle Linux with cloud-init, which fetches an `oke_init_script` from the [OCI Instance Metadata Service (IMDS)](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/gettingmetadata.htm) and runs it. That script calls `oke-install.sh` to configure kubelet and join the node to the cluster.

Bottlerocket cannot run cloud-init or arbitrary shell scripts. Instead this project uses Bottlerocket's **bootstrap container** mechanism:

```
OCI Instance boots with Bottlerocket
        │
        ▼
early-boot-config applies TOML userdata
        │
        ▼
Bootstrap container: ghcr.io/tonymarkel/oke-bottlerocket-bootstrap
        │
        ├─ curl IMDS → oke_init_script → base64 decode
        ├─ parse --apiserver-endpoint, --kubelet-ca-cert, --bootstrap-token
        └─ apiclient set kubernetes.api-server=...
                       kubernetes.cluster-certificate=...
                       kubernetes.bootstrap-token=...
        │
        ▼
Bootstrap container exits cleanly
        │
        ▼
Bottlerocket starts kubelet → node joins OKE cluster
```

The bootstrap container runs **before kubelet starts**, translates OKE's IMDS-provided configuration into Bottlerocket's settings API, then exits — allowing Bottlerocket's built-in kubelet to join the cluster exactly like a standard OKE worker node.

## Repository Layout

```
.
├── bootstrap/
│   ├── Dockerfile        # Alpine-based bootstrap container image
│   └── bootstrap.sh      # Fetches OKE config from IMDS, applies via apiclient
├── terraform/
│   ├── main.tf           # OCI provider, data sources
│   ├── variables.tf      # All input variables with defaults
│   ├── outputs.tf
│   ├── vcn.tf            # VCN, subnets, gateways, security lists
│   ├── oke.tf            # OKE cluster
│   ├── image.tf          # Custom image import from Object Storage
│   └── node-pool.tf      # Node pool using Bottlerocket image
├── userdata/
│   └── bottlerocket.toml.tpl  # TOML userdata template for Bottlerocket
├── scripts/
│   └── prepare-image.sh  # Download Bottlerocket image and upload to OCI
└── .github/workflows/
    └── bootstrap-container.yml  # Build and push bootstrap image to ghcr.io
```

## Prerequisites

- OCI account with permissions to create: Compute, VCN, OKE, Object Storage
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) configured (`~/.oci/config`)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- `curl`, `lz4`, `docker` (for building the bootstrap container locally)

## Step 1 — Push the Bootstrap Container

The bootstrap container is built and pushed automatically to `ghcr.io/tonymarkel/oke-bottlerocket-bootstrap` via GitHub Actions on every push to `main` that touches `bootstrap/`.

To build and push manually:

```bash
docker build -t ghcr.io/tonymarkel/oke-bottlerocket-bootstrap:latest bootstrap/
docker push ghcr.io/tonymarkel/oke-bottlerocket-bootstrap:latest
```

Make the package **public** in your GitHub account settings so Bottlerocket nodes can pull it without credentials. Alternatively add registry credentials to the TOML userdata template (`[settings.docker-credentials]`).

## Step 2 — Prepare the Bottlerocket Image

Download the `metal-k8s` variant image from [Bottlerocket releases](https://github.com/bottlerocket-os/bottlerocket/releases), decompress it, and upload to OCI Object Storage:

```bash
# Create a bucket first (one-time)
oci os bucket create \
  --compartment-id <compartment-ocid> \
  --name bottlerocket-images \
  --namespace <your-namespace>

# Download, decompress, upload
./scripts/prepare-image.sh 1.31 1.21.0 <your-oci-namespace> bottlerocket-images
```

The script outputs the Terraform variable values to use in the next step. The available `metal-k8s` variants and Bottlerocket release versions are listed at:
https://github.com/bottlerocket-os/bottlerocket/releases

> **Note:** OCI image import from Object Storage takes 10–40 minutes. Terraform waits for it automatically.

## Step 3 — Deploy with Terraform

```bash
cd terraform
terraform init

# Create a terraform.tfvars file:
cat > terraform.tfvars <<EOF
compartment_id             = "ocid1.compartment.oc1..xxx"
region                     = "us-ashburn-1"
cluster_name               = "oke-bottlerocket"
kubernetes_version         = "1.31"
bottlerocket_version       = "1.21.0"
bottlerocket_image_bucket  = "bottlerocket-images"
bottlerocket_image_object  = "bottlerocket-metal-k8s-1.31-x86_64-1.21.0.img"
node_count                 = 2
node_shape                 = "VM.Standard.E4.Flex"
node_ocpus                 = 2
node_memory_gbs            = 16
EOF

terraform apply
```

## Step 4 — Verify

Get a kubeconfig for the cluster:

```bash
oci ce cluster create-kubeconfig \
  --cluster-id $(terraform output -raw cluster_id) \
  --region <region> \
  --token-version 2.0.0 \
  --kube-endpoint PRIVATE_ENDPOINT \
  --file ~/.kube/config
```

Check that nodes are Ready:

```bash
kubectl get nodes -o wide
# NAME          STATUS   ROLES    OS-IMAGE                         ...
# 10.0.1.x      Ready    <none>   Bottlerocket OS 1.21.0 (...)    ...
```

Confirm the OS image:

```bash
kubectl get node <node-name> -o jsonpath='{.status.nodeInfo.osImage}'
# Bottlerocket OS 1.21.0 (aws-k8s-1.31)
```