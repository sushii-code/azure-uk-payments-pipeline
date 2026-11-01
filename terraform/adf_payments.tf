# Column lists used by the datasets and the copy below
# Why they matter: with no declared types, ADF does no conversion, so nothing is ever rejected
locals {
  # The 13 columns in the bronze CSV, with the types we expect the text to contain
  bronze_payments_csv_schema = [
    { name = "transaction_id", type = "String" },
    { name = "txn_timestamp", type = "DateTime" },
    { name = "card_id", type = "String" },
    { name = "customer_id", type = "String" },
    { name = "card_home_country", type = "String" },
    { name = "merchant_id", type = "String" },
    { name = "merchant_name", type = "String" },
    { name = "merchant_category", type = "String" },
    { name = "merchant_country", type = "String" },
    { name = "amount", type = "Decimal" },
    { name = "currency", type = "String" },
    { name = "channel", type = "String" },
    { name = "status", type = "String" },
  ]

  # The 16 columns in the silver file, using Parquet's own type names
  # INT96 is how ADF stores a DateTime in Parquet, and UTF8 is how it stores text
  silver_payments_parquet_schema = [
    { name = "transaction_id", type = "UTF8" },
    { name = "txn_timestamp", type = "INT96" },
    { name = "card_id", type = "UTF8" },
    { name = "customer_id", type = "UTF8" },
    { name = "card_home_country", type = "UTF8" },
    { name = "merchant_id", type = "UTF8" },
    { name = "merchant_name", type = "UTF8" },
    { name = "merchant_category", type = "UTF8" },
    { name = "merchant_country", type = "UTF8" },
    { name = "amount", type = "DECIMAL", precision = 18, scale = 2 },
    { name = "currency", type = "UTF8" },
    { name = "channel", type = "UTF8" },
    { name = "status", type = "UTF8" },
    { name = "ingest_run_id", type = "UTF8" },
    { name = "source_file", type = "UTF8" },
    { name = "ingested_at_utc", type = "UTF8" },
  ]

  # How the copy moves each column; the source type and format tell ADF how to parse the CSV text
  payments_column_mappings = [
    { source = { name = "transaction_id", type = "String" }, sink = { name = "transaction_id", type = "String" } },
    { source = { name = "txn_timestamp", type = "DateTime", format = "yyyy-MM-dd'T'HH:mm:ss'Z'" }, sink = { name = "txn_timestamp", type = "DateTime" } },
    { source = { name = "card_id", type = "String" }, sink = { name = "card_id", type = "String" } },
    { source = { name = "customer_id", type = "String" }, sink = { name = "customer_id", type = "String" } },
    { source = { name = "card_home_country", type = "String" }, sink = { name = "card_home_country", type = "String" } },
    { source = { name = "merchant_id", type = "String" }, sink = { name = "merchant_id", type = "String" } },
    { source = { name = "merchant_name", type = "String" }, sink = { name = "merchant_name", type = "String" } },
    { source = { name = "merchant_category", type = "String" }, sink = { name = "merchant_category", type = "String" } },
    { source = { name = "merchant_country", type = "String" }, sink = { name = "merchant_country", type = "String" } },
    { source = { name = "amount", type = "Decimal" }, sink = { name = "amount", type = "Decimal", precision = 18, scale = 2 } },
    { source = { name = "currency", type = "String" }, sink = { name = "currency", type = "String" } },
    { source = { name = "channel", type = "String" }, sink = { name = "channel", type = "String" } },
    { source = { name = "status", type = "String" }, sink = { name = "status", type = "String" } },
    # These last three are added by the copy, to show where each row came from and when
    { source = { name = "ingest_run_id", type = "String" }, sink = { name = "ingest_run_id", type = "String" } },
    { source = { name = "source_file", type = "String" }, sink = { name = "source_file", type = "String" } },
    { source = { name = "ingested_at_utc", type = "String" }, sink = { name = "ingested_at_utc", type = "String" } },
  ]
}

# Dataset: the raw payments CSV for one date in bronze
# It reuses the existing connection, which can reach every container in the storage account
resource "azurerm_data_factory_custom_dataset" "bronze_payments_csv" {
  name            = "ds_bronze_payments_csv"
  data_factory_id = azurerm_data_factory.main.id
  type            = "DelimitedText"

  # Use the data lake connection from adf.tf
  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.bronze.name
  }

  # The date is passed in when the pipeline runs
  parameters = {
    run_date = ""
  }

  # Declare the expected column types, so ADF has something to check the text against
  schema_json = jsonencode(local.bronze_payments_csv_schema)

  # Find bronze/payments/date=<run_date>/payments.csv and describe how the file is laid out
  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = azurerm_storage_container.layers["bronze"].name
      folderPath = {
        value = "@concat('payments/date=', dataset().run_date)"
        type  = "Expression"
      }
      fileName = "payments.csv"
    }
    columnDelimiter  = ","
    encodingName     = "UTF-8"
    firstRowAsHeader = true
  })
}

