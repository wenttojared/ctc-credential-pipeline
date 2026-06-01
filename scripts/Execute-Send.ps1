# Execute-Send.ps1
# Purpose: Orchestrates the weekly export of certificated employee data from DBVisualizer
#          and hands off to hcm-to-ctc.ps1 for SFTP delivery to CTC.
#          Sends error notification emails via Graph API if any stage fails.
# Pipeline: Timer Job > Execute-Send.ps1 > query.sql > hcm-to-ctc.ps1 > SendMail-GraphAPI.ps1

# =============================================================================
# CONFIGURATION — update all values in this section before deploying
# =============================================================================

# --- DBVisualizer ---
$dbvisPath    = "C:\Path\To\DBVisualizer\dbviscmd.bat"
$sqlFile      = "E:\Path\To\export.sql"
$dbConnection = "prod_db_connection_name"   # Name of the DBVisualizer connection to use for export

# --- Script paths ---
$hcmToCtcScript = "E:\Path\To\hcm-to-ctc.ps1"
$sendMailScript = "E:\Path\To\SendMail-GraphAPI.ps1"

# --- Logging ---
$logFile           = "C:\Path\To\Logs\ExecuteSend_Log.txt"
$logRetentionDays  = 90   # Log entries older than this many days are removed at the start of each run

# --- Timing ---
# Buffer in seconds to allow DBVisualizer to finish flushing file output after exit.
# Adjust or remove if your environment handles exit codes reliably.
$exportBuffer = 120

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

function Invoke-DbVisExport {
    Param (
        [string]$commandPath,
        [string]$arguments,
        [string]$label
    )
    Log "Starting DBVisualizer export: $label"
    $process = Start-Process -FilePath $commandPath -ArgumentList $arguments -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        Log "ERROR: DBVisualizer export failed for '$label' (exit code $($process.ExitCode))"
        & $sendMailScript -logPath $logFile
        exit 1
    }
    Log "DBVisualizer export succeeded: $label"
}

Log "Execute-Send.ps1 started."
Invoke-LogRotation -path $logFile -retentionDays $logRetentionDays

# --- Export ---
Invoke-DbVisExport `
    -commandPath $dbvisPath `
    -arguments   "-connection $dbConnection -sqlfile $sqlFile" `
    -label       "CTC Credential Export"

Log "Waiting $exportBuffer seconds for DBVisualizer to finish writing output."
Start-Sleep -Seconds $exportBuffer

# --- Hand off to hcm-to-ctc.ps1 ---
Log "Handing off to hcm-to-ctc.ps1"
& PowerShell -File $hcmToCtcScript -NoNewWindow -Wait

if ($LASTEXITCODE -ne 0) {
    Log "ERROR: hcm-to-ctc.ps1 exited with code $LASTEXITCODE"
    & $sendMailScript -logPath $logFile
    exit 1
}

Log "Pipeline completed successfully."