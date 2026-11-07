# azure-uk-payments-pipeline

**Status: in progress.** The pipeline runs end to end, from bronze through silver to the Azure SQL warehouse, with daily orchestration and failure alerts.

A daily Azure batch pipeline on finance data: simulated card payments plus real ECB FX rates from the [Frankfurter API](https://frankfurter.dev/).

```text
Simulator + Frankfurter API -> Azure Data Factory -> ADLS Gen2 -> Azure SQL -> Power BI
```

## Progress

- [x] Day 3: FX ingestion (Frankfurter API to ADLS bronze)
- [x] Day 4: Payments simulator and typed bronze to silver copy with a reject log
- [x] Day 5: Azure SQL star schema, GBP conversion, fraud rules and reconciliation
- [x] Day 6: Watermark-driven daily orchestration, schedule trigger and failure email alert

## How it runs

1. **Daily trigger:** `tr_daily_0600` starts `pl_daily` at 06:00 UK time. It's kept off while the simulator upload is manual.
2. **Watermark:** `dw.usp_get_dates_to_load` lists every day up to yesterday that has no successful load, oldest first.
3. **Per-day pipeline:** `pl_run_day` runs for each missing day. It loads FX rates and moves payments from bronze to silver in parallel, then loads the warehouse.
4. **Email alert on failure:** an Azure Monitor alert emails me when any pipeline run fails.

## Folders

| Folder | Contents |
| --- | --- |
| `terraform/` | Azure infrastructure as code |
| `adf/` | Data Factory pipelines |
| `simulator/` | Card payment simulator |
| `sql/` | Database scripts |
| `powerbi/` | Power BI report |
| `docs/` | Project notes, including [what I learned](docs/learnings.md) |
| `tests/` | Tests |

## Security

The project stores no passwords. People sign in with Microsoft Entra ID, and Azure services use managed identities.
