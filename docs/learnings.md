# Learnings

Notes in simple words, so I can explain each idea in an interview.

## Day 1: Azure basics

- **Subscription:** the account that Azure usage is billed to. Mine is "Azure for Students".
- **Resource group:** a folder for related resources. Deleting the group deletes everything inside it, which makes clean-up easy.
- **Region:** the part of the world where a resource physically runs. Closer usually means faster, and some regions can be blocked by policy.
- **Budget alert:** an email warning when spending reaches an amount I choose. It warns me but does not stop the spending.
- **`az login`:** signs the Azure command line in with my own account. Terraform then reuses that sign-in, so no password goes in the code.

## Day 2: Infrastructure as code

### What I learned about the services

- **ADLS Gen2:** Azure's data lake, a storage account with the "hierarchical namespace" turned on so it has real folders. I use three containers: bronze for raw data, silver for cleaned data and gold for report-ready data.
- **Key Vault:** a safe for secrets. Soft delete means a deleted secret can be recovered for a few days (7 in this project).
- **Azure Data Factory (ADF):** the tool that schedules and runs the daily pipeline steps.
- **Managed identity:** an identity that Azure creates and looks after for a service. ADF uses one to prove who it is, so nobody has to store a password for it.
- **RBAC (role-based access control):** giving someone a role on a resource. For example, "Storage Blob Data Contributor" on the storage account lets ADF read and write files there and nothing more.
- **Entra-only SQL authentication:** only Microsoft Entra ID accounts can sign in to the SQL server. SQL usernames and passwords are switched off.

### Why no passwords?

- A password can leak through code, logs or chat, and then anyone can use it.
- Passwords have to be changed by hand from time to time, and people forget.
- With Entra ID and managed identities, Azure handles short-lived tokens for me, and I control access with roles that I can remove at any time.

### What surprised me

- **The region I wanted was blocked.** A student subscription policy only allows five regions, and `uksouth` is not one of them. I chose `belgiumcentral`, the closest allowed region to the UK. Always check the policy first.
- **New subscriptions need resource providers registered.** A provider is the part of Azure that offers a service, such as `Microsoft.Sql`. It has to be registered before it can be used.
- **The Azure SQL free offer can't be set from azurerm.** The provider has no setting for it, so I create the database with the `azapi` provider, which calls the Azure API directly.
- **How the free offer works:** each month one database per subscription gets a free amount of compute (100,000 vCore seconds) and storage (32 GB of data and 32 GB of backups). A vCore second is one CPU core running for one second. I chose `AutoPause`, so when the free amount runs out the database pauses until next month instead of charging me. It also pauses after 60 minutes without use, which saves free compute. The free offer sets the database size itself: when I asked for a custom size with `AutoPause`, Azure rejected it, so I left the size out.
- **The free SQL offer isn't available in every region.** It failed in Belgium Central, so the database lives in Germany West Central while the data lake stays in Belgium Central. A SQL server and its database must be in the same region.
- **A perpetual diff means my code and Azure describe the same thing differently.** I wrote the SKU as `GP_S_Gen5_2`, Azure stores it as `GP_S_Gen5` with capacity 2, and `terraform plan` kept showing a change until my code matched what Azure returns.
- **Antivirus can break developer tools.** Avast's HTTPS scanning replaces certificates, which broke the Azure CLI and also Terraform's private connection to its own plugins. The fix is not to turn off certificate checks; it's to find out who is replacing the certificate and deal with that.

## Day 3: First Data Factory pipeline

### What I learned about Data Factory

- **Linked service:** the connection details for an outside system, such as an address and how to sign in. Mine point to the Frankfurter API and to my data lake.
- **Dataset:** the specific data inside a connection, such as one API response or one file.
- **Activity:** one step of work, such as "set a variable" or "copy data".
- **Pipeline:** a group of activities that run together in a set order.
- **Parameter:** a value passed in when something runs. `run_date` lets the same pipeline load any date, and if it's empty the pipeline uses today's UTC date.
- **Managed identity for ADLS:** Data Factory proves who it is with its Azure-managed identity, and its "Storage Blob Data Contributor" role allows it to write files. No account key or SAS token exists to leak, and shared key access is turned off on the account anyway.

### How the data is stored

- **Partitioned folders:** each day gets its own folder, such as `fx_rates/date=2026-10-30/`. A later step can read one day without scanning everything, and re-running a day overwrites only that day's file.
- **Why bronze keeps raw JSON:** bronze is my record of what the source sent. If I find a mistake in my cleaning code, I can fix it and rebuild silver and gold without asking the API again.

### ECB working-day rates

- The ECB publishes rates on working days only, so weekends and holidays have no new rates.
- Frankfurter doesn't return an error for those days. It returns `200 OK` with the last published rates, and it did the same for a future date when I tested it.
- So the folder date is the day I asked for, and the `date` inside the file is the day the rates were published. For Saturday 2026-10-31, the file inside `date=2026-10-31` says `2026-10-30`. Later steps should trust the `date` inside the file.

### Choosing the right connector

- **WebTable:** reads tables out of HTML web pages. It can't be used for my API, and my first pipeline run failed with "The connector WebTable is not supported".
- **HTTP:** downloads whatever a URL returns, such as a file or one API response. This is what I use, because one GET request returns everything I need.
- **REST:** made for JSON APIs that need extra handling, such as following many pages of results. Frankfurter doesn't need that here.
- **Why Binary keeps bronze byte-exact:** a Binary copy moves the bytes without reading them, while a JSON copy reads the data and writes it out again, which can change the formatting. With Binary, `rates.json` is exactly what the API sent, but the Copy activity can't check that the content is valid JSON, so a later step has to.

