# Settings shared by every activity in the warehouse pipeline
locals {
  # Retry after 60 seconds, which gives a paused database time to wake up
  warehouse_activity_policy = {
    timeout                = "0.00:15:00"
    retry                  = 2
    retryIntervalInSeconds = 60
    secureInput            = false
    secureOutput           = false
  }

  # Pass the pipeline's run_date to a dataset, or to a stored procedure as a date
  warehouse_run_date_expression = {
    value = "@pipeline().parameters.run_date"
    type  = "Expression"
  }

  # Point an activity at the Azure SQL connection below
  azure_sql_linked_service_reference = {
    referenceName = azurerm_data_factory_linked_service_azure_sql_database.warehouse.name
    type          = "LinkedServiceReference"
  }
}

# Linked service: how Data Factory reaches Azure SQL, using its managed identity (no password or key)
# Connect Timeout=120 waits up to 2 minutes, because the free database pauses and needs time to wake up
resource "azurerm_data_factory_linked_service_azure_sql_database" "warehouse" {
  name                 = "ls_azure_sql"
  data_factory_id      = azurerm_data_factory.main.id
  connection_string    = "Data Source=${azurerm_mssql_server.main.fully_qualified_domain_name};Initial Catalog=${azapi_resource.sql_database.name};Integrated Security=False;Encrypt=True;Connect Timeout=120"
  use_managed_identity = true
}

# Dataset: the staging table in Azure SQL, where silver data lands before it's cleaned
resource "azurerm_data_factory_custom_dataset" "sql_stg_payments" {
  name            = "ds_sql_stg_payments"
  data_factory_id = azurerm_data_factory.main.id
  type            = "AzureSqlTable"

  # Use the Azure SQL connection from above
  linked_service {
    name = azurerm_data_factory_linked_service_azure_sql_database.warehouse.name
  }

  # Point at the table stg.payments
  type_properties_json = jsonencode({
    schema = "stg"
    table  = "payments"
  })
}

# Dataset: the same FX file as ds_bronze_fx_json, but read as JSON so Lookup can see its contents
# The Binary dataset stays for the ingest pipeline, because Binary only moves bytes without reading them
resource "azurerm_data_factory_custom_dataset" "bronze_fx_json_doc" {
  name            = "ds_bronze_fx_json_doc"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Json"

  # Use the data lake connection from adf.tf
  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.bronze.name
  }

  # The date is passed in when the pipeline runs
  parameters = {
    run_date = ""
  }

  # Find bronze/fx_rates/date=<run_date>/rates.json
  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = azurerm_storage_container.layers["bronze"].name
      folderPath = {
        value = "@concat('fx_rates/date=', dataset().run_date)"
        type  = "Expression"
      }
      fileName = "rates.json"
    }
  })
}

# Pipeline: loads one day into the warehouse: FX rates and staging first, then the payments
resource "azurerm_data_factory_pipeline" "load_warehouse" {
  name            = "pl_load_warehouse"
  data_factory_id = azurerm_data_factory.main.id

  # The date to process; always enter one, because there's no "use today" fallback here
  parameters = {
    run_date = ""
  }

  activities_json = jsonencode([
    # Step a: read the FX file, so its text can be passed to the stored procedure
    {
      name      = "Lookup FX json"
      type      = "Lookup"
      dependsOn = []
      policy    = local.warehouse_activity_policy
      typeProperties = {
        source = {
          type = "JsonSource"
          storeSettings = {
            type = "AzureBlobFSReadSettings"
          }
          formatSettings = {
            type = "JsonReadSettings"
            # ADF adds this empty setting itself, so we declare it to stop plan showing a change every time
            compressionProperties = null
          }
        }
        dataset = {
          referenceName = azurerm_data_factory_custom_dataset.bronze_fx_json_doc.name
          type          = "DatasetReference"
          parameters = {
            run_date = local.warehouse_run_date_expression
          }
        }
        firstRowOnly = true
      }
    },
    # Step b: save the FX rates in SQL, once the file has been read
    # @string() turns the Lookup result back into JSON text for the @payload parameter
    {
      name = "Load FX rates"
      type = "SqlServerStoredProcedure"
      dependsOn = [
        {
          activity             = "Lookup FX json"
          dependencyConditions = ["Succeeded"]
        }
      ]
      policy            = local.warehouse_activity_policy
      linkedServiceName = local.azure_sql_linked_service_reference
      typeProperties = {
        storedProcedureName = "dw.usp_load_fx_rates"
        storedProcedureParameters = {
          run_date = {
            value = local.warehouse_run_date_expression
            type  = "Date"
          }
          payload = {
            value = {
              value = "@string(activity('Lookup FX json').output.firstRow)"
              type  = "Expression"
            }
            type = "String"
          }
        }
      }
    },
    # Step c: copy silver into staging; it has no dependencies, so it runs alongside steps a and b
    {
      name      = "Copy silver to staging"
      type      = "Copy"
      dependsOn = []
      policy    = local.warehouse_activity_policy

      # Read this date's Parquet file from silver
      inputs = [
        {
          referenceName = azurerm_data_factory_custom_dataset.silver_payments_parquet.name
          type          = "DatasetReference"
          parameters = {
            run_date = local.warehouse_run_date_expression
          }
        }
      ]

      # Write to the staging table
      outputs = [
        {
          referenceName = azurerm_data_factory_custom_dataset.sql_stg_payments.name
          type          = "DatasetReference"
        }
      ]

      # Empty staging before each copy (and each retry), so rows are never loaded twice
      typeProperties = {
        source = {
          type = "ParquetSource"
          storeSettings = {
            type = "AzureBlobFSReadSettings"
          }
        }
        sink = {
          type          = "AzureSqlSink"
          preCopyScript = "TRUNCATE TABLE stg.payments"
          writeBehavior = "insert"
        }
        enableStaging = false
      }
    },
    # Step d: clean and load the payments, only when both the FX rates and staging are ready
    {
      name = "Load payments warehouse"
      type = "SqlServerStoredProcedure"
      dependsOn = [
        {
          activity             = "Load FX rates"
          dependencyConditions = ["Succeeded"]
        },
        {
          activity             = "Copy silver to staging"
          dependencyConditions = ["Succeeded"]
        }
      ]
      policy            = local.warehouse_activity_policy
      linkedServiceName = local.azure_sql_linked_service_reference
      typeProperties = {
        storedProcedureName = "dw.usp_load_payments"
        storedProcedureParameters = {
          run_date = {
            value = local.warehouse_run_date_expression
            type  = "Date"
          }
        }
      }
    }
  ])
}
