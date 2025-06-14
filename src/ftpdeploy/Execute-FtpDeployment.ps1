﻿[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
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
    [bool]$DisableConnectivityTests = $false,

    [Parameter(Mandatory = $false)]
    [bool]$EnableDiffUpload = $true
)

$protocol = 'ftp://'

class Result {
    [bool]$Success
    [System.Object]$Value
    [System.Exception]$Exception

    # Private constructor to prevent direct instantiation
    hidden Result() {
        $this.Success = $false
        $this.Value = $null
        $this.Exception = $null
    }

    # Factory method for generic success
    static [Result] Success() {
        $result = [Result]::new()
        $result.Success = $true
        return $result
    }

    # Factory method for success with value
    static [Result] Success([System.Object]$value) {
        $result = [Result]::new()
        $result.Success = $true
        $result.Value = $value
        return $result
    }

    # Factory method for generic failure
    static [Result] Fail() {
        $result = [Result]::new()
        $result.Success = $false
        return $result
    }

    # Factory method for failure with exception
    static [Result] Fail([System.Exception]$exception) {
        $result = [Result]::new()
        $result.Success = $false
        $result.Exception = $exception
        return $result
    }
}

# HELPER FUNCTIONS

function New-FtpUri {
    param(
        [string]$BaseUri,
        [string]$Path = ''
    )

    # Remove protocol if it's already in BaseUri
    $cleanBaseUri = $BaseUri -replace '^ftp://', ''

    # Clean and normalize the path
    $cleanPath = $Path.Trim('/')

    # Construct the final URI
    if ([string]::IsNullOrWhiteSpace($cleanPath)) {
        return "$protocol$cleanBaseUri"
    }
    else {
        return "$protocol$cleanBaseUri/$cleanPath"
    }
}

