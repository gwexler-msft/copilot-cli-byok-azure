variable "caller_auth_rollout" {
  type    = string
  default = "legacy"
  validation {
    condition     = contains(["legacy", "shared", "coexistence"], var.caller_auth_rollout)
    error_message = "caller_auth_rollout must be legacy, shared or coexistence."
  }
}

variable "caller_auth_preparation" {
  type = object({
    enabled   = bool, keyEnabled = bool, entraEnabled = bool, entraClientIds = list(string), jwtProductId = string
    oktaTrust = object({ enabled = bool, issuer = string, openIdConfigUrl = string, audience = string, requiredScope = string, clientIds = list(string) })
  })
  default = {
    enabled   = false, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
    oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
  }
}

variable "caller_policy_package" {
  type    = string
  default = "../caller-policies.json"
}

variable "caller_jwt_tiering" {
  type = object({
    entra = object({ enabled = bool, mappings = list(object({ claimValue = string, tier = string })) })
    okta  = object({ enabled = bool, claimName = string, mappings = list(object({ claimValue = string, tier = string })) })
  })
  default = {
    entra = { enabled = false, mappings = [] }
    okta  = { enabled = false, claimName = "byok_tier", mappings = [] }
  }
  nullable = false
  validation {
    condition = try(
      alltrue([for provider in [var.caller_jwt_tiering.entra, var.caller_jwt_tiering.okta] :
        provider.enabled != null && length(provider.mappings) <= 16 && (!provider.enabled || length(provider.mappings) > 0) &&
        length(distinct([for mapping in provider.mappings : mapping.claimValue])) == length(provider.mappings) &&
        alltrue([for mapping in provider.mappings : can(regex("^[A-Za-z][A-Za-z0-9_.:-]{0,127}$", mapping.claimValue)) && can(regex("^[a-z][a-z0-9-]{0,79}$", mapping.tier))])
      ]) && can(regex("^[A-Za-z][A-Za-z0-9_.-]{0,63}$", var.caller_jwt_tiering.okta.claimName)) &&
      !contains(["iss", "aud", "sub", "uid", "cid", "scp", "exp", "nbf", "iat", "jti", "azp", "tid", "oid", "idtyp"], var.caller_jwt_tiering.okta.claimName),
      false
    )
    error_message = "JWT tier settings require explicit flags, a safe entitlement claim and at most sixteen unique claim mappings per issuer."
  }
}

variable "product_tiers" {
  description = "Reviewed catalog from the existing gateway deployment. This bolt-on reuses its tier numbers without modifying native product policies."
  type = list(object({
    name             = string
    callsPerMinute   = number
    tokensPerMinute  = number
    monthlyCallQuota = number
  }))
  default  = []
  nullable = false
  validation {
    condition = try(length(var.product_tiers) <= 8 &&
      length(distinct([for tier in var.product_tiers : tier.name])) == length(var.product_tiers) &&
      alltrue([for tier in var.product_tiers : can(regex("^[a-z][a-z0-9-]{0,79}$", tier.name)) &&
        alltrue([for limit in [tier.callsPerMinute, tier.tokensPerMinute, tier.monthlyCallQuota] : limit >= 1 && limit <= 2147483647 && limit == floor(limit)])
    ]), false)
    error_message = "The shared tier catalog allows at most eight unique tiers with positive integer ceilings no greater than 2147483647."
  }
}

variable "entra_tenant_id" {
  type    = string
  default = ""
}
variable "api_audience" {
  type    = string
  default = ""
}
variable "required_scope" {
  type    = string
  default = "cli.invoke"
}
variable "existing_backend_origin" {
  type    = string
  default = ""
}
variable "foundry_auth_mode" {
  type    = string
  default = "apiKey"
  validation {
    condition     = contains(["apiKey", "managedIdentity"], var.foundry_auth_mode)
    error_message = "foundry_auth_mode must be apiKey or managedIdentity."
  }
}
variable "response_owner_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "response_owner_previous_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "jwt_limits" {
  type    = object({ calls_per_minute = number, tokens_per_minute = number, monthly_calls = number })
  default = { calls_per_minute = 120, tokens_per_minute = 200000, monthly_calls = 200000 }
  validation {
    condition     = alltrue([for limit in values(var.jwt_limits) : limit > 0 && limit == floor(limit)])
    error_message = "JWT limits must be positive integers."
  }
}