### What went wrong and how I fixed it

- **First run failed:** ErrorCode 2200, "The connector WebTable is not supported". The Web linked service only reads HTML tables.
- **Fix:** I switched to an HTTP (`HttpServer`) linked service with Binary source and sink datasets, so the JSON is copied byte-for-byte into bronze.
- **Terraform race:** swapping the linked service type but keeping the name caused a create/delete race ("already exists"). A second `terraform apply` fixed it.
- **Successful run:** on 2026-11-01 with `run_date=2026-10-30`, the pipeline took 32s and wrote `bronze/fx_rates/date=2026-10-30/rates.json` (134 B).

## Day 4: Payments simulator and bronze to silver

### What I built

- **Seeded simulator (standard library only):** it makes 2,000 rows a day. Using the date as the random seed means the same date always gives an identical file.
- **Planted fraud:** 10 high-amount payments, 3 velocity cards and 3 impossible-travel cards.
- **Planted dirty data:** 20 duplicates, 10 empty amounts, 6 bad timestamps and 5 lowercase currencies.
- **Upload:** I uploaded the file to `bronze/payments/date=.../payments.csv` using `az` with `--auth-mode login`, because shared keys are disabled.
- **ADF Copy from bronze CSV to silver Parquet:** it adds lineage columns (`ingest_run_id`, `source_file`, `ingested_at_utc`) that show where each row came from. Rows that can't be converted are skipped and written to a reject log.

### Lesson: a green run doesn't prove the data is right

- **First run:** it said 2000 read, 2000 written, 0 skipped. That looked fine, but opening the Parquet showed that every column was a string.
- **Why:** with no dataset schema, ADF never converted the types, so nothing could be rejected.
- **Fix:** I declared schemas on both datasets and added source types to the mapping.
- **Re-run:** 2000 read, 1994 written, 6 skipped, matching the planted bad timestamps. The reject log lists exactly those 6 rows.
- **Still open:** `amount` is a real decimal now, but it came out as `decimal(38,18)` instead of the `decimal(18,2)` I declared. The values are correct, so I need to round or cast it in a later step.

### Left for Day 5 SQL

Duplicates, NULL amounts and lowercase currency codes are still in silver. They're valid for their column types, so this copy doesn't reject them.

## Day 5: Azure SQL warehouse and fraud rules

### What I built

- **Star schema in Azure SQL:** `dw.fact_payment` sits in the middle, with `dim_card`, `dim_merchant` and `dim_date` around it. `dw.fx_rate`, `dw.reject_payment`, `dw.load_audit` and `stg.payments` support the load.
- **Managed identity in SQL:** Data Factory signs in with its managed identity (`CREATE USER ... FROM EXTERNAL PROVIDER`). It has least privilege: it can write to `stg`, but only has SELECT and EXECUTE on `dw`.
- **`pl_load_warehouse`:** Lookup FX json runs `usp_load_fx_rates`, while Copy silver to `stg` runs in parallel (it runs TRUNCATE first). `usp_load_payments` starts when both have succeeded. Activities retry 2 times, 60 seconds apart, because the free database auto-pauses and needs time to wake up.

### Results for 2026-10-30

- **Rows:** 1994 staged, 1964 loaded and 30 rejected (20 `duplicate`, 10 `missing_amount`).
- **Planted fraud:** all caught, with 0 false positives: 10 high amount, 23 velocity rows on 3 cards and 3 impossible travel, making 36 suspicious rows.
- **Reconciliation:** 14 of 14 checks PASS against counts predicted independently in Python.
- **Idempotency test:** I ran the pipeline twice and still had 1964 fact rows, with 2 audit rows. Idempotent means running it again doesn't change the answer.

### Gotchas

- **Portal Query editor:** it showed only the last result set, and it rejected COLLATE in a WHERE. I used one UNION ALL query and a VARBINARY comparison instead.
- **Terraform perpetual diff:** ADF adds `compressionProperties = null` to `formatSettings`, so I declared it explicitly to make my code match what Azure returns.

## Day 6: Daily orchestration and alerts

### How the daily run works

- **Watermark:** `dw.usp_get_dates_to_load` finds every day since the first successful load that has no 'succeeded' audit row. It's gap-aware, not "last date + 1", so a failed day in the middle is never forgotten. It returns the oldest days first, with at most 7 per run.
- **Orchestration:** `pl_daily` looks up the missing dates, then runs a sequential ForEach. For each date it calls `pl_run_day`, which runs FX ingest and bronze to silver in parallel, then the warehouse load.
- **Trigger:** `tr_daily_0600` runs at 06:00 GMT Standard Time with `up_to_date` set to yesterday. I created it but left it OFF, because the simulator upload is manual.

### Test 1: catch-up

- I ran `pl_daily` with `up_to_date` 2026-11-01. It found 31 Oct and 1 Nov and loaded both.
- **Each day:** 1964 loaded and 30 rejected. 31 Oct had 18 velocity rows, matching the simulator.
- **Weekend days:** they used Friday's ECB rates (`ecb_date` 2026-10-30).
- **Paused database:** it had been paused for a week. The Lookup took 58s, and the retries absorbed the delay.

### Test 2: failure

- I ran `pl_daily` for 2026-11-02 with no payments file.
- Bronze to silver retried twice and failed, so the warehouse load never started and `pl_daily` failed.
- The Azure Monitor alert (`PipelineFailedRuns` > 0, emailed through the action group) fired.

### Setup notes

- I registered `Microsoft.Insights` manually, because Terraform has `resource_provider_registrations = "none"`.
- The alert email is passed with `-var alert_email` and is never committed.