function New-FtpRequest {
    param(
        [string]$Uri,
        [string]$Method,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive,
        [int]$TimeoutMs = 15000
    )

    $request = [System.Net.FtpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Credentials = $Credentials
    $request.UsePassive = $UsePassive
    $request.Timeout = $TimeoutMs

    return $request
}

function Test-FileMatchesPatterns {
    param([string]$FilePath, [string[]]$Patterns)
    if ($Patterns.Count -eq 0) {
        return [Result]::Fail()
    }

    foreach ($pattern in $Patterns) {
        if ($FilePath -like $pattern) {
            return [Result]::Success()
        }
    }
    return [Result]::Fail()
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
        [object]$ErrorSource,

        [Parameter(Mandatory = $false)]
        [string]$Context = '',

        [Parameter(Mandatory = $false)]
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

    # Determine if we have an ErrorRecord or Exception and extract the Exception
    $exception = $null
    $scriptStackTrace = $null

    if ($ErrorSource -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorSource.Exception
        $scriptStackTrace = $ErrorSource.ScriptStackTrace
    }
    elseif ($ErrorSource -is [System.Exception]) {
        $exception = $ErrorSource
        $scriptStackTrace = $null
    }
    else {
        Write-Host "⚠️ Unknown error source type: $($ErrorSource.GetType().FullName)"
        return
    }

    # Use the recursive exception details function
    Write-ExceptionDetails -Exception $exception -Level 0

    # ScriptStackTrace (PowerShell specific)
    if ($scriptStackTrace) {
        Write-Host "`n📝 Script Stack Trace:"
        Write-Host "`e[90m$scriptStackTrace`e[0m"
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

function Read-FtpPath {
    param(
        [string]$BaseUri,
        [string]$PathToRead,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )
    $readPath = New-FtpUri -BaseUri $BaseUri -Path $PathToRead
    Write-Host "`n🔍 Read FTP Path: `e[36m$readPath`e[0m"
    try {
        $request = New-FtpRequest -Uri "$readPath" -Method ([System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails) -Credentials $Credentials -UsePassive $UsePassive -TimeoutMs 10000
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $details = $reader.ReadToEnd()
        $reader.Close()
        $stream.Close()

        Write-Host " • ✅ `e[32mAccessible`e[0m - Contains $((($details -split "`n") | Where-Object { $_.Trim() }).Count) items"
        return [Result]::Success($details)
    }
    catch {
        Write-Host " • ❌ `e[31mNot accessible`e[0m - $($_.Exception.Message)"
        Write-FtpErrorDetails -ErrorSource $_ -Context "Read for '$readPath'" -AdditionalInfo @{
            'FTP URI'     = $readPath
            'Operation'   = 'Read path'
            'Credentials' = $Credentials.UserName
            'Use Passive' = $UsePassive
        }
        return [Result]::Fail($_.Exception)
    }
}

function Read-FtpFilesRecursive {
    param(
        [string]$BaseUri,
        [string]$Path,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    $files = @()
    $directories = @()

    $currentUri = if ($Path -eq '') {
        $BaseUri
    }
    else {
        "$BaseUri/$Path"
    }

    $result = Read-FtpPath -BaseUri $currentUri -PathToRead '' -Credentials $Credentials -UsePassive $UsePassive
    if (-not $result.Success) {
        return $result
    }

    $details = $result.Value

    if ($details) {
        $details -split "`n" | ForEach-Object {
            $line = $_.Trim()
            if ($line) {
                $parts = $line -split '\s+'
                if ($parts.Length -gt 0) {
                    $itemName = $parts[-1]
                    if ($itemName -and $itemName -ne '.' -and $itemName -ne '..') {
                        $itemPath = if ($Path -eq '') {
                            $itemName
                        }
                        else {
                            "$Path/$itemName"
                        }

                        if ($line.StartsWith('d')) {
                            # It's a directory - recursively get its contents
                            $directories += $itemPath
                            $subResults = Read-FtpFilesRecursive -BaseUri $BaseUri -Path $itemPath -Credentials $Credentials -UsePassive $UsePassive
                            if ($subResults.Success) {
                                $files += $subResults.Value.Files
                                $directories += $subResults.Value.Directories
                            }
                            else {
                                return $subResults
                            }
                        }
                        else {
                            # It's a file
                            $files += $itemPath
                        }
                    }
                }
            }
        }
    }

    return [Result]::Success(@{Files = $files; Directories = $directories })
}

function New-FtpDirectory {
    param(
        [string]$BaseUri,
        [string]$DirectoryUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    $pathSegments = $DirectoryUri.Trim('/') -split '/'
    $currentPath = ''

    foreach ($segment in $pathSegments) {
        if ($segment) {
            $currentPath += '/' + $segment
            $createUri = New-FtpUri -BaseUri $BaseUri -Path $currentPath

            try {
                $createRequest = New-FtpRequest -Uri $createUri -Method ([System.Net.WebRequestMethods+Ftp]::MakeDirectory) -Credentials $Credentials -UsePassive $UsePassive

                $createResponse = $createRequest.GetResponse()
                $createResponse.Close()
                Write-Host " • ✅ Created directory: `e[32m$currentPath`e[0m"
            }
            catch {
                # Check if this is a "directory already exists" error by using Read-FtpPath
                # This is more reliable than parsing error messages which vary between FTP servers
                $testResult = Read-FtpPath -BaseUri $BaseUri -PathToRead $currentPath -Credentials $Credentials -UsePassive $UsePassive
                if ($testResult.Success) {
                    # If we can read the directory, it exists - that's fine
                    Write-Host " • ℹ️ Directory already exists: `e[36m$currentPath`e[0m"
                }
                else {
                    # If we can't read it either, then there's a real problem
                    Write-Host " • ⚠️ Directory creation failed for `e[33m$createUri`e[0m"
                    Write-Host " • ⚠️ Creation error: $($_.Exception.Message)"
                    return [Result]::Fail($_.Exception)
                }
            }
        }
    }

    return [Result]::Success()
}

function Remove-FtpDirectory {
    param(
        [string]$BaseUri,
        [string]$DirectoryUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    $removeUri = New-FtpUri -BaseUri $BaseUri -Path $DirectoryUri

    try {
        $request = New-FtpRequest -Uri $removeUri -Method ([System.Net.WebRequestMethods+Ftp]::RemoveDirectory) -Credentials $Credentials -UsePassive $UsePassive
        $response = $request.GetResponse()
        $response.Close()
        Write-Host " • ✅ Removed directory: `e[32m$removeUri`e[0m"
        return [Result]::Success()
    }
    catch {
        Write-Host " • ⚠️ Directory removal failed for `e[33m$removeUri`e[0m"
        return [Result]::Fail($_.Exception)
    }
}

function Upload-FtpFile {
    param(
        [string]$BaseUri,
        [string]$FileUri,
        [byte[]]$FileContent,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    try {
        # Split the FileUri into directory path and filename
        $pathSegments = $FileUri.Trim('/') -split '/'
        if ($pathSegments.Count -gt 1) {
            # Extract directory path (all segments except the last one)
            $directoryPath = ($pathSegments[0..($pathSegments.Count - 2)]) -join '/'
            # Create directory structure recursively (New-FtpDirectory handles this)
            $createDirResult = New-FtpDirectory -BaseUri $BaseUri -DirectoryUri $directoryPath -Credentials $Credentials -UsePassive $UsePassive
            if (-not $createDirResult.Success) {
                return $createDirResult
            }
        }
        # Upload the file
        $uploadUri = New-FtpUri -BaseUri $BaseUri -Path $FileUri
        $request = New-FtpRequest -Uri $uploadUri -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile) -Credentials $Credentials -UsePassive $UsePassive
        $request.ContentLength = $FileContent.Length

        $requestStream = $request.GetRequestStream()
        $requestStream.Write($FileContent, 0, $FileContent.Length)
        $requestStream.Close()

        $response = $request.GetResponse()
        $response.Close()
        Write-Host " • ✅ Uploaded file [$($FileContent.Length) bytes]: `e[32m$uploadUri`e[0m"
        return [Result]::Success()
    }
    catch {
        Write-Host " • ⚠️ File upload failed for `e[33m$uploadUri`e[0m"
        return [Result]::Fail($_.Exception)
    }
}

function Remove-FtpFile {
    param(
        [string]$BaseUri,
        [string]$FileUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    $removeUri = New-FtpUri -BaseUri $BaseUri -Path $FileUri

    try {
        $request = New-FtpRequest -Uri $removeUri -Method ([System.Net.WebRequestMethods+Ftp]::DeleteFile) -Credentials $Credentials -UsePassive $UsePassive
        $response = $request.GetResponse()
        $response.Close()

        Write-Host " • ✅ Removed file: `e[32m$removeUri`e[0m"
        return [Result]::Success()
    }
    catch {
        Write-Host " • ⚠️ File removal failed for `e[33m$removeUri`e[0m"
        return [Result]::Fail($_.Exception)
    }
}

function Test-FtpConnectivity {
    param(
        [string]$FtpUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive = $true
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
        Write-Host " • Testing basic connection to `e[36m$FtpUri`e[0m"
        $result = Read-FtpPath -BaseUri $baseUri -PathToRead $pathPart -Credentials $Credentials -UsePassive $UsePassive
        if (-not $result.Success) {
            Write-FtpErrorDetails -ErrorSource $result.Exception -Context '[TEST] FTP connectivity and read' -AdditionalInfo @{
                'Remote Path' = $FtpUri
            }
            return $result
        }
        $tempDir = "$pathPart/agx-ftp-test-temp"
        $createDirResult = New-FtpDirectory -BaseUri $baseUri -DirectoryUri $tempDir -Credentials $Credentials -UsePassive $UsePassive
        if (-not $createDirResult.Success) {
            Write-FtpErrorDetails -ErrorSource $createDirResult.Exception -Context '[TEST] Creating temp directory' -AdditionalInfo @{
                'Remote Path' = $tempDir
            }
            return $createDirResult
        }
        $deleteDirResult = Remove-FtpDirectory -BaseUri $baseUri -DirectoryUri $tempDir -Credentials $Credentials -UsePassive $UsePassive
        if (-not $deleteDirResult.Success) {
            Write-FtpErrorDetails -ErrorSource $deleteDirResult.Exception -Context '[TEST] Deleting temp directory' -AdditionalInfo @{
                'Remote Path' = $tempDir
            }
            return $deleteDirResult
        }

        $tempFile = "$pathPart/agx-ftp-test.tmp"
        $fileContent = "# FTP Test File`nCreated by AgX.FTPDeploy on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)

        $createFileResult = Upload-FtpFile -BaseUri $baseUri -FileUri "$tempFile" -FileContent $contentBytes -Credentials $Credentials -UsePassive $UsePassive
        if (-not $createFileResult.Success) {
            Write-FtpErrorDetails -ErrorSource $createFileResult.Exception -Context '[TEST] Creating temp file' -AdditionalInfo @{
                'Remote Path' = "$tempFile"
            }
            return $createFileResult
        }

        $deleteFileResult = Remove-FtpFile -BaseUri $baseUri -FileUri $tempFile -Credentials $Credentials -UsePassive $UsePassive
        if (-not $deleteFileResult.Success) {
            Write-FtpErrorDetails -ErrorSource $deleteFileResult.Exception -Context '[TEST] Deleting temp file' -AdditionalInfo @{
                'Remote Path' = "$tempFile"
            }
            return $deleteFileResult
        }
    }
    catch {
        Write-Host " ❌ `e[31mFTP connectivity test failed: $($_.Exception.Message)`e[0m"
        Write-FtpErrorDetails -ErrorSource $_ -Context 'FTP connectivity test'
        return [Result]::Fail($_.Exception)
    }

    return [Result]::Success()
}

# DIFFERENTIAL UPLOAD FUNCTIONS

function Get-RemoteFileSize {
    param(
        [string]$BaseUri,
        [string]$FileUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    try {
        $ftpUri = New-FtpUri -BaseUri $BaseUri -Path $FileUri
        $request = New-FtpRequest -Uri $ftpUri -Method ([System.Net.WebRequestMethods+Ftp]::GetFileSize) -Credentials $Credentials -UsePassive $UsePassive
        $response = $request.GetResponse()
        $size = $response.ContentLength
        $response.Close()

        return [Result]::Success($size)
    }
    catch {
        # File doesn't exist or can't be accessed
        return [Result]::Fail($_.Exception)
    }
}

function Test-FileNeedsUpload {
    param(
        [System.IO.FileInfo]$LocalFile,
        [string]$BaseUri,
        [string]$FileUri,
        [System.Net.NetworkCredential]$Credentials,
        [bool]$UsePassive
    )

    $remoteSizeResult = Get-RemoteFileSize -BaseUri $BaseUri -FileUri $FileUri -Credentials $Credentials -UsePassive $UsePassive

    # If we can't get remote file size, assume upload is needed (file doesn't exist or error)
    if (-not $remoteSizeResult.Success) {
        return [Result]::Success($true)
    }

    $remoteSize = $remoteSizeResult.Value
    $localSize = $LocalFile.Length

    # If sizes differ, upload is needed
    if ($localSize -ne $remoteSize) {
        return [Result]::Success($true)
    }

    # Sizes match, no upload needed
    return [Result]::Success($false)
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
Write-Host "   • Enable Diff Upload: `e[36m$EnableDiffUpload`e[0m"

Write-Host "`n🔄 Processing exclude patterns..."
try {
    $excludeList = @()
    if (-not [string]::IsNullOrWhiteSpace($ExcludePatterns)) {
        $excludeList = $ExcludePatterns -split ', ' | ForEach-Object { $_.Trim() }
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
    Write-Host "   • [HOST] Destination: `e[36m$protocol$ftpUri`e[0m"
    if (-not (Test-Path -Path $DeployPath)) {
        Write-Host "   • ❌ `e[31mDeploy path does not exist!`e[0m"
        throw "Deploy path not found: $DeployPath"
    }

    $sourceFiles = Get-ChildItem -Path $DeployPath -Recurse -File
    Write-Host "   • Found `e[36m$($sourceFiles.Count)`e[0m files to process"
    $uploadCount = 0
    $skippedCount = 0
    $credentials = New-Object System.Net.NetworkCredential($Username, $Password)

    if (-not $DisableConnectivityTests) {
        $connectivityResult = Test-FtpConnectivity -FtpUri $ftpUri -Credentials $credentials -UsePassive $PassiveMode
        if (-not $connectivityResult.Success) {
            throw "FTP connectivity test failed: $($connectivityResult.Exception.Message)"
        }
    }

    Write-Host "`n📤 Starting file upload process..."
    $differentialSkippedCount = 0
    $sourceFiles | ForEach-Object {
        $currentFile = $_
        $relativePath = $currentFile.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
        $relativePath = $relativePath -replace '\\', '/'

        # Skip files matching exclude patterns
        if ((Test-FileMatchesPatterns -FilePath $relativePath -Patterns $excludeList).Success) {
            $skippedCount++
            return
        }

        # Check if differential upload is enabled and file needs upload
        if ($EnableDiffUpload) {
            $uploadCheckResult = Test-FileNeedsUpload -LocalFile $currentFile -BaseUri $ftpUri -FileUri $relativePath -Credentials $credentials -UsePassive $PassiveMode

            if ($uploadCheckResult.Success -and -not $uploadCheckResult.Value) {
                $differentialSkippedCount++
                return
            }
        }

        $uploadResult = Upload-FtpFile -BaseUri $ftpUri -FileUri $relativePath -FileContent ([System.IO.File]::ReadAllBytes($currentFile.FullName)) -Credentials $credentials -UsePassive $PassiveMode
        if (-not $uploadResult.Success) {
            Write-FtpErrorDetails -ErrorSource $uploadResult.Exception -Context 'File upload' -AdditionalInfo @{
                'File'       = $currentFile.Name
                'Local path' = $currentFile.FullName
                'Remote URI' = New-FtpUri -BaseUri $ftpUri -Path $relativePath
                'File size'  = "$($currentFile.Length) bytes"
            }
            throw "Failed to upload file: $($currentFile.FullName)"
        }

        $uploadCount++
    }

    $cleanupCount = 0
    if ($CleanTarget) {
        Write-Host '🧹 Starting cleanup of old files...'
        $preserveList = @()
        if (-not [string]::IsNullOrWhiteSpace($PreservePatterns)) {
            $preserveList = $PreservePatterns -split ', ' | ForEach-Object { $_.Trim() }
            Write-Host "   • Preserve patterns: `e[36m$($preserveList -join ', ')`e[0m"
        }

        try {
            $uploadedFiles = @()
            Get-ChildItem -Path $DeployPath -Recurse -File | ForEach-Object {
                $relativePath = $_.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
                $relativePath = $relativePath -replace '\\', '/'

                if (-not (Test-FileMatchesPatterns -FilePath $relativePath -Patterns $excludeList).Success) {
                    $uploadedFiles += $relativePath
                }
            }

            Write-Host '   • 🔍 Scanning remote server for all files (including subdirectories)...'
            $result = Read-FtpFilesRecursive -BaseUri $ftpUri -Path '' -Credentials $credentials -UsePassive $PassiveMode
            if (-not $result.Success) {
                Write-FtpErrorDetails -ErrorSource $result.Exception -Context 'Listing remote files for cleanup' -AdditionalInfo @{
                    'FTP URI' = $ftpUri
                }
                throw "Failed to list remote files: $($result.Exception.Message)"
            }
            $remoteStructure = $result.Value

            if ($remoteStructure) {
                $existingFiles = $remoteStructure.Files
                $existingDirectories = $remoteStructure.Directories

                Write-Host "   • Found `e[36m$($existingFiles.Count)`e[0m files and `e[36m$($existingDirectories.Count)`e[0m directories on server"

                # Find files to delete (exist on server but not in current deployment)
                $filesToDelete = @()
                foreach ($existingFile in $existingFiles) {
                    if ($uploadedFiles -notcontains $existingFile) {
                        if ((Test-FileMatchesPatterns -FilePath $existingFile -Patterns $preserveList).Success) {
                            Write-Host "   • 🔒 Preserved: `e[32m$existingFile`e[0m (matches preserve pattern)"
                        }
                        else {
                            $filesToDelete += $existingFile
                        }
                    }
                }

                # Delete old files
                foreach ($fileToDelete in $filesToDelete) {
                    $deleteResult = Remove-FtpFile -BaseUri $ftpUri -FileUri $fileToDelete -Credentials $credentials -UsePassive $PassiveMode
                    if (-not $deleteResult.Success) {
                        Write-FtpErrorDetails -ErrorSource $deleteResult.Exception -Context 'File deletion' -AdditionalInfo @{
                            'File path' = $filesToDelete
                        }
                        throw "Failed to delete file: $fileToDelete"
                    }
                    $cleanupCount++
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
                    $deleteResult = Remove-FtpDirectory -BaseUri $ftpUri -DirectoryUri $dirToDelete -Credentials $credentials -UsePassive $PassiveMode
                    if (-not $deleteResult.Success) {
                        Write-FtpErrorDetails -ErrorSource $deleteResult.Exception -Context 'Directory deletion' -AdditionalInfo @{
                            'Directory path' = $dirToDelete
                        }
                        throw "Failed to delete directory: $dirToDelete"
                    }
                    $cleanupCount++
                }

                if ($filesToDelete.Count -eq 0 -and $directoriesToDelete.Count -eq 0) {
                    Write-Host '   • ✅ No old files or directories to cleanup'
                }
            }
            else {
                Write-Host '   • ⚠️ Could not retrieve remote server structure for cleanup'
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
        Write-Host "   • Files skipped (excluded): `e[33m$skippedCount`e[0m"
    }
    if ($EnableDiffUpload -and $differentialSkippedCount -gt 0) {
        Write-Host "   • Files skipped (unchanged): `e[36m$differentialSkippedCount`e[0m"
    }
    if ($cleanupCount -gt 0) {
        Write-Host "   • Files cleaned up: `e[31m$cleanupCount`e[0m"
    }
}
catch {
    Write-Host "❌ `e[31mFTP deployment failed!`e[0m"
    Write-FtpErrorDetails -ErrorSource $_ -Context 'FTP deployment process' -AdditionalInfo @{
        'Deploy Path'  = $DeployPath
        'Server'       = $Server
        'Port'         = $Port
        'Remote Path'  = $RemotePath
        'Passive Mode' = $PassiveMode
        'Clean Target' = $CleanTarget
    }
    exit 1
}
