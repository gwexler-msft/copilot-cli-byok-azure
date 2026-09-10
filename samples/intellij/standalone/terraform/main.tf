# IntelliJ BYOK bolt-on — Terraform route.
#
# Adds the dedicated /intellij API + policy to the customer's EXISTING Internal APIM and stands up
# the static-IP nginx proxy VM. Reuses the SAME shared assets as the Bicep route (no duplication):
#   ../policies/intellij-inference.xml, ../policies/intellij-models.xml   (APIM policies)
#   ../cloud-init.yaml / ../cloud-init.prebaked.yaml                      (proxy nginx bootstrap)
#   ../scripts/build-proxy-image.*                                        (Phase 6 pre-baked image)
#
# See README.md in this folder for the step-by-step.

data "azurerm_api_management" "apim" {
  name                = var.apim_name
  resource_group_name = var.apim_resource_group
}

data "azurerm_application_insights" "ai" {
  name                = var.app_insights_name
  resource_group_name = var.app_insights_resource_group
}

locals {
  # Named values the policies read via {{...}}. Empty optional values become a single space because
  # APIM rejects empty named values (1-4096 chars); both policies treat a whitespace sentinel/tier as
  # "off" (IsNullOrWhiteSpace), so 'auto' is a safe default that stays inert until mini+full are set.
  named_values = {
    "intellij-foundry-backend-id"    = { value = var.existing_backend_name, secret = false }
    "intellij-foundry-api-key"       = { value = var.foundry_api_key == "" ? " " : var.foundry_api_key, secret = true }
    "intellij-api-version"           = { value = var.api_version, secret = false }
    "intellij-auto-sentinel"         = { value = var.auto_route_sentinel == "" ? " " : var.auto_route_sentinel, secret = false }
    "intellij-auto-mini-deployment"  = { value = var.auto_route_mini_deployment == "" ? " " : var.auto_route_mini_deployment, secret = false }
    "intellij-auto-full-deployment"  = { value = var.auto_route_full_deployment == "" ? " " : var.auto_route_full_deployment, secret = false }
    "intellij-auto-length-threshold" = { value = tostring(var.auto_route_length_threshold), secret = false }
    "intellij-auto-ambiguous-band"   = { value = tostring(var.auto_route_ambiguous_band), secret = false }
    "intellij-metrics-enabled"       = { value = "true", secret = false }
  }

  operations = {
    "chat-completions" = { display = "Chat Completions", method = "POST", url = "/v1/chat/completions" }
    "completions"      = { display = "Completions", method = "POST", url = "/v1/completions" }
    "embeddings"       = { display = "Embeddings", method = "POST", url = "/v1/embeddings" }
    "responses"        = { display = "Responses", method = "POST", url = "/v1/responses" }
    "list-models"      = { display = "List Models", method = "GET", url = "/v1/models" }
  }

  # Bake the APIM private IP + gateway host into the shared cloud-init nginx config. When a pre-baked
  # image is supplied, use the config-only variant (no apt), mirroring proxy-vm.bicep.
  cloud_init = replace(replace(
    replace(
      var.proxy_image_id != "" ? file("${path.module}/../cloud-init.prebaked.yaml") : file("${path.module}/../cloud-init.yaml"),
      "__APIM_PRIVATE_IP__", var.apim_private_ip
    ),
    "__APIM_GATEWAY_HOST__", var.apim_gateway_host
  ), "__INTELLIJ_API_PATH__", var.intellij_api_path)
}