locals {
  shared_caller_auth     = var.caller_auth_rollout != "legacy"
  caller_enabled         = var.caller_auth_preparation.enabled
  caller_key_required    = !local.shared_caller_auth || var.caller_auth_preparation.keyEnabled
  caller_trust           = var.caller_auth_preparation
  caller_okta            = local.caller_trust.oktaTrust
  caller_package         = local.caller_enabled ? jsondecode(file(var.caller_policy_package)).parameters.callerPackage.value : null
  caller_tiering_enabled = var.caller_jwt_tiering.entra.enabled || var.caller_jwt_tiering.okta.enabled
  caller_tiering_valid = !local.caller_tiering_enabled || try(
    local.shared_caller_auth && local.caller_enabled && length(var.product_tiers) > 0 &&
    (!var.caller_jwt_tiering.entra.enabled || local.caller_trust.entraEnabled) &&
    (!var.caller_jwt_tiering.okta.enabled || local.caller_okta.enabled) &&
    !contains([for tier in var.product_tiers : lower(tier.name)], lower(local.caller_trust.jwtProductId)) &&
    alltrue([for mapping in concat(var.caller_jwt_tiering.entra.mappings, var.caller_jwt_tiering.okta.mappings) : contains([for tier in var.product_tiers : tier.name], mapping.tier)]) &&
    local.caller_package.tiering.version == 1 &&
    strcontains(local.caller_package.tiering.policyTemplate, "__BYOK_JWT_TIERING_CONFIG__") &&
    strcontains(local.caller_package.tiering.policyTemplate, "__BYOK_JWT_TIER_BRANCHES__") &&
    strcontains(local.caller_package.tiering.branchTemplate, "__BYOK_TIER_NAME__"), false
  )
  caller_tier_configuration = base64encode(jsonencode({
    version = 1
    tiers   = [for tier in var.product_tiers : tier.name]
    entra   = merge(var.caller_jwt_tiering.entra, { claimName = "roles" })
    okta    = var.caller_jwt_tiering.okta
  }))
  caller_tier_branches = local.caller_tiering_enabled ? [for tier in var.product_tiers : try(replace(replace(replace(replace(
    local.caller_package.tiering.branchTemplate, "__BYOK_TIER_NAME__", base64encode(tier.name)),
    "{{jwt-calls-per-minute}}", tostring(tier.callsPerMinute)), "{{jwt-tokens-per-minute}}", tostring(tier.tokensPerMinute)),
  "{{jwt-monthly-call-quota}}", tostring(tier.monthlyCallQuota)), "")] : []
  caller_limits_policy = local.caller_tiering_enabled ? try(replace(replace(
    local.caller_package.tiering.policyTemplate, "__BYOK_JWT_TIERING_CONFIG__", local.caller_tier_configuration),
  "__BYOK_JWT_TIER_BRANCHES__", join("", local.caller_tier_branches)), "") : try(local.caller_package.fragments["byok-apply-caller-limits"], "")
  caller_login_host   = var.arm_environment == "usgovernment" ? "login.microsoftonline.us" : "login.microsoftonline.com"
  caller_issuer       = "https://${local.caller_login_host}/${var.entra_tenant_id}/v2.0"
  caller_guid_pattern = "^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"
  owner_key_pattern   = "^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$"
  caller_zero_guid    = "00000000-0000-0000-0000-000000000000"
  caller_entra_valid = !local.caller_trust.entraEnabled || (
    alltrue([for identifier in concat([var.entra_tenant_id, var.api_audience], local.caller_trust.entraClientIds) : can(regex(local.caller_guid_pattern, identifier)) && identifier != local.caller_zero_guid]) &&
    can(regex("^[A-Za-z0-9._-]{1,128}$", var.required_scope)) &&
    alltrue([for client in local.caller_trust.entraClientIds : client != var.api_audience]) &&
    length(distinct(local.caller_trust.entraClientIds)) == length(local.caller_trust.entraClientIds) && length(join(",", local.caller_trust.entraClientIds)) <= 4096
  )
  caller_okta_valid = !local.caller_okta.enabled || (
    can(regex("^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}(:443)?/oauth2/[A-Za-z0-9_-]+$", local.caller_okta.issuer)) &&
    !can(regex("\\.(invalid|localhost)(:443)?/oauth2/", local.caller_okta.issuer)) &&
    local.caller_okta.openIdConfigUrl == "${local.caller_okta.issuer}/.well-known/openid-configuration" &&
    can(regex("^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$", local.caller_okta.audience)) &&
    can(regex("^[A-Za-z0-9._-]{1,128}$", local.caller_okta.requiredScope)) && length(local.caller_okta.clientIds) > 0 &&
    length(distinct(local.caller_okta.clientIds)) == length(local.caller_okta.clientIds) && length(join(",", local.caller_okta.clientIds)) <= 4096 &&
    alltrue([for client in local.caller_okta.clientIds : can(regex("^[A-Za-z0-9_-]{1,128}$", client)) && !contains(["__any__", "__none__", local.caller_okta.audience], client)])
  )
  caller_configuration_valid = contains(["public", "usgovernment"], var.arm_environment) && local.caller_entra_valid && local.caller_okta_valid && (
    local.caller_trust.keyEnabled || local.caller_trust.entraEnabled || local.caller_okta.enabled
    ) && can(regex("^[A-Za-z0-9_-]{1,80}$", local.caller_trust.jwtProductId)) && !contains(
    [for product in concat([var.existing_product_name], tolist(var.additional_product_names)) : lower(product)], lower(local.caller_trust.jwtProductId)
  )
  caller_settings = {
    "caller-configuration-valid"          = tostring(local.caller_configuration_valid)
    "caller-key-enabled"                  = tostring(local.caller_trust.keyEnabled)
    "caller-native-subscription-required" = tostring(local.caller_trust.keyEnabled)
    "caller-entra-enabled"                = tostring(local.caller_trust.entraEnabled)
    "caller-entra-login-host"             = local.caller_login_host
    "caller-entra-tenant-id"              = var.entra_tenant_id == "" ? "__none__" : var.entra_tenant_id
    "caller-entra-issuer"                 = local.caller_issuer
    "caller-entra-client-ids"             = length(local.caller_trust.entraClientIds) == 0 ? "__any__" : join(",", local.caller_trust.entraClientIds)
    "caller-okta-enabled"                 = tostring(local.caller_okta.enabled)
    "caller-okta-issuer"                  = local.caller_okta.issuer == "" ? "https://unset.invalid/okta" : local.caller_okta.issuer
    "caller-okta-openid-config-url"       = local.caller_okta.openIdConfigUrl == "" ? "https://unset.invalid/okta/.well-known/openid-configuration" : local.caller_okta.openIdConfigUrl
    "caller-okta-audience"                = local.caller_okta.audience == "" ? "__none__" : local.caller_okta.audience
    "caller-okta-required-scope"          = local.caller_okta.requiredScope == "" ? "__none__" : local.caller_okta.requiredScope
    "caller-okta-client-ids"              = length(local.caller_okta.clientIds) == 0 ? "__none__" : join(",", local.caller_okta.clientIds)
    "caller-jwt-product-id"               = local.caller_trust.jwtProductId
    "entra-openid-config-url"             = "${local.caller_issuer}/.well-known/openid-configuration"
    "api-audience"                        = var.api_audience == "" ? "__none__" : var.api_audience
    "required-scope"                      = var.required_scope
    "jwt-calls-per-minute"                = tostring(var.jwt_limits.calls_per_minute)
    "jwt-tokens-per-minute"               = tostring(var.jwt_limits.tokens_per_minute)
    "jwt-monthly-call-quota"              = tostring(var.jwt_limits.monthly_calls)
    "foundry-mi-audience"                 = var.arm_environment == "usgovernment" ? "https://cognitiveservices.azure.us" : "https://cognitiveservices.azure.com"
  }
  caller_entra_validator = try(local.caller_trust.entraEnabled ? local.caller_package.entraValidator : local.caller_package.disabledValidator, "")
  caller_okta_validator  = try(local.caller_okta.enabled ? local.caller_package.oktaValidator : local.caller_package.disabledValidator, "")
  caller_authentication = try(replace(replace(local.caller_package.authentication,
    "<include-fragment fragment-id=\"byok-validate-entra\" />", replace(replace(local.caller_entra_validator, "<fragment>", ""), "</fragment>", "")),
  "<include-fragment fragment-id=\"byok-validate-okta\" />", replace(replace(local.caller_okta_validator, "<fragment>", ""), "</fragment>", "")), "")
  caller_fragments = local.caller_enabled ? merge(
    { "byok-authenticate" = local.caller_authentication },
    { for name, policy in local.caller_package.fragments : name => (name == "byok-apply-caller-limits" ? local.caller_limits_policy : policy) if local.shared_caller_auth || contains(["byok-strip-caller-credentials", "byok-apply-caller-limits"], name) }
  ) : {}
  owner_values = {
    "caller-response-owner-key"          = { value = var.response_owner_key, secret = true }
    "caller-response-owner-key-previous" = { value = var.response_owner_previous_key, secret = true }
    "caller-response-backend-origins"    = { value = jsonencode([var.existing_backend_origin]), secret = false }
    "caller-response-stores"             = { value = jsonencode([{ origin = var.existing_backend_origin, backendId = var.existing_backend_name, kind = "foundry" }]), secret = false }
  }
  native_caller_guard     = "<choose><when condition=\"@(context.Subscription == null || (context.Product != null &amp;&amp; !context.Product.SubscriptionRequired))\"><return-response><set-status code=\"401\" reason=\"Native subscription required\" /></return-response></when></choose>"
  inference_caller_policy = local.shared_caller_auth ? replace(local.caller_package.inference, "__NATIVE_SUBSCRIPTION_REQUIRED__", tostring(local.caller_key_required)) : replace(file("${path.module}/../policies/intellij-inference.xml"), "<inbound>", "<inbound>${local.native_caller_guard}")
  models_caller_policy    = local.shared_caller_auth ? replace(local.caller_package.models, "__NATIVE_SUBSCRIPTION_REQUIRED__", tostring(local.caller_key_required)) : replace(file("${path.module}/../policies/intellij-models.xml"), "<inbound>", "<inbound>${local.native_caller_guard}")
  backend_auth_marker     = "<set-variable name=\"fdKey\" value=\"{{intellij-foundry-api-key}}\" />"
  backend_auth_policy     = var.foundry_auth_mode == "managedIdentity" ? "<authentication-managed-identity resource=\"${local.caller_settings["foundry-mi-audience"]}\" /><set-variable name=\"fdKey\" value=\" \" />" : local.backend_auth_marker
  response_operations = local.shared_caller_auth ? {
    "responses-get"         = { display = "Responses get", method = "GET", url = "/v1/responses/{response_id}" }
    "responses-delete"      = { display = "Responses delete", method = "DELETE", url = "/v1/responses/{response_id}" }
    "responses-cancel"      = { display = "Responses cancel", method = "POST", url = "/v1/responses/{response_id}/cancel" }
    "responses-input-items" = { display = "Responses input items", method = "GET", url = "/v1/responses/{response_id}/input_items" }
  } : {}
  jwt_admission_active = var.caller_auth_rollout == "coexistence" && local.caller_trust.keyEnabled && (local.caller_trust.entraEnabled || local.caller_okta.enabled)
}

