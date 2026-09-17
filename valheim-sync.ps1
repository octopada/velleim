<#
.SYNOPSIS
    Keeps Valheim world saves in sync between this GitHub repo and your Steam save folder.

.DESCRIPTION
    pull    Update the repo from GitHub, then copy the worlds into your Steam worlds folder.
    push    Copy the worlds from your Steam worlds folder into the repo, commit and push.
    play    pull, launch Valheim through Steam, wait for the game to close, then push.
    status  Show which save generation the repo and your Steam folder each hold.

    Valheim writes a world as a folder of chunk files plus _main.<N>.* files, and bumps
    <N> on every save. _main.<N>.ok marks a finished save. The script compares <N> between
    the repo and Steam to avoid overwriting newer progress with an older save.

    Before anything in your Steam folder is overwritten, the existing world is copied to
    localBackupPath.

.EXAMPLE
    .\valheim-sync.cmd play
.EXAMPLE
    .\valheim-sync.cmd pull -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('pull', 'push', 'play', 'status')]
    [string]$Command,

    # Defaults to valheim-sync.config.json next to this script.
    [string]$ConfigPath,

    # Skip the save-generation safety checks.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot isn't set yet inside param() defaults on Windows PowerShell 5.1.
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'valheim-sync.config.json' }
$ValheimAppId = 892970

# ---------------------------------------------------------------- config

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config not found at '$ConfigPath'. Copy valheim-sync.config.example.json to valheim-sync.config.json and fill it in."
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    foreach ($key in 'playerName', 'repoPath', 'worlds') {
        if (-not $cfg.$key) { throw "Config is missing '$key'." }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $cfg.repoPath '.git'))) {
        throw "repoPath '$($cfg.repoPath)' is not a git repository."
    }
    if (-not $cfg.remote) { $cfg | Add-Member remote 'origin' -Force }
    if (-not $cfg.branch) { $cfg | Add-Member branch 'master' -Force }
    if (-not $cfg.repoWorldsDir) { $cfg | Add-Member repoWorldsDir '' -Force }
    if (-not $cfg.keepLocalBackups) { $cfg | Add-Member keepLocalBackups 10 -Force }
    if (-not $cfg.steamWorldsPath) { $cfg | Add-Member steamWorldsPath (Find-SteamWorldsPath) -Force }
    if (-not $cfg.localBackupPath) {
        $cfg | Add-Member localBackupPath (Join-Path $env:LOCALAPPDATA 'valheim-sync\backups') -Force
    }
    if (-not (Test-Path -LiteralPath $cfg.steamWorldsPath)) {
        throw "steamWorldsPath '$($cfg.steamWorldsPath)' does not exist."
    }
    $cfg
}

# Used when steamWorldsPath is left empty. Only works when exactly one Steam account on
# this PC has Valheim cloud saves.
function Find-SteamWorldsPath {
    $userdata = Join-Path ${env:ProgramFiles(x86)} 'Steam\userdata'
    $found = @(Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "$ValheimAppId\remote\worlds" } |
        Where-Object { Test-Path -LiteralPath $_ })
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -eq 0) { throw "Couldn't find a Valheim worlds folder under '$userdata'. Set steamWorldsPath in the config." }
    throw "Found several Valheim worlds folders; set steamWorldsPath in the config to one of:`n  $($found -join "`n  ")"
}

# ---------------------------------------------------------------- git

function Invoke-Git {
    # git writes progress to stderr; in Windows PowerShell 5.1 that becomes an error record,
    # so relax the preference here and rely on the exit code instead.
    $ErrorActionPreference = 'Continue'
    $out = & git -C $cfg.repoPath @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed:`n$($out -join "`n")" }
    $out
}

function Update-Repo {
    Write-Host "Pulling latest saves from $($cfg.remote)/$($cfg.branch)..."
    Invoke-Git pull --ff-only $cfg.remote $cfg.branch | Out-Null
}

# ---------------------------------------------------------------- saves

function Get-RepoWorldDir([string]$world) { Join-Path (Join-Path $cfg.repoPath $cfg.repoWorldsDir) $world }
function Get-SteamWorldDir([string]$world) { Join-Path $cfg.steamWorldsPath $world }

