#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build the pre-baked IntelliJ BYOK proxy VM image (Ubuntu 22.04 + nginx) into an Azure Compute
  Gallery, for AIR-GAPPED subnets where the VM cannot reach package mirrors at boot.

.DESCRIPTION
  Runs ENTIRELY with the Azure CLI (no Packer). It spins up a throwaway build VM in a subscription
  WITH egress, installs nginx, generalizes it, and captures a gallery image version. The build VM
  and its temp resource group are deleted at the end; the gallery image persists.

  Feed the resulting image id into a deployment via the `proxyImageId` parameter (the proxy VM then
  boots from it and only writes the nginx config — no apt). Build once per cloud/region; replicate
  the version to more regions with `az sig image-version update --target-regions` as needed.

.EXAMPLE
  ./build-proxy-image.ps1 -GalleryResourceGroup rg-byok-images -GalleryName byokImages -Location eastus
  ./build-proxy-image.ps1 -GalleryResourceGroup rg-byok-images -GalleryName byokImages -Location usgovvirginia -BuildVmSize Standard_D2as_v6
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$GalleryResourceGroup,
  [Parameter(Mandatory)] [string]$GalleryName,
  [Parameter(Mandatory)] [string]$Location,
  [string]$ImageDefinition = 'byok-proxy-nginx',
  [string]$ImageVersion = '1.0.0',
  [string]$BuildResourceGroup = "rg-byok-imgbuild-$([guid]::NewGuid().ToString('N').Substring(0,6))",
  [string]$BuildVmSize = 'Standard_D2as_v6'
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Fail 'Azure CLI (az) not found on PATH.' }
$buildVm = 'imgbuild-proxy'

Info "== 1/6 Build resource group =="
az group create -n $BuildResourceGroup -l $Location -o none; if ($LASTEXITCODE) { Fail 'group create failed.' }
Ok "$BuildResourceGroup"

try {
  Info "== 2/6 Build VM (with egress) =="
  # Default network gives the build VM outbound internet. TrustedLaunch gen2 (the modern default,
  # needs no feature registration); the gallery image + deploy VM are TrustedLaunch to match.
  az vm create -g $BuildResourceGroup -n $buildVm `
    --image 'Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest' `
    --size $BuildVmSize --admin-username builder --generate-ssh-keys `
    --security-type TrustedLaunch --public-ip-sku Standard -o none
  if ($LASTEXITCODE) { Fail 'vm create failed.' }
  Ok "$buildVm"

  Info "== 3/6 Install nginx + prep =="
  # IMPORTANT: single-line script. A multi-line PowerShell here-string carries CRLF line endings,
  # which break bash on the VM (`set -e\r` etc.), so the install silently no-ops. Keep it one line.
  # Generalization prep uses cloud-init clean (NOT `waagent -deprovision`, which hangs the channel);
  # cloud-init regenerates SSH host keys + hostname on first boot.
  $prep = 'set -e; export DEBIAN_FRONTEND=noninteractive; sudo apt-get update -qq >/dev/null 2>&1; sudo apt-get install -y -qq nginx >/dev/null 2>&1; sudo rm -f /etc/nginx/sites-enabled/default; sudo rm -f /etc/nginx/conf.d/byok-proxy.conf; sudo systemctl enable nginx >/dev/null 2>&1; sudo cloud-init clean --logs >/dev/null 2>&1 || true; sudo rm -f /home/builder/.ssh/authorized_keys || true; echo INSTALLED=$(command -v nginx)'
  $msg = az vm run-command invoke -g $BuildResourceGroup -n $buildVm --command-id RunShellScript --scripts $prep --query "value[0].message" -o tsv
  # az returns the multi-line message as a string[]; join before matching (-notlike on an array filters).
  if (($msg -join "`n") -notlike '*INSTALLED=/usr/sbin/nginx*') { Write-Host $msg; Fail 'nginx install failed (not present in image).' }
  Ok 'nginx installed'

  Info "== 4/6 Deallocate + generalize =="
  az vm deallocate -g $BuildResourceGroup -n $buildVm -o none
  az vm generalize -g $BuildResourceGroup -n $buildVm -o none
  if ($LASTEXITCODE) { Fail 'generalize failed.' }
  $vmId = az vm show -g $BuildResourceGroup -n $buildVm --query id -o tsv
  Ok 'generalized'

  Info "== 5/6 Gallery + image definition + version =="
  az group create -n $GalleryResourceGroup -l $Location -o none; if ($LASTEXITCODE) { Fail 'gallery group create failed.' }
  az sig show -g $GalleryResourceGroup -r $GalleryName -o none 2>$null
  if ($LASTEXITCODE) { az sig create -g $GalleryResourceGroup -r $GalleryName -l $Location -o none }
  az sig image-definition show -g $GalleryResourceGroup -r $GalleryName -i $ImageDefinition -o none 2>$null
  if ($LASTEXITCODE) {
    az sig image-definition create -g $GalleryResourceGroup -r $GalleryName -i $ImageDefinition `
      --publisher byok --offer intellij-proxy --sku ubuntu2204-nginx `
      --os-type Linux --os-state Generalized --hyper-v-generation V2 --features 'SecurityType=TrustedLaunch DiskControllerTypes=SCSI,NVMe' -o none
  }
  az sig image-version create -g $GalleryResourceGroup -r $GalleryName -i $ImageDefinition `
    --gallery-image-version $ImageVersion --virtual-machine $vmId --target-regions $Location -o none
  if ($LASTEXITCODE) { Fail 'image-version create failed.' }
  $imgId = az sig image-version show -g $GalleryResourceGroup -r $GalleryName -i $ImageDefinition -e $ImageVersion --query id -o tsv
  Ok 'image version created'
}
finally {
  Info "== 6/6 Cleanup build resource group =="
  az group delete -n $BuildResourceGroup --yes --no-wait -o none 2>$null
  Ok "$BuildResourceGroup (deleting in background)"
}

Info "`n== Done =="
Write-Host "Pre-baked proxy image:"
Write-Host "  $imgId"
Write-Host ""
Write-Host "Use it by setting this in your deployment params (or -proxyImageId):"
Write-Host "  \"proxyImageId\": { \"value\": \"$imgId\" }"
