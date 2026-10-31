# Connect Terraform to Azure using the account from "az login" (no secrets here)
provider "azurerm" {
  # Don't let Terraform register Azure providers by itself; we do that on purpose with az
  resource_provider_registrations = "none"

  # Talk to storage with Entra ID, because shared key access is disabled
  storage_use_azuread = true

  features {
    # Skip the storage key-based checks; we create containers through Azure Resource Manager
    storage {
      data_plane_available = false
    }
  }
}

# azapi also uses the account from "az login"
provider "azapi" {}
