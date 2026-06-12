# CTC Credential Export Pipeline

A PowerShell automation pipeline for California school districts and county offices of education (COEs) that automates the synchronization of updated certificated employee data between a HR/Payroll or HCM system database and the California Commission on Teacher Credentialing (CTC) SFTP server.

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
  Execute-Send.ps1      ← Orchestrator: runs SQL export, handles top-level errors
        │
        └──► DBVisualizer CLI   ← Queries HCM/ERP DB, writes CSV to local staging path
                  [120s buffer]
                      │
                      ▼
              hcm-to-ctc.ps1   ← Syncs staging folder to CTC SFTP; deletes local files on success
                      │
                      └── on error ──► SendMail-GraphAPI.ps1   ← Emails sysadmin with log attached
```

### Pipeline 2 — Retrieve from CTC → HCM/ERP (inbound)

Retrieves CTC's weekly credential report from their SFTP and forwards it to your HCM/ERP platform's SFTP for import. Schedule this task to run after CTC's report generation window.

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
        ├── on success ──► SendCompletion-GraphAPI.ps1   ← Notifies necessary staff; includes import instructions and screenshots
        │
        └── on error ──► SendMail-GraphAPI.ps1   ← Emails sysadmin with log attached
```

All stages in both pipelines write timestamped log entries. If any stage fails, an error notification is sent automatically with the relevant log file attached.

---

## About the SQL Export

The SQL query (not included — it will be specific to your HCM schema) should produce a CSV matching CTC's required upload format. CTC's bulk upload specification defines required fields for certificated employee assignment reporting. Your Personnel or IT team should have access to the CTC Data Submission Guide, which outlines the expected columns and formatting.

The 120-second sleep buffer in `Execute-Send.ps1` exists because DBVisualizer's CLI (`dbviscmd.bat`) signals completion before it finishes flushing file output in some configurations. Adjust or remove it if your environment handles exit codes reliably.

---

## Scripts

| Script | Pipeline | Purpose |
|---|---|---|
| `Execute-Send.ps1` | Export | Entry point for Pipeline 1. Calls DBVisualizer export, then hands off to hcm-to-ctc. Sends alert email on any failure. |
| `hcm-to-ctc.ps1` | Export | Connects to CTC SFTP via WinSCP, syncs the local staging directory to the remote path using idempotent directory sync, then deletes local files after a confirmed successful upload. |
| `Execute-Retrieve.ps1` | Retrieve | Entry point for Pipeline 2. Hands off to ctc-to-hcm. Sends alert email on any failure. |
| `ctc-to-hcm.ps1` | Retrieve | Pulls the most recent `C21_YYYYMMDD.txt` from CTC's credentials folder and all `.txt` files from CTC's config folder, then uploads each to the corresponding destination on your HCM/ERP SFTP. All configuration is consolidated at the top of the script. Transfer behavior is controlled by the `$overwriteConfig` and `$smartConfigSync` toggles. |
| `SendCompletion-GraphAPI.ps1` | Retrieve | Sends a completion notification email to Personnel staff when the inbound pipeline finishes, including step-by-step import instructions with inline screenshots. Called by `ctc-to-hcm.ps1` on success. |
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

# HCM/ERP SFTP credentials (Pipeline 2 only)
New-StoredCredential -Target "WinSCP_HCM_target_name" `
    -UserName "your_hcm_sftp_username" `
    -Password "your_hcm_sftp_password" `
    -Persist LocalMachine

# Graph API client secret (store clientId as username, secret as password)
New-StoredCredential -Target "GRAPH_API_Credential" `
    -UserName "your-client-id" `
    -Password "your-client-secret" `
    -Persist LocalMachine