# Dataset: the Parquet file for one date in silver
# Parquet keeps column types and is much faster to query than CSV
resource "azurerm_data_factory_custom_dataset" "silver_payments_parquet" {
  name            = "ds_silver_payments_parquet"
  data_factory_id = azurerm_data_factory.main.id
  type            = "Parquet"

  # Use the data lake connection from adf.tf
  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.bronze.name
  }

  # The date is passed in when the pipeline runs
  parameters = {
    run_date = ""
  }

  # Declare the column types the Parquet file should have, otherwise every column stays text
  schema_json = jsonencode(local.silver_payments_parquet_schema)

  # Write to silver/payments/date=<run_date>/payments.parquet, compressed with snappy to save space
  type_properties_json = jsonencode({
    location = {
      type       = "AzureBlobFSLocation"
      fileSystem = azurerm_storage_container.layers["silver"].name
      folderPath = {
        value = "@concat('payments/date=', dataset().run_date)"
        type  = "Expression"
      }
      fileName = "payments.parquet"
    }
    compressionCodec = "snappy"
  })
}

# Pipeline: copies one day of payments from bronze CSV to silver Parquet
resource "azurerm_data_factory_pipeline" "bronze_to_silver_payments" {
  name            = "pl_bronze_to_silver_payments"
  data_factory_id = azurerm_data_factory.main.id

  # The date to process; always enter one, because there's no "use today" fallback here
  parameters = {
    run_date = ""
  }

  activities_json = jsonencode([
    {
      name      = "Copy bronze to silver"
      type      = "Copy"
      dependsOn = []

      # Try up to 2 more times, 30 seconds apart; each try can last 10 minutes
      policy = {
        timeout                = "0.00:10:00"
        retry                  = 2
        retryIntervalInSeconds = 30
        secureInput            = false
        secureOutput           = false
      }

      # Read from the bronze dataset, passing it the date
      inputs = [
        {
          referenceName = azurerm_data_factory_custom_dataset.bronze_payments_csv.name
          type          = "DatasetReference"
          parameters = {
            run_date = {
              value = "@pipeline().parameters.run_date"
              type  = "Expression"
            }
          }
        }
      ]

      # Write to the silver dataset, passing it the same date
      outputs = [
        {
          referenceName = azurerm_data_factory_custom_dataset.silver_payments_parquet.name
          type          = "DatasetReference"
          parameters = {
            run_date = {
              value = "@pipeline().parameters.run_date"
              type  = "Expression"
            }
          }
        }
      ]

      typeProperties = {
        # Read the CSV from ADLS, and add three columns recording where each row came from
        source = {
          type = "DelimitedTextSource"
          storeSettings = {
            type = "AzureBlobFSReadSettings"
          }
          formatSettings = {
            type = "DelimitedTextReadSettings"
            # ADF adds this empty setting itself, so we declare it to stop plan showing a change every time
            compressionProperties = null
          }
          additionalColumns = [
            {
              name = "ingest_run_id"
              value = {
                value = "@pipeline().RunId"
                type  = "Expression"
              }
            },
            # Build the full path, because $$FILEPATH only gave us payments.csv without the date
            {
              name = "source_file"
              value = {
                value = "@concat('bronze/payments/date=', pipeline().parameters.run_date, '/payments.csv')"
                type  = "Expression"
              }
            },
            {
              name = "ingested_at_utc"
              value = {
                value = "@utcNow()"
                type  = "Expression"
              }
            },
          ]
        }

        # Write snappy Parquet to ADLS
        sink = {
          type = "ParquetSink"
          storeSettings = {
            type = "AzureBlobFSWriteSettings"
          }
          formatSettings = {
            type = "ParquetWriteSettings"
          }
        }

        enableStaging = false

        # Map each column by name and convert it to its silver type
        # A value that can't be converted is what makes a row "incompatible", so it gets skipped
        translator = {
          type           = "TabularTranslator"
          mappings       = local.payments_column_mappings
          typeConversion = true

          # Be strict: only accept our exact timestamp format, and never round or cut off values
          typeConversionSettings = {
            allowDataTruncation  = false
            treatBooleanAsNumber = false
            dateTimeFormat       = "yyyy-MM-dd'T'HH:mm:ss'Z'"
          }
        }

        # Skip rows that can't be converted, so one bad row doesn't fail the whole day
        enableSkipIncompatibleRow = true

        # Save the skipped rows to silver/_rejects/payments/, so bad data is never lost silently
        logSettings = {
          enableCopyActivityLog = true
          copyActivityLogSettings = {
            logLevel              = "Warning"
            enableReliableLogging = false
          }
          logLocationSettings = {
            linkedServiceName = {
              referenceName = azurerm_data_factory_linked_service_data_lake_storage_gen2.bronze.name
              type          = "LinkedServiceReference"
            }
            path = "${azurerm_storage_container.layers["silver"].name}/_rejects/payments"
          }
        }
      }
    }
  ])
}
