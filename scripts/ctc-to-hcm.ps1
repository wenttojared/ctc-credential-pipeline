# ctc-to-hcm.ps1
# Purpose: Retrieves the weekly CTC credential report and config files from CTC's SFTP
#          and uploads them to the designated folders on your HCM/ERP platform's SFTP.
#
#          CTC exposes two folders:
#            - Credentials folder: contains versioned files named C21_YYYYMMDD.txt
#                                  Only the most recent file is transferred.
#            - Config folder:      contains setup/reference text files.
#                                  Transfer behavior controlled by $overwriteConfig
#                                  and $smartConfigSync below.
#
# Requirements:
#   - SFTP credentials and inbound folder paths from your HCM/ERP vendor
#   - SFTP credentials from CTC (requested through the CTC LEA portal)
#   - WinSCP .NET assembly installed on the host machine
#   - Both sets of credentials stored in Windows Credential Manager (see README)
#
# Pipeline: Execute-Retrieve.ps1 > ctc-to-hcm.ps1 > SendMail-GraphAPI.ps1

# =============================================================================
# CONFIGURATION — update all values in this section before deploying
# =============================================================================

# --- Paths ---
$stagingPath         = "E:\Path\To\STAGING"          # Local staging root; \credentials and \config subdirs created automatically
$logFile             = "C:\Path\To\Logs\CTCToHCM_Log.txt"
$lastRunFile         = "C:\Path\To\Logs\CTCToHCM_LastRun.txt"  # Stores timestamp of last successful run (used by smart config sync)

# --- CTC SFTP ---
$ctcCredentialTarget  = "WinSCP_CTC_target_name"      # Windows Credential Manager target for CTC SFTP
$ctcHost              = "CTC.SFTP.Host.Address"
$ctcPort              = 22                            # CTC SFTP port (if not standard 22)
$ctcHostKey           = "ssh-rsa #### paste-CTC-fingerprint-here"
$ctcCredentialPath    = "/ctc_credentials_folder"     # Remote path to C21_YYYYMMDD.txt files
$ctcConfigPath        = "/ctc_config_folder"          # Remote path to config/reference .txt files
$ctcSessionLog        = "C:\Path\To\Logs\WinSCP_CTC_SessionLog.txt"

# --- HCM/ERP SFTP ---
$hcmCredentialTarget  = "WinSCP_HCM_target_name"      # Windows Credential Manager target for HCM SFTP
$hcmHost              = "HCM.SFTP.Host.Address"
$hcmPort              = 22                            # HCM SFTP port (if not standard 22)
$hcmHostKey           = "ssh-rsa #### paste-HCM-fingerprint-here"
$hcmCredentialPath    = "/hcm_credentials_destination"
$hcmConfigPath        = "/hcm_config_destination"
$hcmSessionLog        = "C:\Path\To\Logs\WinSCP_HCM_SessionLog.txt"

# --- WinSCP ---
$winScpDllPath        = "C:\Path\To\WinSCPnet.dll"

# --- SendMail script ---
$sendMailScript       = "E:\Path\To\SendMail-GraphAPI.ps1"

# --- Log retention ---
$logRetentionDays        = 90   # Pipeline log retention in days
$sessionLogRetentionDays = 30   # WinSCP session log retention in days (these grow larger)

# --- Behavior toggles ---

# $overwriteConfig: Set to $True to overwrite existing config files on the HCM SFTP.
# Set to $False if your HCM platform manages config versioning itself.
[bool]$overwriteConfig   = $True

# $smartConfigSync: Set to $True to only upload config files whose last-changed date
# (per Dates_tables_updated.txt) is on or after the previous scheduled run date.
# Set to $False to upload all config files every run regardless of change date.
# Note: requires $overwriteConfig = $True to be meaningful; has no effect if $False.
[bool]$smartConfigSync   = $False

# --- Transfer options ---
# Resume support is disabled because the HCM SFTP is append-only — the server does not
# grant rename permission, which WinSCP requires for its default .filepart temp file pattern.
Add-Type -Path $winScpDllPath
$transferOptions = New-Object WinSCP.TransferOptions
$transferOptions.ResumeSupport.State = [WinSCP.TransferResumeSupportState]::Off

# =============================================================================
# END CONFIGURATION
# =============================================================================

$credentialStagingPath = Join-Path $stagingPath "credentials"
$configStagingPath     = Join-Path $stagingPath "config"

