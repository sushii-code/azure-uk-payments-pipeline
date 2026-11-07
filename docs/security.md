# Security

How this project is kept secure, in simple words. It was last reviewed on Day 7.

## Identity: no passwords or keys anywhere

- **Data Factory:** it signs in to storage and SQL with its own **managed identity**, which Azure creates and rotates. No password or key is stored anywhere.
- **Azure SQL:** it uses **Microsoft Entra ID sign-in only**. SQL logins and passwords are switched off, so there's no SQL password to leak.
- **Storage:** **shared key access is disabled**, so account keys and SAS tokens don't work. Every request has to be signed in with Entra ID.
- **My uploads:** I upload files with `az storage blob upload --auth-mode login`, using my own Entra sign-in.
- **Terraform:** it uses my `az login` session, not a stored secret.

## Least privilege: only the access that's needed

| Who | Role | Scope | Why |
| --- | --- | --- | --- |
| Data Factory (managed identity) | Storage Blob Data Contributor | Storage account only | Reads and writes the bronze and silver files |
| Me (user) | Storage Blob Data Contributor | Storage account only | Lets me upload the simulator files |
| Me (user) | Owner | Subscription | It's a single-person student subscription (see accepted risks) |

**Key Vault:** nobody has a secrets role, because the vault is empty. A role gets added only when a real secret is needed.

**Inside Azure SQL** (`sql/01_setup.sql`), Data Factory's database user has:
- **`stg` schema:** SELECT, INSERT, UPDATE, DELETE and ALTER, so it can empty and load the staging table.
- **`dw` schema:** only SELECT and EXECUTE. It can't change warehouse tables directly, only through the stored procedures.

## Data protection

- **Encryption in transit:** TLS 1.2 is the minimum on storage and SQL, and storage accepts HTTPS only.
- **Encryption at rest:** storage encryption is on, and SQL has TDE (transparent data encryption) switched on.
- **No anonymous access:** public blob access is off, so nobody can read a file without signing in.
- **Soft delete:** deleted files and containers can be restored for 7 days.

## Secrets in code

- **gitleaks:** it scans every push and pull request, including the full git history (`.github/workflows/secret-scan.yml`).
- **`.gitignore`:** it covers Terraform state, `.terraform/`, `*.tfvars`, `.env` files, `data/` and `.venv/`.
- **Personal values:** my alert email and laptop IP are passed with `-var` on the command line and are never committed.

## Accepted risks for a dev project

| Risk | Why it's accepted here | What production would do |
| --- | --- | --- |
| SQL firewall allows "Azure services", and the storage endpoint is public | Data Factory needs to reach them, and private networking costs money | Data Factory managed virtual network with private endpoints, and public access off |
| No SQL auditing | It costs extra, and only I use the database | Send SQL auditing to Log Analytics |
| No blob versioning | Every overwrite would keep a paid copy | Turn versioning on for important containers |
| Key Vault purge protection is off | The vault is empty, and this setting can't be turned off again | Turn on purge protection once real secrets are stored |
| I'm Owner of the subscription | It's a single-person student subscription | Separate admin and day-to-day accounts, with just-in-time access |

## How to verify

These are read-only checks. Run each one after `az login`:

```bash
# Who has which role (shows IDs, not names)
az role assignment list --all --include-inherited --query "[].{principal:principalId,type:principalType,role:roleDefinitionName,scope:scope}" -o table

# SQL: Entra-only sign-in, TLS version and public access
az sql server show -g rg-ukpay-dev -n sql-ukpay-dev-de-e0vivl --query "{entraOnly:administrators.azureAdOnlyAuthentication,tls:minimalTlsVersion,public:publicNetworkAccess}"

# SQL firewall rules
az sql server firewall-rule list -g rg-ukpay-dev -s sql-ukpay-dev-de-e0vivl -o table

# SQL encryption at rest
az sql db tde show -g rg-ukpay-dev -s sql-ukpay-dev-de-e0vivl -d sqldb-ukpay-dev --query state

# Storage: shared keys, TLS, HTTPS only, public blob access, network
az storage account show -g rg-ukpay-dev -n stukpaydeve0vivl --query "{sharedKey:allowSharedKeyAccess,tls:minimumTlsVersion,httpsOnly:enableHttpsTrafficOnly,blobPublic:allowBlobPublicAccess,network:networkRuleSet.defaultAction}"

# Storage: soft delete
az storage account blob-service-properties show -g rg-ukpay-dev -n stukpaydeve0vivl --query "{blob:deleteRetentionPolicy,container:containerDeleteRetentionPolicy}"

# Key Vault: RBAC, soft delete, purge protection
az keyvault show -n kv-ukpay-dev-e0vivl --query "{rbac:properties.enableRbacAuthorization,softDelete:properties.enableSoftDelete,purgeProtection:properties.enablePurgeProtection}"

# Key Vault: number of secrets (shows the count only, never the values)
az keyvault secret list --vault-name kv-ukpay-dev-e0vivl --query "length(@)"

# Repo: secrets and tracked files that should be ignored
git ls-files -z | xargs -0 grep -IiE "AccountKey=|sig=|Password=|-----BEGIN"
git ls-files | grep -E "\.tfstate|\.tfvars|(^|/)\.env|^data/"
```

The last two commands should print nothing. On Windows, run the `az` commands in Git Bash, or put each command on one line in PowerShell.

The Key Vault secret count needs a secrets read role, which nobody has now. Expect it to return a permission error, which also shows the least-privilege setting is working.
