# ============================================
# Local Folders ↔ GitHub Repo Manager
# - Creates repos for new folders
# - Offers rename when 1:1 rename is detected
# - Offers archive for repos with no local folder
# Author: Wayne Freestun
# ============================================

# --- USER SETTINGS ---
$GitHubUser = "twodogzz"
$Token      = $env:GITHUB_PAT
$BasePath   = "E:\SoftwareProjects"

# --- EXCLUSIONS (non-project items) ---
$Excluded = @(
    "FileList.txt",
    "MasterProjectList.rtf",
    "SoftwareDevelopmentPlan.rtf"
)

# --- HELPER: GitHub API call ---
function Invoke-GitHubApi {
    param(
        [string]$Method,
        [string]$Uri,
        $Body = $null
    )

    $Headers = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = $GitHubUser
    }

    if ($Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json)
    } else {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
    }
}

# --- 1. Get local project folders ---
$LocalProjects = Get-ChildItem -Path $BasePath -Directory |
                 Where-Object { $Excluded -notcontains $_.Name } |
                 Select-Object -ExpandProperty Name

Write-Host "Local project folders found: $($LocalProjects -join ', ')" -ForegroundColor Yellow

# --- 2. Get GitHub repos for this user ---
$Repos = @()
$page  = 1
do {
    $Uri   = "https://api.github.com/user/repos?per_page=100&page=$page"
    $batch = Invoke-GitHubApi -Method GET -Uri $Uri
    $Repos += $batch
    $page++
} while ($batch.Count -gt 0)

$RemoteProjects = $Repos | Where-Object { $_.owner.login -eq $GitHubUser } |
                  Select-Object -ExpandProperty name

Write-Host "GitHub repos found: $($RemoteProjects -join ', ')" -ForegroundColor Yellow

# --- 3. Compare sets ---
$LocalSet  = [System.Collections.Generic.HashSet[string]]::new()
$RemoteSet = [System.Collections.Generic.HashSet[string]]::new()

$LocalProjects  | ForEach-Object { [void]$LocalSet.Add($_) }
$RemoteProjects | ForEach-Object { [void]$RemoteSet.Add($_) }

$MissingRemote = $LocalProjects  | Where-Object { -not $RemoteSet.Contains($_) }
$OrphanRemote  = $RemoteProjects | Where-Object { -not $LocalSet.Contains($_) }

Write-Host "`nLocal without repo (to create): $($MissingRemote -join ', ')" -ForegroundColor Cyan
Write-Host "Repos without local folder (candidates to archive): $($OrphanRemote -join ', ')" -ForegroundColor Cyan

# --- 4. Simple rename detection (1:1 case) ---
if ($MissingRemote.Count -eq 1 -and $OrphanRemote.Count -eq 1) {
    $NewName = $MissingRemote[0]
    $OldName = $OrphanRemote[0]

    Write-Host "`nPossible rename detected:" -ForegroundColor Magenta
    Write-Host "  Local folder: $NewName" -ForegroundColor Magenta
    Write-Host "  GitHub repo : $OldName" -ForegroundColor Magenta

    $answer = Read-Host "Rename GitHub repo '$OldName' to '$NewName'? (Y/N)"
    if ($answer -match '^[Yy]') {
        $Uri  = "https://api.github.com/repos/$GitHubUser/$OldName"
        $Body = @{ name = $NewName }
        Invoke-GitHubApi -Method PATCH -Uri $Uri -Body $Body

        Write-Host "GitHub repo renamed to '$NewName'." -ForegroundColor Green

        # Update sets
        $RemoteSet.Remove($OldName) | Out-Null
        $RemoteSet.Add($NewName)    | Out-Null

        $MissingRemote = @()
        $OrphanRemote  = @()
    }
}

# --- 5. Create repos for local folders without repos ---
foreach ($Project in $MissingRemote) {
    $ProjectPath = Join-Path $BasePath $Project
    if (!(Test-Path $ProjectPath)) {
        Write-Host "Skipping $Project (folder not found)." -ForegroundColor Yellow
        continue
    }

    Write-Host "`nCreating repo for $Project ..." -ForegroundColor Cyan

    # Ensure basic files exist
    $ReadmePath   = Join-Path $ProjectPath "README.md"
    $LicensePath  = Join-Path $ProjectPath "LICENSE"
    $GitignorePath= Join-Path $ProjectPath ".gitignore"

    if (!(Test-Path $ReadmePath)) {
        Set-Content -Path $ReadmePath -Value "# $Project`n`nProject description goes here."
    }
    if (!(Test-Path $LicensePath)) {
        Set-Content -Path $LicensePath -Value "MIT License"
    }
    if (!(Test-Path $GitignorePath)) {
        Set-Content -Path $GitignorePath -Value "*.log`n*.tmp`n__pycache__/"
    }

    Set-Location $ProjectPath

    if (!(Test-Path "$ProjectPath\.git")) {
        git init | Out-Null
    }

    git add . | Out-Null

    $status = git status --porcelain
    if ($status) {
        git commit -m "Initial commit" | Out-Null
    }

    # Create GitHub repo
    $RepoUrl = "https://api.github.com/user/repos"
    $Body    = @{ name = $Project; private = $false }
    Invoke-GitHubApi -Method POST -Uri $RepoUrl -Body $Body

    # Add remote if missing
    $remotes = git remote
    if (-not ($remotes -match "^origin$")) {
        git remote add origin "https://github.com/$GitHubUser/$Project.git"
    }

    git branch -M main
    git push -u origin main

    Write-Host "Repo '$Project' created and pushed." -ForegroundColor Green
}

# --- 6. Handle orphaned repos (no local folder) -> archive with prompt ---
foreach ($RepoName in $OrphanRemote) {
    Write-Host "`nRepo '$RepoName' has no matching local folder." -ForegroundColor DarkYellow
    $answer = Read-Host "Archive GitHub repo '$RepoName'? (Y/N)"
    if ($answer -match '^[Yy]') {
        $Uri  = "https://api.github.com/repos/$GitHubUser/$RepoName"
        $Body = @{ archived = $true }
        Invoke-GitHubApi -Method PATCH -Uri $Uri -Body $Body
        Write-Host "Repo '$RepoName' archived." -ForegroundColor Green
    } else {
        Write-Host "Repo '$RepoName' left unchanged." -ForegroundColor Yellow
    }
}

Write-Host "`nSync complete." -ForegroundColor Yellow