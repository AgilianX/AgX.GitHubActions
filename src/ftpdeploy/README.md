# FTP Deploy GitHub Action

This reusable GitHub Action deploys files to a server using FTP protocol. It supports deploying either a publish directory (content) or a zip archive (package), with flexible options for FTP configurations.

## ⚠️ Danger Zone

> [!CAUTION]
> **Automatic Package Path Detection**: This action has automatic fallback logic that may behave unexpectedly:
>
> - When `method: package` is used and the specified `package-path` doesn't exist, the action automatically tries appending `.zip` to the path
> - Example: If you specify `package-path: "myapp"` but `myapp` doesn't exist, it will try `myapp.zip`
> - This can lead to unintended deployments if a zip file exists with the fallback name
> - **Recommendation**: Always specify the exact path including file extension for packages, or implement a confirmation delay

## Inputs

| Name                | Description                                                                                   | Required                   |
|---------------------|-----------------------------------------------------------------------------------------------|----------------------------|
| method              | Deployment method: `content` (folder) or `package` (zip archive)                             | No (defaults to `content`) |
| package-path        | Path to the publish directory or zip archive                                                 | No                         |
| server              | FTP server hostname or URL (e.g., ftp.mysite.com)                                           | Yes                        |
| port                | FTP server port                                                                               | No (defaults to 21)        |
| username            | Username for FTP authentication                                                               | Yes                        |
| password            | Password for FTP authentication                                                               | Yes                        |
| remote-path         | Remote directory path on FTP server (e.g., /public_html, /wwwroot)                          | No (defaults to "/")       |
| passive-mode        | Use passive mode for FTP connections                                                         | No (defaults to `true`)    |
| exclude-patterns    | File patterns to exclude from upload (comma-separated, e.g., '*.log,temp/*')                | No                         |
| clean-target        | Clean up old files on server that are not part of the new deployment                        | No (defaults to `false`)   |
| preserve-patterns   | File patterns to preserve during cleanup (comma-separated, e.g., '*.db,logs/*,config.json') | No                         |
| disable-connectivity-tests | Disable FTP connectivity tests (directory and file creation). Use with caution!        | No (defaults to `false`)   |

## Implementation

> [!NOTE]
> This action uses the native .NET FTP client (`FtpWebRequest`) to provide reliable FTP file transfer capabilities.

The implementation includes:

- **FTP Protocol**: Standard File Transfer Protocol support
- **Directory Management**: Automatic creation of remote directories as needed
- **File Exclusions**: Pattern-based file filtering during upload
- **Cleanup Functionality**: Comprehensive cleanup of old files with recursive directory support
- **Error Handling**: Structured error handling with Result pattern for consistent operation success/failure tracking
- **Connectivity Testing**: Built-in temporary file/directory testing to validate server access and permissions

## FTP Connectivity Testing

The action includes built-in FTP connectivity testing to ensure the target server and paths are accessible before attempting deployment:

### How It Works

The connectivity test automatically performs the following operations:

1. **Read Test**: Attempts to list the contents of the target remote directory
2. **Directory Creation Test**: Creates a temporary directory (`agx-ftp-test-temp`) and immediately removes it
3. **File Upload Test**: Creates a temporary test file (`agx-ftp-test.tmp`) and immediately removes it

> [!NOTE]
> **Automatic Testing**: The action uses a standardized temporary file/directory approach to validate connectivity, permissions, and write access to the target path.

### Default Behavior

By default, connectivity testing is enabled and uses temporary resources that are automatically cleaned up:

- **Temporary Directory**: `agx-ftp-test-temp/` (relative to `remote-path`)
- **Temporary File**: `agx-ftp-test.tmp` (relative to `remote-path`)

### Disabling Tests

> [!TIP]
> You can disable connectivity tests if needed:

```yaml
- name: Deploy with FTP (disable tests)
  uses: AgilianX/AgX.GitHubActions/src/ftpdeploy@master
  with:
    ... # other parameters
    disable-connectivity-tests: true
```

## Notes on Artifact Handling

- When using `actions/download-artifact`, the action may extract files directly to the workspace root or to a subdirectory named after the artifact (depending on the version and options used).
- This action has logic to handle both cases:
  - For **directory deployment** (`method: content`), the path can be a folder or omitted to use the workspace root.
  - For **zip deployment** (`method: package`), if the specified path does not include `.zip` extension, the action will try both the provided path and path with `.zip` appended.
- Zip packages are automatically extracted to a temporary directory before FTP upload.

## Cleanup Functionality

The action includes optional cleanup functionality to remove old files from the server that are not part of the new deployment:

- **`clean-target: true`** - Enables cleanup of old files after successful upload
- **`preserve-patterns`** - Protects specific files/patterns from deletion during cleanup

### Cleanup Behavior

> [!Warning]
> When `clean-target` is enabled, the action will:

1. **Upload all new files** to the server
2. **List existing files** on the remote directory
3. **Compare** uploaded files with existing files
4. **Delete old files** that are not in the new deployment
5. **Preserve files** that match the `preserve-patterns`

### Preserve Patterns Examples

```yaml
preserve-patterns: "*.db,logs/*,config.json,uploads/**"
```

