# Dataset: Azure SQL with no table, because a Lookup needs a dataset even when it only calls a stored procedure
resource "azurerm_data_factory_custom_dataset" "sql_generic" {
  name            = "ds_sql_generic"
  data_factory_id = azurerm_data_factory.main.id
  type            = "AzureSqlTable"

  # Use the Azure SQL connection from adf_warehouse.tf
  linked_service {
    name = azurerm_data_factory_linked_service_azure_sql_database.warehouse.name
  }

  # No schema or table on purpose
  type_properties_json = jsonencode({})
}

# Pipeline: runs the full load for one day by calling the three pipelines we already have
resource "azurerm_data_factory_pipeline" "run_day" {
  name            = "pl_run_day"
  data_factory_id = azurerm_data_factory.main.id

  # The date to process
  parameters = {
    run_date = ""
  }

  activities_json = jsonencode([
    # Fetch that day's FX rates into bronze
    # waitOnCompletion means this step only finishes when the child pipeline finishes
    {
      name      = "Ingest FX"
      type      = "ExecutePipeline"
      dependsOn = []
      typeProperties = {
        pipeline = {
          referenceName = azurerm_data_factory_pipeline.ingest_fx_rates.name
          type          = "PipelineReference"
        }
        waitOnCompletion = true
        parameters = {
          run_date = {
            value = "@pipeline().parameters.run_date"
            type  = "Expression"
          }
        }
      }
    },
    # Turn that day's bronze CSV into silver Parquet; it has no dependencies, so it runs alongside Ingest FX
    {
      name      = "Bronze to silver"
      type      = "ExecutePipeline"
      dependsOn = []
      typeProperties = {
        pipeline = {
          referenceName = azurerm_data_factory_pipeline.bronze_to_silver_payments.name
          type          = "PipelineReference"
        }
        waitOnCompletion = true
        parameters = {
          run_date = {
            value = "@pipeline().parameters.run_date"
            type  = "Expression"
          }
        }
      }
    },
    # Load the warehouse, only when both files above are ready
    {
      name = "Load warehouse"
      type = "ExecutePipeline"
      dependsOn = [
        {
          activity             = "Ingest FX"
          dependencyConditions = ["Succeeded"]
        },
        {
          activity             = "Bronze to silver"
          dependencyConditions = ["Succeeded"]
        }
      ]
      typeProperties = {
        pipeline = {
          referenceName = azurerm_data_factory_pipeline.load_warehouse.name
          type          = "PipelineReference"
        }
        waitOnCompletion = true
        parameters = {
          run_date = {
            value = "@pipeline().parameters.run_date"
            type  = "Expression"
          }
        }
      }
    }
  ])
}

# Pipeline: finds every day that still needs loading, then loads them one at a time
resource "azurerm_data_factory_pipeline" "daily" {
  name            = "pl_daily"
  data_factory_id = azurerm_data_factory.main.id

  # The last date to consider
  parameters = {
    up_to_date = ""
  }

  activities_json = jsonencode([
    # Ask SQL which days are missing; firstRowOnly = false returns all of them, not just the first
    # The shared policy retries 2 times, 60 seconds apart, because the database may be waking up
    {
      name      = "Get dates to load"
      type      = "Lookup"
      dependsOn = []
      policy    = local.warehouse_activity_policy
      typeProperties = {
        source = {
          type                         = "AzureSqlSource"
          sqlReaderStoredProcedureName = "dw.usp_get_dates_to_load"
          storedProcedureParameters = {
            up_to_date = {
              type = "Date"
              value = {
                value = "@pipeline().parameters.up_to_date"
                type  = "Expression"
              }
            }
          }
        }
        dataset = {
          referenceName = azurerm_data_factory_custom_dataset.sql_generic.name
          type          = "DatasetReference"
        }
        firstRowOnly = false
      }
    },
    # Run pl_run_day for each missing day; isSequential means one at a time, oldest first
    {
      name = "For each missing day"
      type = "ForEach"
      dependsOn = [
        {
          activity             = "Get dates to load"
          dependencyConditions = ["Succeeded"]
        }
      ]
      typeProperties = {
        isSequential = true
        items = {
          value = "@activity('Get dates to load').output.value"
          type  = "Expression"
        }
        activities = [
          {
            name = "Run day"
            type = "ExecutePipeline"
            typeProperties = {
              pipeline = {
                referenceName = azurerm_data_factory_pipeline.run_day.name
                type          = "PipelineReference"
              }
              waitOnCompletion = true
              parameters = {
                run_date = {
                  value = "@item().run_date"
                  type  = "Expression"
                }
              }
            }
          }
        ]
      }
    }
  ])
}

# Trigger: runs pl_daily at 06:00 UK time, loading everything up to yesterday
# Kept off because the simulator upload is manual; I switch it on for demos
resource "azurerm_data_factory_trigger_schedule" "daily_0600" {
  name            = "tr_daily_0600"
  data_factory_id = azurerm_data_factory.main.id
  frequency       = "Day"
  interval        = 1
  time_zone       = "GMT Standard Time"
  activated       = false

  # Run at exactly 06:00
  schedule {
    hours   = [6]
    minutes = [0]
  }

  # Start pl_daily, passing yesterday's date
  pipeline {
    name = azurerm_data_factory_pipeline.daily.name
    parameters = {
      up_to_date = "@formatDateTime(addDays(trigger().scheduledTime, -1), 'yyyy-MM-dd')"
    }
  }
}

# Action group: who to tell when an alert fires; the address comes from -var, so it's never in the code
resource "azurerm_monitor_action_group" "alerts" {
  name                = "ag-ukpay-dev"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "ukpayalert"
  tags                = var.tags

  # Send an email in Azure's standard alert format
  email_receiver {
    name                    = "email-alert"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Alert: email when any pipeline run fails, checking the last 5 minutes every 5 minutes
resource "azurerm_monitor_metric_alert" "adf_pipeline_failed" {
  name                = "alert-adf-pipeline-failed"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_data_factory.main.id]
  frequency           = "PT5M"
  window_size         = "PT5M"
  severity            = 2
  tags                = var.tags

  # Fire when the number of failed pipeline runs is above 0
  criteria {
    metric_namespace = "Microsoft.DataFactory/factories"
    metric_name      = "PipelineFailedRuns"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  # Tell the action group above
  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }
}