function Log {
    Param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

function Invoke-LogRotation {
    param([string]$path, [int]$retentionDays)
    if (-not (Test-Path $path)) { return }
    $cutoff  = (Get-Date).AddDays(-$retentionDays).ToString("yyyy-MM-dd")
    $lines   = Get-Content $path
    $trimmed = $lines | Where-Object {
        if ($_ -match "^(\d{4}-\d{2}-\d{2})") { $Matches[1] -ge $cutoff } else { $true }
    }
    $trimmed | Set-Content $path
    Log "Log rotation complete ($retentionDays day retention): $path"
}

function ConvertTo-PlainText {
    param([Security.SecureString]$secureString)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    return $plainText
}

function Clear-StagingFolder {
    param([string]$path)
    if (Test-Path $path) {
        Get-ChildItem -Path $path | ForEach-Object {
            $_ | Remove-Item -Force
            Log "Deleted staging file: $($_.FullName)"
        }
    }
}

function Get-ChangedConfigFiles {
    # Parses Dates_tables_updated.txt and returns filenames whose last-changed
    # date is on or after the provided $sinceDate.
    param(
        [string]$datesFilePath,
        [datetime]$sinceDate
    )
    $changed = @()
    $content = Get-Content $datesFilePath
    foreach ($line in $content) {
        if ($line -match "File\s+(\S+)\s+last changed on\s+(\d{2}-\d{2}-\d{4})") {
            $fileName    = $Matches[1]
            $changedDate = [datetime]::ParseExact($Matches[2], "MM-dd-yyyy", $null)
            if ($changedDate -ge $sinceDate) {
                $changed += $fileName
            }
        }
    }
    return $changed
}

Add-Type -AssemblyName System.Security

# Ensure staging subdirectories exist
New-Item -ItemType Directory -Force -Path $credentialStagingPath | Out-Null
New-Item -ItemType Directory -Force -Path $configStagingPath     | Out-Null

# Clear staging at the start of each run to prevent stale files from a previous
# failed run being picked up (cleanup at the end only runs on success)
Log "Clearing staging directories before run."
Clear-StagingFolder -path $credentialStagingPath
Clear-StagingFolder -path $configStagingPath

Invoke-LogRotation -path $logFile        -retentionDays $logRetentionDays
Invoke-LogRotation -path $ctcSessionLog  -retentionDays $sessionLogRetentionDays
Invoke-LogRotation -path $hcmSessionLog  -retentionDays $sessionLogRetentionDays

try {
    Log "WinSCP .NET assembly loaded."

    # -------------------------------------------------------------------------
    # Step 1: Pull from CTC SFTP
    # -------------------------------------------------------------------------
    $ctcCred = Get-StoredCredential -Target $ctcCredentialTarget
    $ctcSessionOptions = New-Object WinSCP.SessionOptions -Property @{
        Protocol              = [WinSCP.Protocol]::Sftp
        HostName              = $ctcHost
        PortNumber            = $ctcPort
        UserName              = $ctcCred.UserName
        Password              = ConvertTo-PlainText $ctcCred.Password
        SshHostKeyFingerprint = $ctcHostKey
    }

    $ctcSession = New-Object WinSCP.Session
    $ctcSession.SessionLogPath = $ctcSessionLog

    try {
        $ctcSession.Open($ctcSessionOptions)
        Log "CTC SFTP session opened."

        # --- Credentials folder: pull only the most recent C21_YYYYMMDD.txt ---
        $credFiles = $ctcSession.ListDirectory($ctcCredentialPath).Files `
            | Where-Object { -not $_.IsDirectory -and $_.Name -match "^C21_\d{8}\.txt$" } `
            | Sort-Object { $_.Name } -Descending

        if ($credFiles.Count -eq 0) {
            Log "WARNING: No C21_YYYYMMDD.txt files found at '$ctcCredentialPath'. Aborting."
            & $sendMailScript -logPath $logFile
            exit 1
        }

        $latestCredFile = $credFiles[0]
        Log "Most recent credentials file: $($latestCredFile.Name). Downloading."

        $ctcSession.GetFiles(
            "$ctcCredentialPath/$($latestCredFile.Name)",
            "$credentialStagingPath\$($latestCredFile.Name)"
        ).Check()

        Log "Credentials file downloaded to staging."

        # --- Config folder: pull all text files ---
        $configFiles = $ctcSession.ListDirectory($ctcConfigPath).Files `
            | Where-Object { -not $_.IsDirectory -and $_.Name -match "\.txt$" }

        if ($configFiles.Count -eq 0) {
            Log "WARNING: No .txt files found in CTC config folder '$ctcConfigPath'. Skipping config transfer."
        } else {
            Log "Found $($configFiles.Count) config file(s). Downloading."
            foreach ($file in $configFiles) {
                $ctcSession.GetFiles(
                    "$ctcConfigPath/$($file.Name)",
                    "$configStagingPath\$($file.Name)"
                ).Check()
                Log "Downloaded config file: $($file.Name)"
            }
        }
    }
    finally {
        $ctcSession.Dispose()
        Log "CTC SFTP session disposed."
    }

    # -------------------------------------------------------------------------
    # Step 2: Push to HCM/ERP SFTP
    # -------------------------------------------------------------------------
    $hcmCred = Get-StoredCredential -Target $hcmCredentialTarget
    $hcmSessionOptions = New-Object WinSCP.SessionOptions -Property @{
        Protocol              = [WinSCP.Protocol]::Sftp
        HostName              = $hcmHost
        PortNumber            = $hcmPort
        UserName              = $hcmCred.UserName
        Password              = ConvertTo-PlainText $hcmCred.Password
        SshHostKeyFingerprint = $hcmHostKey
    }

    $hcmSession = New-Object WinSCP.Session
    $hcmSession.SessionLogPath = $hcmSessionLog

    try {
        $hcmSession.Open($hcmSessionOptions)
        Log "HCM SFTP session opened."

        # --- Upload credentials file (sort descending to guarantee newest file) ---
        $credStagingFile = Get-ChildItem -Path $credentialStagingPath `
            | Sort-Object { $_.Name } -Descending `
            | Select-Object -First 1
        $hcmSession.PutFiles(
            $credStagingFile.FullName,
            "$hcmCredentialPath/$($credStagingFile.Name)",
            $False,
            $transferOptions
        ).Check()
        Log "Credentials file uploaded to HCM: $($credStagingFile.Name)"

        # --- Determine which config files to upload ---
        $configStagingFiles = Get-ChildItem -Path $configStagingPath
        $configFailures = 0

        if ($configStagingFiles.Count -gt 0) {

            # Build list of files to upload based on sync mode
            if ($smartConfigSync) {
                $datesFile = Join-Path $configStagingPath "Dates_tables_updated.txt"
                if (-not (Test-Path $datesFile)) {
                    Log "WARNING: Smart config sync enabled but Dates_tables_updated.txt not found in staging. Falling back to full upload."
                    $filesToUpload = $configStagingFiles
                } else {
                    # Read last run date; fall back to full upload if no record exists
                    if (Test-Path $lastRunFile) {
                        $lastRunDate = [datetime]::Parse((Get-Content $lastRunFile))
                        Log "Smart config sync enabled. Checking for files changed on or after last run: $($lastRunDate.ToString('MM-dd-yyyy'))."
                        $changedFileNames = Get-ChangedConfigFiles -datesFilePath $datesFile -sinceDate $lastRunDate
                        $filesToUpload = $configStagingFiles | Where-Object {
                            $changedFileNames -contains $_.Name
                        }
                        Log "$($filesToUpload.Count) config file(s) changed since last run."
                    } else {
                        Log "Smart config sync enabled but no last-run record found. Falling back to full upload."
                        $filesToUpload = $configStagingFiles
                    }
                }
            } else {
                $filesToUpload = $configStagingFiles
            }

            # Upload the resolved file list
            foreach ($file in $filesToUpload) {
                # Always upload Dates_tables_updated.txt regardless of sync mode — it's the reference file
                $hcmDestPath = "$hcmConfigPath/$($file.Name)"

                if (-not $overwriteConfig -and $file.Name -ne "Dates_tables_updated.txt") {
                    if ($hcmSession.FileExists($hcmDestPath)) {
                        Log "Skipping config file (overwrite disabled, file exists): $($file.Name)"
                        continue
                    }
                }

                try {
                    $hcmSession.PutFiles($file.FullName, $hcmDestPath, $False, $transferOptions).Check()
                    Log "Config file uploaded to HCM: $($file.Name)"
                } catch {
                    Log "WARNING: Failed to upload config file '$($file.Name)': $($_.Exception.Message)"
                    $configFailures++
                }
            }

            if ($configFailures -gt 0) {
                Log "WARNING: $configFailures config file(s) failed to upload. See above for details."
            }
        }
    }
    finally {
        $hcmSession.Dispose()
        Log "HCM SFTP session disposed."
    }

    # -------------------------------------------------------------------------
    # Step 3: Clean up staging and record run timestamp
    # -------------------------------------------------------------------------
    Clear-StagingFolder -path $credentialStagingPath
    Clear-StagingFolder -path $configStagingPath
    Log "Staging directories cleared."

    # Write current run timestamp for smart config sync on next run
    (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Set-Content $lastRunFile
    Log "Last-run timestamp updated."

    Log "Pipeline completed successfully."

} catch {
    Log "Error: $($_.Exception.Message)"
    & $sendMailScript -logPath $logFile
    exit 1
}