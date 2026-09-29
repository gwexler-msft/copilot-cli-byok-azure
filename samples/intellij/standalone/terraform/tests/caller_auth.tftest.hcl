mock_provider "azurerm" {
  mock_data "azurerm_api_management" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/fixture/providers/Microsoft.ApiManagement/service/fixture", sku_name = "Developer_1" }
  }
}
mock_provider "azapi" {}

variables {
  apim_resource_group         = "fixture"
  apim_name                   = "fixture"
  existing_backend_name       = "foundry"
  app_insights_name           = "fixture"
  app_insights_resource_group = "fixture"
  location                    = "usgovvirginia"
  vm_resource_group           = "fixture"
  proxy_static_private_ip     = "192.0.2.1"
  apim_private_ip             = "192.0.2.2"
  apim_gateway_host           = "gateway.example.test"
  vm_admin_ssh_public_key     = "fixture-unused-by-target"
  foundry_auth_mode           = "managedIdentity"
  existing_backend_origin     = "https://backend.example.test"
  response_owner_key          = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
  response_owner_previous_key = "__none__"
  entra_tenant_id             = uuidv5("dns", "tenant.fixture.example.test")
  api_audience                = uuidv5("dns", "audience.fixture.example.test")
  product_tiers = [
    { name = "byok-standard", callsPerMinute = 60, tokensPerMinute = 100000, monthlyCallQuota = 50000 },
    { name = "byok-power", callsPerMinute = 120, tokensPerMinute = 200000, monthlyCallQuota = 200000 }
  ]
}

run "legacy_default" {
  command = plan
  plan_options { target = [terraform_data.caller_contract, azurerm_api_management_api.intellij, azapi_resource.caller_fragment] }
  assert {
    condition     = azurerm_api_management_api.intellij.subscription_required && length(azapi_resource.caller_fragment) == 0
    error_message = "Default native admission must not create shared fragments."
  }
}

run "shared_key_only" {
  command = plan
  variables {
    arm_environment     = "usgovernment"
    caller_auth_rollout = "shared"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
  }
  plan_options { target = [azurerm_api_management_product_api.jwt, azurerm_api_management_api_operation_policy.responses] }
  assert {
    condition     = length(azapi_resource.caller_fragment) == 8 && length(azurerm_api_management_api_operation_policy.responses) == 4 && length(azurerm_api_management_product_api.jwt) == 0
    error_message = "Shared key-only mode must prepare all ownership components without open-product admission."
  }
  assert {
    condition     = alltrue([for fragment in azapi_resource.caller_fragment : startswith(fragment.name, "intellij-byok-") && !strcontains(fragment.body.properties.value, "include-fragment")])
    error_message = "Terraform fragments must remain namespaced and flat."
  }
  assert {
    condition     = local.caller_limits_policy == local.caller_package.fragments["byok-apply-caller-limits"]
    error_message = "Disabled JWT tiering must preserve the flat limiter exactly."
  }
}

run "coexistence_okta_fixture" {
  command = plan
  variables {
    caller_auth_rollout = "coexistence"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = true, issuer = "https://issuer.example.test/oauth2/fixture", openIdConfigUrl = "https://issuer.example.test/oauth2/fixture/.well-known/openid-configuration", audience = "api://fixture", requiredScope = "cli.invoke", clientIds = ["fixture-client"] }
    }
  }
  plan_options { target = [azurerm_api_management_product_api.jwt] }
  assert {
    condition     = length(azurerm_api_management_product_api.jwt) == 1 && azurerm_api_management_api.intellij.subscription_required
    error_message = "Coexistence links the guarded product without disabling native key admission."
  }
}

