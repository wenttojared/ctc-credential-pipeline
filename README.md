# CTC Credential Export Pipeline

A PowerShell automation pipeline for California school districts and county offices of education (COEs) that automates the export of certificated employee data from a legacy HR/Payroll or HCM system and syncs it directly to the California Commission on Teacher Credentialing (CTC) SFTP server.

**Real-world impact:** Replaced a manual, UI-driven upload process that consumed ~40 hours/month for a single Personnel staff member. The entire workflow now runs unattended on a scheduled timer.

---

## The Problem

California's [Commission on Teacher Credentialing (CTC)](https://www.ctc.ca.gov/) maintains a database of certificated employee credentials, including expiration dates. School districts and COEs are responsible for keeping this data current — if a teacher's credential expires and the district hasn't reported correctly, it creates a compliance risk.

Most HR/Payroll and HCM platforms used in California K-12 — legacy and modern alike — **do not have a native integration** with CTC's database. The typical workflow is entirely manual: a Personnel technician logs into CTC's web UI, navigates to the upload section, and submits updated employee data by hand. For a county office managing data across multiple districts, this is extremely time-consuming.

CTC does expose an **SFTP endpoint** for bulk data uploads. This pipeline uses that to bypass the UI entirely.

---

## Who This Is For

- California **school districts** or **county offices of education (COEs)**
- Running any HR/Payroll or HCM system that can export data via SQL query (Escape, Alio, Infinite Visions, Munis, or similar)
- With [DBVisualizer](https://www.dbvis.com/) or another CLI-accessible query tool connected to your database
- Looking to eliminate manual CTC credential upload work from their Personnel department

If your system can produce a correctly formatted CSV export, this pipeline handles everything from there.

---

## Pipeline Architecture

This repo contains two independent pipelines, each triggered by a separate scheduled task.

### Pipeline 1 — Export to CTC (outbound)

Exports certificated employee data from your HCM/ERP database and pushes it to CTC's SFTP for credential reporting.

```
Windows Task Scheduler (weekly or on-demand)
        │
        ▼
  Execute.ps1          ← Orchestrator: runs SQL export, handles top-level errors
        │
        └──► DBVisualizer CLI   ← Queries HCM/ERP DB, writes CSV to local staging path
                  [120s buffer]
                      │
                      ▼
              syncdelete.ps1   ← Syncs staging folder to CTC SFTP; deletes local files on success
                      │
                      └── on error ──► SendMail-GraphAPI.ps1   ← Emails sysadmin with log attached
```

### Pipeline 2 — Retrieve from CTC → Frontline (inbound)

Retrieves CTC's weekly credential report from their SFTP and forwards it to Frontline's SFTP for import. Schedule this task to run after CTC's report generation window.

```
Windows Task Scheduler (weekly, after CTC report window)
        │
        ▼
  Execute-Retrieve.ps1     ← Orchestrator: handles top-level errors
        │
        ▼
  ctc-to-hcm.ps1          ← Pulls report from CTC SFTP to local staging,
        │                     pushes staging to HCM/ERP SFTP,
        │                     then clears the staging directory
        │
        └── on error ──► SendMail-GraphAPI.ps1   ← Emails sysadmin with log attached
```

All stages in both pipelines write timestamped log entries. If any stage fails, an error notification is sent automatically with the relevant log file attached.

---

## About the SQL Export

The SQL query (not included — it will be specific to your HCM schema) should produce a CSV matching CTC's required upload format. CTC's bulk upload specification defines required fields for certificated employee assignment reporting. Your Personnel or IT team should have access to the CTC Data Submission Guide, which outlines the expected columns and formatting.

The 120-second sleep buffer in `Execute.ps1` exists because DBVisualizer's CLI (`dbviscmd.bat`) signals completion before it finishes flushing file output in some configurations. Adjust or remove it if your environment handles exit codes reliably.

---

## Scripts

| Script | Pipeline | Purpose |
|---|---|---|
| `Execute.ps1` | Export | Entry point for Pipeline 1. Calls DBVisualizer export, then hands off to syncdelete. Sends alert email on any failure. |
| `syncdelete.ps1` | Export | Connects to CTC SFTP via WinSCP, syncs the local staging directory to the remote path, then deletes local files after a confirmed successful upload. |
| `Execute-Retrieve.ps1` | Retrieve | Entry point for Pipeline 2. Hands off to ctc-to-hcm. Sends alert email on any failure. |
| `ctc-to-hcm.ps1` | Retrieve | Pulls the most recent `C21_YYYYMMDD.txt` from CTC's credentials folder and all `.txt` files from CTC's config folder, then uploads each to the corresponding destination on your HCM/ERP SFTP. Config overwrite behavior is controlled by the `$overwriteConfig` toggle. |
| `SendMail-GraphAPI.ps1` | Both | Sends an error notification email via Microsoft Graph API with the WinSCP session log attached. Uses client credentials flow (no user login required). |

---

## Prerequisites

### Software
- [DBVisualizer](https://www.dbvis.com/) with CLI access (`dbviscmd.bat`)  
- [WinSCP](https://winscp.net/) with the [.NET assembly](https://winscp.net/eng/docs/library) installed  
- PowerShell 5.1+ (ships with Windows Server / Windows 10+)

### PowerShell Modules
```powershell
# Install CredentialManager module (requires admin)
Install-Module -Name CredentialManager
```

### Microsoft Graph API App Registration
You'll need an Azure AD app registration with `Mail.Send` application permission (not delegated). This allows the script to send mail without an interactive login.

---

## Setup

### 1. Store credentials securely

Never hardcode passwords. Store them in Windows Credential Manager:

```powershell
# CTC SFTP credentials (used by both pipelines)
New-StoredCredential -Target "WinSCP_CTC_target_name" `
    -UserName "your_ctc_sftp_username" `
    -Password "your_ctc_sftp_password" `
    -Persist LocalMachine

# Frontline SFTP credentials (Pipeline 2 only)
New-StoredCredential -Target "WinSCP_Frontline_target_name" `
    -UserName "your_frontline_sftp_username" `
    -Password "your_frontline_sftp_password" `
    -Persist LocalMachine

# Graph API client secret (store clientId as username, secret as password)
New-StoredCredential -Target "GRAPH_API_Credential" `
    -UserName "your-client-id" `
    -Password "your-client-secret" `
    -Persist LocalMachine
```

### 2. Configure paths

**Pipeline 1 — `Execute-Send.ps1` and `syncdelete.ps1`:**

| Placeholder | Replace with |
|---|---|
| `C:\Path\To\DBVisualizer\dbviscmd.bat` | Full path to your DBVisualizer CLI batch file |
| `E:\Path\To\export.sql` | Path to your certificated employee SQL export query |
| `E:\Path\To\EXPORT` | Local staging folder where DBVisualizer writes CSV output |
| `C:\Path\To\Logs\` | Directory for pipeline log files |
| `C:\Path\To\WinSCPnet.dll` | Path to the WinSCP .NET assembly DLL |
| `SFTP.Host.Address` | CTC's SFTP hostname (from CTC's Data Submission documentation) |
| `/weekly_upload` | Remote SFTP path provided by CTC |
| `sender@domain.org` | M365 mailbox used to send error alerts |
| `recipient@domain.org` | Personnel or IT sysadmin to receive failure notifications |
| `ENTER TENANT ID` | Your Azure AD / Entra tenant ID |

**Pipeline 2 — `Execute-Retrieve.ps1` and `ctc-to-hcm.ps1`:**

| Placeholder | Replace with |
|---|---|
| `E:\Path\To\STAGING` | Local staging root — the script creates `\credentials` and `\config` subdirectories automatically |
| `CTC.SFTP.Host.Address` | CTC's SFTP hostname |
| `/ctc_credentials_folder` | CTC remote path containing `C21_YYYYMMDD.txt` versioned credential files |
| `/ctc_config_folder` | CTC remote path containing setup/reference `.txt` files |
| `HCM.SFTP.Host.Address` | Your HCM/ERP platform's SFTP hostname (from your vendor) |
| `/hcm_credentials_destination` | Inbound path on HCM SFTP for the credential data file (from your vendor) |
| `/hcm_config_destination` | Inbound path on HCM SFTP for config/reference files (from your vendor) |
| `E:\Path\To\ctc-to-hcm.ps1` | Full path to `ctc-to-hcm.ps1` in `Execute-Retrieve.ps1` |

**Config overwrite toggle:**
The `$overwriteConfig` parameter in `ctc-to-hcm.ps1` controls whether existing config files on your HCM SFTP are overwritten. It defaults to `$True`. Set it to `$False` if your HCM platform manages its own config versioning and should not have files replaced automatically.

### 3. Get SFTP host key fingerprints

WinSCP will display each server's fingerprint on first connection. Copy and paste into the relevant script:

```powershell
# In syncdelete.ps1 (Pipeline 1 — CTC push):
SshHostKeyFingerprint = "ssh-rsa 2048 xx:xx:xx:..."

# In ctc-to-hcm.ps1 (Pipeline 2 — CTC pull):
SshHostKeyFingerprint = "ssh-rsa 2048 xx:xx:xx:..."

# In ctc-to-hcm.ps1 (Pipeline 2 — HCM/ERP push):
SshHostKeyFingerprint = "ssh-rsa 2048 xx:xx:xx:..."
```

### 4. Schedule with Task Scheduler

**Pipeline 1:**
- **Trigger:** Weekly, ahead of your CTC reporting deadline
- **Action:** `powershell.exe -ExecutionPolicy Bypass -File "E:\Path\To\Execute.ps1"`

**Pipeline 2:**
- **Trigger:** Weekly, scheduled after CTC's report generation window closes
- **Action:** `powershell.exe -ExecutionPolicy Bypass -File "E:\Path\To\Execute-Retrieve.ps1"`

For both tasks:
- **Run as:** A service account with access to the credential store and log directories
- **"Run whether user is logged on or not"**: enabled

---

## Security Notes

- **No credentials are hardcoded.** All secrets are read at runtime from Windows Credential Manager.
- The `ConvertTo-PlainText` helper uses `Marshal` with explicit `ZeroFreeBSTR` cleanup to minimize the window that plaintext exists in memory.
- The Graph API app registration should be scoped to `Mail.Send` only — no broader permissions needed.
- **Restrict access to the staging directory.** The staging path transiently holds certificated employee PII while files are in transit between CTC and your HCM. Ensure it is only accessible to the service account running the scheduled task — not shared drives or broadly permissioned folders.
- Review WinSCP session logs carefully before sharing; they may contain session metadata.

---

## Known Limitations / Future Improvements

- The `Start-Sleep` buffer in `Execute.ps1` is a pragmatic workaround for DBVisualizer's lack of a reliable exit-on-completion signal for file writes. A more robust approach would poll for file presence/lock status.
- No retry logic on transient SFTP failures. For higher-reliability requirements, consider wrapping WinSCP sync calls in a retry loop with exponential backoff.
- Pipeline 2 guards against an empty CTC remote directory but cannot distinguish between CTC being late and a genuine absence of new data. If CTC skips a week, the script will still alert. Consider filtering by file date if that becomes noisy.

---

## License

MIT — use freely, adapt as needed.