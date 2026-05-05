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
    # Bottlerocket reads this field as its TOML userdata via early-boot-config.
    user_data = local.bottlerocket_userdata
  }
}