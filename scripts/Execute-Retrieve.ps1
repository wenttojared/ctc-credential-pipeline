# Execute-Retrieve.ps1
# Purpose: Orchestrates the retrieval of the weekly CTC credential report and upload
#          to your HCM/ERP platform's SFTP. Triggered by a scheduled task after CTC's
#          report generation window.
# Pipeline: Timer Job > Execute-Retrieve.ps1 > ctc-to-hcm.ps1 > SendMail-GraphAPI.ps1

# =============================================================================
# CONFIGURATION — update all values in this section before deploying
# =============================================================================

# --- Script paths ---
$ctcToHcmScript = "E:\Path\To\ctc-to-hcm.ps1"
$sendMailScript = "E:\Path\To\SendMail-GraphAPI.ps1"

# --- Logging ---
$logFile          = "C:\Path\To\Logs\ExecuteRetrieve_Log.txt"
$logRetentionDays = 90   # Log entries older than this many days are removed at the start of each run

# =============================================================================
# END CONFIGURATION
# =============================================================================

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
    Log "Log rotation complete. Entries older than $retentionDays days removed."
}

Log "Execute-Retrieve.ps1 started."
Invoke-LogRotation -path $logFile -retentionDays $logRetentionDays

& PowerShell -File $ctcToHcmScript -NoNewWindow -Wait

if ($LASTEXITCODE -ne 0) {
    Log "ERROR: ctc-to-hcm.ps1 exited with code $LASTEXITCODE"
    & $sendMailScript -logPath $logFile
    exit 1
}

Log "Execute-Retrieve.ps1 completed successfully."