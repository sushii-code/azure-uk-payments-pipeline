# Look up who is logged in with az (gives us your user ID and tenant ID)
data "azurerm_client_config" "current" {}

# Random ending for names that must be unique across all of Azure
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# Resource group: the folder that holds everything in this project
resource "azurerm_resource_group" "main" {
  name     = "rg-ukpay-dev"
  location = var.location
  tags     = var.tags
}

# ADLS Gen2 storage account: the data lake (the hierarchical namespace makes it Gen2)
resource "azurerm_storage_account" "lake" {
  name                            = "stukpaydev${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_kind                    = "StorageV2"
  account_replication_type        = "LRS"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  tags                            = var.tags

  # Keep deleted files and containers for 7 days, so a mistaken delete can be undone
  # Versioning is left off on purpose: it keeps a paid copy every time a file is overwritten
  blob_properties {
    # Deleted files can be restored for 7 days
    delete_retention_policy {
      days = 7
    }

    # Deleted containers (like bronze) can be restored for 7 days
    container_delete_retention_policy {
      days = 7
    }
  }
}

# Three data lake containers: bronze (raw), silver (cleaned), gold (ready for reports)
resource "azurerm_storage_container" "layers" {
  for_each = toset(["bronze", "silver", "gold"])

  name                  = each.key
  storage_account_id    = azurerm_storage_account.lake.id
  container_access_type = "private"
}

# Key Vault: the safe for secrets; access is controlled by RBAC roles, not access policies
# It's empty, because every connection uses a managed identity or Entra sign-in instead of a secret
# So nobody has a secrets role on it; add one back only when a real secret is needed (least privilege)
resource "azurerm_key_vault" "main" {
  name                       = "kv-ukpay-dev-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = var.tags
}

# Data Factory: runs the daily pipeline, using its own managed identity instead of a password
resource "azurerm_data_factory" "main" {
  name                = "adf-ukpay-dev-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  # Ask Azure to create and manage an identity for this factory
  identity {
    type = "SystemAssigned"
  }
}

# Allow Data Factory to read and write files in the data lake
resource "azurerm_role_assignment" "adf_storage" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.main.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Allow you to read and write files in the data lake
resource "azurerm_role_assignment" "me_storage" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure SQL logical server: Entra ID sign-in only, so there is no SQL password at all
resource "azurerm_mssql_server" "main" {
  name                = "sql-ukpay-dev-de-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.sql_location
  version             = "12.0"
  minimum_tls_version = "1.2"
  tags                = var.tags

  # You are the admin; object_id is what identifies you, login_username is just a display label
  azuread_administrator {
    login_username              = "ukpay-sql-admin"
    object_id                   = data.azurerm_client_config.current.object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }
}

# Database on the Azure SQL free offer: it pauses instead of charging when the monthly free amount runs out
# (azurerm has no setting for the free offer, so azapi calls the Azure API directly)
# No size is set here because the free offer sets the database size itself
resource "azapi_resource" "sql_database" {
  type      = "Microsoft.Sql/servers/databases@2025-01-01"
  name      = "sqldb-ukpay-dev"
  parent_id = azurerm_mssql_server.main.id
  location  = azurerm_mssql_server.main.location
  tags      = var.tags

  body = {
    sku = {
      name     = "GP_S_Gen5"
      tier     = "GeneralPurpose"
      family   = "Gen5"
      capacity = 2
    }
    properties = {
      useFreeLimit                     = true
      freeLimitExhaustionBehavior      = "AutoPause"
      autoPauseDelay                   = 60
      minCapacity                      = 0.5
      requestedBackupStorageRedundancy = "Local"
      zoneRedundant                    = false
    }
  }
}

# Firewall: 0.0.0.0 is Azure's special value for "allow Azure services" (so ADF can connect)
resource "azurerm_mssql_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Firewall: allow your laptop to connect
resource "azurerm_mssql_firewall_rule" "my_laptop" {
  name             = "AllowMyLaptop"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = var.my_ip_address
  end_ip_address   = var.my_ip_address
}
