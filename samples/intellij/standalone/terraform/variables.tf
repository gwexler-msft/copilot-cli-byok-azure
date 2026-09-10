# ---- Cloud / provider ---------------------------------------------------------------------------
variable "arm_environment" {
  description = "Azure cloud for the azurerm provider: public | usgovernment | china | german."
  type        = string
  default     = "public"
}

# ---- Existing APIM (the /intellij API + policy are added here) -----------------------------------
variable "apim_resource_group" {
  description = "Resource group of the customer's existing APIM."
  type        = string
}

variable "apim_name" {
  description = "Name of the customer's existing (Internal) APIM service."
  type        = string
}

variable "existing_backend_name" {
  description = "Name of the EXISTING Foundry backend entity in APIM (reused via set-backend-service)."
  type        = string
}

variable "foundry_api_key" {
  description = "Foundry api-key the bolt-on uses to reach the EXISTING Foundry backend. REQUIRED unless that backend entity already carries its own credential — the bolt-on authenticates by api-key only and does NOT use managed identity (unlike the standard BYOK deployment). Empty when required => Foundry returns 401 'Access denied due to invalid subscription key or wrong API endpoint'. Pass via TF_VAR_foundry_api_key; keep out of VCS."
  type        = string
  default     = ""
  sensitive   = true
}

variable "api_version" {
  description = "api-version pinned on deployment-scoped Foundry calls."
  type        = string
  default     = "2025-04-01-preview"
}

variable "intellij_api_path" {
  description = "Path segment for the dedicated API (client base = https://<apim>/<path>/v1)."
  type        = string
  default     = "intellij"
}

variable "existing_product_name" {
  description = "OPTIONAL primary existing APIM product whose subscription keys the IntelliJ users have. Empty with no additional products = all-APIs-scope keys."
  type        = string
  default     = ""
}

variable "additional_product_names" {
  description = "Additional existing APIM products whose subscription keys must also authorize the /intellij API (for example, standard + power tiers)."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for name in var.additional_product_names : trimspace(name) != ""])
    error_message = "additional_product_names cannot contain empty product names."
  }
}

# ---- Auto-route (on by default; activates only when mini + full are set) -------------------------
variable "auto_route_sentinel" {
  description = "Auto-route sentinel model value(s), comma-separated. Empty disables tiering."
  type        = string
  default     = "auto"
}

variable "auto_route_mini_deployment" {
  description = "Foundry deployment for the cheap (mini) tier. Blank leaves auto-route inert."
  type        = string
  default     = ""
}

variable "auto_route_full_deployment" {
  description = "Foundry deployment for the full tier. Blank leaves auto-route inert."
  type        = string
  default     = ""
}

variable "auto_route_length_threshold" {
  description = "Auto-route Level-1 prompt-length threshold (chars)."
  type        = number
  default     = 500
}

variable "auto_route_ambiguous_band" {
  description = "Auto-route Level-1 half-width of the ambiguous band."
  type        = number
  default     = 200
}

# ---- Metrics: reuse an EXISTING Application Insights (none is created) ---------------------------
variable "app_insights_name" {
  description = "Name of an EXISTING Application Insights to send /intellij request + token metrics to."
  type        = string
}

variable "app_insights_resource_group" {
  description = "Resource group of that Application Insights (may differ from APIM's)."
  type        = string
}

# ---- Proxy VM -----------------------------------------------------------------------------------
variable "location" {
  description = "Azure region for the proxy VM + its resource group."
  type        = string
}

variable "vm_resource_group" {
  description = "Resource group for the proxy VM. Created when create_vm_resource_group=true; otherwise it must already exist (point it at any RG you have Contributor on — e.g. the APIM RG to keep everything in one RG)."
  type        = string
}

variable "create_vm_resource_group" {
  description = "Create vm_resource_group (true) or deploy the VM into an EXISTING RG (false). Set false + vm_resource_group=<apim RG> to deploy everything into one RG."
  type        = bool
  default     = true
}

variable "vm_subnet_id" {
  description = "Resource id of the EXISTING subnet for a deployment-created NIC. Required when proxy_nic_id is empty; ignored when a customer NIC is supplied."
  type        = string
  default     = ""
}

variable "proxy_nic_id" {
  description = "OPTIONAL full resource ID of a customer-created NIC. When set, Terraform attaches it to the proxy VM and creates no NIC. The NIC remains customer-owned and is not managed as a Terraform resource."
  type        = string
  default     = ""

  validation {
    condition     = var.proxy_nic_id == "" || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/networkInterfaces/[^/]+$", var.proxy_nic_id))
    error_message = "proxy_nic_id must be empty or a full Microsoft.Network/networkInterfaces resource ID."
  }
}

variable "proxy_static_private_ip" {
  description = "The STATIC private IP to assign the proxy (a free address in that subnet)."
  type        = string
}

variable "apim_private_ip" {
  description = "Private IP of the customer Internal APIM (nginx connects here directly — no DNS)."
  type        = string
}

variable "apim_gateway_host" {
  description = "APIM gateway hostname (Host header + TLS SNI when forwarding by IP)."
  type        = string
}

variable "vm_admin_username" {
  description = "Admin username for the proxy VM."
  type        = string
  default     = "byokadmin"
}

variable "vm_admin_ssh_public_key" {
  description = "SSH public key for the proxy VM admin (password auth disabled)."
  type        = string
}

variable "vm_size" {
  description = "Proxy VM size. B2s is plenty; some regions (e.g. usgovvirginia) need a v6 size like Standard_D2as_v6."
  type        = string
  default     = "Standard_B2s"
}

variable "vm_name" {
  description = "Proxy VM name."
  type        = string
  default     = "vm-byok-intellij-proxy"
}

variable "proxy_image_id" {
  description = "OPTIONAL Azure Compute Gallery image version id (nginx pre-installed) for air-gapped subnets. Build it with ../scripts/build-proxy-image.*; empty = install nginx at boot from the Ubuntu marketplace image."
  type        = string
  default     = ""
}
