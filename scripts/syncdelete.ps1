# syncdelete.ps1
# Note: You need to add new credentials to the Credentials Manager and change $cred to have its target.
#       If you're running this somewhere the module is not installed, please run this with admin rights:
#       Install-Module -Name CredentialManager
#       Then run the following code to add the relevant credentials:
#       New-StoredCredential -Target "WinSCP_hostname_username" -UserName "username" -Password "password" -Persist LocalMachine


param (
    $localPath = "E:\Path\To\EXPORT",
    $remotePath = "/weekly_upload"
)

$logFile = "C:\Path\To\Logs\WinSCP_Log.txt"

#Function Logging
function Log {
    Param ([string]$message)
    Write-Host $message
    $message | Out-File $logFile -Append
}

# Function to convert secure strings to plaintext
Add-Type -AssemblyName System.Security
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

try {
    # Load WinSCP .NET assembly
    Add-Type -Path "C:\Path\To\WinSCPnet.dll"
    Log "WinSCP .NET assembly loaded."

    # Setup session options, getting credentials from Windows Credentials Manager
    $cred = Get-StoredCredential -Target "target_name"
    $sessionOptions = New-Object WinSCP.SessionOptions -Property @{
        Protocol = [WinSCP.Protocol]::Sftp
        HostName = "SFTP.Host.Address"
        UserName = $cred.UserName
        Password = ConvertTo-PlainText $cred.Password
	    SshHostKeyFingerprint = "paste ssh-rsa 2048 fingerprint"
    }

    $session = New-Object WinSCP.Session
    $session.SessionLogPath = "C:\Path\To\WinSCP_SessionLog.txt"

    try {
        # Connect to remote directory
        $session.Open($sessionOptions)
        Log "Session opened."

        # Synchronize files to remote directory, collect results
        $synchronizationResult = $session.SynchronizeDirectories(
            [WinSCP.SynchronizationMode]::Remote, $localPath, $remotePath, $False)
        Log "Synchronization operation completed."

        # Check if synchronization was successful
        if ($synchronizationResult.IsSuccess) {
            # Delete files from local path after successful upload
            Get-ChildItem -Path $localPath | ForEach-Object {
                $_ | Remove-Item -Force
                Log "Deleted file $($_.FullName)"
            }
        }
    } finally {
        # Disconnect, clean up
        $session.Dispose()
        Log "Session disposed."
    }
} catch {
    Log "Error: $($_.Exception.Message)"
    & "E:\Path\To\SendMail-GraphAPI.ps1"
    exit 1
}