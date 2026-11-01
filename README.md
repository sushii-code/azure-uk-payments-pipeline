# azure-uk-payments-pipeline

**Status: in progress.** The infrastructure is deployed, and FX rates are loading into the bronze layer.

A daily Azure batch pipeline on finance data: simulated card payments plus real ECB FX rates from the [Frankfurter API](https://frankfurter.dev/).

```text
Simulator + Frankfurter API -> Azure Data Factory -> ADLS Gen2 -> Azure SQL -> Power BI
```

## Progress

- [x] Day 3: FX ingestion (Frankfurter API to ADLS bronze)
- [x] Day 4: Payments simulator and typed bronze to silver copy with a reject log

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