# Highest finished save generation in a world folder, or -1 if there is none.
function Get-SaveGeneration([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return -1 }
    $gens = @(Get-ChildItem -LiteralPath $dir -File -Filter '_main.*.ok' |
        Where-Object { $_.Name -match '^_main\.(\d+)\.ok$' } |
        ForEach-Object { [int]($_.Name -replace '^_main\.(\d+)\.ok$', '$1') })
    if ($gens.Count -eq 0) { return -1 }
    ($gens | Measure-Object -Maximum).Maximum
}

function Assert-ValheimClosed {
    if (Get-Process -Name valheim -ErrorAction SilentlyContinue) {
        throw 'Valheim is running. Close it first so a save is not copied half-written.'
    }
}

# Replace $to with an exact copy of $from, then check names and sizes match.
function Copy-WorldFolder([string]$from, [string]$to) {
    $staging = "$to.valheim-sync-tmp"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null
    Get-ChildItem -LiteralPath $from | Copy-Item -Destination $staging -Recurse -Force

    $expected = Get-ChildItem -LiteralPath $from -Recurse -File | ForEach-Object { "$($_.FullName.Substring($from.Length))|$($_.Length)" }
    $actual = Get-ChildItem -LiteralPath $staging -Recurse -File | ForEach-Object { "$($_.FullName.Substring($staging.Length))|$($_.Length)" }
    if (Compare-Object @($expected) @($actual)) {
        Remove-Item -LiteralPath $staging -Recurse -Force
        throw "Copy of '$from' did not verify; nothing was replaced."
    }

    if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
    Rename-Item -LiteralPath $staging -NewName (Split-Path $to -Leaf)
}

