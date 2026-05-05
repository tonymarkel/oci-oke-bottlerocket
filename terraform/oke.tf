resource "oci_containerengine_cluster" "oke" {
  compartment_id     = var.compartment_id
  name               = var.cluster_name
  kubernetes_version = "v${var.kubernetes_version}"
  vcn_id             = oci_core_vcn.vcn.id
  type               = "BASIC_CLUSTER"

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

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }
}