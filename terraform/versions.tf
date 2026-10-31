# Terraform version and the provider plugins this project needs
terraform {
  required_version = ">= 1.9"

  required_providers {
    # azurerm creates the Azure resources (4.x only, so upgrades don't break us)
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # azapi creates the SQL database, because azurerm can't turn on the free offer
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.13"
    }

    # random creates the suffix that makes global names unique
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
