# ============================================
# Local Folders ↔ GitHub Repo Manager (v2.2 Hardened)
# Author: Wayne Freestun + Kai
# ============================================

# ---------- USER SETTINGS ----------
$GitHubUser = "twodogzz"
$Token      = $env:GITHUB_PAT
$BasePath   = "E:\SoftwareProjects"
$LogFile    = "$BasePath\GitHubRepoManager.log"

# ---------- DRY RUN PROMPT ----------
$answer = Read-Host "Run in DRY RUN mode (no GitHub changes)? (Y/N)"

if ($answer -match '^[Yy]') {
    $DryRun = $true
    Write-Host "DRY RUN ENABLED - No changes will be made." -ForegroundColor Yellow
}
else {
    $DryRun = $false
    Write-Host "LIVE MODE - GitHub WILL be modified." -ForegroundColor Red
}

# ---------- HARDCORE SAFETY CONFIRMATION ----------
if (-not $DryRun) {
    Write-Host "`n⚠️  WARNING: You are about to MODIFY GitHub repositories." -ForegroundColor Red
    Write-Host "This may CREATE, RENAME, or ARCHIVE repositories." -ForegroundColor Red

    $confirm = Read-Host "Type YES to confirm LIVE GitHub changes"
    if ($confirm -ne "YES") {
        Write-Host "Aborted. No changes made." -ForegroundColor Yellow
        exit
    }
}

# ---------- EXCLUSIONS ----------
$Excluded = @(
    "FileList.txt",
    "MasterProjectList.rtf",
    "SoftwareDevelopmentPlan.rtf"
)

# ---------- LOGGING ----------
function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp | $msg"
    Write-Host $msg
    Add-Content -Path $LogFile -Value $line
}

# ---------- GITHUB API ----------
function Invoke-GitHubApi {
    param($Method, $Uri, $Body = $null)

    if (-not $Token) {
        throw "GITHUB_PAT is not set. Run: setx GITHUB_PAT 'your_token_here'"
    }

    $Headers = @{
        Authorization = "Bearer $Token"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = $GitHubUser
    }

    try {
        if ($Body) {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json)
        }
        else {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
        }
    }
    catch {
        Log "ERROR calling GitHub API: $Method $Uri"
        throw $_
    }
}

# ---------- VERIFY AUTH ----------
Log "Testing GitHub authentication..."
try {
    $me = Invoke-GitHubApi GET "https://api.github.com/user"
    Log "Authenticated as $($me.login)"
}
catch {
    throw "Authentication failed. Check token scopes and expiry."
}

# ---------- LOCAL PROJECTS ----------
$LocalProjects = Get-ChildItem -Path $BasePath -Directory |
                 Where-Object { $Excluded -notcontains $_.Name } |
                 Select-Object -ExpandProperty Name

Log "Local folders: $($LocalProjects -join ', ')"

# ---------- GET REMOTE REPOS ----------
$Repos = @()
$page = 1
do {
    $Uri   = "https://api.github.com/user/repos?per_page=100&page=$page"
    $batch = Invoke-GitHubApi GET $Uri
    if (!$batch) { break }
    $Repos += $batch
    $page++
} while ($batch.Count -gt 0)

$RemoteProjects = $Repos |
                  Where-Object { $_.owner.login -eq $GitHubUser } |
                  Select-Object -ExpandProperty name

Log "Remote repos: $($RemoteProjects -join ', ')"

# ---------- SET COMPARISON ----------
$LocalSet  = [System.Collections.Generic.HashSet[string]]::new()
$RemoteSet = [System.Collections.Generic.HashSet[string]]::new()

$LocalProjects  | ForEach-Object { [void]$LocalSet.Add($_) }
$RemoteProjects | ForEach-Object { [void]$RemoteSet.Add($_) }

# ---------- AUTO-UNARCHIVE DETECTION ----------
foreach ($repo in $Repos) {
    if ($repo.archived -and $LocalSet.Contains($repo.name)) {

        Write-Host "`nRepo '$($repo.name)' is archived but a local folder exists." -ForegroundColor Magenta
        $answer = Read-Host "Unarchive GitHub repo '$($repo.name)'? (Y/N)"

        if ($answer -match '^[Yy]') {
            if ($DryRun) {
                Log "DRY RUN: Would unarchive $($repo.name)"
            }
            else {
                $Uri = "https://api.github.com/repos/$GitHubUser/$($repo.name)"
                Invoke-GitHubApi -Method PATCH -Uri $Uri -Body @{ archived = $false }
                Log "Repo '$($repo.name)' unarchived."
            }
        }
    }
}

