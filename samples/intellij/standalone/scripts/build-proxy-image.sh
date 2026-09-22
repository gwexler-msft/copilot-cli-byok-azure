#!/usr/bin/env bash
# Build the pre-baked IntelliJ BYOK proxy VM image (Ubuntu 22.04 + nginx) into an Azure Compute
# Gallery, for AIR-GAPPED subnets where the VM cannot reach package mirrors at boot.
#
# Runs entirely with the Azure CLI (no Packer): spins up a throwaway build VM WITH egress, installs
# nginx, generalizes it, and captures a gallery image version. The build VM + temp RG are deleted at
# the end; the gallery image persists. Feed the image id into a deployment via `proxyImageId`.
#
# Requires: az.
#
# Usage:
#   ./build-proxy-image.sh -g rg-byok-images -r byokImages -l eastus
#   ./build-proxy-image.sh -g rg-byok-images -r byokImages -l usgovvirginia -s Standard_D2as_v6
set -euo pipefail

GALLERY_RG=""; GALLERY=""; LOCATION=""
IMG_DEF="byok-proxy-nginx"; IMG_VER="1.0.0"
BUILD_RG="rg-byok-imgbuild-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
BUILD_SIZE="Standard_D2as_v6"

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--gallery-rg) GALLERY_RG="$2"; shift 2 ;;
    -r|--gallery)    GALLERY="$2"; shift 2 ;;
    -l|--location)   LOCATION="$2"; shift 2 ;;
    -i|--image-def)  IMG_DEF="$2"; shift 2 ;;
    -v|--image-ver)  IMG_VER="$2"; shift 2 ;;
    -s|--build-size) BUILD_SIZE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

info() { printf '\033[36m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]  \033[0m %s\n' "$1"; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1" >&2; exit 1; }

command -v az >/dev/null 2>&1 || fail "Azure CLI (az) not found on PATH."
[ -n "$GALLERY_RG" ] && [ -n "$GALLERY" ] && [ -n "$LOCATION" ] || fail "Required: -g <gallery-rg> -r <gallery> -l <location>"
BUILD_VM="imgbuild-proxy"

cleanup() { info "== 6/6 Cleanup build resource group =="; az group delete -n "$BUILD_RG" --yes --no-wait -o none 2>/dev/null || true; ok "$BUILD_RG (deleting in background)"; }
trap cleanup EXIT

info "== 1/6 Build resource group =="
az group create -n "$BUILD_RG" -l "$LOCATION" -o none
ok "$BUILD_RG"

info "== 2/6 Build VM (with egress) =="
az vm create -g "$BUILD_RG" -n "$BUILD_VM" \
  --image 'Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest' \
  --size "$BUILD_SIZE" --admin-username builder --generate-ssh-keys \
  --security-type TrustedLaunch --public-ip-sku Standard -o none
ok "$BUILD_VM"

info "== 3/6 Install nginx + prep =="
# Single-line script (parity with the pwsh path, and avoids any CRLF/heredoc pitfalls that make the
# remote bash silently no-op). cloud-init clean (NOT waagent deprovision) preps for generalize;
# cloud-init regenerates SSH host keys + hostname on first boot.
PREP='set -e; export DEBIAN_FRONTEND=noninteractive; sudo apt-get update -qq >/dev/null 2>&1; sudo apt-get install -y -qq nginx >/dev/null 2>&1; sudo rm -f /etc/nginx/sites-enabled/default; sudo rm -f /etc/nginx/conf.d/byok-proxy.conf; sudo systemctl enable nginx >/dev/null 2>&1; sudo cloud-init clean --logs >/dev/null 2>&1 || true; sudo rm -f /home/builder/.ssh/authorized_keys || true; echo INSTALLED=$(command -v nginx)'
MSG="$(az vm run-command invoke -g "$BUILD_RG" -n "$BUILD_VM" --command-id RunShellScript --scripts "$PREP" --query "value[0].message" -o tsv)"
echo "$MSG" | grep -q 'INSTALLED=/usr/sbin/nginx' || { echo "$MSG"; fail "nginx install failed (not present in image)."; }
ok "nginx installed"

info "== 4/6 Deallocate + generalize =="
az vm deallocate -g "$BUILD_RG" -n "$BUILD_VM" -o none
az vm generalize -g "$BUILD_RG" -n "$BUILD_VM" -o none
VM_ID="$(az vm show -g "$BUILD_RG" -n "$BUILD_VM" --query id -o tsv)"
ok "generalized"

info "== 5/6 Gallery + image definition + version =="
az group create -n "$GALLERY_RG" -l "$LOCATION" -o none
az sig show -g "$GALLERY_RG" -r "$GALLERY" -o none 2>/dev/null || az sig create -g "$GALLERY_RG" -r "$GALLERY" -l "$LOCATION" -o none
az sig image-definition show -g "$GALLERY_RG" -r "$GALLERY" -i "$IMG_DEF" -o none 2>/dev/null || \
  az sig image-definition create -g "$GALLERY_RG" -r "$GALLERY" -i "$IMG_DEF" \
    --publisher byok --offer intellij-proxy --sku ubuntu2204-nginx \
    --os-type Linux --os-state Generalized --hyper-v-generation V2 --features 'SecurityType=TrustedLaunch DiskControllerTypes=SCSI,NVMe' -o none
az sig image-version create -g "$GALLERY_RG" -r "$GALLERY" -i "$IMG_DEF" \
  --gallery-image-version "$IMG_VER" --virtual-machine "$VM_ID" --target-regions "$LOCATION" -o none
IMG_ID="$(az sig image-version show -g "$GALLERY_RG" -r "$GALLERY" -i "$IMG_DEF" -e "$IMG_VER" --query id -o tsv)"
ok "image version created"

info $'\n== Done =='
echo "Pre-baked proxy image:"
echo "  $IMG_ID"
echo ""
echo "Use it by setting this in your deployment params (or --proxy-image-id):"
echo "  \"proxyImageId\": { \"value\": \"$IMG_ID\" }"
