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

    [Parameter(Mandatory = $true)]
    [string]$Protocol,

    [Parameter(Mandatory = $false)]
    [bool]$PassiveMode = $true,

    [Parameter(Mandatory = $false)]
    [bool]$VerifySSL = $true,

    [Parameter(Mandatory = $false)]
    [string]$ExcludePatterns = '',

    [Parameter(Mandatory = $false)]
    [bool]$CleanTarget = $false,

    [Parameter(Mandatory = $false)]
    [string]$PreservePatterns = ''
)

Write-Host '🔧 Starting FTP deployment...' -ForegroundColor Green

Write-Host '🔍 Environment Variables:' -ForegroundColor Cyan
Write-Host "   • DEPLOY_PATH: `e[36m$env:DEPLOY_PATH`e[0m"
Write-Host "   • SOURCE_PATH: `e[36m$env:SOURCE_PATH`e[0m"
Write-Host "   • SOURCE_TYPE: `e[36m$env:SOURCE_TYPE`e[0m"
Write-Host "   • FTP_METHOD: `e[36m$env:FTP_METHOD`e[0m"

Write-Host '🔍 Input Parameters:' -ForegroundColor Cyan
Write-Host "   • Server: `e[36m$Server`e[0m"
Write-Host "   • Port: `e[36m$Port`e[0m"
Write-Host "   • Remote Path: `e[36m$RemotePath`e[0m"
Write-Host "   • Protocol: `e[36m$Protocol`e[0m"
Write-Host "   • Passive Mode: `e[36m$PassiveMode`e[0m"
Write-Host "   • Verify SSL: `e[36m$VerifySSL`e[0m"
Write-Host "   • Clean Target: `e[36m$CleanTarget`e[0m"
Write-Host "   • Exclude Patterns: `e[36m$ExcludePatterns`e[0m"
Write-Host "   • Preserve Patterns: `e[36m$PreservePatterns`e[0m"

