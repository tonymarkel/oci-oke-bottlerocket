variable "compartment_id" {
  description = "OCID of the compartment to deploy resources into."
  type        = string
}

variable "region" {
  description = "OCI region identifier (e.g. us-ashburn-1)."
  type        = string
}

variable "cluster_name" {
  description = "Display name for the OKE cluster and node pool."
  type        = string
  default     = "oke-bottlerocket"
}

variable "kubernetes_version" {
  description = "Kubernetes version string without 'v' prefix (e.g. 1.31)."
  type        = string
  default     = "1.31"
}

variable "bottlerocket_version" {
  description = "Bottlerocket OS release version (e.g. 1.21.0). Used only in image display name."
  type        = string
  default     = "1.21.0"
}

# -------------------------------------------------------------------
# Bottlerocket image — must be uploaded to Object Storage first via
# scripts/prepare-image.sh before running terraform apply.
# -------------------------------------------------------------------
variable "bottlerocket_image_bucket" {
  description = "Name of the OCI Object Storage bucket containing the Bottlerocket RAW image."
  type        = string
}

variable "bottlerocket_image_object" {
  description = "Object name of the Bottlerocket RAW image in the bucket (e.g. bottlerocket-metal-k8s-1.31-x86_64-1.21.0.img)."
  type        = string
}

# -------------------------------------------------------------------
# Bootstrap container
# -------------------------------------------------------------------
variable "bootstrap_image_tag" {
  description = "Tag of ghcr.io/tonymarkel/oke-bottlerocket-bootstrap to use."
  type        = string
  default     = "latest"
}

# -------------------------------------------------------------------
# Node pool sizing
# -------------------------------------------------------------------
variable "node_count" {
  description = "Number of worker nodes in the Bottlerocket node pool."
  type        = number
  default     = 2
}

variable "node_shape" {
  description = "OCI compute shape for worker nodes."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "node_ocpus" {
  description = "Number of OCPUs per worker node (Flex shapes only)."
  type        = number
  default     = 2
}

variable "node_memory_gbs" {
  description = "Memory in GB per worker node (Flex shapes only)."
  type        = number
  default     = 16
}

# -------------------------------------------------------------------
# Networking — CIDR blocks
# -------------------------------------------------------------------
variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "control_plane_subnet_cidr" {
  type    = string
  default = "10.0.0.0/28"
}

variable "worker_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "lb_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}