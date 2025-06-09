[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Password received as string from GitHub Actions secrets')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is used intentionally for GitHub Actions console output and logging')]
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
    [string]$PreservePatterns = ''
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

function New-FtpDirectory {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'ShouldProcess not needed for internal FTP operations in deployment context')]
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
        return $true
    }
    catch {
        # Directory might already exist, which is fine
        if ($_.Exception.Message -like '*550*') {
            return $true  # Directory already exists
        }
        Write-Host "   • ⚠️  Could not create directory `e[33m$DirectoryUri`e[0m: $($_.Exception.Message)"
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
    }

    return @{
        Files       = $files
        Directories = $directories
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
    $createdDirectories = @()

    $sourceFiles | ForEach-Object {
        try {
            $currentFile = $_
            $relativePath = $currentFile.FullName.Substring($DeployPath.Length).TrimStart('\', '/')
            $relativePath = $relativePath -replace '\\', '/'
            if (Test-ExcludeFile -FilePath $relativePath -Patterns $excludeList) {
                $skippedCount++
                return
            }

            # Ensure parent directories exist
            $pathParts = $relativePath -split '/'
            if ($pathParts.Length -gt 1) {
                $currentPath = ''
                for ($i = 0; $i -lt ($pathParts.Length - 1); $i++) {
                    $currentPath = if ($currentPath -eq '') { $pathParts[$i] } else { "$currentPath/$pathParts[$i]" }
                    $dirUri = "$ftpUri/$currentPath" -replace '/+', '/'

                    if ($createdDirectories -notcontains $currentPath) {
                        $null = New-FtpDirectory -DirectoryUri $dirUri -Credentials $credentials -UsePassive $PassiveMode
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
            try {
                $requestStream = $request.GetRequestStream()
            }
            catch {
                if (-not ($_.Exception.Message -like '*550*')) {
                    # File might not exist yet
                    throw $_  # Re-throw other exceptions
                }
            }
            $requestStream.Write($fileContent, 0, $fileContent.Length)
            $requestStream.Close()
            $response = $request.GetResponse()
            $response.Close()
            $uploadCount++
        }
        catch {
            Write-Host "❌ `e[31mError uploading file `e[36m$($currentFile.Name)`e[31m:`e[0m $($_.Exception.Message)"
            Write-Host "❌ `e[31mRemote Path:`e[36mftp://$remoteFileUri`e[0m"
            Write-Host "❌ `e[31mError details:`e[0m $($_.Exception.GetType().FullName)"
            Write-Host "❌ `e[31mStack trace:`e[0m $($_.ScriptStackTrace)"
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
    Write-Host "❌ `e[31mFTP deployment failed:`e[0m $($_.Exception.Message)"
    Write-Host "❌ `e[31mError type:`e[0m $($_.Exception.GetType().FullName)"
    Write-Host "❌ `e[31mStack trace:`e[0m $($_.ScriptStackTrace)"
    Write-Host "❌ `e[31mInner exception:`e[0m $($_.Exception.InnerException.Message)"
    exit 1
}