# Parse exclude patterns
Write-Host '🔄 Processing exclude patterns...'
try {
    $excludeList = @()
    if (-not [string]::IsNullOrWhiteSpace($ExcludePatterns)) {
        $excludeList = $ExcludePatterns -split ',' | ForEach-Object { $_.Trim() }
        Write-Host "   • Exclude patterns parsed: `e[36m$($excludeList -join ', ')`e[0m"
        Write-Host "   • Exclude list count: `e[36m$($excludeList.Count)`e[0m"
    }
    else {
        Write-Host '   • No exclude patterns specified'
    }
}
catch {
    Write-Host "❌ Error parsing exclude patterns: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host '🔄 Defining helper functions...'
try {
    function Test-ExcludeFile {
        param([string]$FilePath, [string[]]$Patterns)
        Write-Host "     • Testing file: `e[33m$FilePath`e[0m against $($Patterns.Count) patterns" -ForegroundColor DarkGray
        if ($Patterns.Count -eq 0) {
            Write-Host '     • No patterns to check, file not excluded' -ForegroundColor DarkGray
            return $false
        }

        foreach ($pattern in $Patterns) {
            Write-Host "     • Checking pattern: `e[33m$pattern`e[0m" -ForegroundColor DarkGray
            if ($FilePath -like $pattern) {
                Write-Host '     • ✅ Pattern matched, file will be excluded' -ForegroundColor DarkGray
                return $true
            }
        }
        Write-Host '     • ❌ No patterns matched, file will be included' -ForegroundColor DarkGray
        return $false
    }
    Write-Host '   • Helper function Test-ExcludeFile defined successfully'
}
catch {
    Write-Host "❌ Error defining helper functions: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host '🔍 Checking FTP method...'
Write-Host "   • FTP_METHOD environment variable: `e[36m$env:FTP_METHOD`e[0m"

if ($env:FTP_METHOD -eq 'WinSCP') {
    Write-Host '🔧 Using WinSCP for FTP operations...' -ForegroundColor Cyan

    try {
        Write-Host '🔄 Creating WinSCP session options...'

        # Create session options
        Write-Host '   • Creating SessionOptions object...'
        $sessionOptions = New-Object WinSCP.SessionOptions -Property @{
            Protocol   = switch ($Protocol) {
                'ftp' {
                    Write-Host "   • Protocol set to: `e[36mFTP`e[0m"
                    [WinSCP.Protocol]::Ftp
                }
                'ftps' {
                    Write-Host "   • Protocol set to: `e[36mFTPS`e[0m"
                    [WinSCP.Protocol]::Ftps
                }
                'sftp' {
                    Write-Host "   • Protocol set to: `e[36mSFTP`e[0m"
                    [WinSCP.Protocol]::Sftp
                }
                default {
                    Write-Host "   • Protocol defaulted to: `e[36mFTP`e[0m"
                    [WinSCP.Protocol]::Ftp
                }
            }
            HostName   = $Server
            PortNumber = $Port
            UserName   = $Username
            Password   = $Password
        }
        Write-Host '🔄 SessionOptions object created successfully'
        Write-Host "   • Hostname: `e[36m$($sessionOptions.HostName)`e[0m"
        Write-Host "   • Port: `e[36m$($sessionOptions.PortNumber)`e[0m"
        Write-Host "   • Username: `e[36m$($sessionOptions.UserName)`e[0m"
        Write-Host "   • Protocol: `e[36m$($sessionOptions.Protocol)`e[0m"

        if ($Protocol -eq 'ftps') {
            Write-Host '🔄 Configuring FTPS settings...'
            $sessionOptions.FtpSecure = [WinSCP.FtpSecure]::ExplicitSsl
            Write-Host "   • FtpSecure set to: `e[36mExplicitSsl`e[0m"

            if (-not $VerifySSL) {
                $sessionOptions.GiveUpSecurityAndAcceptAnySslCertificate = $true
                Write-Host "   • SSL certificate verification: `e[33mDisabled`e[0m"
            }
            else {
                Write-Host "   • SSL certificate verification: `e[32mEnabled`e[0m"
            }
        }

        # Create session and connect
        Write-Host '🔄 Creating WinSCP session...'
        $session = New-Object WinSCP.Session
        Write-Host '   • WinSCP Session object created'

        Write-Host '🔄 Attempting to open connection...'
        $session.Open($sessionOptions)
        Write-Host '   • ✅ Connected to FTP server successfully'

        # Test connection
        Write-Host '🔄 Testing connection...'
        $sessionInfo = $session.SessionInfo
        Write-Host "   • Session protocol name: `e[36m$($sessionInfo.ProtocolName)`e[0m"
        Write-Host "   • Remote directory: `e[36m$($session.HomePath)`e[0m"

        # Ensure remote directory exists
        Write-Host '🔄 Verifying remote directory...'
        if (-not [string]::IsNullOrWhiteSpace($RemotePath) -and $RemotePath -ne '/') {
            try {
                Write-Host "   • Attempting to create/verify directory: `e[36m$RemotePath`e[0m"
                $session.CreateDirectory($RemotePath)
                Write-Host "   • ✅ Created/verified remote directory: `e[36m$RemotePath`e[0m"
            }
            catch {
                Write-Host "   • ⚠️  Directory operation result: $($_.Exception.Message)" -ForegroundColor Yellow                        # Check if directory already exists by trying to list it
                try {
                    $null = $session.ListDirectory($RemotePath)
                    Write-Host '   • ✅ Directory exists and is accessible'
                }
                catch {
                    Write-Host "   • ❌ Directory creation/verification failed: $($_.Exception.Message)" -ForegroundColor Red
                    if ($_.Exception.Message -notlike '*already exists*' -and $_.Exception.Message -notlike '*exist*') {
                        throw
                    }
                }
            }
        }
        else {
            Write-Host '   • Using root directory or default path'
        }

        # Check source directory
        Write-Host '🔄 Checking source directory...'
        Write-Host "   • Deploy path: `e[36m$DeployPath`e[0m"
        if (-not (Test-Path -Path $DeployPath)) {
            Write-Host '   • ❌ Deploy path does not exist!' -ForegroundColor Red
            throw "Deploy path not found: $DeployPath"
        }

        $sourceFiles = Get-ChildItem -Path $DeployPath -Recurse -File
        Write-Host "   • Found $($sourceFiles.Count) files to process"

        # Upload files
        Write-Host '🔄 Starting file upload process...'
        $uploadCount = 0
        $skippedCount = 0

        $sourceFiles | ForEach-Object {
            try {
                $currentFile = $_
                Write-Host "🔄 Processing file: `e[36m$($currentFile.Name)`e[0m" -ForegroundColor DarkGray

                $relativePath = $currentFile.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
                $relativePath = $relativePath -replace '\\', '/'
                Write-Host "   • Relative path: `e[33m$relativePath`e[0m" -ForegroundColor DarkGray

                if (Test-ExcludeFile -FilePath $relativePath -Patterns $excludeList) {
                    Write-Host "   • ⏭️  Skipped: `e[33m$relativePath`e[0m (excluded)" -ForegroundColor Yellow
                    $skippedCount++
                    return
                }

                $remoteFilePath = if ($RemotePath -eq '/' -or [string]::IsNullOrWhiteSpace($RemotePath)) {
                    "/$relativePath"
                }
                else {
                    "$RemotePath/$relativePath"
                }
                $remoteFilePath = $remoteFilePath -replace '/+', '/'
                Write-Host "   • Remote file path: `e[33m$remoteFilePath`e[0m" -ForegroundColor DarkGray

                # Ensure remote directory exists for this file
                $remoteDir = Split-Path $remoteFilePath -Parent
                if ($remoteDir -and $remoteDir -ne '/' -and $remoteDir -ne '') {
                    try {
                        Write-Host "   • Ensuring remote directory exists: `e[33m$remoteDir`e[0m" -ForegroundColor DarkGray
                        $session.CreateDirectory($remoteDir)
                    }
                    catch {
                        # Ignore if directory already exists
                        Write-Host "   • Directory operation: $($_.Exception.Message)" -ForegroundColor DarkGray
                    }
                }

                Write-Host "   • Uploading: `e[32m$($currentFile.FullName)`e[0m → `e[32m$remoteFilePath`e[0m" -ForegroundColor Green
                $session.PutFiles($currentFile.FullName, $remoteFilePath, $false, $null)
                Write-Host "   • ✅ Uploaded: `e[32m$relativePath`e[0m"
                $uploadCount++
            }
            catch {
                Write-Host "❌ Error uploading file $($currentFile.Name): $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "❌ Error details: $($_.Exception.GetType().FullName)" -ForegroundColor Red
                Write-Host "❌ Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
                throw
            }
        }

        # Cleanup old files if requested
        $cleanupCount = 0
        if ($CleanTarget) {
            Write-Host '🧹 Starting cleanup of old files...' -ForegroundColor Cyan

            # Parse preserve patterns
            $preserveList = @()
            if (-not [string]::IsNullOrWhiteSpace($PreservePatterns)) {
                $preserveList = $PreservePatterns -split ',' | ForEach-Object { $_.Trim() }
                Write-Host "   • Preserve patterns: `e[36m$($preserveList -join ', ')`e[0m"
            }

            function Test-PreserveFile {
                param([string]$FilePath, [string[]]$Patterns)
                if ($Patterns.Count -eq 0) { return $false }

                foreach ($pattern in $Patterns) {
                    if ($FilePath -like $pattern) {
                        return $true
                    }
                }
                return $false
            }

            try {
                # Get list of uploaded files (our new deployment)
                $uploadedFiles = @()
                Get-ChildItem -Path $DeployPath -Recurse -File | ForEach-Object {
                    $relativePath = $_.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
                    $relativePath = $relativePath -replace '\\', '/'

                    if (-not (Test-ExcludeFile -FilePath $relativePath -Patterns $excludeList)) {
                        $uploadedFiles += $relativePath
                    }
                }

                # Get list of existing files on server
                $remoteDirectory = if ([string]::IsNullOrWhiteSpace($RemotePath) -or $RemotePath -eq '/') { '/' } else { $RemotePath }
                $existingFiles = @()

                function Get-RemoteFiles {
                    param([string]$Directory, [string]$BasePath = '')

                    try {
                        $items = $session.ListDirectory($Directory)
                        foreach ($item in $items.Files) {
                            if ($item.Name -eq '.' -or $item.Name -eq '..') { continue }

                            $itemPath = if ($BasePath -eq '') { $item.Name } else { "$BasePath/$($item.Name)" }

                            if ($item.IsDirectory) {
                                $subDirPath = if ($Directory -eq '/') { "/$($item.Name)" } else { "$Directory/$($item.Name)" }
                                Get-RemoteFiles -Directory $subDirPath -BasePath $itemPath
                            }
                            else {
                                $existingFiles += $itemPath
                            }
                        }
                    }
                    catch {
                        Write-Host "   • ⚠️  Could not list directory $Directory : $($_.Exception.Message)"
                    }
                }

                Get-RemoteFiles -Directory $remoteDirectory

                Write-Host "   • Found $($existingFiles.Count) existing files on server"
                Write-Host "   • Current deployment contains $($uploadedFiles.Count) files"

                # Find files to delete (exist on server but not in current deployment)
                $filesToDelete = @()
                foreach ($existingFile in $existingFiles) {
                    if ($uploadedFiles -notcontains $existingFile) {
                        if (Test-PreserveFile -FilePath $existingFile -Patterns $preserveList) {
                            Write-Host "   • 🔒 Preserved: `e[33m$existingFile`e[0m (matches preserve pattern)"
                        }
                        else {
                            $filesToDelete += $existingFile
                        }
                    }
                }

                # Delete old files
                foreach ($fileToDelete in $filesToDelete) {
                    $remoteFilePath = if ($remoteDirectory -eq '/') { "/$fileToDelete" } else { "$remoteDirectory/$fileToDelete" }
                    $remoteFilePath = $remoteFilePath -replace '/+', '/'

                    try {
                        $session.RemoveFiles($remoteFilePath)
                        Write-Host "   • 🗑️  Deleted: `e[31m$fileToDelete`e[0m"
                        $cleanupCount++
                    }
                    catch {
                        Write-Host "   • ⚠️  Could not delete `e[33m$fileToDelete`e[0m: $($_.Exception.Message)"
                    }
                }

                if ($filesToDelete.Count -eq 0) {
                    Write-Host '   • ✅ No old files to cleanup'
                }

            }
            catch {
                Write-Host "   • ⚠️  Cleanup failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host '   • 📤 Deployment was successful, but cleanup encountered issues'
            }
        }

        $session.Close()
        Write-Host '🎉 FTP deployment completed successfully!' -ForegroundColor Green
        Write-Host "   • Files uploaded: `e[32m$uploadCount`e[0m"
        if ($skippedCount -gt 0) {
            Write-Host "   • Files skipped: `e[33m$skippedCount`e[0m"
        }
        if ($cleanupCount -gt 0) {
            Write-Host "   • Files cleaned up: `e[31m$cleanupCount`e[0m"
        }
    }
    catch {
        Write-Host "❌ FTP deployment failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "❌ Error type: $($_.Exception.GetType().FullName)" -ForegroundColor Red
        Write-Host "❌ Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
        Write-Host "❌ Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        if ($session -and $session.Opened) {
            Write-Host '🔄 Disposing WinSCP session...' -ForegroundColor Yellow
            $session.Dispose()
        }
        exit 1
    }
}
else {
    Write-Host '🔧 Using native .NET FTP client...' -ForegroundColor Cyan
    Write-Host '⚠️  Note: Native client has limited protocol support (FTP only)' -ForegroundColor Yellow

    Write-Host '🔄 Validating protocol for native client...'
    if ($Protocol -ne 'ftp') {
        Write-Host '❌ Native .NET client only supports FTP protocol. Please install WinSCP module for FTPS/SFTP support.' -ForegroundColor Red
        Write-Host "   • Current protocol: `e[36m$Protocol`e[0m" -ForegroundColor Red
        exit 1
    }

    try {
        Write-Host '🔄 Setting up native .NET FTP connection...'

        # Simple FTP upload using .NET FtpWebRequest
        $encodedPath = [System.Uri]::EscapeUriString($RemotePath)
        $ftpUri = "ftp://${Server}:${Port}${encodedPath}"
        Write-Host "   • Connecting to: `e[36m$ftpUri`e[0m"
        Write-Host "   • Encoded remote path: `e[36m$encodedPath`e[0m"

        # Check source directory
        Write-Host '🔄 Checking source directory...'
        Write-Host "   • Deploy path: `e[36m$DeployPath`e[0m"
        if (-not (Test-Path -Path $DeployPath)) {
            Write-Host '   • ❌ Deploy path does not exist!' -ForegroundColor Red
            throw "Deploy path not found: $DeployPath"
        }

        $sourceFiles = Get-ChildItem -Path $DeployPath -Recurse -File
        Write-Host "   • Found $($sourceFiles.Count) files to process"

        $uploadCount = 0
        $skippedCount = 0

        $sourceFiles | ForEach-Object {
            try {
                $currentFile = $_
                Write-Host "🔄 Processing file: `e[36m$($currentFile.Name)`e[0m" -ForegroundColor DarkGray

                $relativePath = $currentFile.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
                $relativePath = $relativePath -replace '\\', '/'
                Write-Host "   • Relative path: `e[33m$relativePath`e[0m" -ForegroundColor DarkGray

                if (Test-ExcludeFile -FilePath $relativePath -Patterns $excludeList) {
                    Write-Host "   • ⏭️  Skipped: `e[33m$relativePath`e[0m (excluded)" -ForegroundColor Yellow
                    $skippedCount++
                    return
                }

                $remoteFileUri = "$ftpUri/$relativePath" -replace '/+', '/'
                Write-Host "   • Remote URI: `e[33m$remoteFileUri`e[0m" -ForegroundColor DarkGray

                Write-Host '   • Creating FTP request...' -ForegroundColor DarkGray
                $request = [System.Net.FtpWebRequest]::Create($remoteFileUri)
                $request.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
                $request.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
                $request.UsePassive = $PassiveMode
                Write-Host "   • FTP request configured (Method: UploadFile, UsePassive: $PassiveMode)" -ForegroundColor DarkGray

                Write-Host '   • Reading file content...' -ForegroundColor DarkGray
                $fileContent = [System.IO.File]::ReadAllBytes($currentFile.FullName)
                $request.ContentLength = $fileContent.Length
                Write-Host "   • File size: `e[33m$($fileContent.Length) bytes`e[0m" -ForegroundColor DarkGray

                Write-Host '   • Uploading file content...' -ForegroundColor DarkGray
                $requestStream = $request.GetRequestStream()
                $requestStream.Write($fileContent, 0, $fileContent.Length)
                $requestStream.Close()

                Write-Host '   • Getting response...' -ForegroundColor DarkGray
                $response = $request.GetResponse()
                Write-Host "   • Response status: `e[33m$($response.StatusDescription)`e[0m" -ForegroundColor DarkGray
                $response.Close()
                Write-Host "   • ✅ Uploaded: `e[32m$relativePath`e[0m"
                $uploadCount++

            }
            catch {
                Write-Host "❌ Error uploading file $($currentFile.Name): $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "❌ Error details: $($_.Exception.GetType().FullName)" -ForegroundColor Red
                Write-Host "❌ Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
                throw
            }
        }

        # Cleanup old files if requested (Note: Limited functionality with native client)
        $cleanupCount = 0
        if ($CleanTarget) {
            Write-Host '🧹 Starting cleanup of old files...' -ForegroundColor Cyan
            Write-Host '⚠️  Note: Cleanup with native .NET client has limited functionality' -ForegroundColor Yellow

            # Parse preserve patterns
            $preserveList = @()
            if (-not [string]::IsNullOrWhiteSpace($PreservePatterns)) {
                $preserveList = $PreservePatterns -split ',' | ForEach-Object { $_.Trim() }
                Write-Host "   • Preserve patterns: `e[36m$($preserveList -join ', ')`e[0m"
            }

            function Test-PreserveFile {
                param([string]$FilePath, [string[]]$Patterns)
                if ($Patterns.Count -eq 0) { return $false }

                foreach ($pattern in $Patterns) {
                    if ($FilePath -like $pattern) {
                        return $true
                    }
                }
                return $false
            }

            try {
                # Get list of uploaded files (our new deployment)
                $uploadedFiles = @()
                Get-ChildItem -Path $DeployPath -Recurse -File | ForEach-Object {
                    $relativePath = $_.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
                    $relativePath = $relativePath -replace '\\', '/'

                    if (-not (Test-ExcludeFile -FilePath $relativePath -Patterns $excludeList)) {
                        $uploadedFiles += $relativePath
                    }
                }

                # Try to list existing files on server (limited support)
                try {
                    $listRequest = [System.Net.FtpWebRequest]::Create($ftpUri)
                    $listRequest.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
                    $listRequest.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
                    $listRequest.UsePassive = $PassiveMode

                    $listResponse = $listRequest.GetResponse()
                    $listStream = $listResponse.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($listStream)
                    $directoryListing = $reader.ReadToEnd()
                    $reader.Close()
                    $listResponse.Close()

                    $existingFiles = @()
                    $directoryListing -split "`n" | ForEach-Object {
                        $line = $_.Trim()
                        if ($line -and -not $line.StartsWith('d')) {
                            # Simple parsing - get filename (last part after spaces)
                            $parts = $line -split '\s+'
                            if ($parts.Length -gt 0) {
                                $fileName = $parts[-1]
                                if ($fileName -and $fileName -ne '.' -and $fileName -ne '..') {
                                    $existingFiles += $fileName
                                }
                            }
                        }
                    }

                    Write-Host "   • Found $($existingFiles.Count) existing files on server"
                    Write-Host '   • ⚠️  Note: Only root-level files can be cleaned with native client'

                    # Find files to delete (exist on server but not in current deployment)
                    $filesToDelete = @()
                    foreach ($existingFile in $existingFiles) {
                        if ($uploadedFiles -notcontains $existingFile) {
                            if (Test-PreserveFile -FilePath $existingFile -Patterns $preserveList) {
                                Write-Host "   • 🔒 Preserved: `e[33m$existingFile`e[0m (matches preserve pattern)"
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
                            $deleteRequest = [System.Net.FtpWebRequest]::Create($deleteUri)
                            $deleteRequest.Method = [System.Net.WebRequestMethods+Ftp]::DeleteFile
                            $deleteRequest.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
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

                    if ($filesToDelete.Count -eq 0) {
                        Write-Host '   • ✅ No old files to cleanup'
                    }

                }
                catch {
                    Write-Host "   • ⚠️  Could not list server files for cleanup: $($_.Exception.Message)"
                    Write-Host '   • 💡 Consider using WinSCP module for better cleanup support'
                }

            }
            catch {
                Write-Host "   • ⚠️  Cleanup failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host '   • 📤 Deployment was successful, but cleanup encountered issues'
            }
        }

        Write-Host '🎉 FTP deployment completed successfully!' -ForegroundColor Green
        Write-Host "   • Files uploaded: `e[32m$uploadCount`e[0m"
        if ($skippedCount -gt 0) {
            Write-Host "   • Files skipped: `e[33m$skippedCount`e[0m"
        }
        if ($cleanupCount -gt 0) {
            Write-Host "   • Files cleaned up: `e[31m$cleanupCount`e[0m"
        }
    }
    catch {
        Write-Host "❌ FTP deployment failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "❌ Error type: $($_.Exception.GetType().FullName)" -ForegroundColor Red
        Write-Host "❌ Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
        Write-Host "❌ Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        exit 1
    }
}
