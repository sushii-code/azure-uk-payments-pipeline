# Linked service: how Data Factory reaches the Frankfurter API (public, so no sign-in needed)
# (a custom linked service because azurerm's "web" resource creates WebTable, which only reads HTML tables)
resource "azurerm_data_factory_linked_custom_service" "frankfurter" {
  name            = "ls_frankfurter"
  data_factory_id = azurerm_data_factory.main.id
  type            = "HttpServer"

  # Connection details: the API address, no sign-in, and always check the server's certificate
  type_properties_json = jsonencode({
    url                               = "https://api.frankfurter.dev/v1/"
    authenticationType                = "Anonymous"
    enableServerCertificateValidation = true
  })
}

# Linked service: how Data Factory reaches the data lake, using its managed identity (no key or SAS)
resource "azurerm_data_factory_linked_service_data_lake_storage_gen2" "bronze" {
  name                 = "ls_adls_bronze"
  data_factory_id      = azurerm_data_factory.main.id
  url                  = azurerm_storage_account.lake.primary_dfs_endpoint
  use_managed_identity = true
}

# Dataset: the API response for one date, in GBP, for our 6 currencies
# (Binary means Data Factory moves the bytes without reading or rewriting them)
resource "azurerm_data_factory_custom_dataset" "fx_api" {
  name            = "ds_fx_api"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Binary"

  # Use the Frankfurter connection from above
  linked_service {
    name = azurerm_data_factory_linked_custom_service.frankfurter.name
  }

  # The date is passed in when the pipeline runs
  parameters = {
    run_date = ""
  }

  # Build the URL, for example 2026-10-30?base=GBP&symbols=EUR,USD,INR,JPY,AUD,CAD
  type_properties_json = jsonencode({
    location = {
      type = "HttpServerLocation"
      relativeUrl = {
        value = "@concat(dataset().run_date, '?base=GBP&symbols=EUR,USD,INR,JPY,AUD,CAD')"
        type  = "Expression"
      }
    }
  })
}

# Dataset: the JSON file we write to bronze, one folder per date
# (also Binary, so the file is an exact copy of what the API sent)
resource "azurerm_data_factory_custom_dataset" "bronze_fx_json" {
  name            = "ds_bronze_fx_json"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Binary"

  # Use the data lake connection from above
  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.bronze.name
  }

  # The date is passed in when the pipeline runs
  parameters = {
    run_date = ""
  }

  # Build the path, for example bronze/fx_rates/date=2026-10-30/rates.json
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

# Pipeline: works out which date to use, then copies that date's rates into bronze
resource "azurerm_data_factory_pipeline" "ingest_fx_rates" {
  name            = "pl_ingest_fx_rates"
  data_factory_id = azurerm_data_factory.main.id

  # Optional date to load; leave it empty to use today
  parameters = {
    run_date = ""
  }

  # Holds the date this run will actually use
  variables = {
    resolved_run_date = ""
  }

  activities_json = jsonencode([
    # Step 1: use run_date if it was given, otherwise today's UTC date as yyyy-MM-dd
    {
      name      = "Set resolved run date"
      type      = "SetVariable"
      dependsOn = []
      typeProperties = {
        variableName = "resolved_run_date"
        value = {
          value = "@if(empty(pipeline().parameters.run_date), formatDateTime(utcNow(), 'yyyy-MM-dd'), pipeline().parameters.run_date)"
          type  = "Expression"
        }
      }
    },
    # Step 2: copy from the API to bronze once step 1 has succeeded
    {
      name = "Copy FX rates to bronze"
      type = "Copy"
      dependsOn = [
        {
          activity             = "Set resolved run date"
          dependencyConditions = ["Succeeded"]
        }
      ]

      # Try up to 2 more times, 30 seconds apart; each try can last 10 minutes
      policy = {
        timeout                = "0.00:10:00"
        retry                  = 2
        retryIntervalInSeconds = 30
        secureInput            = false
        secureOutput           = false
      }

      # Read from the API dataset, passing it the date
      inputs = [
        {
          referenceName = azurerm_data_factory_custom_dataset.fx_api.name
          type          = "DatasetReference"
          parameters = {
            run_date = {
              value = "@variables('resolved_run_date')"
              type  = "Expression"
            }
          }
        }
      ]

      # Write to the bronze dataset, passing it the same date
      outputs = [
        {
          referenceName = azurerm_data_factory_custom_dataset.bronze_fx_json.name
          type          = "DatasetReference"
          parameters = {
            run_date = {
              value = "@variables('resolved_run_date')"
              type  = "Expression"
            }
          }
        }
      ]

      # Say how to read bytes over HTTP and how to write them to ADLS Gen2
      typeProperties = {
        source = {
          type = "BinarySource"
          storeSettings = {
            type          = "HttpReadSettings"
            requestMethod = "GET"
          }
        }
        sink = {
          type = "BinarySink"
          storeSettings = {
            type = "AzureBlobFSWriteSettings"
          }
        }
        enableStaging = false
      }
    }
  ])
}
