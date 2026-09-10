# ---- Proxy VM resource group (created only when create_vm_resource_group=true) ------------------
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "vm" {
  count    = var.create_vm_resource_group ? 1 : 0
  name     = var.vm_resource_group
  location = var.location
}

locals {
  proxy_nic_id_parts = var.proxy_nic_id == "" ? [] : split("/", trim(var.proxy_nic_id, "/"))
  expected_proxy_vm_id = format(
    "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/virtualMachines/%s",
    data.azurerm_client_config.current.subscription_id,
    var.vm_resource_group,
    var.vm_name,
  )
}

data "azurerm_network_interface" "proxy" {
  count = var.proxy_nic_id == "" ? 0 : 1

  name                = local.proxy_nic_id_parts[7]
  resource_group_name = local.proxy_nic_id_parts[3]
}

# ---- NIC with a STATIC private IP, no public IP -------------------------------------------------
resource "azurerm_network_interface" "proxy" {
  count = var.proxy_nic_id == "" ? 1 : 0

  name                = "nic-${var.vm_name}"
  location            = var.location
  resource_group_name = var.vm_resource_group
  depends_on          = [azurerm_resource_group.vm]

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.vm_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.proxy_static_private_ip
  }
}

moved {
  from = azurerm_network_interface.proxy
  to   = azurerm_network_interface.proxy[0]
}

# ---- The proxy VM -------------------------------------------------------------------------------
# Marketplace path (proxy_image_id empty): Ubuntu 22.04 gen2 + install nginx at boot (cloud-init.yaml),
# platform-managed patching. Pre-baked path (proxy_image_id set): boot the TrustedLaunch gallery image
# (nginx already installed) with the config-only cloud-init; patch via new image versions.
resource "azurerm_linux_virtual_machine" "proxy" {
  name                = var.vm_name
  resource_group_name = var.vm_resource_group
  location            = var.location
  size                = var.vm_size
  admin_username      = var.vm_admin_username
  network_interface_ids = [
    var.proxy_nic_id == "" ? azurerm_network_interface.proxy[0].id : data.azurerm_network_interface.proxy[0].id
  ]
  disable_password_authentication = true
  custom_data                     = base64encode(local.cloud_init)

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.vm_admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  # Gallery image (pre-baked) vs Ubuntu marketplace.
  source_image_id = var.proxy_image_id != "" ? var.proxy_image_id : null

  dynamic "source_image_reference" {
    for_each = var.proxy_image_id == "" ? [1] : []
    content {
      publisher = "Canonical"
      offer     = "0001-com-ubuntu-server-jammy"
      sku       = "22_04-lts-gen2"
      version   = "latest"
    }
  }

  # The pre-baked image is built TrustedLaunch (see ../scripts/build-proxy-image.*), so match it.
  secure_boot_enabled = var.proxy_image_id != "" ? true : null
  vtpm_enabled        = var.proxy_image_id != "" ? true : null

  # Captured images aren't registered for platform guest-patching -> ImageDefault on that path.
  patch_mode            = var.proxy_image_id != "" ? "ImageDefault" : "AutomaticByPlatform"
  patch_assessment_mode = var.proxy_image_id != "" ? "ImageDefault" : "AutomaticByPlatform"

  depends_on = [azurerm_resource_group.vm]

  lifecycle {
    precondition {
      condition     = var.proxy_nic_id != "" || var.vm_subnet_id != ""
      error_message = "vm_subnet_id is required when proxy_nic_id is empty."
    }
    precondition {
      condition     = var.proxy_nic_id == "" ? true : lower(local.proxy_nic_id_parts[1]) == lower(data.azurerm_client_config.current.subscription_id)
      error_message = "The supplied proxy NIC must be in the active AzureRM subscription."
    }
    precondition {
      condition     = var.proxy_nic_id == "" ? true : length(data.azurerm_network_interface.proxy[0].ip_configuration) == 1
      error_message = "The supplied proxy NIC must have exactly one IP configuration."
    }
    precondition {
      condition     = var.proxy_nic_id == "" ? true : data.azurerm_network_interface.proxy[0].ip_configuration[0].subnet_id != ""
      error_message = "The supplied proxy NIC must be attached to a subnet."
    }
    precondition {
      condition     = var.proxy_nic_id == "" ? true : lower(data.azurerm_network_interface.proxy[0].location) == lower(var.location)
      error_message = "The supplied proxy NIC must be in the same Azure region as the proxy VM."
    }
    precondition {
      condition     = var.proxy_nic_id == "" ? true : data.azurerm_network_interface.proxy[0].private_ip_address == var.proxy_static_private_ip
      error_message = "proxy_static_private_ip must match the supplied proxy NIC's private IP."
    }
    precondition {
      condition     = var.proxy_nic_id == "" ? true : data.azurerm_network_interface.proxy[0].ip_configuration[0].private_ip_address_allocation == "Static"
      error_message = "The supplied proxy NIC must use static private IP allocation."
    }
    precondition {
      condition     = var.proxy_nic_id == "" ? true : data.azurerm_network_interface.proxy[0].ip_configuration[0].public_ip_address_id == ""
      error_message = "The supplied proxy NIC must not have a public IP address."
    }
    precondition {
      condition = var.proxy_nic_id == "" ? true : (
        data.azurerm_network_interface.proxy[0].virtual_machine_id == "" ||
        lower(data.azurerm_network_interface.proxy[0].virtual_machine_id) == lower(local.expected_proxy_vm_id)
      )
      error_message = "The supplied proxy NIC is already attached to a different VM."
    }
  }
}
