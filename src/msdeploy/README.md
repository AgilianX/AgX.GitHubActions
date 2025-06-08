# MSDeploy Deploy GitHub Action

This reusable GitHub Action deploys a .NET application to IIS using Web Deploy (msdeploy.exe). It supports deploying either a publish directory (content) or a zip archive (package).

## Inputs

| Name     | Description                                                      | Required                   |
|----------|------------------------------------------------------------------|----------------------------|
| method   | Deployment method: `content` (folder) or `package` (zip archive) | No (defaults to `content`) |
| package  | Path to the publish directory or zip archive                     | Yes                        |
| site     | IIS site name on destination server                              | Yes                        |
| server   | MSDeploy server endpoint                                         | Yes                        |
| username | Username for MSDeploy authentication                             | Yes                        |
| password | Password or token for MSDeploy authentication                    | Yes                        |

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

jobs:
  build:
    # build the solution ...
    - name: Upload artifact for deployment job
      uses: actions/upload-artifact@v4
      with:
        name: publish-package
        path: .publish/ # or ./publish.zip
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
          name: publish-package

      # For directory deployment:
      - name: Deploy with MSDeploy (folder)
        uses: AgilianX/AgX.GitHubActions/src/msdeploy@master
        with:
          package: ./publish-package/ # Path to the publish directory
          site: ${{ env.MSDEPLOY_SITE }} # msdeploySite in .PublishSettings file
          server: ${{ secrets.MSDEPLOY_SERVER }} # https://{server}/msdeploy.axd?{site}" from .PublishSettings file
          username: ${{ secrets.MSDEPLOY_USER }}
          password: ${{ secrets.MSDEPLOY_PASSWORD }}

      # For zip package deployment
      - name: Deploy with MSDeploy (zip package)
        uses: AgilianX/AgX.GitHubActions/src/msdeploy@master
        with:
          method: package
          package: ./publish-package/publish.zip
          site: ${{ secrets.MSDEPLOY_SITE }} # msdeploySite in .PublishSettings file
          server: ${{ secrets.MSDEPLOY_SERVER }} # https://{server}/msdeploy.axd?{site}" from .PublishSettings file
          username: ${{ secrets.MSDEPLOY_USER }}
          password: ${{ secrets.MSDEPLOY_PASSWORD }}

```

---

**Related source files:**

- [action.yml](./action.yml)
