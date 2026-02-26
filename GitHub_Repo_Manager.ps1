# ============================================
# Local Folders ↔ GitHub Repo Manager (v2.4.5)
# Author: Wayne Freestun + Kai
# Features: Portable BasePath, N3 logging, treat missing .git as new project,
#           always exclude .git_backups, prompt before create, M3 mismatch flow,
#           DRY RUN in-memory simulation for renames.
# ============================================

# ---------- USER SETTINGS ----------
$GitHubUser = "twodogzz"
$Token      = $env:GITHUB_PAT

# ---------- BASE PATH RESOLUTION ----------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptRoot "GitHubRepoManager.config.json"
$BasePath   = $null

if (Test-Path $ConfigFile) {
    try {
        $Config   = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $BasePath = $Config.BasePath
    }
    catch {
        Write-Host "Config file invalid or unreadable. Rebuilding..." -ForegroundColor Yellow
        $BasePath = $null
    }
}

if (-not $BasePath) {
    $BasePath = Split-Path $ScriptRoot -Parent
}

if (-not (Test-Path $BasePath)) {
    Write-Host "Project root not found at '$BasePath'." -ForegroundColor Yellow
    $BasePath = Read-Host "Enter your SoftwareProjects folder path (e.g. C:\SoftwareProjects)"
}

if (-not (Test-Path $BasePath)) {
    Write-Host "The path '$BasePath' does not exist. Aborting." -ForegroundColor Red
    exit
}

# Save config for next run
$Config = @{ BasePath = $BasePath }
$Config | ConvertTo-Json | Set-Content $ConfigFile

$LogFile    = Join-Path $BasePath "GitHubRepoManager.log"
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

# ---------- LOGGING ----------
function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp | $msg"
    Write-Host $msg
    Add-Content -Path $LogFile -Value $line
}

