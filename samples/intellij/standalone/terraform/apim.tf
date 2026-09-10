# ---- Named values the policies read via {{...}} -------------------------------------------------
resource "azurerm_api_management_named_value" "nv" {
  for_each            = local.named_values
  name                = each.key
  resource_group_name = var.apim_resource_group
  api_management_name = var.apim_name
  display_name        = each.key
  value               = each.value.value
  secret              = each.value.secret
}

# ---- The dedicated API --------------------------------------------------------------------------
resource "azurerm_api_management_api" "intellij" {
  name                  = "intellij-byok"
  resource_group_name   = var.apim_resource_group
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "IntelliJ BYOK -> Foundry"
  path                  = var.intellij_api_path
  protocols             = ["https"]
  subscription_required = true

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }
}

# ---- Operations ---------------------------------------------------------------------------------
resource "azurerm_api_management_api_operation" "op" {
  for_each            = local.operations
  operation_id        = each.key
  api_name            = azurerm_api_management_api.intellij.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
  display_name        = each.value.display
  method              = each.value.method
  url_template        = each.value.url

  response {
    status_code = 200
  }
}

# ---- Policies (shared XML, same files the Bicep route uses) --------------------------------------
# Operation-scoped models policy (omits <base/>, so the API inference policy's body-parse guard
# does not run on the body-less GET).
resource "azurerm_api_management_api_operation_policy" "models" {
  api_name            = azurerm_api_management_api.intellij.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
  operation_id        = azurerm_api_management_api_operation.op["list-models"].operation_id
  xml_content         = file("${path.module}/../policies/intellij-models.xml")

  depends_on = [azurerm_api_management_named_value.nv]
}

# API-scoped inference policy (chat/completions/embeddings/responses).
resource "azurerm_api_management_api_policy" "inference" {
  api_name            = azurerm_api_management_api.intellij.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
  xml_content         = file("${path.module}/../policies/intellij-inference.xml")

  depends_on = [
    azurerm_api_management_named_value.nv,
    azurerm_api_management_api_operation.op,
  ]
}

# ---- Product association (reuse the customer's existing subscription keys) -----------------------
resource "azurerm_api_management_product_api" "link" {
  count               = var.existing_product_name != "" ? 1 : 0
  api_name            = azurerm_api_management_api.intellij.name
  product_id          = var.existing_product_name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
}

resource "azurerm_api_management_product_api" "additional_links" {
  for_each = setsubtract(
    var.additional_product_names,
    var.existing_product_name == "" ? toset([]) : toset([var.existing_product_name]),
  )

  api_name            = azurerm_api_management_api.intellij.name
  product_id          = each.value
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
}

# ---- Metrics: reuse an EXISTING App Insights (none is created) -----------------------------------
resource "azurerm_api_management_logger" "ai" {
  name                = "intellij-appinsights"
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
  resource_id         = data.azurerm_application_insights.ai.id

  application_insights {
    instrumentation_key = data.azurerm_application_insights.ai.instrumentation_key
  }
}

# API-SCOPED diagnostic so telemetry is added ONLY for /intellij (leaves global APIM diagnostics alone).
resource "azurerm_api_management_api_diagnostic" "ai" {
  identifier               = "applicationinsights"
  resource_group_name      = var.apim_resource_group
  api_management_name      = var.apim_name
  api_name                 = azurerm_api_management_api.intellij.name
  api_management_logger_id = azurerm_api_management_logger.ai.id

  sampling_percentage       = 100
  always_log_errors         = true
  verbosity                 = "information"
  http_correlation_protocol = "W3C"
  log_client_ip             = true
}

# AzureRM does not expose the diagnostic's `metrics` property. Without it, APIM accepts
# `emit-metric` policies but skips every emission at runtime. Keep this managed here so the
# Terraform route has the same custom-metric behavior as Bicep.
resource "azapi_update_resource" "diag_metrics" {
  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01"
  resource_id = azurerm_api_management_api_diagnostic.ai.id

  body = {
    properties = {
      metrics = true
    }
  }
}
