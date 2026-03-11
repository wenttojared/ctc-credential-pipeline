# Execute.ps1
# Purpose: Orchestrates data exports from DBVisualizer and hands off to the SFTP sync pipeline.
#          Sends error notification emails via Graph API if any stage fails.
# Pipeline: Timer Job > Execute.ps1 > query.sql > syncdelete.ps1 > SendMail-GraphAPI.ps1

$sendMailScript = "E:\Path\To\SendMail-GraphAPI.ps1"
$logFile = "C:\Path\To\Logs\Execute_Log.txt"

function Log {
    Param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
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
        & $sendMailScript
        exit 1
    }
    Log "DBVisualizer export succeeded: $label"
}

# --- Export ---
Invoke-DbVisExport `
    -commandPath "C:\Path\To\DBVisualizer\dbviscmd.bat" `
    -arguments "-connection prodhrspay -sqlfile E:\Path\To\export.sql" `
    -label "CTC Credential Export"

# Buffer: allow DBVisualizer to finish writing output before sync
# Adjust or remove if your environment handles exit codes reliably
Start-Sleep -Seconds 120

# --- Sync to SFTP ---
Log "Handing off to syncdelete.ps1"
$scriptPath = "E:\Path\To\syncdelete.ps1"
& PowerShell -File $scriptPath -NoNewWindow -Wait

if ($LASTEXITCODE -ne 0) {
    Log "ERROR: syncdelete.ps1 exited with code $LASTEXITCODE"
    exit 1
}

Log "Pipeline completed successfully."