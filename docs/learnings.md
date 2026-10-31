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
