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
