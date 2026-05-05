#!/bin/bash
# Downloads a Bottlerocket metal-k8s image from GitHub releases, decompresses
# it from .lz4 to a raw disk image, and uploads it to OCI Object Storage.
#
# Prerequisites: curl, lz4, oci CLI (configured with credentials)
#
# Usage:
#   ./scripts/prepare-image.sh <k8s-version> <br-version> <oci-namespace> <bucket>
#
# Example:
#   ./scripts/prepare-image.sh 1.31 1.21.0 mynamespace bottlerocket-images

set -euo pipefail

K8S_VERSION="${1:?Usage: $0 <k8s-version> <br-version> <oci-namespace> <bucket>}"
BR_VERSION="${2:?}"
OCI_NAMESPACE="${3:?}"
BUCKET="${4:?}"

ARCH="x86_64"
VARIANT="metal-k8s-${K8S_VERSION}"
IMAGE_BASE="bottlerocket-${VARIANT}-${ARCH}-${BR_VERSION}"
LZ4_FILE="${IMAGE_BASE}.img.lz4"
RAW_FILE="${IMAGE_BASE}.img"
DOWNLOAD_URL="https://github.com/bottlerocket-os/bottlerocket/releases/download/v${BR_VERSION}/${LZ4_FILE}"
TMPDIR="${TMPDIR:-/tmp}"

echo "==> Downloading Bottlerocket ${BR_VERSION} (${VARIANT}, ${ARCH})..."
echo "    URL: ${DOWNLOAD_URL}"
curl -fL --progress-bar -o "${TMPDIR}/${LZ4_FILE}" "${DOWNLOAD_URL}"

echo "==> Decompressing ${LZ4_FILE}..."
# lz4 -d: decompress; will fail if output already exists unless -f is given
lz4 -d -f "${TMPDIR}/${LZ4_FILE}" "${TMPDIR}/${RAW_FILE}"
rm -f "${TMPDIR}/${LZ4_FILE}"

echo "==> Uploading ${RAW_FILE} to OCI Object Storage (bucket: ${BUCKET})..."
oci os object put \
  --namespace "${OCI_NAMESPACE}" \
  --bucket-name "${BUCKET}" \
  --name "${RAW_FILE}" \
  --file "${TMPDIR}/${RAW_FILE}" \
  --no-multipart \
  --force

rm -f "${TMPDIR}/${RAW_FILE}"

echo ""
echo "Done. Set these Terraform variables before running terraform apply:"
echo ""
echo "  bottlerocket_image_bucket = \"${BUCKET}\""
echo "  bottlerocket_image_object = \"${RAW_FILE}\""
echo ""
echo "Or in terraform.tfvars:"
echo "  bottlerocket_image_bucket = \"${BUCKET}\""
echo "  bottlerocket_image_object = \"${RAW_FILE}\""