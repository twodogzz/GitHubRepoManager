# ============================================
# Local Folders ↔ GitHub Repo Manager (v2.4 Intelligent)
# Author: Wayne Freestun + Kai
# ============================================

# ---------- USER SETTINGS ----------
$GitHubUser = "twodogzz"
$Token      = $env:GITHUB_PAT
$BasePath   = "E:\SoftwareProjects"
$LogFile    = "$BasePath\GitHubRepoManager.log"
$BackupRoot = Join-Path $BasePath ".git_backups"

# ---------- DRY RUN PROMPT ----------
$answer = Read-Host "Run in DRY RUN mode (no GitHub changes)? (Y/N)"

if ($answer -match '^[Yy]') {
    $DryRun = $true
    Write-Host "DRY RUN ENABLED - No GitHub changes will be made." -ForegroundColor Yellow
}
else {
    $DryRun = $false
    Write-Host "LIVE MODE - GitHub WILL be modified." -ForegroundColor Red
}

# ---------- HARDCORE SAFETY CONFIRMATION ----------
if (-not $DryRun) {
    Write-Host "`nWARNING: You are about to MODIFY GitHub repositories." -ForegroundColor Red
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

# ---------- .GIT BACKUP / RESTORE HELPERS ----------
if (-not (Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

function Test-GitCorrupted {
    param([string]$FolderPath)

    $gitPath = Join-Path $FolderPath ".git"
    if (-not (Test-Path $gitPath)) { return $true }

    $config = Join-Path $gitPath "config"
    $head   = Join-Path $gitPath "HEAD"
    $refs   = Join-Path $gitPath "refs"

    if (-not (Test-Path $config)) { return $true }
    if (-not (Test-Path $head))   { return $true }
    if (-not (Test-Path $refs))   { return $true }

    $urlLine = Select-String -Path $config -Pattern "url =" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $urlLine) { return $true }

    return $false
}

function Backup-GitFolder {
    param(
        [string]$FolderPath,
        [string]$ProjectName
    )

    $gitPath = Join-Path $FolderPath ".git"
    if (-not (Test-Path $gitPath)) { return }

    $backupFile      = Join-Path $BackupRoot "$ProjectName.git.zip"
    $gitLastWrite    = (Get-Item $gitPath).LastWriteTime
    $backupLastWrite = if (Test-Path $backupFile) { (Get-Item $backupFile).LastWriteTime } else { [datetime]::MinValue }

    if ($gitLastWrite -gt $backupLastWrite) {
        if (Test-Path $backupFile) { Remove-Item $backupFile -Force }
        Compress-Archive -Path $gitPath -DestinationPath $backupFile -Force
        Log "Backed up .git for '$ProjectName' to '$backupFile'"
    }
}

function Restore-GitFolder {
    param(
        [string]$FolderPath,
        [string]$ProjectName
    )

    $backupFile = Join-Path $BackupRoot "$ProjectName.git.zip"
    if (-not (Test-Path $backupFile)) { return $false }

    Write-Host "`nA .git backup exists for '$ProjectName'." -ForegroundColor Cyan
    $resp = Read-Host "Restore .git from backup? (Y/N)"
    if ($resp -notmatch '^[Yy]') { return $false }

    Expand-Archive -Path $backupFile -DestinationPath $FolderPath -Force
    Log "Restored .git for '$ProjectName' from backup."
    return $true
}

function Get-RemoteRepoName {
    param([string]$FolderPath)

    $gitConfig = Join-Path $FolderPath ".git\config"
    if (-not (Test-Path $gitConfig)) { return $null }

    try {
        $urlLine = Select-String -Path $gitConfig -Pattern "url =" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $urlLine) { return $null }

        $url = $urlLine.ToString().Split("=")[1].Trim()
        $repoName = ($url -split "/")[-1].Replace(".git","")
        return $repoName
    }
    catch {
        return $null
    }
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

# ---------- PER-PROJECT .GIT HEALTH + BACKUP ----------
foreach ($Project in $LocalProjects) {
    $ProjectPath = Join-Path $BasePath $Project
    if (-not (Test-Path $ProjectPath)) { continue }

    if (Test-GitCorrupted $ProjectPath) {
        Log "Detected missing/corrupted .git in '$Project'."
        if (Restore-GitFolder -FolderPath $ProjectPath -ProjectName $Project) {
            if (-not (Test-GitCorrupted $ProjectPath)) {
                Log ".git for '$Project' is healthy after restore."
            }
            else {
                Log ".git for '$Project' still appears corrupted after restore."
            }
        }
        else {
            Log "No restore performed for '$Project'."
        }
    }

    if (-not (Test-GitCorrupted $ProjectPath)) {
        Backup-GitFolder -FolderPath $ProjectPath -ProjectName $Project
    }
}

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

# ---------- INTELLIGENT RENAME DETECTION ----------
foreach ($Project in $LocalProjects.ToArray()) {

    $ProjectPath = Join-Path $BasePath $Project
    if (-not (Test-Path $ProjectPath)) { continue }
    if (Test-GitCorrupted $ProjectPath) { continue }

    $RemoteName = Get-RemoteRepoName -FolderPath $ProjectPath
    if (-not $RemoteName) { continue }

    $HasRemoteRepo = $RemoteProjects -contains $RemoteName

    # Only care when names differ and remote exists
    if ($HasRemoteRepo -and $RemoteName -ne $Project) {

        Write-Host "`n⚠️ Name mismatch detected." -ForegroundColor Yellow
        Write-Host "Local folder: $Project"
        Write-Host "GitHub repo: $RemoteName`n"
        Write-Host "Renaming a GitHub repo updates URLs and may affect external links."
        Write-Host "Renaming a local folder may affect scripts, shortcuts, or tooling.`n"

        Write-Host "Choose an action:" -ForegroundColor Cyan
        Write-Host "  1 = Rename GitHub repo → $Project"
        Write-Host "  2 = Rename local folder → $RemoteName"
        Write-Host "  3 = Skip (no action)"

        $choice = Read-Host "Enter 1 / 2 / 3 (default = 3)"

        switch ($choice) {

            "1" {
                # Rename GitHub repo to match local folder
                if ($DryRun) {
                    Log "DRY RUN: Would rename GitHub repo '$RemoteName' to '$Project'"
                }
                else {
                    $Uri = "https://api.github.com/repos/$GitHubUser/$RemoteName"
                    Invoke-GitHubApi PATCH $Uri @{ name = $Project }
                    Log "Renamed GitHub repo '$RemoteName' to '$Project'"

                    # Update in-memory remote list
                    $RemoteProjects = $RemoteProjects | ForEach-Object {
                        if ($_ -eq $RemoteName) { $Project } else { $_ }
                    }
                }
            }

            "2" {
                # Rename local folder to match GitHub repo
                $NewPath = Join-Path $BasePath $RemoteName
                if ($DryRun) {
                    Log "DRY RUN: Would rename local folder '$Project' to '$RemoteName'"
                }
                else {
                    if (-not (Test-Path $NewPath)) {
                        Rename-Item -Path $ProjectPath -NewName $RemoteName
                        Log "Renamed local folder '$Project' to '$RemoteName'"

                        # Update in-memory local list
                        $LocalProjects = $LocalProjects | ForEach-Object {
                            if ($_ -eq $Project) { $RemoteName } else { $_ }
                        }
                    }
                    else {
                        Log "Cannot rename folder '$Project' to '$RemoteName' because '$NewPath' already exists."
                    }
                }
            }

            default {
                Log "Skipped rename for mismatch: folder '$Project', repo '$RemoteName'"
            }
        }
    }
}

# ---------- REBUILD SETS AFTER POSSIBLE RENAMES ----------
$LocalProjects = Get-ChildItem -Path $BasePath -Directory |
                 Where-Object { $Excluded -notcontains $_.Name } |
                 Select-Object -ExpandProperty Name

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

    if (-not (Test-GitCorrupted $ProjectPath)) {
        Backup-GitFolder -FolderPath $ProjectPath -ProjectName $Project
    }
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

                if (-not (Test-GitCorrupted $LocalPath)) {
                    Backup-GitFolder -FolderPath $LocalPath -ProjectName $RepoName
                }
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