resource "terraform_data" "caller_contract" {
  input = var.caller_auth_rollout
  lifecycle {
    precondition {
      condition     = local.caller_tiering_valid
      error_message = "Enabled JWT tiers require matching shared issuer trust, a reviewed catalog and a current caller package with tiering version 1."
    }
    precondition {
      condition     = !local.caller_tiering_enabled || can(regex("^(Developer|Premium)_[0-9]+$", data.azurerm_api_management.apim.sku_name))
      error_message = "JWT tiers currently require classic Developer or Premium APIM."
    }
    precondition {
      condition     = !local.caller_enabled || (local.caller_configuration_valid && try(local.caller_package.version, 0) == 1)
      error_message = "Enabled caller trust needs valid cloud/issuer/client settings and a freshly rendered caller policy package."
    }
    precondition {
      condition = !local.shared_caller_auth || (local.caller_enabled &&
        can(regex(local.owner_key_pattern, var.response_owner_key)) && var.response_owner_key != "${join("", [for index in range(43) : "A"])}=" &&
        (var.response_owner_previous_key == "__none__" || (can(regex(local.owner_key_pattern, var.response_owner_previous_key)) && var.response_owner_previous_key != var.response_owner_key && var.response_owner_previous_key != "${join("", [for index in range(43) : "A"])}=")) &&
        can(regex("^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]{2,63}(:443)?$", var.existing_backend_origin)) &&
        !can(regex("(?i)(localhost|\\.invalid)(:443)?$", var.existing_backend_origin)) &&
      (var.foundry_auth_mode == "managedIdentity" || trimspace(var.foundry_api_key) != ""))
      error_message = "Shared callers require prepared trust, stable current/explicit previous owner keys, an exact HTTPS backend origin and explicit lookup credentials."
    }
    precondition {
      condition     = var.caller_auth_rollout != "coexistence" || local.jwt_admission_active
      error_message = "Coexistence requires native keys and at least one enabled JWT issuer."
    }
  }
}

