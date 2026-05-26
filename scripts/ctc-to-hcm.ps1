# ctc-to-hcm.ps1
# Purpose: Retrieves the weekly CTC credential report and config files from CTC's SFTP
#          and uploads them to the designated folders on your HCM/ERP platform's SFTP.
#
#          CTC exposes two folders:
#            - Credentials folder: contains versioned files named C21_YYYYMMDD.txt
#                                  Only the most recent file is transferred.
#            - Config folder:      contains setup/reference text files.
#                                  All files are transferred; see $overwriteConfig below.
#
# Requirements:
#   - SFTP credentials and inbound folder paths from your HCM/ERP vendor
#   - SFTP credentials from CTC (requested through the CTC LEA portal)
#   - WinSCP .NET assembly installed on the host machine
#   - Both sets of credentials stored in Windows Credential Manager (see README)
#
# Pipeline: Execute-Retrieve.ps1 > ctc-to-hcm.ps1 > SendMail-GraphAPI.ps1

param (
    $stagingPath            = "E:\Path\To\STAGING",

    # CTC remote paths
    $ctcCredentialPath      = "/ctc_credentials_folder",
    $ctcConfigPath          = "/ctc_config_folder",

    # HCM/ERP remote destination paths
    $hcmCredentialPath      = "/hcm_credentials_destination",
    $hcmConfigPath          = "/hcm_config_destination",

    # Set to $True  to overwrite existing config files on the HCM SFTP.
    # Set to $False if your HCM platform manages config versioning itself.
    [bool]$overwriteConfig  = $True
)

$credentialStagingPath = Join-Path $stagingPath "credentials"
$configStagingPath     = Join-Path $stagingPath "config"
$logFile               = "C:\Path\To\Logs\CTCToHCM_Log.txt"

function Log {
    Param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
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

Add-Type -AssemblyName System.Security

# Ensure staging subdirectories exist
New-Item -ItemType Directory -Force -Path $credentialStagingPath | Out-Null
New-Item -ItemType Directory -Force -Path $configStagingPath     | Out-Null

try {
    Add-Type -Path "C:\Path\To\WinSCPnet.dll"
    Log "WinSCP .NET assembly loaded."

    # -------------------------------------------------------------------------
    # Step 1: Pull from CTC SFTP
    # -------------------------------------------------------------------------
    $ctcCred = Get-StoredCredential -Target "WinSCP_CTC_target_name"
    $ctcSessionOptions = New-Object WinSCP.SessionOptions -Property @{
        Protocol              = [WinSCP.Protocol]::Sftp
        HostName              = "CTC.SFTP.Host.Address"
        UserName              = $ctcCred.UserName
        Password              = ConvertTo-PlainText $ctcCred.Password
        SshHostKeyFingerprint = "paste CTC ssh-rsa 2048 fingerprint"
    }

    $ctcSession = New-Object WinSCP.Session
    $ctcSession.SessionLogPath = "C:\Path\To\Logs\WinSCP_CTC_SessionLog.txt"

    try {
        $ctcSession.Open($ctcSessionOptions)
        Log "CTC SFTP session opened."

        # --- Credentials folder: pull only the most recent C21_YYYYMMDD.txt ---
        $credFiles = $ctcSession.ListDirectory($ctcCredentialPath).Files `
            | Where-Object { -not $_.IsDirectory -and $_.Name -match "^C21_\d{8}\.txt$" } `
            | Sort-Object { $_.Name } -Descending

        if ($credFiles.Count -eq 0) {
            Log "WARNING: No C21_YYYYMMDD.txt files found at '$ctcCredentialPath'. Aborting."
            & "E:\Path\To\SendMail-GraphAPI.ps1"
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
    $hcmCred = Get-StoredCredential -Target "WinSCP_HCM_target_name"
    $hcmSessionOptions = New-Object WinSCP.SessionOptions -Property @{
        Protocol              = [WinSCP.Protocol]::Sftp
        HostName              = "HCM.SFTP.Host.Address"
        UserName              = $hcmCred.UserName
        Password              = ConvertTo-PlainText $hcmCred.Password
        SshHostKeyFingerprint = "paste HCM ssh-rsa 2048 fingerprint"
    }

    $hcmSession = New-Object WinSCP.Session
    $hcmSession.SessionLogPath = "C:\Path\To\Logs\WinSCP_HCM_SessionLog.txt"

    try {
        $hcmSession.Open($hcmSessionOptions)
        Log "HCM SFTP session opened."

        # Disable resume support — HCM SFTP is append-only; rename permission is not granted,
        # so WinSCP's default .filepart temp file pattern will fail at the rename step.
        $transferOptions = New-Object WinSCP.TransferOptions
        $transferOptions.ResumeSupport.State = [WinSCP.TransferResumeSupportState]::Off

        # --- Upload credentials file ---
        $credStagingFile = Get-ChildItem -Path $credentialStagingPath | Select-Object -First 1
        $hcmSession.PutFiles(
            $credStagingFile.FullName,
            "$hcmCredentialPath/$($credStagingFile.Name)",
            $False,
            $transferOptions
        ).Check()
        Log "Credentials file uploaded to HCM: $($credStagingFile.Name)"

        # --- Upload config files (respects $overwriteConfig toggle) ---
        $configStagingFiles = Get-ChildItem -Path $configStagingPath
        if ($configStagingFiles.Count -gt 0) {
            foreach ($file in $configStagingFiles) {
                $hcmDestPath = "$hcmConfigPath/$($file.Name)"

                if (-not $overwriteConfig) {
                    # Skip if file already exists on HCM SFTP
                    if ($hcmSession.FileExists($hcmDestPath)) {
                        Log "Skipping config file (overwrite disabled, file exists): $($file.Name)"
                        continue
                    }
                }

                $hcmSession.PutFiles($file.FullName, $hcmDestPath, $False, $transferOptions).Check()
                Log "Config file uploaded to HCM: $($file.Name)"
            }
        }
    }
    finally {
        $hcmSession.Dispose()
        Log "HCM SFTP session disposed."
    }

    # -------------------------------------------------------------------------
    # Step 3: Clean up staging
    # -------------------------------------------------------------------------
    Clear-StagingFolder -path $credentialStagingPath
    Clear-StagingFolder -path $configStagingPath
    Log "Staging directories cleared."

    Log "Pipeline completed successfully."

} catch {
    Log "Error: $($_.Exception.Message)"
    & "E:\Path\To\SendMail-GraphAPI.ps1"
    exit 1
}