function LogN3($level, $project, $gitPath) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] ${level}: $project has no .git folder (PATH: $gitPath). Marked as new project."
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# ---------- .GIT BACKUP / RESTORE HELPERS ----------
if (-not (Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

function Resolve-GitMetadataPath {
    param([string]$FolderPath)

    $gitEntryPath = Join-Path $FolderPath ".git"
    if (-not (Test-Path -LiteralPath $gitEntryPath)) { return $null }

    $gitEntryItem = Get-Item -LiteralPath $gitEntryPath -Force -ErrorAction SilentlyContinue
    if (-not $gitEntryItem) { return $null }

    $isPointerFile = $false
    $isValid       = $true
    $gitDirPath    = $null

    if ($gitEntryItem.PSIsContainer) {
        $gitDirPath = $gitEntryItem.FullName
    }
    else {
        $isPointerFile = $true
        $gitdirLine = Get-Content -LiteralPath $gitEntryPath -ErrorAction SilentlyContinue |
                      Where-Object { $_ -match '^\s*gitdir\s*:\s*(.+)\s*$' } |
                      Select-Object -First 1

        if (-not $gitdirLine) {
            $isValid = $false
        }
        else {
            $gitdirTarget = ([regex]::Match($gitdirLine, '^\s*gitdir\s*:\s*(.+)\s*$')).Groups[1].Value.Trim()
            if ([System.IO.Path]::IsPathRooted($gitdirTarget)) {
                $resolvedPath = $gitdirTarget
            }
            else {
                $resolvedPath = Join-Path $FolderPath $gitdirTarget
            }

            try {
                $gitDirPath = [System.IO.Path]::GetFullPath($resolvedPath)
            }
            catch {
                $gitDirPath = $resolvedPath
            }

            if (-not (Test-Path -LiteralPath $gitDirPath -PathType Container)) {
                $isValid = $false
            }
        }
    }

    $configPath = if ($gitDirPath) { Join-Path $gitDirPath "config" } else { $null }
    $headPath   = if ($gitDirPath) { Join-Path $gitDirPath "HEAD" } else { $null }
    $refsPath   = if ($gitDirPath) { Join-Path $gitDirPath "refs" } else { $null }

    return [pscustomobject]@{
        GitEntryPath   = $gitEntryPath
        GitDirPath     = $gitDirPath
        ConfigPath     = $configPath
        HeadPath       = $headPath
        RefsPath       = $refsPath
        IsPointerFile  = $isPointerFile
        IsValid        = $isValid
    }
}

function Test-GitCorrupted {
    param([string]$FolderPath)

    $gitMetadata = Resolve-GitMetadataPath -FolderPath $FolderPath
    if (-not $gitMetadata) { return $true }
    if (-not $gitMetadata.IsValid) { return $true }

    if (-not (Test-Path -LiteralPath $gitMetadata.ConfigPath)) { return $true }
    if (-not (Test-Path -LiteralPath $gitMetadata.HeadPath))   { return $true }

    $packedRefs = Join-Path $gitMetadata.GitDirPath "packed-refs"
    $hasRefs    = (Test-Path -LiteralPath $gitMetadata.RefsPath) -or (Test-Path -LiteralPath $packedRefs)
    if (-not $hasRefs) { return $true }

    $urlLine = Select-String -Path $gitMetadata.ConfigPath -Pattern "url =" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $urlLine) { return $true }

    return $false
}

function Backup-GitFolder {
    param(
        [string]$FolderPath,
        [string]$ProjectName
    )

    $gitMetadata = Resolve-GitMetadataPath -FolderPath $FolderPath
    if (-not $gitMetadata) { return }
    if (-not $gitMetadata.IsValid) { return }

    $backupFile      = Join-Path $BackupRoot "$ProjectName.git.zip"
    $gitLastWrite    = (Get-Item -LiteralPath $gitMetadata.GitDirPath -Force).LastWriteTime
    $backupLastWrite = if (Test-Path $backupFile) { (Get-Item $backupFile).LastWriteTime } else { [datetime]::MinValue }

    if ($gitLastWrite -gt $backupLastWrite) {
        if (Test-Path $backupFile) { Remove-Item $backupFile -Force }
        Compress-Archive -Path $gitMetadata.GitDirPath -DestinationPath $backupFile -Force
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

    $gitMetadata = Resolve-GitMetadataPath -FolderPath $FolderPath
    if (-not $gitMetadata) { return $null }
    if (-not $gitMetadata.IsValid) { return $null }
    if (-not (Test-Path -LiteralPath $gitMetadata.ConfigPath)) { return $null }

    try {
        $urlLine = Select-String -Path $gitMetadata.ConfigPath -Pattern "url =" -ErrorAction SilentlyContinue | Select-Object -First 1
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

# ---------- LOCAL PROJECTS (FIRST PASS) ----------
$LocalProjects = Get-ChildItem -Path $BasePath -Directory -Force |
                 Where-Object { $_.Name -ne ".git_backups" } |
                 Select-Object -ExpandProperty Name

$LocalProjects = @($LocalProjects)

Log "Local folders: $($LocalProjects -join ', ')"

# ---------- PER-PROJECT .GIT HEALTH + BACKUP ----------
foreach ($Project in $LocalProjects) {
    $ProjectPath = Join-Path $BasePath $Project
    if (-not (Test-Path $ProjectPath)) { continue }

    $gitMetadata = Resolve-GitMetadataPath -FolderPath $ProjectPath
    $gitPath     = Join-Path $ProjectPath ".git"

    if (-not $gitMetadata) {
        # N3-style detailed log
        LogN3 "INFO" $Project $gitPath
        # Do not run backup/restore; project remains in pipeline for later steps
        continue
    }

    if ($gitMetadata.IsPointerFile) {
        if ($gitMetadata.IsValid) {
            Log "Detected .git pointer file for '$Project' -> '$($gitMetadata.GitDirPath)'."
        }
        else {
            Log "Detected invalid .git pointer file for '$Project'. Target path missing/unreadable. Classified as corrupted."
        }
    }
    else {
        Log "Detected .git directory for '$Project' at '$($gitMetadata.GitDirPath)'."
    }

    # .git exists — safe to run health/backup
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

# ---------- GET REMOTE REPOS (FIRST PASS) ----------
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
foreach ($Project in $LocalProjects) {

    $ProjectPath = Join-Path $BasePath $Project
    if (-not (Test-Path $ProjectPath)) { continue }

    if (Test-GitCorrupted $ProjectPath) { continue }

    $RemoteName = Get-RemoteRepoName -FolderPath $ProjectPath
    if (-not $RemoteName) { continue }

    $HasRemoteRepo = $RemoteProjects -contains $RemoteName

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
                if ($DryRun) {
                    Log "DRY RUN: Would rename GitHub repo '$RemoteName' to '$Project'"
                    Log "DRY RUN: Simulated remote rename applied to internal state"
                    $RemoteProjects = $RemoteProjects | ForEach-Object { if ($_ -eq $RemoteName) { $Project } else { $_ } }
                }
                else {
                    $Uri = "https://api.github.com/repos/$GitHubUser/$RemoteName"
                    Invoke-GitHubApi PATCH $Uri @{ name = $Project }
                    Log "Renamed GitHub repo '$RemoteName' to '$Project'"
                    $RemoteProjects = $RemoteProjects | ForEach-Object { if ($_ -eq $RemoteName) { $Project } else { $_ } }
                }
            }

            "2" {
                $NewPath = Join-Path $BasePath $RemoteName
                if ($DryRun) {
                    Log "DRY RUN: Would rename local folder '$Project' to '$RemoteName'"
                    Log "DRY RUN: Simulated local folder rename applied to internal state"
                    $LocalProjects = $LocalProjects | ForEach-Object { if ($_ -eq $Project) { $RemoteName } else { $_ } }
                }
                else {
                    if (-not (Test-Path $NewPath)) {
                        Rename-Item -Path $ProjectPath -NewName $RemoteName
                        Log "Renamed local folder '$Project' to '$RemoteName'"
                        $LocalProjects = $LocalProjects | ForEach-Object { if ($_ -eq $Project) { $RemoteName } else { $_ } }
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

# ---------- REBUILD LOCAL PROJECTS AFTER POSSIBLE RENAMES ----------
$LocalProjects = Get-ChildItem -Path $BasePath -Directory -Force |
                 Where-Object { $_.Name -ne ".git_backups" } |
                 Select-Object -ExpandProperty Name

$LocalProjects = @($LocalProjects)

# ---------- REFETCH REMOTE REPOS ONLY IN LIVE MODE ----------
if (-not $DryRun) {
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
}

# ---------- BUILD SETS ----------
$LocalSet  = [System.Collections.Generic.HashSet[string]]::new()
$RemoteSet = [System.Collections.Generic.HashSet[string]]::new()

$LocalProjects  | ForEach-Object { [void]$LocalSet.Add($_) }
$RemoteProjects | ForEach-Object { [void]$RemoteSet.Add($_) }

# ---------- CASE: local has no .git but remote exists (M3) ----------
foreach ($Project in $LocalProjects) {
    $ProjectPath = Join-Path $BasePath $Project
    $gitPath = Join-Path $ProjectPath ".git"

    if ((-not (Test-Path $gitPath)) -and ($RemoteProjects -contains $Project)) {

        # If a backup exists, offer restore first
        $backupFile = Join-Path $BackupRoot "$Project.git.zip"
        if (Test-Path $backupFile) {
            Log "Backup exists for '$Project' at '$backupFile'. Offering restore."
            $resp = Read-Host "A .git backup exists for '$Project'. Restore .git from backup? (Y/N)"
            if ($resp -match '^[Yy]') {
                if (Restore-GitFolder -FolderPath $ProjectPath -ProjectName $Project) {
                    Log "Restored .git for '$Project' from backup."
                    continue
                }
            }
        }

        Write-Host "`nA GitHub repo exists for '$Project' but the local folder has no .git." -ForegroundColor Yellow
        Write-Host "Choose an action:" -ForegroundColor Cyan
        Write-Host "  1 = Clone remote repo into this folder (restore .git)"
        Write-Host "  2 = Recreate .git and connect to remote (git init + remote)"
        Write-Host "  3 = Skip (do nothing)"

        $mchoice = Read-Host "Enter 1 / 2 / 3 (default = 3)"

        switch ($mchoice) {
            "1" {
                if ($DryRun) {
                    Log "DRY RUN: Would clone https://github.com/$GitHubUser/$Project.git into $ProjectPath"
                } else {
                    # Initialize .git and attach remote, fetch and checkout main if present
                    if (-not (Test-Path $ProjectPath)) { New-Item -ItemType Directory -Path $ProjectPath | Out-Null }
                    Set-Location $ProjectPath
                    if (-not (Test-Path ".git")) { git init | Out-Null }
                    if (-not (git remote | Select-String origin)) {
                        git remote add origin "https://github.com/$GitHubUser/$Project.git"
                    }
                    git fetch origin
                    try { git checkout -b main origin/main } catch { }
                    Log "Cloned remote into existing folder for '$Project' (restored .git)."
                }
            }
            "2" {
                if ($DryRun) {
                    Log "DRY RUN: Would recreate .git and connect to https://github.com/$GitHubUser/$Project.git for $Project"
                } else {
                    Set-Location $ProjectPath
                    if (-not (Test-Path ".git")) { git init | Out-Null }
                    if (-not (git remote | Select-String origin)) {
                        git remote add origin "https://github.com/$GitHubUser/$Project.git"
                    }
                    git fetch origin
                    try { git checkout -b main origin/main } catch { }
                    Log "Recreated .git and connected to remote for '$Project'."
                }
            }
            default {
                Log "User skipped auto-repair for '$Project'."
            }
        }
    }
}

# ---------- COMPARE ----------
$MissingRemote = $LocalProjects  | Where-Object { -not $RemoteSet.Contains($_) }
$OrphanRemote  = $RemoteProjects | Where-Object { -not $LocalSet.Contains($_) }

Log "Local without repo: $($MissingRemote -join ', ')"
Log "Repos without folder: $($OrphanRemote -join ', ')"

# ---------- CREATE MISSING REPOS (ask user per R1) ----------
foreach ($Project in $MissingRemote) {
    $ProjectPath = Join-Path $BasePath $Project
    if (!(Test-Path $ProjectPath)) { continue }

    Write-Host "`nLocal project '$Project' has no GitHub repo." -ForegroundColor Cyan
    $create = Read-Host "Create GitHub repo for '$Project'? (Y/N)"
    if ($create -notmatch '^[Yy]') {
        Log "User chose not to create repo for '$Project'."
        continue
    }

    Log "Creating repo for $Project"

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

# ---------- ORPHAN REMOTE REPOS ----------
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

# ---------- SAFE PAUSE ----------
if ($Host.Name -notmatch "ISE") {
    Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
else {
    Write-Host "`nRunning inside PowerShell ISE - no pause available." -ForegroundColor DarkYellow
}
