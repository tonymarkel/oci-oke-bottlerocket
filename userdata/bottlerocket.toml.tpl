# Bottlerocket userdata for OKE managed node pool integration.
#
# The bootstrap container (oke-init) runs before kubelet starts and populates
# kubernetes.api-server, kubernetes.cluster-certificate, and
# kubernetes.bootstrap-token by reading from the OCI instance metadata service.
#
# Template variables (filled in by Terraform templatefile()):
#   cluster_name        - OKE cluster display name, used as kubelet cluster-name
#   bootstrap_image_tag - tag for ghcr.io/tonymarkel/oke-bottlerocket-bootstrap
[settings.bootstrap-containers.oke-init]
source    = "ghcr.io/tonymarkel/oke-bottlerocket-bootstrap:${bootstrap_image_tag}"
mode      = "once"
essential = true
[settings.kubernetes]
cluster-name = "${cluster_name}"
# api-server, cluster-certificate, and bootstrap-token are set at runtime
# by the oke-init bootstrap container via apiclient.
[settings.host-containers.admin]
# Disable the interactive admin container in production.
# Set to true temporarily for debugging bootstrap failures.
enabled = false
[settings.ntp]
time-servers = ["169.254.169.254"]