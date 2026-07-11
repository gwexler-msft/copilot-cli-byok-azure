terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.10"
    }
  }
}

provider "azurerm" {
  features {}
  # Sovereign clouds: set var.arm_environment to "usgovernment" / "china" (or export ARM_ENVIRONMENT).
  environment = var.arm_environment
}

provider "azapi" {
  environment = var.arm_environment == "german" ? "custom" : var.arm_environment
  endpoint = var.arm_environment == "german" ? [{
    active_directory_authority_host = "https://login.microsoftonline.de/"
    resource_manager_audience       = "https://management.core.cloudapi.de/"
    resource_manager_endpoint       = "https://management.microsoftazure.de/"
  }] : []
}