function Backup-SteamWorld([string]$world) {
    $src = Get-SteamWorldDir $world
    if (-not (Test-Path -LiteralPath $src)) { return }

    $root = Join-Path $cfg.localBackupPath $world
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $dest = Join-Path $root (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-WorldFolder $src $dest
    Write-Host "  Backed up your local $world to $dest"

    Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending |
        Select-Object -Skip $cfg.keepLocalBackups | Remove-Item -Recurse -Force
}

# ---------------------------------------------------------------- sync state

# Remembers, per world, which save generation this PC last pulled or pushed: the save you
# started playing from. A push uses it to tell whether someone else pushed in the meantime.
$StatePath = Join-Path $env:LOCALAPPDATA 'valheim-sync\state.json'

function Get-BaseGeneration([string]$world) {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $key = "$($cfg.repoPath)|$world"
    if ($state.PSObject.Properties.Name -contains $key) { return [int]$state.$key }
    $null
}

function Set-BaseGeneration([string]$world, [int]$generation) {
    $state = New-Object psobject
    if (Test-Path -LiteralPath $StatePath) { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json }
    $state | Add-Member -NotePropertyName "$($cfg.repoPath)|$world" -NotePropertyValue $generation -Force
    New-Item -ItemType Directory -Path (Split-Path $StatePath) -Force | Out-Null
    $state | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

# ---------------------------------------------------------------- commands

function Invoke-Pull {
    Assert-ValheimClosed
    Update-Repo
    foreach ($world in $cfg.worlds) {
        $repoDir = Get-RepoWorldDir $world
        $steamDir = Get-SteamWorldDir $world
        $repoGen = Get-SaveGeneration $repoDir
        $steamGen = Get-SaveGeneration $steamDir
        $baseGen = Get-BaseGeneration $world

        if ($repoGen -lt 0) { Write-Warning "$world is not in the repo; skipping."; continue }
        if ($steamGen -eq $repoGen) {
            Set-BaseGeneration $world $repoGen
            Write-Host "$world is already up to date (save $repoGen)."
            continue
        }
        # Steam has saves the repo doesn't have: progress you haven't pushed yet.
        $unpushed = ($steamGen -gt $repoGen) -or ($null -ne $baseGen -and $steamGen -ge 0 -and $steamGen -ne $baseGen)
        if ($unpushed -and -not $Force) {
            Write-Warning "$world in Steam (save $steamGen) has progress that isn't in the repo (save $repoGen). Not overwriting it. Run 'push' to upload it, or 'pull -Force' to replace it with the repo's save (yours is backed up first)."
            continue
        }

        Backup-SteamWorld $world
        Copy-WorldFolder $repoDir $steamDir
        Set-BaseGeneration $world $repoGen
        Write-Host "${world}: copied save $repoGen from the repo into Steam."
    }
}

function Invoke-Push {
    Assert-ValheimClosed
    Update-Repo
    $changed = @{}
    foreach ($world in $cfg.worlds) {
        $repoDir = Get-RepoWorldDir $world
        $steamDir = Get-SteamWorldDir $world
        $repoGen = Get-SaveGeneration $repoDir
        $steamGen = Get-SaveGeneration $steamDir
        $baseGen = Get-BaseGeneration $world

        if ($steamGen -lt 0) { Write-Warning "$world has no finished save in '$steamDir'; skipping."; continue }
        if ($steamGen -eq $repoGen) {
            Set-BaseGeneration $world $steamGen
            Write-Host "${world}: nothing new to push (save $steamGen)."
            continue
        }
        if ($repoGen -ge 0 -and -not $Force) {
            if ($null -eq $baseGen) {
                Write-Warning "${world}: this PC has never pulled this world, so it can't tell whether your save ($steamGen) or the repo's ($repoGen) should win. Run 'pull' first, or 'push -Force' to upload yours."
                continue
            }
            if ($repoGen -ne $baseGen) {
                Write-Warning "${world}: someone pushed save $repoGen after you started from save $baseGen. Pushing your save $steamGen would wipe their progress, so nothing was pushed. Agree whose save to keep, then run 'push -Force' (yours) or 'pull -Force' (theirs)."
                continue
            }
        }

        Copy-WorldFolder $steamDir $repoDir
        Invoke-Git add -A -- $repoDir | Out-Null
        $changed[$world] = $steamGen
    }

    if ($changed.Count -gt 0) {
        & git -C $cfg.repoPath diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            $summary = ($changed.Keys | Sort-Object | ForEach-Object { "$_ save $($changed[$_])" }) -join ', '
            Invoke-Git commit -m "$($cfg.playerName): $summary ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))" | Out-Null
        }
    }

    # Also sends a commit left behind by an earlier push that failed, e.g. with no internet.
    $ahead = [int](Invoke-Git rev-list --count "$($cfg.remote)/$($cfg.branch)..HEAD")
    if ($ahead -gt 0) {
        Write-Host "Pushing $ahead commit(s) to $($cfg.remote)/$($cfg.branch)..."
        Invoke-Git push $cfg.remote $cfg.branch | Out-Null
        Write-Host 'Done.'
    }
    foreach ($world in $changed.Keys) { Set-BaseGeneration $world $changed[$world] }
}

function Invoke-Play {
    Invoke-Pull
    Write-Host 'Launching Valheim...'
    Start-Process "steam://rungameid/$ValheimAppId"

    $deadline = (Get-Date).AddMinutes(5)
    while (-not (Get-Process -Name valheim -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { throw "Valheim didn't start within 5 minutes. Run 'push' yourself after playing." }
        Start-Sleep -Seconds 5
    }
    Write-Host 'Valheim is running. Saves will be pushed when you quit the game.'
    Wait-Process -Name valheim
    # Give Steam Cloud a moment to settle after the game exits.
    Start-Sleep -Seconds 10
    Invoke-Push
}

function Show-Status {
    Write-Host "Player:       $($cfg.playerName)"
    Write-Host "Repo:         $($cfg.repoPath)"
    Write-Host "Steam worlds: $($cfg.steamWorldsPath)"
    Write-Host "Backups:      $($cfg.localBackupPath)"
    foreach ($world in $cfg.worlds) {
        Write-Host ("  {0,-16} repo save {1,4}   steam save {2,4}" -f $world, (Get-SaveGeneration (Get-RepoWorldDir $world)), (Get-SaveGeneration (Get-SteamWorldDir $world)))
    }
}

$cfg = Read-Config
switch ($Command) {
    'pull' { Invoke-Pull }
    'push' { Invoke-Push }
    'play' { Invoke-Play }
    'status' { Show-Status }
}