```

### 2. Configure paths

**Pipeline 1 — `Execute-Send.ps1` and `hcm-to-ctc.ps1`:**

| Placeholder | Replace with |
|---|---|
| `C:\Path\To\DBVisualizer\dbviscmd.bat` | Full path to your DBVisualizer CLI batch file |
| `E:\Path\To\export.sql` | Path to your certificated employee SQL export query |
| `prodhrspay` | Your DBVisualizer connection name |
| `E:\Path\To\hcm-to-ctc.ps1` | Full path to `hcm-to-ctc.ps1` in `Execute-Send.ps1` |
| `E:\Path\To\EXPORT` | Local staging folder where DBVisualizer writes CSV output |
| `C:\Path\To\Logs\` | Directory for pipeline log files |
| `C:\Path\To\WinSCPnet.dll` | Path to the WinSCP .NET assembly DLL |
| `WinSCP_CTC_target_name` | Windows Credential Manager target name for CTC SFTP credentials |
| `CTC.SFTP.Host.Address` | CTC's SFTP hostname (from CTC's Data Submission documentation) |
| `22` | CTC SFTP port — update if anything other than default |
| `/weekly_upload` | Remote SFTP path provided by CTC |
| `90` (`$logRetentionDays`) | Number of days of pipeline log entries to retain; older entries are trimmed at the start of each run |
| `30` (`$sessionLogRetentionDays`) | Number of days of WinSCP session log entries to retain (session logs grow larger; shorter window is appropriate) |
| `recipient@domain.org` | Personnel or IT sysadmin to receive failure notifications |
| `ENTER TENANT ID` | Your Azure AD / Entra tenant ID |
| `[Server Name]` | Friendly hostname shown in alert email body |

**Pipeline 2 — `Execute-Retrieve.ps1` and `ctc-to-hcm.ps1`:**

All configuration for `ctc-to-hcm.ps1` is consolidated in the configuration block at the top of the script.

| Placeholder | Replace with |
|---|---|
| `E:\Path\To\STAGING` | Local staging root — the script creates `\credentials` and `\config` subdirectories automatically |
| `C:\Path\To\Logs\CTCToHCM_Log.txt` | Path for the pipeline log file |
| `C:\Path\To\Logs\CTCToHCM_LastRun.txt` | Path for the last-run timestamp file (used by smart config sync; created automatically on first successful run) |
| `WinSCP_CTC_target_name` | Windows Credential Manager target name for CTC SFTP credentials |
| `CTC.SFTP.Host.Address` | CTC's SFTP hostname |
| `/ctc_credentials_folder` | CTC remote path containing `C21_YYYYMMDD.txt` versioned credential files |
| `/ctc_config_folder` | CTC remote path containing setup/reference `.txt` files |
| `WinSCP_HCM_target_name` | Windows Credential Manager target name for HCM/ERP SFTP credentials |
| `HCM.SFTP.Host.Address` | Your HCM/ERP platform's SFTP hostname (from your vendor) |
| `22` | HCM/ERP SFTP port — update if your vendor uses a different port |
| `/hcm_credentials_destination` | Inbound path on HCM SFTP for the credential data file (from your vendor) |
| `/hcm_config_destination` | Inbound path on HCM SFTP for config/reference files (from your vendor) |
| `E:\Path\To\ctc-to-hcm.ps1` | Full path to `ctc-to-hcm.ps1` in `Execute-Retrieve.ps1` |
| `E:\Path\To\SendCompletion-GraphAPI.ps1` | Full path to `SendCompletion-GraphAPI.ps1` in `ctc-to-hcm.ps1` |
| `E:\Path\To\Instructions\Screenshots` | Folder containing screenshot image files (`step1.png`, `step2.png`, etc.) |
| `recipient@domain.org` (SendCompletion) | Primary recipient for the completion notification — typically your credentials analyst or Personnel staff |
| `cc-recipient-1@domain.org` | CC recipients for the completion notification — add or remove entries in the `$ccList` array |
| `bcc-recipient-1@domain.org` | BCC recipients for the completion notification — add or remove entries in the `$bccList` array |

**Inline screenshot instructions (`SendCompletion-GraphAPI.ps1`):**

The completion email supports inline screenshots embedded directly in the body. To configure for your HCM/ERP system:

1. Save your instruction screenshots as `step1.png`, `step2.png`, etc. in `$screenshotFolder`
2. Update `$stepImages` in the config block to list your filenames in order
3. Update the `$emailBody` here-string with your instruction text — each step's screenshot is referenced with `<img src="cid:stepN" />` where `stepN` matches the filename without extension
4. To update instructions later, replace the image files in the folder — no script changes needed
| `90` (`$logRetentionDays`) | Number of days of pipeline log entries to retain |
| `30` (`$sessionLogRetentionDays`) | Number of days of WinSCP session log entries to retain |

**Behavior toggles (set in the configuration block at the top of `ctc-to-hcm.ps1`):**

`$overwriteConfig` — controls whether existing config files on your HCM SFTP are overwritten. Defaults to `$True`. Set to `$False` if your HCM platform manages its own config versioning and should not have files replaced automatically.

`$smartConfigSync` — when `$True`, parses `Dates_tables_updated.txt` and only uploads config files whose last-changed date is on or after the previous scheduled run. Defaults to `$False` (upload all config files every run). Requires `$overwriteConfig = $True` to be meaningful. If no last-run record exists yet, falls back to a full upload automatically.

### 3. Get SFTP host key fingerprints

WinSCP will display each server's fingerprint on first connection. Copy and paste into the relevant script:

```powershell
# In hcm-to-ctc.ps1 config block (Pipeline 1 — CTC push):
$ctcHostKey = "ssh-rsa #### xx:xx:xx:..."

# In ctc-to-hcm.ps1 config block (Pipeline 2 — CTC pull):
$ctcHostKey = "ssh-rsa #### xx:xx:xx:..."

# In ctc-to-hcm.ps1 config block (Pipeline 2 — HCM/ERP push):
$hcmHostKey = "ssh-rsa #### xx:xx:xx:..."
```

### 4. Schedule with Task Scheduler

**Pipeline 1:**
- **Trigger:** Weekly, ahead of your CTC reporting deadline
- **Action:** `powershell.exe -ExecutionPolicy Bypass -File "E:\Path\To\Execute-Send.ps1"`

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
- Alert emails attach the **pipeline log** of the failing script (`HMCtoCTC_Log.txt`, `CTCToHCM_Log.txt`, etc.), not the WinSCP session logs. Session logs are retained on disk for manual inspection when debugging SFTP-specific issues but are not emailed — they can be large and contain session metadata.
- Review WinSCP session logs carefully before sharing; they may contain session metadata.

---

## Known Limitations / Future Improvements

- The `Start-Sleep` buffer in `Execute-Send.ps1` is a pragmatic workaround for DBVisualizer's lack of a reliable exit-on-completion signal for file writes. A more robust approach would poll for file presence/lock status.
- No retry logic on transient SFTP failures. For higher-reliability requirements, consider wrapping WinSCP sync calls in a retry loop with exponential backoff.
- Pipeline 2 guards against an empty CTC remote directory but cannot distinguish between CTC being late and a genuine absence of new data. If CTC skips a week, the script will still alert. Consider filtering by file date if that becomes noisy.
- Log rotation trims entries by date prefix from a single rolling file rather than archiving. If you need to preserve a full historical record, consider adjusting `$logRetentionDays` or implementing file-based archiving instead.

---

## License

MIT — use freely, adapt as needed.