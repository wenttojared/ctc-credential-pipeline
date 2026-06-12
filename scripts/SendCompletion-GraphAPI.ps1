# SendCompletion-GraphAPI.ps1
# Purpose: Sends a completion notification email when the CTC inbound pipeline
#          finishes successfully, notifying staff that the credential file is
#          ready for processing in their HCM/ERP system.
#
#          Supports inline screenshots embedded directly in the email body --
#          useful for including step-by-step import instructions alongside the
#          notification. Screenshots are loaded from a configurable folder;
#          updating instructions requires only replacing the image files,
#          not editing this script.
#
#          To add or remove steps:
#            1. Add/remove image files in $screenshotFolder (step1.png, step2.png, etc.)
#            2. Update $stepImages array to match
#            3. Update $emailBody HTML to add/remove the corresponding <li> and <img> blocks
#
# Called by: ctc-to-hcm.ps1 on successful completion

param (
    [Parameter(Mandatory=$true)]
    [string]$credentialFileName   # e.g. C21_20260528.txt -- passed by ctc-to-hcm.ps1
)

# =============================================================================
# CONFIGURATION -- update all values in this section before deploying
# =============================================================================

# --- Graph API ---
$tenantId              = "ENTER TENANT ID"
$graphCredentialTarget = "GRAPH API Stored Secret name"  # Windows Credential Manager target
                                                          # Store clientId as username, secret as password

# --- Mail properties ---
$mailSender  = "sender@domain.org"
$recipient   = "recipient@domain.org"       # Primary recipient -- credentials analyst or Personnel staff

# CC recipients -- add or remove addresses as needed
$ccList = @(
    "cc-recipient-1@domain.org",
    "cc-recipient-2@domain.org"
)

# BCC recipients -- add or remove addresses as needed
$bccList = @(
    "bcc-recipient-1@domain.org",
    "bcc-recipient-2@domain.org"
)

$mailSubject = "Credentials File Ready For Processing"

# --- Screenshots ---
# Folder containing screenshot image files referenced in $emailBody below.
# Files must be named to match the entries in $stepImages.
# Supported formats: .png, .jpg -- update contentType in the attachment block if using .jpg
$screenshotFolder = "E:\Path\To\Instructions\Screenshots"

# List of screenshot filenames in the order they appear in the email body.
# Each filename here must have a matching <img src="cid:..."> tag in $emailBody below.
# The contentId used in the cid: reference is the filename without extension (e.g. "step1").
$stepImages = @("step1.png", "step2.png")

# --- Logging ---
$logFile = "C:\Path\To\Logs\SendCompletion_Log.txt"

# =============================================================================
# END CONFIGURATION
# =============================================================================

Add-Type -AssemblyName System.Security

function Log {
    Param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
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

Log "Starting SendCompletion-GraphAPI script. Credential file: $credentialFileName"

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

# --- Load screenshots and build attachments list ---
# Using PSCustomObject instead of string interpolation so ConvertTo-Json handles
# all escaping -- avoids 400 Bad Request errors from malformed JSON with large base64 strings
$attachmentsList   = @()
$screenshotsLoaded = $true

foreach ($imgFile in $stepImages) {
    $imgPath   = Join-Path $screenshotFolder $imgFile
    $contentId = [System.IO.Path]::GetFileNameWithoutExtension($imgFile)

    try {
        $imgBase64       = [Convert]::ToBase64String([IO.File]::ReadAllBytes($imgPath))
        $attachmentsList += [PSCustomObject]@{
            "@odata.type" = "#microsoft.graph.fileAttachment"
            "name"        = $imgFile
            "contentType" = "image/png"
            "contentBytes"= $imgBase64
            "isInline"    = $true
            "contentId"   = $contentId
        }
        Log "Screenshot loaded: $imgFile"
    } catch {
        Log "WARNING: Could not load screenshot '$imgFile' from '$imgPath'. It will be omitted. Error: $($_.Exception.Message)"
        $screenshotsLoaded = $false
    }
}

# --- Build email body ---
# To reference a screenshot inline, use: <img src="cid:FILENAME_WITHOUT_EXTENSION" style="max-width:600px;" />
# The contentId must match the filename without extension (e.g. step1.png -> cid:step1).
# If a screenshot fails to load, its <img> tag will render as a broken image in the email.
#
# $credentialFileName is passed in from ctc-to-hcm.ps1 and resolves to the actual filename
# (e.g. C21_20260528.txt) so the analyst knows exactly which file to select in the UI.
$emailBody = @"
<p>Hello,</p>
<p>This is an automated message to notify you that the CTC Pipeline has been successfully completed.</p>
<p>You may now process the uploaded file <strong>$credentialFileName</strong> in your HCM/ERP system.</p>
<p><strong>Instructions:</strong></p>
<ol>
    <li>
        <p>Lorem ipsum dolor sit amet -- navigate to the credential import section of your HCM/ERP platform.</p>
        <img src="cid:step1" style="max-width:600px;" />
    </li>
    <li>
        <p>Consectetur adipiscing elit -- select <strong>$credentialFileName</strong> from the import file dropdown.</p>
        <img src="cid:step2" style="max-width:600px;" />
    </li>
</ol>
<p>If you have any questions or experience any problems with the import, please reach out to support or reply to this email.</p>
<p>Thank you</p>
"@

# --- Build full message as PS object and serialize ---
# ConvertTo-Json handles all escaping automatically -- no manual JSON string building needed
$messageObject = [PSCustomObject]@{
    message = [PSCustomObject]@{
        subject = $mailSubject
        body    = [PSCustomObject]@{
            contentType = "HTML"
            content     = $emailBody
        }
        toRecipients = @(
            [PSCustomObject]@{
                emailAddress = [PSCustomObject]@{ address = $recipient }
            }
        )
        ccRecipients = @(
            $ccList | ForEach-Object {
                [PSCustomObject]@{
                    emailAddress = [PSCustomObject]@{ address = $_ }
                }
            }
        )
        bccRecipients = @(
            $bccList | ForEach-Object {
                [PSCustomObject]@{
                    emailAddress = [PSCustomObject]@{ address = $_ }
                }
            }
        )
        attachments = $attachmentsList
    }
    saveToSentItems = "true"
}

$bodyJsonSend = $messageObject | ConvertTo-Json -Depth 10

# --- Send mail ---
Log "Sending completion notification to $recipient."

$urlSend = "https://graph.microsoft.com/v1.0/users/$mailSender/sendMail"

try {
    Invoke-RestMethod -Method POST -Uri $urlSend -Headers $headers -Body $bodyJsonSend | Out-Null
    Log "Completion email sent successfully to $recipient."
    if (-not $screenshotsLoaded) {
        Log "WARNING: One or more screenshots could not be loaded -- email sent but may have missing images."
    }
} catch {
    Log "FATAL: Failed to send completion email. Error: $($_.Exception.Message)"
    Log "Status Code: $($_.Exception.Response.StatusCode.value__)"
    Log "Status Description: $($_.Exception.Response.StatusDescription)"
}