# ---------- COMPARE ----------
$MissingRemote = $LocalProjects  | Where-Object { -not $RemoteSet.Contains($_) }
$OrphanRemote  = $RemoteProjects | Where-Object { -not $LocalSet.Contains($_) }

Log "Local without repo: $($MissingRemote -join ', ')"
Log "Repos without folder: $($OrphanRemote -join ', ')"

# ---------- RENAME DETECTION ----------
if ($MissingRemote.Count -eq 1 -and $OrphanRemote.Count -eq 1) {
    $NewName = $MissingRemote[0]
    $OldName = $OrphanRemote[0]

    Log "POSSIBLE RENAME: '$OldName' → '$NewName'"

    $answer = Read-Host "Rename GitHub repo '$OldName' to '$NewName'? (Y/N)"
    if ($answer -match '^[Yy]') {
        if ($DryRun) {
            Log "DRY RUN: Would rename repo"
        }
        else {
            $Uri  = "https://api.github.com/repos/$GitHubUser/$OldName"
            Invoke-GitHubApi PATCH $Uri @{ name = $NewName }
            Log "Repo renamed to $NewName"
        }
    }
}

# ---------- CREATE MISSING REPOS ----------
foreach ($Project in $MissingRemote) {
    $ProjectPath = Join-Path $BasePath $Project
    if (!(Test-Path $ProjectPath)) { continue }

    Log "Creating repo for $Project"

    # Ensure base files
    foreach ($file in @("README.md","LICENSE",".gitignore")) {
        $path = Join-Path $ProjectPath $file
        if (!(Test-Path $path)) {
            Set-Content $path "# $Project"
        }
    }

    Set-Location $ProjectPath

    if (!(Test-Path ".git")) { git init | Out-Null }

    git add . | Out-Null
    if (git status --porcelain) { git commit -m "Initial commit" | Out-Null }

    if ($DryRun) {
        Log "DRY RUN: Would create GitHub repo $Project"
        continue
    }

    Invoke-GitHubApi POST "https://api.github.com/user/repos" @{ name=$Project; private=$false }

    if (-not (git remote | Select-String origin)) {
        git remote add origin "https://github.com/$GitHubUser/$Project.git"
    }

    git branch -M main
    git push -u origin main

    Log "Repo '$Project' created and pushed"
}

# ---------- ORPHAN REMOTE REPOS (NO LOCAL FOLDER) ----------
foreach ($RepoName in $OrphanRemote) {

    $LocalPath = Join-Path $BasePath $RepoName
    Log "Repo '$RepoName' exists on GitHub but not locally."

    Write-Host "`nOptions for ${RepoName}:" -ForegroundColor Cyan
    Write-Host "  P = Pull/Clone into local projects folder $BasePath"
    Write-Host "  A = Archive on GitHub"
    Write-Host "  S = Skip (do nothing)"

    $choice = Read-Host "Choose P / A / S (default = S)"

    switch ($choice.ToUpper()) {

        "P" {
            if ($DryRun) {
                Log "DRY RUN: Would clone $RepoName to $LocalPath"
            }
            else {
                $CloneUrl = "https://github.com/$GitHubUser/$RepoName.git"
                Log "Cloning $RepoName to $LocalPath"
                git clone $CloneUrl $LocalPath
            }
        }

        "A" {
            if ($DryRun) {
                Log "DRY RUN: Would archive $RepoName"
            }
            else {
                $Uri = "https://api.github.com/repos/$GitHubUser/$RepoName"
                Invoke-GitHubApi PATCH $Uri @{ archived = $true }
                Log "Archived $RepoName"
            }
        }

        default {
            Log "Skipped $RepoName"
        }
    }
}

Log "SYNC COMPLETE"

# ---------- SAFE PAUSE (SKIPS IN ISE) ----------
if ($Host.Name -notmatch "ISE") {
    Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
else {
    Write-Host "`nRunning inside PowerShell ISE - no pause available." -ForegroundColor DarkYellow
}