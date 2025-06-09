[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'Password received as string from GitHub Actions secrets')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Write-Host is used intentionally for GitHub Actions console output and logging')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
    Justification = 'Internal function for FTP operations')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '',
    Justification = 'Internal function for FTP operations')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'ShouldProcess not needed for internal FTP operations in deployment context')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DeployPath,

    [Parameter(Mandatory = $true)]
    [string]$Server,

    [Parameter(Mandatory = $true)]
    [int]$Port,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    # Note: Password is string type because it's received from GitHub Actions environment
    # which passes secrets as string values
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [string]$RemotePath = '/',

    [Parameter(Mandatory = $false)]
    [bool]$PassiveMode = $true,

    [Parameter(Mandatory = $false)]
    [string]$ExcludePatterns = '',

    [Parameter(Mandatory = $false)]
    [bool]$CleanTarget = $false,

    [Parameter(Mandatory = $false)]
    [string]$PreservePatterns = '',

    [Parameter(Mandatory = $false)]
    [string]$TestFtpDirectory = '',

    [Parameter(Mandatory = $false)]
    [string]$TestFtpFile = '',

    [Parameter(Mandatory = $false)]
    [bool]$DisableConnectivityTests = $false
)

# HELPER FUNCTIONS

function Test-ExcludeFile {
    param([string]$FilePath, [string[]]$Patterns)
    if ($Patterns.Count -eq 0) {
        return $false
    }

    foreach ($pattern in $Patterns) {
        if ($FilePath -like $pattern) {
            return $true
        }
    }
    return $false
}

