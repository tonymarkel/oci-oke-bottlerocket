# Import a Bottlerocket metal-k8s RAW disk image from OCI Object Storage.
#
# Before running terraform apply, upload the image via:
#   ./scripts/prepare-image.sh <k8s-version> <br-version> <oci-namespace> <bucket>
#
# The import takes 10–30 minutes; Terraform waits for it to complete.

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
    create = "40m"
  }
}