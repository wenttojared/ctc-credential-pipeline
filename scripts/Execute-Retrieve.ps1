# Execute-Retrieve.ps1
# Purpose: Orchestrates the retrieval of the weekly CTC credential report and upload
#          to your HCM/ERP platform's SFTP. Triggered by a scheduled task after CTC's
#          report generation window.
# Pipeline: Timer Job > Execute-Retrieve.ps1 > ctc-to-hcm.ps1 > SendMail-GraphAPI.ps1

$sendMailScript = "E:\Path\To\SendMail-GraphAPI.ps1"
$logFile        = "C:\Path\To\Logs\ExecuteRetrieve_Log.txt"

function Log {
    Param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

Log "Execute-Retrieve.ps1 started."

# Hand off to ctc-to-hcm.ps1
$scriptPath = "E:\Path\To\ctc-to-hcm.ps1"
& PowerShell -File $scriptPath -NoNewWindow -Wait

if ($LASTEXITCODE -ne 0) {
    Log "ERROR: ctc-to-hcm.ps1 exited with code $LASTEXITCODE"
    & $sendMailScript
    exit 1
}

Log "Execute-Retrieve.ps1 completed successfully."