function Test-PreserveFile {
    param([string]$FilePath, [string[]]$Patterns)
    if ($Patterns.Count -eq 0) {
        return $false
    }

    foreach ($pattern in $Patterns) {
        if ($FilePath -like $pattern) {
            return $true
        }
    }
    return $false
}
function Write-ExceptionDetails {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception,

        [Parameter(Mandatory = $false)]
        [int]$Level = 0,

        [Parameter(Mandatory = $false)]
        [string]$Prefix = ''
    )

    $indent = '   ' * ($Level + 1)
    $levelLabel = if ($Level -eq 0) { '📋 Exception Information' } else { "🔗 Inner Exception (Level $Level)" }

    Write-Host "`n`e[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host "$($levelLabel):"
    Write-Host "$indent• Type: `e[33m$($Exception.GetType().FullName)`e[0m"
    Write-Host "$indent• Message: `e[33m$($Exception.Message)`e[0m"

    # Check for WebException (FTP errors are usually WebExceptions)
    if ($Exception -is [System.Net.WebException]) {
        $webEx = $Exception
        Write-Host "`n$indent🌐 WebException Details:"
        Write-Host "$indent• Status: `e[33m$($webEx.Status)`e[0m"

        # Add WebException status interpretation
        switch ($webEx.Status) {
            ([System.Net.WebExceptionStatus]::ConnectFailure) {
                Write-Host "$indent💡 Connection Failure - Server may be down or unreachable"
            }
            ([System.Net.WebExceptionStatus]::NameResolutionFailure) {
                Write-Host "$indent💡 DNS Resolution Failed - Check server hostname/IP"
            }
            ([System.Net.WebExceptionStatus]::Timeout) {
                Write-Host "$indent💡 Connection Timeout - Server too slow or network issues"
            }
            ([System.Net.WebExceptionStatus]::ProtocolError) {
                Write-Host "$indent💡 FTP Protocol Error - Check FTP server response below"
            }
            ([System.Net.WebExceptionStatus]::TrustFailure) {
                Write-Host "$indent💡 SSL/TLS Trust Failure - Certificate issues with FTPS"
            }
            ([System.Net.WebExceptionStatus]::SecureChannelFailure) {
                Write-Host "$indent💡 Secure Channel Failure - SSL/TLS negotiation failed"
            }
        }

        if ($webEx.Response) {
            $ftpResponse = $webEx.Response
            Write-Host "$indent• Response Type: `e[33m$($ftpResponse.GetType().FullName)`e[0m"
            if ($ftpResponse -is [System.Net.FtpWebResponse]) {
                Write-Host "`n$indent📡 FTP Server Response:"
                Write-Host "$indent• Status Code: `e[31m$($ftpResponse.StatusCode)`e[0m ($([int]$ftpResponse.StatusCode))"
                Write-Host "$indent• Status Description: `e[31m$($ftpResponse.StatusDescription.Trim())`e[0m"
                Write-Host "$indent• Banner Message: `e[33m$($ftpResponse.BannerMessage.Trim())`e[0m"
                Write-Host "$indent• Welcome Message: `e[33m$($ftpResponse.WelcomeMessage.Trim())`e[0m"
                Write-Host "$indent• Exit Message: `e[33m$($ftpResponse.ExitMessage.Trim())`e[0m"
                Write-Host "$indent• Last Modified: `e[33m$($ftpResponse.LastModified)`e[0m"
                Write-Host "$indent• Content Length: `e[33m$($ftpResponse.ContentLength)`e[0m"

                # Additional FTP response properties
                try {
                    Write-Host "$indent• Response URI: `e[33m$($ftpResponse.ResponseUri)`e[0m"
                    Write-Host "$indent• Server: `e[33m$($ftpResponse.Server)`e[0m"
                    Write-Host "$indent• Headers: `e[33m$($ftpResponse.Headers.Count) headers`e[0m"

                    # Display headers if available
                    if ($ftpResponse.Headers -and $ftpResponse.Headers.Count -gt 0) {
                        Write-Host "$indent📋 Response Headers:"
                        foreach ($headerName in $ftpResponse.Headers.AllKeys) {
                            Write-Host "$indent  • $headerName`: `e[36m$($ftpResponse.Headers[$headerName])`e[0m"
                        }
                    }

                    # Check if response supports reading of additional properties
                    if ($ftpResponse.SupportsHeaders) {
                        Write-Host "$indent• Supports Headers: `e[32mYes`e[0m"
                    }
                }
                catch {
                    Write-Host "$indent• Could not read additional response properties: $($_.Exception.Message)"
                }

                # Try to read any response stream content
                try {
                    if ($ftpResponse.GetResponseStream()) {
                        $stream = $ftpResponse.GetResponseStream()
                        $reader = New-Object System.IO.StreamReader($stream)
                        $responseContent = $reader.ReadToEnd()
                        $reader.Close()
                        if ($responseContent) {
                            Write-Host "$indent📄 Response Content:"
                            $lines = $responseContent -split "`n"
                            foreach ($line in $lines) {
                                if ($line.Trim()) {
                                    Write-Host "$indent  `e[31m$($line.Trim())`e[0m"
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Host "$indent• Could not read response stream: $($_.Exception.Message)"
                }

                # Add FTP error code interpretation
                switch ($ftpResponse.StatusCode) {
                    ([System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable) {
                        Write-Host "`n$indent💡 FTP Error 550 Analysis:"
                        Write-Host "$indent• This typically indicates:"
                        Write-Host "$indent  - File/directory does not exist"
                        Write-Host "$indent  - Insufficient permissions to access the resource"
                        Write-Host "$indent  - Path syntax is incorrect"
                        Write-Host "$indent  - Server-side path restrictions"
                    }
                    ([System.Net.FtpStatusCode]::ActionNotTakenInsufficientSpace) {
                        Write-Host "`n$indent💡 FTP Error 552 Analysis: Insufficient storage space on server"
                    }
                    ([System.Net.FtpStatusCode]::ActionNotTakenFilenameNotAllowed) {
                        Write-Host "`n$indent💡 FTP Error 553 Analysis: Filename not allowed (naming restrictions)"
                    }
                    ([System.Net.FtpStatusCode]::NotLoggedIn) {
                        Write-Host "`n$indent💡 FTP Error 530 Analysis: Authentication failed or required"
                    }
                    ([System.Net.FtpStatusCode]::ActionNotTakenFileUnavailableOrBusy) {
                        Write-Host "`n$indent💡 FTP Error 450 Analysis: File unavailable or busy (temporary)"
                    }
                }
            }
        }
    }

    # Data from exception
    if ($Exception.Data -and $Exception.Data.Count -gt 0) {
        Write-Host "`n$indent📊 Exception Data:"
        foreach ($key in $Exception.Data.Keys) {
            Write-Host "$indent• $key`: `e[33m$($Exception.Data[$key])`e[0m"
        }
    }

    # HResult (Windows error code)
    if ($Exception.HResult) {
        Write-Host "`n$indent🔢 HResult (Windows Error Code): `e[33m0x$($Exception.HResult.ToString('X8'))`e[0m ($($Exception.HResult))"
    }

    # Stack trace (only for main exception)
    if ($Level -eq 0) {
        Write-Host "`n$indent📚 Stack Trace:"
        Write-Host "`e[90m$($Exception.StackTrace)`e[0m"
    }

    # Recursively handle inner exceptions
    if ($Exception.InnerException) {
        Write-ExceptionDetails -Exception $Exception.InnerException -Level ($Level + 1) -Prefix $Prefix
    }
}

function Write-FtpErrorDetails {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $false)]
        [string]$Context = '', [Parameter(Mandatory = $false)]
        [hashtable]$AdditionalInfo = @{}
    )

    Write-Host "❌ `e[31mDETAILED FTP ERROR ANALYSIS`e[0m"
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

    # Context information
    if ($Context) {
        Write-Host "🔍 Context: `e[36m$Context`e[0m"
    }

    # Additional context information
    foreach ($key in $AdditionalInfo.Keys) {
        Write-Host "🔍 $key`: `e[36m$($AdditionalInfo[$key])`e[0m"
    }

    # Use the recursive exception details function
    Write-ExceptionDetails -Exception $ErrorRecord.Exception -Level 0

    # ScriptStackTrace (PowerShell specific)
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Host "`n📝 Script Stack Trace:"
        Write-Host "`e[90m$($ErrorRecord.ScriptStackTrace)`e[0m"
    }

    # Provide troubleshooting suggestions based on context and error type
    Write-Host "`n🔧 Troubleshooting Suggestions:"
    if ($Context -like '*connectivity*' -or $Context -like '*connection*') {
        Write-Host '   📞 Connection Issues:'
        Write-Host '     • Verify server hostname/IP address is correct'
        Write-Host "     • Check if FTP port ($(if ($AdditionalInfo['Port']) { $AdditionalInfo['Port'] } else { '21' })) is open"
        Write-Host "     • Confirm passive mode setting ($(if ($AdditionalInfo['Passive Mode']) { $AdditionalInfo['Passive Mode'] } else { 'Unknown' }))"
        Write-Host '     • Test with FTP client (FileZilla, WinSCP) manually'
        Write-Host '     • Check firewall rules on both client and server'
    }
    if ($ErrorRecord.Exception.Message -like '*550*' -or ($ErrorRecord.Exception -is [System.Net.WebException] -and $ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode -eq [System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable)) {
        Write-Host '   📁 File/Directory Access Issues (550):'
        Write-Host "     • Verify the remote path exists: '$(if ($AdditionalInfo['Remote Path']) { $AdditionalInfo['Remote Path'] } elseif ($AdditionalInfo['Remote URI']) { $AdditionalInfo['Remote URI'] } else { 'Unknown' })'"
        Write-Host '     • Check user permissions for the target directory'
        Write-Host '     • Ensure parent directories exist'
        Write-Host '     • Verify path syntax (forward slashes for FTP)'
        Write-Host '     • Try connecting to parent directory first'
    }

    if ($Context -like '*upload*' -or $Context -like '*file*') {
        Write-Host '   📤 File Upload Issues:'
        Write-Host '     • Check available disk space on server'
        Write-Host "     • Verify file isn't locked or in use"
        Write-Host "     • Confirm filename doesn't contain invalid characters"
        Write-Host '     • Try uploading a smaller test file first'
    }

    if ($ErrorRecord.Exception.Message -like '*authentication*' -or $ErrorRecord.Exception.Message -like '*530*') {
        Write-Host '   🔐 Authentication Issues:'
        Write-Host '     • Verify username and password are correct'
        Write-Host '     • Check if account is locked or expired'
        Write-Host '     • Confirm user has FTP access permissions'
        Write-Host '     • Test credentials with FTP client manually'
    }

    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

function Test-FtpPath {
    param(
        [string]$FtpUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive,
        [string]$PathToTest
    )

    Write-Host "`n🔍 Testing FTP Path: `e[36m$PathToTest`e[0m"

    # Test each part of the path progressively
    $pathParts = $PathToTest.Trim('/') -split '/'
    $currentPath = ''

    for ($i = 0; $i -lt $pathParts.Length; $i++) {
        if ($pathParts[$i]) {
            $currentPath += '/' + $pathParts[$i]
            $testUri = "$FtpUri$currentPath"

            Write-Host "   • Testing path segment: `e[33m$currentPath`e[0m"

            try {
                $listRequest = [System.Net.FtpWebRequest]::Create("ftp://$testUri")
                $listRequest.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
                $listRequest.Credentials = $Credentials
                $listRequest.UsePassive = $UsePassive
                $listRequest.Timeout = 10000

                $listResponse = $listRequest.GetResponse()
                $listStream = $listResponse.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($listStream)
                $directoryListing = $reader.ReadToEnd()
                $reader.Close()
                $listResponse.Close()

                Write-Host "     ✅ `e[32mAccessible`e[0m - Contains $((($directoryListing -split "`n") | Where-Object { $_.Trim() }).Count) items"
            }
            catch {
                Write-Host "     ❌ `e[31mNot accessible`e[0m - $($_.Exception.Message)"
                Write-FtpErrorDetails -ErrorRecord $_ -Context "Path segment test for '$currentPath'" -AdditionalInfo @{
                    'FTP URI'     = "ftp://$testUri"
                    'Operation'   = 'List directory details'
                    'Credentials' = $Credentials.UserName
                    'Use Passive' = $UsePassive
                }
                break
            }
        }
    }

    # Also test if we can create a file in the target directory
    if ($currentPath -eq $PathToTest.TrimEnd('/')) {
        Write-Host "`n🧪 Testing write permissions in target directory..."
        $testFileName = "write_test_$(Get-Date -Format 'yyyyMMdd_HHmmss').tmp"
        $testFileUri = "$FtpUri$PathToTest/$testFileName" -replace '//+', '/'

        try {
            $uploadRequest = [System.Net.FtpWebRequest]::Create("ftp://$testFileUri")
            $uploadRequest.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
            $uploadRequest.Credentials = $Credentials
            $uploadRequest.UsePassive = $UsePassive
            $uploadRequest.Timeout = 10000

            $testContent = "FTP write test - $(Get-Date)"
            $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($testContent)
            $uploadRequest.ContentLength = $contentBytes.Length

            $requestStream = $uploadRequest.GetRequestStream()
            $requestStream.Write($contentBytes, 0, $contentBytes.Length)
            $requestStream.Close()

            $uploadResponse = $uploadRequest.GetResponse()
            $uploadResponse.Close()

            Write-Host "   ✅ `e[32mWrite test successful`e[0m - Can create files in target directory"

            # Clean up test file
            try {
                $deleteRequest = [System.Net.FtpWebRequest]::Create("ftp://$testFileUri")
                $deleteRequest.Method = [System.Net.WebRequestMethods+Ftp]::DeleteFile
                $deleteRequest.Credentials = $Credentials
                $deleteRequest.UsePassive = $UsePassive
                $deleteRequest.Timeout = 5000

                $deleteResponse = $deleteRequest.GetResponse()
                $deleteResponse.Close()
                Write-Host '   🧹 Test file cleaned up'
            }
            catch {
                Write-Host "   ⚠️  Could not clean up test file: $testFileName"
            }
        }
        catch {
            Write-Host "   ❌ `e[31mWrite test failed`e[0m - Cannot create files in target directory"
            if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
                $errorResponse = $_.Exception.Response
                if ($errorResponse -is [System.Net.FtpWebResponse]) {
                    Write-Host "     • FTP Error: $($errorResponse.StatusCode) - $($errorResponse.StatusDescription)"
                }
            }
        }
    }
}

function Create-FtpDirectory {
    param(
        [string]$DirectoryUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    try {
        $request = [System.Net.FtpWebRequest]::Create("ftp://$DirectoryUri")
        $request.Method = [System.Net.WebRequestMethods+Ftp]::MakeDirectory
        $request.Credentials = $Credentials
        $request.UsePassive = $UsePassive

        $response = $request.GetResponse()
        $response.Close()
        Write-Host "   • ✅ Created directory: `e[32mftp://$DirectoryUri`e[0m"
        return $true
    }
    catch {
        # Enhanced directory creation error handling
        Write-Host "   • ⚠️  Directory creation failed for `e[33mftp://$DirectoryUri`e[0m"
        Write-FtpErrorDetails -ErrorRecord $_ -Context "Directory creation for '$DirectoryUri'" -AdditionalInfo @{
            'FTP URI'     = "ftp://$DirectoryUri"
            'Operation'   = 'Create directory'
            'Credentials' = $Credentials.UserName
            'Use Passive' = $UsePassive
        }
        return $false
    }
}

function Get-FtpDirectoryListing {
    param(
        [string]$FtpUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    try {
        $listRequest = [System.Net.FtpWebRequest]::Create("ftp://$FtpUri")
        $listRequest.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $listRequest.Credentials = $Credentials
        $listRequest.UsePassive = $UsePassive

        $listResponse = $listRequest.GetResponse()
        $listStream = $listResponse.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($listStream)
        $directoryListing = $reader.ReadToEnd()
        $reader.Close()
        $listResponse.Close()

        return $directoryListing
    }
    catch {
        Write-Host "   • ⚠️  Could not list directory `e[33mftp://$FtpUri`e[0m: $($_.Exception.Message)"
        return $null
    }
}

function Get-FtpFilesRecursive {
    param(
        [string]$FtpBaseUri,
        [string]$CurrentPath,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    $files = @()
    $directories = @()

    $currentUri = if ($CurrentPath -eq '') {
        $FtpBaseUri
    }
    else {
        "$FtpBaseUri/$CurrentPath" -replace '/+', '/'
    }

    $directoryListing = Get-FtpDirectoryListing -FtpUri $currentUri -Credentials $Credentials -UsePassive $UsePassive

    if ($directoryListing) {
        $directoryListing -split "`n" | ForEach-Object {
            $line = $_.Trim()
            if ($line) {
                $parts = $line -split '\s+'
                if ($parts.Length -gt 0) {
                    $itemName = $parts[-1]
                    if ($itemName -and $itemName -ne '.' -and $itemName -ne '..') {
                        $itemPath = if ($CurrentPath -eq '') {
                            $itemName
                        }
                        else {
                            "$CurrentPath/$itemName"
                        }

                        if ($line.StartsWith('d')) {
                            # It's a directory - recursively get its contents
                            $directories += $itemPath
                            $subResults = Get-FtpFilesRecursive -FtpBaseUri $FtpBaseUri -CurrentPath $itemPath -Credentials $Credentials -UsePassive $UsePassive
                            $files += $subResults.Files
                            $directories += $subResults.Directories
                        }
                        else {
                            # It's a file
                            $files += $itemPath
                        }
                    }
                }
            }
        }
    }    return @{
        Files       = $files
        Directories = $directories
    }
}

function Test-FtpConnectivity {
    param(
        [string]$FtpUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive,
        [ValidateSet('Directory', 'File')]
        [string]$TestType = 'Directory'
    )

    Write-Host "`n🔌 Testing FTP connectivity..."

    # Extract base URI (server:port) and path separately
    $baseUri = $FtpUri -replace '/.*$', ''  # Remove path, keep just server:port
    $pathPart = $FtpUri -replace '^[^/]*/', '/'  # Extract just the path part

    # If no path specified, default to root
    if (-not $pathPart -or $pathPart -eq $FtpUri) {
        $pathPart = '/'
        $baseUri = $FtpUri
    }

    try {
        # Test 1: Basic connection and authentication
        Write-Host "   • Testing basic connection to `e[36mftp://$FtpUri`e[0m"
        $listRequest = [System.Net.FtpWebRequest]::Create("ftp://$FtpUri")
        $listRequest.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $listRequest.Credentials = $Credentials
        $listRequest.UsePassive = $UsePassive
        $listRequest.Timeout = 30000  # 30 seconds timeout

        $listResponse = $listRequest.GetResponse()
        Write-Host '   • ✅ Connection successful!'
        Write-Host "   • FTP Status: `e[32m$($listResponse.StatusCode) - $($listResponse.StatusDescription.Trim())`e[0m"
        Write-Host "   • Banner: `e[36m$($listResponse.BannerMessage.Trim())`e[0m"
        Write-Host "   • Welcome: `e[36m$($listResponse.WelcomeMessage.Trim())`e[0m"

        # Test 2: Try to list directory contents
        $listStream = $listResponse.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($listStream)
        $directoryListing = $reader.ReadToEnd()
        $reader.Close()
        $listResponse.Close()

        if ($directoryListing) {
            $lineCount = ($directoryListing -split "`n").Count
            Write-Host "   • ✅ Directory listing successful ($lineCount entries)"
        }
        else {
            Write-Host '   • ⚠️  Directory appears empty'
        }

        # Test 3: Try to create a test directory to check write permissions
        Write-Host '   • Testing write permissions...'
        $testDirName = "test_write_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $testDirUri = "$FtpUri/$testDirName"

        try {
            $createRequest = [System.Net.FtpWebRequest]::Create("ftp://$testDirUri")
            $createRequest.Method = [System.Net.WebRequestMethods+Ftp]::MakeDirectory
            $createRequest.Credentials = $Credentials
            $createRequest.UsePassive = $UsePassive
            $createRequest.Timeout = 15000  # 15 seconds timeout

            $createResponse = $createRequest.GetResponse()
            $createResponse.Close()
            Write-Host '   • ✅ Write permissions confirmed (test directory created)'

            # Clean up test directory
            try {
                $deleteRequest = [System.Net.FtpWebRequest]::Create("ftp://$testDirUri")
                $deleteRequest.Method = [System.Net.WebRequestMethods+Ftp]::RemoveDirectory
                $deleteRequest.Credentials = $Credentials
                $deleteRequest.UsePassive = $UsePassive
                $deleteRequest.Timeout = 10000  # 10 seconds timeout

                $deleteResponse = $deleteRequest.GetResponse()
                $deleteResponse.Close()
                Write-Host '   • ✅ Test directory cleaned up'
            }
            catch {
                Write-Host "   • ⚠️  Could not clean up test directory: $($_.Exception.Message)"
            }
        }
        catch {
            Write-Host '   • ❌ Write permission test failed!'
            Write-FtpErrorDetails -ErrorRecord $_ -Context 'Write permission test' -AdditionalInfo @{
                'Test Directory URI' = "ftp://$testDirUri"
                'Operation'          = 'Create test directory'
            }
            return $false
        }

        return $true
    }
    catch {
        $is550Error = $_.Exception.Message -like '*550*' -or ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response -and $_.Exception.Response.StatusCode -eq [System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable)

        if ($is550Error -and $pathPart -and $pathPart -ne '/') {
            if ($TestType -eq 'Directory') {
                try {
                    Write-Host "   • 📁 Target doesn't exist - Creating directory structure..."
                    $pathSegments = $pathPart.Trim('/') -split '/'
                    $currentPath = ''
                    $baseUri = $FtpUri -replace '/.*$', ''  # Server:port only

                    foreach ($segment in $pathSegments) {
                        if ($segment) {
                            $currentPath += '/' + $segment
                            $createUri = "ftp://$baseUri$currentPath"

                            try {
                                $createRequest = [System.Net.FtpWebRequest]::Create($createUri)
                                $createRequest.Method = [System.Net.WebRequestMethods+Ftp]::MakeDirectory
                                $createRequest.Credentials = $Credentials
                                $createRequest.UsePassive = $UsePassive
                                $createRequest.Timeout = 15000

                                $createResponse = $createRequest.GetResponse()
                                $createResponse.Close()
                                Write-Host "   • ✅ Created directory: `e[32m$currentPath`e[0m"
                            }
                            catch {
                                # Directory might already exist, which is fine
                                if ($_.Exception.Message -like '*550*' -and $_.Exception.Message -like '*exists*') {
                                    Write-Host "     ℹ️  Directory already exists: `e[33m$currentPath`e[0m"
                                }
                                else {
                                    Write-Host "     ⚠️  Could not create directory $currentPath`: $($_.Exception.Message)"
                                    # Continue trying other segments
                                }
                            }
                        }
                    }

                    # Test if we can now access the target directory
                    try {
                        $testRequest = [System.Net.FtpWebRequest]::Create("ftp://$FtpUri")
                        $testRequest.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
                        $testRequest.Credentials = $Credentials
                        $testRequest.UsePassive = $UsePassive
                        $testRequest.Timeout = 15000

                        $testResponse = $testRequest.GetResponse()
                        $testResponse.Close()
                        Write-Host '   • ✅ Directory is accessible!'
                        return $true
                    }
                    catch {
                        Write-Host "   • ❌ Directory creation completed but target still not accessible: $($_.Exception.Message)"
                    }
                }
                catch {
                    Write-Host "   • ❌ Directory creation failed: $($_.Exception.Message)"
                }
            }
            elseif ($TestType -eq 'File') {
                # Try to create as a file
                Write-Host "   • 📄  Target doesn't exist - Creating as file..."
                try {
                    $fileContent = "# FTP Test File`nCreated by AgX.FTPDeploy on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
                    $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)

                    $uploadRequest = [System.Net.FtpWebRequest]::Create("ftp://$FtpUri")
                    $uploadRequest.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
                    $uploadRequest.Credentials = $Credentials
                    $uploadRequest.UsePassive = $UsePassive
                    $uploadRequest.ContentLength = $contentBytes.Length
                    $uploadRequest.Timeout = 15000

                    $requestStream = $uploadRequest.GetRequestStream()
                    $requestStream.Write($contentBytes, 0, $contentBytes.Length)
                    $requestStream.Close()

                    $uploadResponse = $uploadRequest.GetResponse()
                    $uploadResponse.Close()

                    Write-Host "   • ✅ Created file: `e[32m$FtpUri`e[0m"
                    return $true
                }
                catch {
                    Write-Host "   • ❌ File creation failed: $($_.Exception.Message)"
                }
            }
        }

        # If we get here, all fallbacks failed - provide detailed error information
        Write-FtpErrorDetails -ErrorRecord $_ -Context 'FTP connectivity test' -AdditionalInfo @{
            'FTP URI'      = "ftp://$FtpUri"
            'Operation'    = 'Basic connection and directory listing'
            'Passive Mode' = $UsePassive
            'Port'         = (($FtpUri -split ':')[1] -split '/')[0]
            'Remote Path'  = $FtpUri
        }

        return $false
    }
}

# MAIN SCRIPT EXECUTION

Write-Host "🔧 `e[32mStarting FTP deployment...`e[0m"

Write-Host "`n🔍 Input Parameters:"
Write-Host "   • Port: `e[36m$Port`e[0m"
Write-Host "   • Remote Path: `e[36m$RemotePath`e[0m"
Write-Host "   • Passive Mode: `e[36m$PassiveMode`e[0m"
Write-Host "   • Clean Target: `e[36m$CleanTarget`e[0m"
Write-Host "   • Exclude Patterns: `e[36m$ExcludePatterns`e[0m"
Write-Host "   • Preserve Patterns: `e[36m$PreservePatterns`e[0m"

Write-Host "`n🔄 Processing exclude patterns..."
try {
    $excludeList = @()
    if (-not [string]::IsNullOrWhiteSpace($ExcludePatterns)) {
        $excludeList = $ExcludePatterns -split ',' | ForEach-Object { $_.Trim() }
    }
}
catch {
    Write-Host "❌ `e[31mError parsing exclude patterns:`e[0m $($_.Exception.Message)"
    exit 1
}

Write-Host '🔧 Using native .NET FTP client...'
try {
    # Normalize and encode the remote path
    $normalizedPath = $RemotePath.TrimEnd('/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        $encodedPath = ''
    }
    else {
        $encodedPath = '/' + [System.Uri]::EscapeUriString($normalizedPath)
    }
    $ftpUri = "${Server}:${Port}${encodedPath}"
    Write-Host "   • [CI] Source: `e[36m$DeployPath`e[0m"
    Write-Host "   • [HOST] Destination: `e[36mftp://$ftpUri`e[0m"
    if (-not (Test-Path -Path $DeployPath)) {
        Write-Host "   • ❌ `e[31mDeploy path does not exist!`e[0m"
        throw "Deploy path not found: $DeployPath"
    }

    $sourceFiles = Get-ChildItem -Path $DeployPath -Recurse -File
    Write-Host "   • Found `e[36m$($sourceFiles.Count)`e[0m files to process"
    $uploadCount = 0
    $skippedCount = 0
    $credentials = New-Object System.Net.NetworkCredential($Username, $Password)
    $createdDirectories = @()     # Perform pre-flight connectivity and permissions test
    $connectivityOk = $true

    if (-not $DisableConnectivityTests) {
        if (-not [string]::IsNullOrWhiteSpace($TestFtpDirectory)) {
            $testDirUri = "$ftpUri/$($TestFtpDirectory.TrimStart('/'))" -replace '//+', '/'
            $dirConnectivityOk = Test-FtpConnectivity -FtpUri $testDirUri -Credentials $credentials -UsePassive $PassiveMode -TestType 'Directory'
            $connectivityOk = $connectivityOk -and $dirConnectivityOk
        }

        if (-not [string]::IsNullOrWhiteSpace($TestFtpFile)) {
            $testFileUri = "$ftpUri/$($TestFtpFile.TrimStart('/'))" -replace '//+', '/'
            $fileConnectivityOk = Test-FtpConnectivity -FtpUri $testFileUri -Credentials $credentials -UsePassive $PassiveMode -TestType 'File'
            $connectivityOk = $connectivityOk -and $fileConnectivityOk
        }

        if (-not $connectivityOk) {
            Write-Host "❌ `e[31mFTP connectivity test failed. Deployment cannot proceed.`e[0m"
            throw 'FTP connectivity test failed'
        }
    }

    Write-Host "`n📤 Starting file upload process..."
    $sourceFiles | ForEach-Object {
        try {
            $currentFile = $_
            $relativePath = $currentFile.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
            $relativePath = $relativePath -replace '\\', '/'
            if (Test-ExcludeFile -FilePath $relativePath -Patterns $excludeList) {
                $skippedCount++
                return
            }
            Write-Host "   • Uploading file: `e[36m$relativePath`e[0m"
            # Ensure parent directories exist
            $pathParts = $relativePath -split '/'
            if ($pathParts.Length -gt 1) {
                $currentPath = ''
                for ($i = 0; $i -lt ($pathParts.Length - 1); $i++) {
                    $currentPath = if ($currentPath -eq '') { $pathParts[$i] } else { "$currentPath/$pathParts[$i]" }
                    # Construct directory URI properly - maintain proper FTP URI format
                    $dirUri = "$ftpUri/$currentPath" -replace '/+', '/'

                    if ($createdDirectories -notcontains $currentPath) {
                        $null = Create-FtpDirectory -DirectoryUri $dirUri -Credentials $credentials -UsePassive $PassiveMode
                        $createdDirectories += $currentPath
                    }
                }
            }

            $remoteFileUri = "$ftpUri/$relativePath" -replace '/+', '/'
            $request = [System.Net.FtpWebRequest]::Create("ftp://$remoteFileUri")
            $request.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
            $request.Credentials = $credentials
            $request.UsePassive = $PassiveMode
            $fileContent = [System.IO.File]::ReadAllBytes($currentFile.FullName)
            $request.ContentLength = $fileContent.Length
            $requestStream = $request.GetRequestStream()
            $requestStream.Write($fileContent, 0, $fileContent.Length)
            $requestStream.Close()
            $response = $request.GetResponse()
            $response.Close()
            $uploadCount++
        }
        catch {
            Write-FtpErrorDetails -ErrorRecord $_ -Context 'File upload operation' -AdditionalInfo @{
                'File'          = $currentFile.Name
                'Local path'    = $currentFile.FullName
                'Remote URI'    = "ftp://$remoteFileUri"
                'File size'     = "$($fileContent.Length) bytes"
                'Relative path' = $relativePath
            }
            throw
        }
    }

    $cleanupCount = 0
    if ($CleanTarget) {
        Write-Host '🧹 Starting cleanup of old files...'
        $preserveList = @()
        if (-not [string]::IsNullOrWhiteSpace($PreservePatterns)) {
            $preserveList = $PreservePatterns -split ',' | ForEach-Object { $_.Trim() }
            Write-Host "   • Preserve patterns: `e[36m$($preserveList -join ', ')`e[0m"
        }

        try {
            $uploadedFiles = @()
            Get-ChildItem -Path $DeployPath -Recurse -File | ForEach-Object {
                $relativePath = $_.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
                $relativePath = $relativePath -replace '\\', '/'

                if (-not (Test-ExcludeFile -FilePath $relativePath -Patterns $excludeList)) {
                    $uploadedFiles += $relativePath
                }
            }

            try {
                Write-Host '   • 🔍 Scanning remote server for all files (including subdirectories)...'
                $remoteStructure = Get-FtpFilesRecursive -FtpBaseUri $ftpUri -CurrentPath '' -Credentials $credentials -UsePassive $PassiveMode

                if ($remoteStructure) {
                    $existingFiles = $remoteStructure.Files
                    $existingDirectories = $remoteStructure.Directories

                    Write-Host "   • Found `e[36m$($existingFiles.Count)`e[0m files and `e[36m$($existingDirectories.Count)`e[0m directories on server"

                    # Find files to delete (exist on server but not in current deployment)
                    $filesToDelete = @()
                    foreach ($existingFile in $existingFiles) {
                        if ($uploadedFiles -notcontains $existingFile) {
                            if (Test-PreserveFile -FilePath $existingFile -Patterns $preserveList) {
                                Write-Host "   • 🔒 Preserved: `e[32m$existingFile`e[0m (matches preserve pattern)"
                            }
                            else {
                                $filesToDelete += $existingFile
                            }
                        }
                    }

                    # Delete old files
                    foreach ($fileToDelete in $filesToDelete) {
                        $deleteUri = "$ftpUri/$fileToDelete" -replace '/+', '/'

                        try {
                            $deleteRequest = [System.Net.FtpWebRequest]::Create("ftp://$deleteUri")
                            $deleteRequest.Method = [System.Net.WebRequestMethods+Ftp]::DeleteFile
                            $deleteRequest.Credentials = $credentials
                            $deleteRequest.UsePassive = $PassiveMode

                            $deleteResponse = $deleteRequest.GetResponse()
                            $deleteResponse.Close()

                            Write-Host "   • 🗑️  Deleted: `e[31m$fileToDelete`e[0m"
                            $cleanupCount++
                        }
                        catch {
                            Write-Host "   • ⚠️  Could not delete `e[33m$fileToDelete`e[0m: $($_.Exception.Message)"
                        }
                    }

                    # Find and delete empty directories (in reverse order to handle nested directories)
                    $uploadedDirectories = @()
                    Get-ChildItem -Path $DeployPath -Recurse -Directory | ForEach-Object {
                        $relativePath = $_.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
                        $relativePath = $relativePath -replace '\\', '/'
                        $uploadedDirectories += $relativePath
                    }

                    $directoriesToDelete = @()
                    foreach ($existingDir in $existingDirectories) {
                        if ($uploadedDirectories -notcontains $existingDir) {
                            $directoriesToDelete += $existingDir
                        }
                    }

                    # Sort directories by depth (deepest first) to avoid deletion conflicts
                    $directoriesToDelete = $directoriesToDelete | Sort-Object { ($_ -split '/').Count } -Descending

                    foreach ($dirToDelete in $directoriesToDelete) {
                        $deleteUri = "$ftpUri/$dirToDelete" -replace '/+', '/'

                        try {
                            $deleteRequest = [System.Net.FtpWebRequest]::Create("ftp://$deleteUri")
                            $deleteRequest.Method = [System.Net.WebRequestMethods+Ftp]::RemoveDirectory
                            $deleteRequest.Credentials = $credentials
                            $deleteRequest.UsePassive = $PassiveMode

                            $deleteResponse = $deleteRequest.GetResponse()
                            $deleteResponse.Close()

                            Write-Host "   • 📁🗑️  Deleted directory: `e[31m$dirToDelete`e[0m"
                            $cleanupCount++
                        }
                        catch {
                            Write-Host "   • ⚠️  Could not delete directory `e[33m$dirToDelete`e[0m: $($_.Exception.Message)"
                        }
                    }

                    if ($filesToDelete.Count -eq 0 -and $directoriesToDelete.Count -eq 0) {
                        Write-Host '   • ✅ No old files or directories to cleanup'
                    }
                }
                else {
                    Write-Host '   • ⚠️  Could not retrieve remote server structure for cleanup'
                }

            }
            catch {
                Write-Host "   • ⚠️  `e[33mCould not list server files for cleanup:`e[0m $($_.Exception.Message)"
            }

        }
        catch {
            Write-Host "   • ⚠️  `e[33mCleanup failed:`e[0m $($_.Exception.Message)"
            Write-Host '   • 📤 Deployment was successful, cleanup failed.'
        }
    }

    Write-Host "🎉 `e[32mFTP deployment completed successfully!`e[0m"
    Write-Host "   • Files uploaded: `e[32m$uploadCount`e[0m"
    if ($skippedCount -gt 0) {
        Write-Host "   • Files skipped: `e[33m$skippedCount`e[0m"
    }
    if ($cleanupCount -gt 0) {
        Write-Host "   • Files cleaned up: `e[31m$cleanupCount`e[0m"
    }
}
catch {
    Write-Host "❌ `e[31mFTP deployment failed!`e[0m"
    Write-FtpErrorDetails -ErrorRecord $_ -Context 'FTP deployment process' -AdditionalInfo @{
        'Deploy Path'  = $DeployPath
        'Server'       = $Server
        'Port'         = $Port
        'Remote Path'  = $RemotePath
        'Passive Mode' = $PassiveMode
        'Clean Target' = $CleanTarget
    }
    exit 1
}
