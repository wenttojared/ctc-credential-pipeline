# hcm-to-ctc.ps1
# Purpose: Syncs the local CSV export directory to CTC's SFTP server.
#          Deletes local files after a confirmed successful upload.
#          Uses SynchronizeDirectories for idempotent behavior — files already
#          present on the remote will not be re-uploaded on accidental re-runs.
# Pipeline: Execute-Send.ps1 > hcm-to-ctc.ps1 > SendMail-GraphAPI.ps1

# =============================================================================
# CONFIGURATION — update all values in this section before deploying
# =============================================================================

# --- Paths ---
$localPath      = "E:\Path\To\EXPORT"    # Local folder where DBVisualizer writes CSV output
$logFile        = "C:\Path\To\Logs\HMCtoCTC_Log.txt"
$sessionLogPath = "C:\Path\To\Logs\WinSCP_CTC_SessionLog.txt"

# --- WinSCP ---
$winScpDllPath  = "C:\Path\To\WinSCPnet.dll"

# --- CTC SFTP ---
$ctcCredentialTarget = "WinSCP_CTC_target_name"   # Windows Credential Manager target
$ctcHost             = "CTC.SFTP.Host.Address"
$ctcPort             = 22                         # CTC SFTP port (if not standard 22)
$ctcRemotePath       = "/weekly_upload"           # Remote SFTP destination path provided by CTC
$ctcHostKey          = "ssh-rsa #### paste-CTC-fingerprint-here"

# --- SendMail script ---
$sendMailScript = "E:\Path\To\SendMail-GraphAPI.ps1"

# --- Log retention ---
$logRetentionDays        = 90   # Pipeline log retention in days
$sessionLogRetentionDays = 30   # WinSCP session log retention in days (these grow larger)

# =============================================================================
# END CONFIGURATION
# =============================================================================

Add-Type -AssemblyName System.Security

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

Log "hcm-to-ctc.ps1 started."
Invoke-LogRotation -path $logFile        -retentionDays $logRetentionDays
Invoke-LogRotation -path $sessionLogPath -retentionDays $sessionLogRetentionDays

try {
    Add-Type -Path $winScpDllPath
    Log "WinSCP .NET assembly loaded."

    $cred = Get-StoredCredential -Target $ctcCredentialTarget
    $sessionOptions = New-Object WinSCP.SessionOptions -Property @{
        Protocol              = [WinSCP.Protocol]::Sftp
        HostName              = $ctcHost
        PortNumber            = $ctcPort
        UserName              = $cred.UserName
        Password              = ConvertTo-PlainText $cred.Password
        SshHostKeyFingerprint = $ctcHostKey
    }

    $session = New-Object WinSCP.Session
    $session.SessionLogPath = $sessionLogPath

    try {
        $session.Open($sessionOptions)
        Log "CTC SFTP session opened."

        $synchronizationResult = $session.SynchronizeDirectories(
            [WinSCP.SynchronizationMode]::Remote, $localPath, $ctcRemotePath, $False)
        Log "Synchronization operation completed."

        if ($synchronizationResult.IsSuccess) {
            Get-ChildItem -Path $localPath | ForEach-Object {
                $_ | Remove-Item -Force
                Log "Deleted local file: $($_.FullName)"
            }
            Log "Local export directory cleared."
        } else {
            Log "ERROR: Synchronization reported failure without throwing. Check WinSCP session log."
            & $sendMailScript -logPath $logFile
            exit 1
        }
    }
    finally {
        $session.Dispose()
        Log "CTC SFTP session disposed."
    }

} catch {
    Log "Error: $($_.Exception.Message)"
    & $sendMailScript -logPath $logFile
    exit 1
}