resource "azurerm_api_management_named_value" "caller" {
  for_each            = local.caller_enabled ? local.caller_settings : {}
  name                = "intellij-${each.key}"
  display_name        = "intellij-${each.key}"
  resource_group_name = var.apim_resource_group
  api_management_name = var.apim_name
  value               = each.value
  secret              = false
  depends_on          = [terraform_data.caller_contract]
}

resource "azurerm_api_management_named_value" "owner" {
  for_each            = local.shared_caller_auth ? toset(["caller-response-owner-key", "caller-response-owner-key-previous", "caller-response-backend-origins", "caller-response-stores"]) : toset([])
  name                = "intellij-${each.key}"
  display_name        = "intellij-${each.key}"
  resource_group_name = var.apim_resource_group
  api_management_name = var.apim_name
  value               = local.owner_values[each.key].value
  secret              = local.owner_values[each.key].secret
  depends_on          = [terraform_data.caller_contract]
}

resource "azapi_resource" "caller_fragment" {
  for_each  = local.caller_fragments
  type      = "Microsoft.ApiManagement/service/policyFragments@2024-05-01"
  parent_id = data.azurerm_api_management.apim.id
  name      = "intellij-${each.key}"
  body = { properties = {
    description = "Standalone validated caller and response ownership contract."
    format      = "xml"
    value       = replace(replace(each.value, "{{", "{{intellij-"), "__BACKEND_AUTH_MODE__", var.foundry_auth_mode)
  } }
  depends_on = [azurerm_api_management_named_value.caller, azurerm_api_management_named_value.owner, azurerm_api_management_named_value.nv]
}

