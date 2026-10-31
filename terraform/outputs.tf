# Name of the resource group
output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

# Name of the ADLS Gen2 storage account
output "storage_account_name" {
  value = azurerm_storage_account.lake.name
}

# Names of the data lake containers
output "storage_container_names" {
  value = sort([for container in azurerm_storage_container.layers : container.name])
}

# Name of the Key Vault
output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

# Name of the Data Factory
output "data_factory_name" {
  value = azurerm_data_factory.main.name
}

# Name of the Azure SQL logical server
output "sql_server_name" {
  value = azurerm_mssql_server.main.name
}

# Name of the Azure SQL database
output "sql_database_name" {
  value = azapi_resource.sql_database.name
}