run "reject_unprepared_rollout" {
  command = plan
  variables { caller_auth_rollout = "shared" }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "reject_missing_owner_state" {
  command = plan
  variables {
    caller_auth_rollout         = "shared"
    response_owner_previous_key = ""
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "reject_coexistence_without_issuer" {
  command = plan
  variables {
    caller_auth_rollout = "coexistence"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "reject_numeric_backend_origin" {
  command = plan
  variables {
    caller_auth_rollout     = "shared"
    existing_backend_origin = "https://127.0.0.1"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "reject_zero_owner_key" {
  command = plan
  variables {
    caller_auth_rollout = "shared"
    response_owner_key  = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "reject_native_product_collision" {
  command = plan
  variables {
    caller_auth_rollout   = "shared"
    existing_product_name = "intellij-jwt"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "reject_unsupported_cloud" {
  command = plan
  variables {
    arm_environment     = "china"
    caller_auth_rollout = "shared"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "tiers_entra" {
  command = plan
  variables {
    caller_auth_rollout = "coexistence"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = true, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
    caller_jwt_tiering = {
      entra = { enabled = true, mappings = [{ claimValue = "Byok.Standard", tier = "byok-standard" }, { claimValue = "Byok.Power", tier = "byok-power" }] }
      okta  = { enabled = false, claimName = "byok_tier", mappings = [] }
    }
  }
  plan_options { target = [azurerm_api_management_product_api.jwt, azurerm_api_management_api_operation_policy.responses] }
  assert {
    condition = (azurerm_api_management_api.intellij.subscription_required && length(azapi_resource.caller_fragment) == 8 &&
      length(azurerm_api_management_api_operation_policy.responses) == 4 && length(azurerm_api_management_product_api.jwt) == 1 &&
      strcontains(azapi_resource.caller_fragment["byok-apply-caller-limits"].body.properties.value, "byokCallerTier") &&
    !strcontains(local.caller_limits_policy, "__BYOK_") && !strcontains(local.caller_limits_policy, "<include-fragment"))
    error_message = "Entra tiers must preserve native admission/ownership and render the flat inline tier selector."
  }
  assert {
    condition = (length(regexall("counter-key=\"@\\(\\(string\\)context.Variables\\[&quot;callerPrincipalKey&quot;\\]\\)\"", local.caller_limits_policy)) == 9 &&
      strcontains(local.caller_tier_branches[0], "calls=\"50000\"") && strcontains(local.caller_tier_branches[1], "calls=\"200000\"") &&
    alltrue([for branch in local.caller_tier_branches : strcontains(branch, "renewal-period=\"2592000\"")]))
    error_message = "All flat/selected-tier counters must share the immutable caller key with literal quota ceilings and unchanged windows."
  }
}

run "tiers_okta" {
  command = plan
  variables {
    arm_environment     = "public"
    caller_auth_rollout = "coexistence"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = false, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = true, issuer = "https://issuer.example.test/oauth2/fixture", openIdConfigUrl = "https://issuer.example.test/oauth2/fixture/.well-known/openid-configuration", audience = "api://fixture", requiredScope = "cli.invoke", clientIds = ["fixture-client"] }
    }
    caller_jwt_tiering = {
      entra = { enabled = false, mappings = [] }
      okta  = { enabled = true, claimName = "byok_tier", mappings = [{ claimValue = "standard", tier = "byok-standard" }] }
    }
  }
  plan_options { target = [azapi_resource.caller_fragment] }
  assert {
    condition = (jsondecode(base64decode(local.caller_tier_configuration)).okta.enabled &&
      !jsondecode(base64decode(local.caller_tier_configuration)).entra.enabled &&
      jsondecode(base64decode(local.caller_tier_configuration)).okta.mappings[0].tier == "byok-standard" &&
    strcontains(local.caller_limits_policy, "byokCallerTier"))
    error_message = "Okta tier claims must use the shared catalog without silently enabling Entra tiering."
  }
}

run "reject_tiers_without_shared_trust" {
  command = plan
  variables {
    caller_jwt_tiering = {
      entra = { enabled = true, mappings = [{ claimValue = "Byok.Standard", tier = "byok-standard" }] }
      okta  = { enabled = false, claimName = "byok_tier", mappings = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "reject_unknown_tier" {
  command = plan
  variables {
    caller_auth_rollout = "shared"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = true, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
    caller_jwt_tiering = {
      entra = { enabled = true, mappings = [{ claimValue = "Byok.Standard", tier = "not-in-catalog" }] }
      okta  = { enabled = false, claimName = "byok_tier", mappings = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}

run "reject_empty_tier_mapping" {
  command = plan
  variables {
    caller_jwt_tiering = {
      entra = { enabled = true, mappings = [] }
      okta  = { enabled = false, claimName = "byok_tier", mappings = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [var.caller_jwt_tiering]
}

run "reject_duplicate_tier_mapping" {
  command = plan
  variables {
    caller_jwt_tiering = {
      entra = { enabled = false, mappings = [{ claimValue = "Byok.Standard", tier = "byok-standard" }, { claimValue = "Byok.Standard", tier = "byok-power" }] }
      okta  = { enabled = false, claimName = "byok_tier", mappings = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [var.caller_jwt_tiering]
}

run "reject_reserved_tier_claim" {
  command = plan
  variables {
    caller_jwt_tiering = {
      entra = { enabled = false, mappings = [] }
      okta  = { enabled = false, claimName = "sub", mappings = [] }
    }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [var.caller_jwt_tiering]
}

run "reject_fractional_tier_quota" {
  command = plan
  variables {
    product_tiers = [{ name = "byok-standard", callsPerMinute = 60, tokensPerMinute = 100000, monthlyCallQuota = 1.5 }]
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [var.product_tiers]
}

run "reject_duplicate_catalog_tier" {
  command = plan
  variables {
    product_tiers = [
      { name = "byok-standard", callsPerMinute = 60, tokensPerMinute = 100000, monthlyCallQuota = 50000 },
      { name = "byok-standard", callsPerMinute = 120, tokensPerMinute = 200000, monthlyCallQuota = 200000 }
    ]
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [var.product_tiers]
}

run "reject_v2_tier_target" {
  command = plan
  variables {
    caller_auth_rollout = "shared"
    caller_auth_preparation = {
      enabled   = true, keyEnabled = true, entraEnabled = true, entraClientIds = [], jwtProductId = "intellij-jwt"
      oktaTrust = { enabled = false, issuer = "", openIdConfigUrl = "", audience = "", requiredScope = "", clientIds = [] }
    }
    caller_jwt_tiering = {
      entra = { enabled = true, mappings = [{ claimValue = "Byok.Standard", tier = "byok-standard" }] }
      okta  = { enabled = false, claimName = "byok_tier", mappings = [] }
    }
  }
  override_data {
    target = data.azurerm_api_management.apim
    values = { sku_name = "StandardV2_1" }
  }
  plan_options { target = [terraform_data.caller_contract] }
  expect_failures = [terraform_data.caller_contract]
}