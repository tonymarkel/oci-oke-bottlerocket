output "cluster_id" {
  description = "OCID of the OKE cluster."
  value       = oci_containerengine_cluster.oke.id
}

output "cluster_kubernetes_version" {
  description = "Kubernetes version running on the cluster."
  value       = oci_containerengine_cluster.oke.kubernetes_version
}

output "cluster_private_endpoint" {
  description = "Private API server endpoint for the OKE cluster."
  value       = oci_containerengine_cluster.oke.endpoints[0].private_endpoint
}

output "node_pool_id" {
  description = "OCID of the Bottlerocket node pool."
  value       = oci_containerengine_node_pool.bottlerocket.id
}

output "bottlerocket_image_id" {
  description = "OCID of the imported Bottlerocket custom image."
  value       = oci_core_image.bottlerocket.id
}

output "vcn_id" {
  description = "OCID of the VCN."
  value       = oci_core_vcn.vcn.id
}