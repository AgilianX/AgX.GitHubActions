git submodule update --init --remote .agx
& .\.agx\tools\init.ps1

# Get owner from git remote
$remoteUrl = git remote get-url origin 2>$null
if ($remoteUrl -match '[:\/]([^\/:]+)\/([^\/]+?)(\.git)?$') {
    $owner = $matches[1]
    $repoName = $matches[2]
}
else {
    $owner = ''
    $repoName = Split-Path -Leaf $PSScriptRoot
}

$templateWorkspace = Join-Path $PSScriptRoot 'AgX.RepositoryTemplate.code-workspace'
if (Test-Path $templateWorkspace) {
    Rename-Item -Path $templateWorkspace -NewName ("$repoName.code-workspace")
}

$templateAiRepoInfo = Join-Path $PSScriptRoot '.github/Repository.AgX.RepositoryTemplate.md'
if (Test-Path $templateAiRepoInfo) {
    $newRepoInfo = "Repository.$repoName.md"
    Rename-Item -Path $templateAiRepoInfo -NewName $newRepoInfo

    $repoInfoContent = @"
# Repository Information

**Owner:** $owner
**Repository name:** ``$repoName``
**Goal:**
"@
    Set-Content -Path (Join-Path $PSScriptRoot ".github/$newRepoInfo") -Value $repoInfoContent
}

$readMe = Join-Path $PSScriptRoot 'README.md'
Write-Host "`n📄 Please read the $readMe file." -ForegroundColor Magenta
