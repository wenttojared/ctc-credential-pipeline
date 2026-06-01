# SendMail-GraphAPI.ps1
# Purpose: Sends error notification emails to the system administrator via Microsoft
#          Graph API when any pipeline stage fails. The calling script passes its own
#          log file as an attachment so the triggering error is visible in the alert.
# Called by: Execute-Send.ps1, hcm-to-ctc.ps1, Execute-Retrieve.ps1, ctc-to-hcm.ps1

param (
    # Path to the calling script's log file — attached to the alert email.
    # Defaults to a fallback path; callers should always pass this explicitly.
    [Parameter(Mandatory=$true)]
    [string]$logPath 
)

# =============================================================================
# CONFIGURATION — update all values in this section before deploying
# =============================================================================

# --- Graph API ---
$tenantId              = "ENTER TENANT ID"
$graphCredentialTarget = "GRAPH API Stored Secret name"  # Windows Credential Manager target
                                                         # Store clientId as username, secret as password

# --- Mail properties ---
$mailSender  = "sender@domain.org"     # M365 mailbox used to send alerts (must match app registration)
$recipient   = "recipient@domain.org"  # Sysadmin or Personnel contact to receive failure notifications
$mailSubject = "CTC Pipeline Error — Action Required"
$serverLabel = "[Server Name]"         # Friendly name shown in the email body to identify the host

# --- Logging ---
$sendMailLogFile = "C:\Path\To\Logs\SendMail_Log.txt"

# =============================================================================
# END CONFIGURATION
# =============================================================================

Add-Type -AssemblyName System.Security

function Log {
    Param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Add-Content -Path $sendMailLogFile -Value $logMessage
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

Log "Starting SendMail-GraphAPI script. Attachment: $logPath"

# --- Retrieve Graph API credentials ---
try {
    $secrets      = Get-StoredCredential -Target $graphCredentialTarget
    $clientId     = $secrets.UserName
    $clientSecret = ConvertTo-PlainText $secrets.Password
    Log "Graph API credentials retrieved from Credential Manager."
} catch {
    Log "FATAL: Failed to retrieve Graph API credentials from Credential Manager target '$graphCredentialTarget'. Error: $($_.Exception.Message)"
    exit 1
}

# --- Obtain access token ---
try {
    $tokenBody = @{
        Grant_Type    = "client_credentials"
        Scope         = "https://graph.microsoft.com/.default"
        Client_Id     = $clientId
        Client_Secret = $clientSecret
    }
    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody
    Log "Access token obtained successfully."
} catch {
    Log "FATAL: Failed to obtain Graph API access token. The client secret may be expired or the app registration misconfigured."
    Log "Error: $($_.Exception.Message)"
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $($tokenResponse.access_token)"
    "Content-type"  = "application/json"
}

# --- Read attachment (caller's log file) immediately before sending ---
# so the triggering error entry is present in the file before we encode it
try {
    $fileName     = (Get-Item -Path $logPath).Name
    $base64string = [Convert]::ToBase64String([IO.File]::ReadAllBytes($logPath))
    Log "Attachment '$fileName' read successfully ($([Math]::Round((Get-Item $logPath).Length / 1KB, 1)) KB)."
} catch {
    Log "WARNING: Could not read attachment at '$logPath'. Sending email without attachment. Error: $($_.Exception.Message)"
    $fileName     = "unavailable.txt"
    $base64string = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("Log file could not be read at send time. Path: $logPath"))
}

# --- Send mail ---
Log "Sending error notification to $recipient."

$urlSend      = "https://graph.microsoft.com/v1.0/users/$mailSender/sendMail"
$bodyJsonSend = @"
{
    "message": {
        "subject": "$mailSubject",
        "body": {
            "contentType": "HTML",
            "content": "This message was sent via Microsoft Graph API.<br>An error occurred running the CTC credential sync pipeline on $serverLabel.<br>See the attached log for details."
        },
        "toRecipients": [
            {
                "emailAddress": {
                    "address": "$recipient"
                }
            }
        ],
        "attachments": [
            {
                "@odata.type": "#microsoft.graph.fileAttachment",
                "name": "$fileName",
                "contentType": "text/plain",
                "contentBytes": "$base64string"
            }
        ]
    },
    "saveToSentItems": "false"
}
"@

try {
    $response = Invoke-RestMethod -Method POST -Uri $urlSend -Headers $headers -Body $bodyJsonSend
    Log "Email sent successfully to $recipient."
} catch {
    Log "FATAL: Failed to send email. Error: $($_.Exception.Message)"
    Log "Status Code: $($_.Exception.Response.StatusCode.value__)"
    Log "Status Description: $($_.Exception.Response.StatusDescription)"
}