# MSDeploy Deploy GitHub Action

This reusable GitHub Action deploys a .NET application to IIS using Web Deploy (msdeploy.exe). It supports deploying either a publish directory (content) or a zip archive (package). It also supports advanced scenarios by allowing you to override the msdeploy arguments directly.

## ⚠️ Danger Zone

> [!CAUTION]
> **Automatic Package Path Detection**: This action has automatic fallback logic that may behave unexpectedly:
>
> - When `method: package` is used and the specified `package-path` doesn't exist, the action automatically tries appending `.zip` to the path
> - Example: If you specify `package-path: "myapp"` but `myapp` doesn't exist, it will try `myapp.zip`
> - This can lead to unintended deployments if a zip file exists with the fallback name
> - **Recommendation**: Always specify the exact path including file extension for packages, or implement a confirmation delay

## Inputs

| Name                  | Description                                                                                 | Required                   |
|-----------------------|------------------------------------------------------------------------------|----------------------------|
| method                | Deployment method: `content` (folder) or `package` (zip archive)             | No (defaults to `content`) |
| package-path          | Path to the publish directory or zip archive                                 | No                         |
| site                  | IIS site name on destination server                                          | Yes                        |
| server                | MSDeploy server endpoint (e.g. win6053.site4now.net:8172)                    | Yes                        |
| username              | Username for MSDeploy authentication                                         | Yes                        |
| password              | Password or token for MSDeploy authentication                                | Yes                        |
| msdeploy-args-override| (Advanced) If set, overrides all msdeploy arguments with the provided string | No                         |

## Notes on Artifact Handling & Argument Override

- When using `actions/download-artifact`, the action may extract files directly to the workspace root or to a subdirectory named after the artifact (depending on the version and options used).
- This action has logic to handle both cases:
  - For **directory deployment** (`method: content`), the path can be a folder or omitted to use the workspace root.
  - For **zip deployment** (`method: package`), if the specified path does not include `.zip` extension, the action will try both the provided path and path with `.zip` appended.
- If you set `msdeploy-args-override`, the action will use your provided arguments for msdeploy.exe and ignore all other deployment-related inputs except for `-source:` and `-dest:`.

## Example Usage

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
  PUBLISH_PACKAGE_SOURCE: './publish' # or ./publish.zip
  PUBLISH_PACKAGE: 'publish-package'

jobs:
  build:
    # build the solution ...
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
          # if you want to extract to the workspace root(empty in this example)
          # you can omit this `path` and the `package-path` input in the next step

      # For directory deployment:
      - name: Deploy with MSDeploy (folder)
        uses: AgilianX/AgX.GitHubActions/src/msdeploy@master
        with:
          package-path: ${{ env.PUBLISH_PACKAGE }}
          site: ${{ vars.MSDEPLOY_SITE }} # msdeploySite in .PublishSettings file
          server: ${{ vars.MSDEPLOY_SERVER }} # https://{server}/msdeploy.axd?{site}" from .PublishSettings file
          username: ${{ secrets.MSDEPLOY_USER }}
          password: ${{ secrets.MSDEPLOY_PASSWORD }}

      # For zip package deployment
      - name: Deploy with MSDeploy (zip package)
        uses: AgilianX/AgX.GitHubActions/src/msdeploy@master
        with:
          method: package
          package-path: ${{ env.PUBLISH_PACKAGE }}/publish.zip
          site: ${{ vars.MSDEPLOY_SITE }}
          server: ${{ vars.MSDEPLOY_SERVER }}
          username: ${{ secrets.MSDEPLOY_USER }}
          password: ${{ secrets.MSDEPLOY_PASSWORD }}

```

---

**Related source files:**

- [action.yml](./action.yml)
