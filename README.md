# CTC Credentials Pipeline

A PowerShell automation pipeline for California school districts and county offices of education (COEs) that automates the export of certificated employee data from a HR/Payroll or HCM system and syncs it directly to the California Commission on Teacher Credentialing (CTC) SFTP server.

**Real-world impact:** Replaced a manual, UI-driven upload process that consumed ~40 hours/month for a single Personnel credentials analyst. The entire workflow now runs unattended on a scheduled timer. 

## The Problem

California's [Commission on Teacher Credentialing (CTC)](https://www.ctc.ca.gov/) maintains a database of certificated employee credentials, including expiration dates. School districts and COEs are responsible for keeping this data current — if a teacher's credential expires and the district hasn't reported correctly, it creates a compliance risk.

Most HR/Payroll and HCM platforms used in California K-12 **do not have a native integration** with CTC's database. The typical workflow is entirely manual: a credentials analyst or designated employee logs into CTC's web UI, navigates to the upload section, and submits updated employee data by hand. For a county office managing credentials data across multiple districts, this is extremely time-consuming.

CTC does expose an **SFTP endpoint** for bulk data uploads. This pipeline uses that to bypass the UI entirely.

## Who This Is For

- California **school districts** or **county offices of education (COEs)**
- Running any HR/Payroll or HCM system that can export data via SQL query with [DBVisualizer](https://www.dbvis.com/) or another CLI-accessible query tool connected to your database
- Looking to eliminate manual CTC credential upload work from their Personnel/Credentials department

If your system can produce a correctly formatted CSV export, this pipeline handles everything from there.

## Pipeline Architecture

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

All stages write timestamped log entries. If any stage fails, an error notification is sent automatically with the relevant log file attached.

## About the SQL Export

The SQL query (not included — it will be specific to your HCM schema) should produce a CSV matching CTC's required upload format. CTC's bulk upload specification defines required fields for certificated employee assignment reporting. Your Personnel or IT team should have access to the CTC Data Submission Guide, which outlines the expected columns and formatting.

The 120-second sleep buffers in `Execute.ps1` exist because DBVisualizer's CLI (`dbviscmd.bat`) signals completion before it finishes flushing file output in some configurations. Adjust or remove these if your environment handles exit codes reliably.

## Scripts

| Script | Purpose |
|---|---|
| `Execute.ps1` | Entry point. Calls DBVisualizer exports sequentially, then hands off to syncdelete. Sends alert email on any failure. |
| `syncdelete.ps1` | Connects to SFTP via WinSCP, syncs the local export directory to the remote path, then deletes local files after a confirmed successful upload. |
| `SendMail-GraphAPI.ps1` | Sends an error notification email via Microsoft Graph API with the WinSCP session log attached. Uses client credentials flow (no user login required). |

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

## Setup

### 1. Store credentials securely

Never hardcode passwords. Store them in Windows Credential Manager:

```powershell
# SFTP credentials
New-StoredCredential -Target "WinSCP_hostname_username" `
    -UserName "your_sftp_username" `
    -Password "your_sftp_password" `
    -Persist LocalMachine

# Graph API client secret (store clientId as username, secret as password)
New-StoredCredential -Target "GRAPH_API_Credential" `
    -UserName "your-client-id" `
    -Password "your-client-secret" `
    -Persist LocalMachine
```

### 2. Configure paths

Update the following placeholders across all three scripts:

| Placeholder | Replace with |
|---|---|
| `C:\Path\To\DBVisualizer\dbviscmd.bat` | Full path to your DBVisualizer CLI batch file |
| `E:\Path\To\export.sql` | Path to your certificated employee SQL export query |
| `E:\Path\To\EXPORT` | Local staging folder where DBVisualizer writes CSV output |
| `C:\Path\To\Logs\` | Directory for pipeline log files |
| `C:\Path\To\WinSCPnet.dll` | Path to the WinSCP .NET assembly DLL |
| `SFTP.Host.Address` | CTC's SFTP hostname (obtain from CTC's Data Submission documentation) |
| `/weekly_upload` | Remote SFTP path provided by CTC (if different) |
| `sender@domain.org` | M365 mailbox used to send error alerts |
| `recipient@domain.org` | Personnel or IT sysadmin who should receive failure notifications |
| `ENTER TENANT ID` | Your Azure AD / Entra tenant ID |

### 3. Get the SFTP host key fingerprint

```powershell
# WinSCP will display the fingerprint on first connection.
# Copy it and paste into syncdelete.ps1:
SshHostKeyFingerprint = "ssh-rsa 2048 xx:xx:xx:..."
```

### 4. Schedule with Task Scheduler

- **Trigger:** Weekly (or whatever cadence your partner expects)  
- **Action:** `powershell.exe -ExecutionPolicy Bypass -File "E:\Path\To\Execute.ps1"`  
- **Run as:** A service account with access to the credential store and log directories  
- **"Run whether user is logged on or not"**: enabled

---

## Security Notes

- **No credentials are hardcoded.** All secrets are read at runtime from Windows Credential Manager.
- The `ConvertTo-PlainText` helper uses `Marshal` with explicit `ZeroFreeBSTR` cleanup to minimize the window that plaintext exists in memory.
- The Graph API app registration should be scoped to `Mail.Send` only — no broader permissions needed.
- Review WinSCP session logs carefully before sharing; they may contain session metadata.

---

## Known Limitations / Future Improvements

- The `Start-Sleep` buffers in `Execute.ps1` are a pragmatic workaround for DBVisualizer's lack of a reliable exit-on-completion signal for file writes. A more robust approach would poll for file presence/lock status.
- No retry logic on transient SFTP failures. For higher-reliability requirements, consider wrapping the WinSCP sync in a retry loop with exponential backoff.
- Email notification fires only on SFTP sync failure, not on DBVisualizer export failure. `Execute.ps1` now handles the latter, but both funnel to the same `SendMail-GraphAPI.ps1`.
- This pipeline only handles one direction of the credentials process (HCM DB Export to CTC SFTP). Getting the resulting reports that CTC creates from this data back into your organizations HCM system will still require human intervention. 

