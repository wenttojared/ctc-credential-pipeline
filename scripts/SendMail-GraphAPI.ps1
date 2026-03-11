# SendMail-GraphAPI.ps1
# To send error notifications to system administrator if process ever fails

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

#Configure Mail Properties
$MailSender = "sender@domain.org"
$tenantId = 'ENTER TENANT ID'
$secrets = Get-StoredCredential -Target "GRAPH API Stored Secret name"
$clientId = $secrets.UserName 
$clientSecret = ConvertTo-PlainText $secrets.Password
$Attachment="C:\Path\To\WinSCP_Log.txt"
$Recipient="recipient@domain.org"

#Get File Name and Base64 string
$FileName=(Get-Item -Path $Attachment).name
$base64string = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Attachment))

function Log {
    Param ([string]$message)
    $logFile = "C:\Path\To\EmailLog.txt"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Add-Content -Path $logFile -Value $logMessage
}

Log "Starting SendMail-GraphAPI script."
#Connect to GRAPH API
$tokenBody = @{
    Grant_Type    = "client_credentials"
    Scope         = "https://graph.microsoft.com/.default"
    Client_Id     = $clientId
    Client_Secret = $clientSecret
}
$tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantID/oauth2/v2.0/token" -Method POST -Body $tokenBody
$headers = @{
    "Authorization" = "Bearer $($tokenResponse.access_token)"
    "Content-type"  = "application/json"
}

#Send Mail 
Log "Prepared the email body and setting up headers for the Graph API call."   
$URLsend = "https://graph.microsoft.com/v1.0/users/$MailSender/sendMail"
$BodyJsonsend = @"
                    {
                        "message": {
                          "subject": "Email Subject",
                          "body": {
                            "contentType": "HTML",
                            "content": "This Mail is sent via Microsoft GRAPH API. <br>
                            An error occurred running the synchronization script on [Server Name]. <br>
                            See Attachment <br>
                            "
                          },
                          
                          "toRecipients": [
                            {
                              "emailAddress": {
                                "address": "$Recipient"
                              }
                            }
                          ]
                          ,"attachments": [
                            {
                              "@odata.type": "#microsoft.graph.fileAttachment",
                              "name": "$FileName",
                              "contentType": "text/plain",
                              "contentBytes": "$base64string"
                            }
                          ]
                        },
                        "saveToSentItems": "false"
                      }
"@

try {
    $response = Invoke-RestMethod -Method POST -Uri $URLsend -Headers $headers -Body $BodyJsonsend
    Log "Email sent successfully to $Recipient."
} catch {
    Log "Failed to send email. Error: $($_.Exception.Message)"
    Log "Status Code: $($_.Exception.Response.StatusCode.value__)"
    Log "Status Description: $($_.Exception.Response.StatusDescription)"
}