resource "azurerm_api_management_api_operation_policy" "responses" {
  for_each            = local.response_operations
  api_name            = azurerm_api_management_api.intellij.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
  operation_id        = azurerm_api_management_api_operation.op[each.key].operation_id
  xml_content         = replace(local.caller_package.responses, "__NATIVE_SUBSCRIPTION_REQUIRED__", tostring(local.caller_key_required))
  depends_on          = [azapi_resource.caller_fragment]
}

resource "azurerm_api_management_product" "jwt" {
  count                 = local.caller_enabled ? 1 : 0
  product_id            = local.caller_trust.jwtProductId
  api_management_name   = var.apim_name
  resource_group_name   = var.apim_resource_group
  display_name          = "IntelliJ validated JWT admission"
  subscription_required = false
  published             = false
  depends_on            = [terraform_data.caller_contract]
}

resource "azurerm_api_management_product_policy" "jwt" {
  count               = local.caller_enabled ? 1 : 0
  product_id          = azurerm_api_management_product.jwt[0].product_id
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
  xml_content         = replace(local.caller_package.jwtProductGuard, "__ACTIVE__", tostring(local.jwt_admission_active))
}

resource "azurerm_api_management_product_api" "jwt" {
  count               = local.jwt_admission_active ? 1 : 0
  product_id          = azurerm_api_management_product.jwt[0].product_id
  api_name            = azurerm_api_management_api.intellij.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
  depends_on          = [azurerm_api_management_product_policy.jwt, azurerm_api_management_api_policy.inference, azurerm_api_management_api_operation_policy.models, azurerm_api_management_api_operation_policy.responses]
}