- `*.db` - Preserves all database files (e.g., SQLite databases)
- `logs/*` - Preserves all files in the logs directory
- `config.json` - Preserves a specific configuration file
- `uploads/**` - Preserves entire uploads directory and subdirectories

### Important Notes

- **Full recursive cleanup**: Complete cleanup support with subdirectories and nested folder structures
- **Safety**: Cleanup only runs after successful upload
- **Error handling**: Upload succeeds even if cleanup fails

## Security Considerations

- Always use secrets for sensitive information like passwords and usernames
- Use passive mode when possible to avoid firewall issues
- Consider using exclude patterns to prevent uploading sensitive files
- Regularly rotate FTP credentials
- Use strong passwords for FTP authentication

## Example Usage

### Basic FTP Upload

```yaml
on:
  workflow_dispatch:
    inputs:
      TARGET_ENVIRONMENT:
        type: choice
        description: "Target environment"
        options:
          - Staging
          - Production
        default: Staging
        required: true

env:
  PUBLISH_PACKAGE_SOURCE: './publish'
  PUBLISH_PACKAGE: 'publish-package'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # ... build steps ...

      - name: Upload artifact for deployment job
        uses: actions/upload-artifact@v4
        with:
          name: ${{ env.PUBLISH_PACKAGE }}
          path: ${{ env.PUBLISH_PACKAGE_SOURCE }}
          retention-days: 1

  deploy:
    runs-on: windows-latest
    needs: build
    environment:
      name: ${{ github.event.inputs.TARGET_ENVIRONMENT }}
      url: ${{ vars.SITE_URL }}

    steps:
      - name: Download publish artifact
        uses: actions/download-artifact@v4
        with:
          name: ${{ env.PUBLISH_PACKAGE }}
          path: ${{ env.PUBLISH_PACKAGE }}

      # For directory deployment with FTP:
      - name: Deploy with FTP (directory)
        uses: AgilianX/AgX.GitHubActions/src/ftpdeploy@master
        with:
          package-path: ${{ env.PUBLISH_PACKAGE }}
          server: ${{ secrets.FTP_SERVER }}
          username: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          remote-path: "/mysite"
```

### Zip Package Deployment

```yaml
      - name: Deploy with FTP (zip package)
        uses: AgilianX/AgX.GitHubActions/src/ftpdeploy@master
        with:
          method: package
          package-path: ${{ env.PUBLISH_PACKAGE }}/publish.zip
          server: ${{ secrets.FTP_SERVER }}
          username: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          remote-path: "/mysite"
```

### FTP Upload with Full Cleanup

```yaml
      - name: Deploy with FTP (full clean deployment)
        uses: AgilianX/AgX.GitHubActions/src/ftpdeploy@master
        with:
          method: content
          package-path: ${{ env.PUBLISH_PACKAGE }}
          server: ${{ secrets.FTP_SERVER }}
          username: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          remote-path: "/mysite"
          clean-target: true
          # No preserve-patterns = clean everything not in deployment
```

### Example with sqlite Database Preservation

```yaml
      - name: Deploy with FTP (preserve SQLite databases)
        uses: AgilianX/AgX.GitHubActions/src/ftpdeploy@master
        with:
          method: content
          package-path: ${{ env.PUBLISH_PACKAGE }}
          server: ${{ secrets.FTP_SERVER }}
          username: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          remote-path: "/mysite"
          clean-target: true
          preserve-patterns: "*.db,*.sqlite,*.sqlite3"
```

## Site-Specific Examples

### Deploy to SmarterASP.NET

```yaml
      - name: FTP Deploy to SmarterASP.NET
        uses: AgilianX/AgX.GitHubActions/src/ftpdeploy@master
        with:
          server: ${{ secrets.FTP_SERVER }}
          username: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          clean-target: true
          preserve-patterns: "*.db,*.sqlite,*.sqlite3,logs/*" # preserve sqlite and logs
```

## Advanced Configuration

### Environment Variables Setup

For multiple environments, consider setting up environment-specific variables:

```yaml
# In repository settings > Environments > [Environment Name] > Variables
vars:
  FTP_SERVER: "myhost.com"
  SITE_URL: "https://staging.mysite.com"
  FTP_REMOTE_PATH: "/mysite"
```

> [!TIP]
> If all environments use the same server, consider putting these in repository variables

---

```yaml
# In repository settings > Environments > [Environment Name] > Secrets
secrets:
  FTP_USERNAME: "secure_username"
  FTP_PASSWORD: "secure_password"
```

### Troubleshooting

- **Connection Issues**: Check server, port, and passive mode settings
- **Authentication Failures**: Verify username and password in secrets
- **File Upload Failures**: Check remote-path permissions and ensure directory exists
- **550 File/Directory Not Found**: The action will attempt to create missing directories automatically. If this fails, check FTP user permissions for directory creation
- **Connectivity Test Failures**: The action uses built-in temporary file/directory testing. If tests fail, verify FTP user has read, write, and directory creation permissions on the target path
- **Large File Issues**: FTP may have timeout issues with very large files

---

**Related source files:**

- [action.yml](./action.yml)
- [Execute-FtpDeployment.ps1](./Execute-FtpDeployment.ps1)
