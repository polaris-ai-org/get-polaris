<#
.SYNOPSIS
    Polaris AI one-liner installer - everything from a bare Windows machine to
    an opened Dashboard.

.DESCRIPTION
    This is the canonical Polaris install script. Run it straight from the
    public bootstrap repo:

        irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1 | iex

    Running via `irm | iex` needs no downloaded file, so neither the execution
    policy nor mark-of-the-web applies. To pass parameters, either wrap it:

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1))) -DryRun

    or download first and run it as a file:

        irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1 -OutFile install.ps1
        powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun

    The script walks six stages, each idempotent (safe to re-run; done work is
    skipped):

      1. Prerequisites  - Git, Node.js LTS, GitHub CLI via winget (Docker
                          Desktop opt-in via -IncludeDocker); Claude Code via
                          its native installer. Verifies Git Bash and the
                          Windows WSL bash.exe alias.
      2. GitHub sign-in - one browser device-flow login, `gh auth setup-git`,
                          and (when Docker is present) GHCR. Known traps -
                          a shadowing GH_TOKEN, a fine-grained PAT, the WSL
                          bash alias - get guided fixes with a re-check loop.
      3. Polaris plugin - non-interactive `claude plugin` install from the
                          private dist repo.
      4. Dashboard      - downloads and runs the Setup package from the dist
                          repo's latest release (silent, per-user). Falls back
                          to the plain-EXE install for releases that predate
                          the Setup package.
      5. Claude sign-in - detects existing Anthropic credentials (presence
                          only - values are never read or printed) and offers
                          a guided browser sign-in. Never a hard failure: the
                          machine setup completes without a seat, and Claude
                          asks again on first use.
      6. Finish         - open the Polaris Dashboard.

    Stages 3 and 4 need the stage-2 sign-in (the dist repo is private). If you
    skip or fail a sign-in, later stages degrade to printed instructions
    instead of aborting.

    WHAT YOU NEED BEFORE RUNNING THIS
      * Windows 10/11. Windows PowerShell 5.1 (preinstalled) is enough.
      * winget - preinstalled on Windows 11; on Windows 10 install
        "App Installer" from the Microsoft Store (https://aka.ms/getwinget).
      * Permission to approve UAC prompts (winget installs are machine-wide).
        If you are not a local administrator, your IT has to run stage 1.
      * A GitHub account with Read access to polaris-ai-org/PolarisAI-dist
        (ask the maintainer; you will receive an email invite to accept).

    Run it from a NORMAL PowerShell window - do not "Run as administrator".
    The UAC prompts handle elevation per package; a per-user install done as
    admin would land in the wrong profile.

.PARAMETER DryRun
    Probe only - print what every stage would do and change nothing.

.PARAMETER IncludeDocker
    Also install Docker Desktop and log it in to GHCR. Needed only to run
    agents in containers; large install, so it is opt-in.

.PARAMETER SkipClaudeCode
    Do not install Claude Code even if it is missing (just report it).

.PARAMETER SkipDashboard
    Skip stage 4 (the Dashboard download/install).

.PARAMETER SkipAnthropicSignIn
    Skip stage 5 (the Claude sign-in offer). Detection still runs; nothing
    interactive happens. Useful for IT provisioning a machine for someone else.

.EXAMPLE
    irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1))) -DryRun -IncludeDocker

.NOTES
    Source of truth: docs/onboarding/install.ps1 in the private PolarisAI
    source repo. The release pipeline publishes it to the public bootstrap
    repo (polaris-ai-org/get-polaris) and attaches it to every dist release -
    do not edit the published copies.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$IncludeDocker,
    [switch]$SkipClaudeCode,
    [switch]$SkipDashboard,
    [switch]$SkipAnthropicSignIn
)

$ErrorActionPreference = 'Stop'

# Stamped by the release pipeline; 'dev' when run from a working tree.
$script:BootstrapVersion = '3.0.1'

# --- Constants ----------------------------------------------------------------

$DistRepo          = 'polaris-ai-org/PolarisAI-dist'
$DistRepoUrl       = "https://github.com/$DistRepo.git"
$MarketplaceName   = 'polaris-marketplace'
$PluginSpec        = "polaris@$MarketplaceName"

# Velopack Setup package (Tier 2a artifact). The asset is matched by pattern so
# a pack-id rename never strands this script; the silent flag is Velopack's.
$SetupAssetPattern = '*Setup.exe'
$SetupSilentArg    = '--silent'

# Legacy copy-EXE layout (pre-Velopack releases) - the fallback install.
$LegacyInstallDir  = Join-Path $env:LOCALAPPDATA 'PolarisAI\Dashboard'
$LegacyExeName     = 'PolarisAI.Dashboard.exe'
$ShortcutName      = 'Polaris AI Dashboard.lnk'

# Velopack per-user install layout (pack id PolarisAI.Dashboard).
$VelopackExePath   = Join-Path $env:LOCALAPPDATA 'PolarisAI.Dashboard\current\PolarisAI.Dashboard.exe'

# --- Output helpers -----------------------------------------------------------

function Write-Section($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Write-Ok($text)      { Write-Host "    [ok] $text" -ForegroundColor Green }
function Write-Skip($text)    { Write-Host "    [skip] $text" -ForegroundColor DarkGray }
function Write-Warn2($text)   { Write-Host "    [warn] $text" -ForegroundColor Yellow }
function Write-Step($text)    { Write-Host "    [..] $text" }
function Write-Plan($text)    { Write-Host "    [dry-run] $text" -ForegroundColor DarkCyan }

# Per-stage outcome collected for the finish summary.
$script:StageResults = New-Object System.Collections.ArrayList
function Set-StageResult([string]$Stage, [string]$Result) {
    [void]$script:StageResults.Add([pscustomobject]@{ Stage = $Stage; Result = $Result })
}

# --- Process helpers ----------------------------------------------------------

# Run a native command capturing combined output + exit code without tripping
# $ErrorActionPreference='Stop' (Windows PowerShell 5.1 turns a native command's
# redirected stderr into a terminating NativeCommandError; relaxing the
# preference around the call avoids that).
function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Interactive choice with a safe default. Returns the default without asking in
# -DryRun and whenever stdin is not an interactive console (CI, redirection).
function Read-Choice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Options,   # e.g. 'Y','n'
        [Parameter(Mandatory)][string]$Default
    )
    $canAsk = -not $DryRun
    try { if ([Console]::IsInputRedirected) { $canAsk = $false } } catch { $canAsk = $false }
    if (-not $canAsk) { return $Default }
    $optionText = ($Options -join '/')
    while ($true) {
        $answer = Read-Host "    $Prompt [$optionText]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        foreach ($opt in $Options) {
            if ($answer.Trim().ToLowerInvariant() -eq $opt.ToLowerInvariant()) { return $opt }
        }
        Write-Host "    Please answer one of: $optionText"
    }
}

# Installers extend the *stored* PATH; the running process keeps its startup
# copy. Re-reading both scopes makes freshly installed tools visible right away.
function Update-SessionPath {
    $parts = @()
    foreach ($scope in 'Machine', 'User') {
        $value = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($value) { $parts += $value }
    }
    if ($parts.Count -gt 0) { $env:Path = ($parts -join ';') }
    # Claude Code's native installer lands in ~\.local\bin; make sure the
    # verification pass sees it even before a new window picks up the PATH.
    $localBin = Join-Path $env:USERPROFILE '.local\bin'
    if ((Test-Path $localBin) -and (($env:Path -split ';') -notcontains $localBin)) {
        $env:Path = "$env:Path;$localBin"
    }
}

function Invoke-WingetInstall {
    param([Parameter(Mandatory)][string]$Id, [switch]$Upgrade)

    $verb = 'install'
    if ($Upgrade) { $verb = 'upgrade' }
    $wingetArgs = @($verb, '--id', $Id, '--exact', '--source', 'winget',
                    '--accept-source-agreements', '--accept-package-agreements')

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        winget @wingetArgs --silent | Out-Host
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            # Some installers refuse an unattended run - retry showing their UI.
            Write-Warn2 "winget $verb --silent exited with $code - retrying with the installer UI"
            winget @wingetArgs | Out-Host
            $code = $LASTEXITCODE
        }
        return $code
    } finally {
        $ErrorActionPreference = $prev
    }
}

# --- Stage 1: prerequisites ---------------------------------------------------

# Claude Code installs via its native installer (irm https://claude.ai/install.ps1),
# not npm: per-user, no Node coupling, no npm global-bin PATH timing.
$Prerequisites = @(
    @{
        Name = 'Claude Code'; Command = 'claude'; VersionArg = '--version'
        Installer = 'native'; Purpose = 'everything'
        Hint = 'irm https://claude.ai/install.ps1 | iex'
    },
    @{
        Name = 'Node.js 18+'; Command = 'node'; VersionArg = '--version'
        Installer = 'winget'; WingetId = 'OpenJS.NodeJS.LTS'; MinMajor = 18
        Purpose = 'plugin hooks & scripts'
    },
    @{
        Name = 'Git'; Command = 'git'; VersionArg = '--version'
        Installer = 'winget'; WingetId = 'Git.Git'; Purpose = 'plugin install + bash for hooks'
    },
    @{
        Name = 'GitHub CLI'; Command = 'gh'; VersionArg = '--version'
        Installer = 'winget'; WingetId = 'GitHub.cli'; Purpose = 'sign-in + downloads'
    },
    @{
        Name = 'Docker Desktop'; Command = 'docker'; VersionArg = '--version'
        Installer = 'winget'; WingetId = 'Docker.DockerDesktop'; Optional = $true
        Purpose = 'agents only (optional)'
    }
)

function Get-ToolStatus {
    param([Parameter(Mandatory)][hashtable]$Tool)

    if (-not (Get-Command $Tool.Command -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Status = 'Missing'; Version = '' }
    }

    $probe = Invoke-Native -Exe $Tool.Command -Arguments @($Tool.VersionArg)
    $version = ''
    if ($probe.Output -match '\d+(\.\d+)+') { $version = $Matches[0] }
    # On PATH but not answering - treat as absent so it gets (re)installed.
    if ($probe.ExitCode -ne 0 -and -not $version) {
        return [pscustomobject]@{ Status = 'Missing'; Version = '' }
    }

    if ($Tool.MinMajor -and $version) {
        $major = [int](($version -split '\.')[0])
        if ($major -lt $Tool.MinMajor) {
            return [pscustomobject]@{ Status = 'Outdated'; Version = $version }
        }
    }
    return [pscustomobject]@{ Status = 'Ok'; Version = $version }
}

# The plugin's hooks are bash scripts, so Git for Windows' bash is a hard
# requirement. Returns the found bash.exe path or $null.
function Find-GitBash {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        # git.exe sits in <root>\cmd or <root>\bin; bash.exe always in <root>\bin.
        $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
        $candidate = Join-Path $gitRoot 'bin\bash.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    $roots = @{
        $env:ProgramFiles          = 'Git\bin\bash.exe'
        ${env:ProgramFiles(x86)}   = 'Git\bin\bash.exe'
        $env:LOCALAPPDATA          = 'Programs\Git\bin\bash.exe'
    }
    foreach ($root in $roots.Keys) {
        if (-not $root) { continue }
        $candidate = Join-Path $root $roots[$root]
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# $true when `bash` on PATH resolves to the Windows WSL app-execution alias
# (which shadows Git Bash and fails when no WSL distro is installed).
function Test-WslBashAlias {
    $onPath = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $onPath) { return $false }
    return ($onPath.Source -like "$env:SystemRoot\System32\bash.exe" -or $onPath.Source -like '*\WindowsApps\*')
}

# Guided fix for the WSL alias trap: opens the Settings page and re-checks
# until fixed or the user chooses to continue anyway.
function Repair-WslBashAlias {
    while (Test-WslBashAlias) {
        $source = (Get-Command bash -ErrorAction SilentlyContinue).Source
        Write-Warn2 "bash on PATH resolves to $source - that is the Windows WSL alias, not Git Bash."
        Write-Warn2 'The Polaris plugin runs its hooks through Git Bash; the WSL alias shadows it and fails without a WSL distro.'
        Write-Host  '    Fix: Settings > Apps > Advanced app settings > App execution aliases > turn OFF bash.exe.'
        if ($DryRun) { Write-Plan 'Would open the App execution aliases Settings page and re-check.'; return $false }
        $choice = Read-Choice -Prompt 'Open that Settings page now, then press Enter here after toggling? (o=open, r=re-check, s=skip)' -Options 'o','r','s' -Default 's'
        if ($choice -eq 's') {
            Write-Warn2 'Continuing with the WSL alias in place - plugin hooks may fail until it is turned off.'
            return $false
        }
        if ($choice -eq 'o') {
            Start-Process 'ms-settings:appsfeatures-app' | Out-Null
            [void](Read-Host '    Press Enter when you have turned the bash.exe alias OFF')
        }
        # 'r' (and the post-'o' path) fall through to the loop re-check.
    }
    if (Get-Command bash -ErrorAction SilentlyContinue) { Write-Ok 'bash on PATH is not the WSL alias' }
    return $true
}

function Invoke-StagePrerequisites {
    Write-Section 'Stage 1 of 6 - prerequisites'

    $probed = @()
    foreach ($tool in $Prerequisites) {
        $state = Get-ToolStatus -Tool $tool
        $probed += [pscustomobject]@{ Definition = $tool; Status = $state.Status; Version = $state.Version }
        switch ($state.Status) {
            'Ok'       { Write-Ok    "$($tool.Name) - $($state.Version)" }
            'Outdated' { Write-Warn2 "$($tool.Name) - found $($state.Version), need $($tool.MinMajor) or newer" }
            'Missing'  { Write-Warn2 "$($tool.Name) - not found" }
        }
    }

    $wingetWork = @()
    $nativeWork = @()
    foreach ($entry in $probed) {
        if ($entry.Status -eq 'Ok') { continue }
        $def = $entry.Definition
        if ($def.Optional -and -not $IncludeDocker) {
            Write-Skip "$($def.Name) - optional, pass -IncludeDocker to install it"
            continue
        }
        if ($def.Installer -eq 'native') {
            if ($SkipClaudeCode) {
                Write-Skip "$($def.Name) - skipped (-SkipClaudeCode), install it yourself: $($def.Hint)"
            } else {
                $nativeWork += $entry
            }
            continue
        }
        $wingetWork += $entry
    }

    if ($wingetWork.Count -gt 0 -and -not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install 'App Installer' from the Microsoft Store (https://aka.ms/getwinget) and re-run, or install the tools manually: Node.js https://nodejs.org, Git https://git-scm.com/download/win, GitHub CLI https://cli.github.com."
    }

    if ($DryRun) {
        if ($wingetWork.Count -eq 0 -and $nativeWork.Count -eq 0) {
            Write-Plan 'Nothing to install - every required prerequisite is already satisfied.'
        }
        foreach ($entry in $wingetWork) {
            $verb = 'install'
            if ($entry.Status -eq 'Outdated') { $verb = 'upgrade' }
            Write-Plan "winget $verb --id $($entry.Definition.WingetId) --exact --source winget --silent"
        }
        foreach ($entry in $nativeWork) {
            Write-Plan 'irm https://claude.ai/install.ps1 | iex   (Claude Code native installer, per-user)'
        }
        [void](Repair-WslBashAlias)
        Set-StageResult 'Prerequisites' 'dry-run'
        return
    }

    $restartPending = $false
    if ($wingetWork.Count -eq 0 -and $nativeWork.Count -eq 0) {
        Write-Ok 'Nothing to install'
    } else {
        if ($wingetWork.Count -gt 0) {
            Write-Section "Installing $($wingetWork.Count) package(s) with winget - approve the UAC prompts"
            foreach ($entry in $wingetWork) {
                $def = $entry.Definition
                Write-Step "$($def.Name) ($($def.WingetId))"
                $code = Invoke-WingetInstall -Id $def.WingetId -Upgrade:($entry.Status -eq 'Outdated')
                if ($code -ne 0 -and $entry.Status -eq 'Outdated') {
                    # Nothing for winget to upgrade (installed outside winget, or
                    # a different package id) - install the current package.
                    $code = Invoke-WingetInstall -Id $def.WingetId
                }
                if ($code -eq 0) {
                    Write-Ok "$($def.Name) installed"
                } elseif ($code -in @(1641, 3010)) {
                    Write-Warn2 "$($def.Name) installed - a restart is required to finish"
                    $restartPending = $true
                } else {
                    Write-Warn2 "$($def.Name) - winget exited with $code, see its output above"
                }
            }
            Write-Step 'Reloading PATH for this window'
            Update-SessionPath
        }

        foreach ($entry in $nativeWork) {
            Write-Section 'Installing Claude Code (native installer, per-user, no admin rights)'
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -UseBasicParsing | Invoke-Expression | Out-Host
            } catch {
                Write-Warn2 "Claude Code installer failed: $($_.Exception.Message)"
                Write-Warn2 'Install it manually later: irm https://claude.ai/install.ps1 | iex'
            } finally {
                $ErrorActionPreference = $prev
            }
            Update-SessionPath
            if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Ok 'Claude Code installed' }
        }
    }

    # Verify.
    Write-Section 'Verifying prerequisites'
    $rows = @()
    $blocking = @()
    $optionalMissing = @()
    foreach ($tool in $Prerequisites) {
        $state = Get-ToolStatus -Tool $tool
        $rows += [pscustomobject]@{
            Tool         = $tool.Name
            Status       = $state.Status
            Version      = $state.Version
            'Needed for' = $tool.Purpose
        }
        if ($state.Status -eq 'Ok') { continue }
        if ($tool.Optional) { $optionalMissing += $tool } else { $blocking += $tool }
    }
    $rows | Format-Table -AutoSize | Out-Host

    $gitBash = Find-GitBash
    if ($gitBash) {
        Write-Ok "Git Bash found - $gitBash"
    } else {
        Write-Warn2 'Git Bash not found - the plugin runs its hooks through bash. Install Git for Windows and re-run.'
    }
    [void](Repair-WslBashAlias)

    foreach ($tool in $blocking) {
        Write-Warn2 "$($tool.Name) is still not usable - close this window, open a NEW one and re-run this script (installers only extend PATH for new processes)."
        if ($tool.Hint) { Write-Warn2 "  manual install: $($tool.Hint)" }
    }
    if ($restartPending) {
        Write-Warn2 'Restart Windows to finish an installer that asked for it, then re-run this script.'
    }
    foreach ($tool in $optionalMissing) {
        Write-Skip "$($tool.Name) is not installed - re-run with -IncludeDocker if you want to run agents in containers."
    }

    if ($blocking.Count -gt 0) {
        Set-StageResult 'Prerequisites' 'incomplete'
        throw 'Prerequisites incomplete - see the warnings above, then re-run this script.'
    }
    Set-StageResult 'Prerequisites' 'ok'
}

# --- Stage 2: GitHub sign-in --------------------------------------------------

# Trap 1: a pre-existing GH_TOKEN/GITHUB_TOKEN environment variable overrides
# gh's stored (keyring) credentials AND a fresh browser login. Guided fix with
# a re-check loop; clearing it here affects this process and its children, but
# the variable will come back in new windows until its source (usually the
# PowerShell $PROFILE) is cleaned up.
function Repair-ShadowingToken {
    while ($true) {
        $shadowing = @()
        if (Test-Path Env:GH_TOKEN)     { $shadowing += 'GH_TOKEN' }
        if (Test-Path Env:GITHUB_TOKEN) { $shadowing += 'GITHUB_TOKEN' }
        if ($shadowing.Count -eq 0) { return $true }

        $names = $shadowing -join ' and '
        Write-Warn2 "$names is set - gh uses it instead of your browser login, and sign-in below would silently have no effect."
        Write-Warn2 'If that token cannot read polaris-ai-org/PolarisAI-dist, every download in this script fails with "not found".'

        # Point at the persistent source without ever printing file content
        # (a matched line could contain the token value).
        if ($PROFILE -and (Test-Path $PROFILE)) {
            $inProfile = Select-String -Path $PROFILE -Pattern 'GH_TOKEN|GITHUB_TOKEN' -Quiet
            if ($inProfile) {
                Write-Warn2 "Your PowerShell profile sets it persistently - remove that line from: $PROFILE"
            }
        }

        if ($DryRun) { Write-Plan "Would offer to clear $names for this session and re-check."; return $false }
        $choice = Read-Choice -Prompt 'Clear it for this session (recommended), keep using it, or re-check? (c=clear, k=keep, r=re-check)' -Options 'c','k','r' -Default 'c'
        if ($choice -eq 'c') {
            foreach ($name in $shadowing) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
            Write-Ok "$names cleared for this session (new windows still have it until the profile line is removed)"
            return $true
        }
        if ($choice -eq 'k') {
            $status = Invoke-Native -Exe 'gh' -Arguments @('auth', 'status')
            if ($status.ExitCode -eq 0) {
                Write-Ok "gh accepts the existing $names - continuing with it"
                Write-Warn2 'Note: a fine-grained PAT cannot authenticate to GHCR (Docker agents) - only a browser login or a classic read:packages PAT can.'
                return $true
            }
            Write-Warn2 "gh cannot authenticate with the existing $names - it looks stale or invalid."
            # Loop: show the choices again.
        }
        # 'r' loops and re-checks.
    }
}

# Trap 2: a fine-grained PAT (github_pat_...) works for repo reads but cannot
# authenticate to GHCR, and `gh auth refresh` cannot add scopes to it. Only the
# token's SHAPE is inspected; the value is never printed or persisted.
function Test-FineGrainedPat {
    $probe = Invoke-Native -Exe 'gh' -Arguments @('auth', 'token')
    if ($probe.ExitCode -ne 0) { return $false }
    $isFineGrained = $probe.Output.Trim() -like 'github_pat_*'
    $probe = $null
    return $isFineGrained
}

function Invoke-StageGitHubAuth {
    Write-Section 'Stage 2 of 6 - GitHub sign-in'

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warn2 'gh is not available - complete stage 1 first (new window if it was just installed).'
        Set-StageResult 'GitHub sign-in' 'skipped (gh missing)'
        return $false
    }

    if ($DryRun) {
        Write-Plan 'Check for a shadowing GH_TOKEN/GITHUB_TOKEN (guided fix if set).'
        Write-Plan 'gh auth login --web --hostname github.com --git-protocol https --scopes "read:packages"  (skipped when already signed in)'
        Write-Plan 'gh auth setup-git'
        Write-Plan 'gh auth token | docker login ghcr.io --password-stdin  (only when Docker is present and running)'
        $status = Invoke-Native -Exe 'gh' -Arguments @('auth', 'status')
        if ($status.ExitCode -eq 0) { Write-Ok 'gh is already signed in' } else { Write-Plan 'gh is not signed in yet - the browser device flow would run.' }
        Set-StageResult 'GitHub sign-in' 'dry-run'
        return ($status.ExitCode -eq 0)
    }

    if (-not (Repair-ShadowingToken)) {
        Write-Warn2 'Continuing with the shadowing token in place.'
    }

    # Sign-in with a re-check loop: after every attempt the status is probed
    # again, and the user can retry until it works or chooses to move on.
    $attempts = 0
    while ($true) {
        $status = Invoke-Native -Exe 'gh' -Arguments @('auth', 'status')
        if ($status.ExitCode -eq 0) { break }
        if ($attempts -ge 3) {
            Write-Warn2 'GitHub sign-in still failing after several attempts.'
            $choice = Read-Choice -Prompt 'Try again or continue without GitHub? (t=try again, c=continue)' -Options 't','c' -Default 'c'
            if ($choice -eq 'c') {
                Write-Warn2 'Continuing without GitHub - the plugin and Dashboard stages will print manual instructions instead of installing.'
                Set-StageResult 'GitHub sign-in' 'failed'
                return $false
            }
            $attempts = 0
        }
        Write-Step 'A browser opens to github.com/login/device - approve the code it shows.'
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # Out-Host keeps gh's output on the console instead of leaking it
            # into this function's return value.
            gh auth login --web --hostname github.com --git-protocol https --scopes "read:packages" | Out-Host
        } finally {
            $ErrorActionPreference = $prev
        }
        $attempts++
    }
    Write-Ok 'gh is signed in'

    # Scope check: read:packages is what GHCR needs later.
    $status = Invoke-Native -Exe 'gh' -Arguments @('auth', 'status')
    if ($status.Output -notmatch 'read:packages') {
        if (Test-FineGrainedPat) {
            Write-Warn2 'Your gh login is a fine-grained personal access token. It can read the dist repo, but it CANNOT authenticate to GHCR (Docker agents), and scopes cannot be added to it.'
            $choice = Read-Choice -Prompt 'Replace it with a browser sign-in now? (y=yes, n=no, keep the PAT)' -Options 'y','n' -Default 'n'
            if ($choice -eq 'y') {
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    gh auth login --web --hostname github.com --git-protocol https --scopes "read:packages" | Out-Host
                } finally {
                    $ErrorActionPreference = $prev
                }
                if (Test-FineGrainedPat) { Write-Warn2 'Still using the fine-grained PAT - agents will need a browser login later.' }
                else { Write-Ok 'Browser sign-in replaced the fine-grained PAT' }
            } else {
                Write-Warn2 'Keeping the PAT - fine for the plugin and Dashboard; re-run this script before using Docker agents.'
            }
        } else {
            Write-Step 'Adding the read:packages scope (needed later for the agent image).'
            $refresh = Invoke-Native -Exe 'gh' -Arguments @('auth', 'refresh', '--hostname', 'github.com', '--scopes', 'read:packages')
            if ($refresh.ExitCode -eq 0) { Write-Ok 'read:packages scope added' }
            else { Write-Warn2 'Could not add read:packages - Docker agents will need it; everything else works without it.' }
        }
    }

    # Wire git-over-HTTPS to the gh token so the plugin install is silent.
    $setupGit = Invoke-Native -Exe 'gh' -Arguments @('auth', 'setup-git')
    if ($setupGit.ExitCode -eq 0) { Write-Ok 'git is wired to the gh sign-in (gh auth setup-git)' }
    else { Write-Warn2 'gh auth setup-git failed - git may pop up password prompts during the plugin install.' }

    # Access probe: is this account actually invited to the dist repo yet?
    $repoProbe = Invoke-Native -Exe 'gh' -Arguments @('api', "repos/$DistRepo", '--jq', '.full_name')
    if ($repoProbe.ExitCode -eq 0) {
        Write-Ok "Access to $DistRepo confirmed"
    } else {
        Write-Warn2 "This GitHub account cannot see $DistRepo yet."
        Write-Warn2 'Ask the maintainer for Read access (send your GitHub username), accept the email invite, then re-run this script.'
    }

    # GHCR (agents). Same token; needs Docker present and its daemon running.
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Step 'Signing Docker in to ghcr.io (agent image)'
        $daemon = Invoke-Native -Exe 'docker' -Arguments @('info')
        if ($daemon.ExitCode -ne 0) {
            Write-Warn2 'Docker daemon not reachable - start Docker Desktop and re-run this script if you plan to run agents.'
        } else {
            $ghUser = (Invoke-Native -Exe 'gh' -Arguments @('api', 'user', '--jq', '.login')).Output.Trim()
            if ([string]::IsNullOrWhiteSpace($ghUser)) {
                Write-Warn2 'Could not resolve your GitHub login - skipping the GHCR sign-in.'
            } else {
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    (gh auth token) | docker login ghcr.io -u $ghUser --password-stdin | Out-Host
                    if ($LASTEXITCODE -eq 0) { Write-Ok "Docker signed in to ghcr.io as $ghUser" }
                    else { Write-Warn2 'docker login ghcr.io failed - a fine-grained PAT cannot log in to GHCR; use the browser sign-in. Agents need this, nothing else does.' }
                } finally {
                    $ErrorActionPreference = $prev
                }
            }
        }
    } else {
        Write-Skip 'docker not installed - GHCR sign-in skipped (only needed for agents in containers)'
    }

    Set-StageResult 'GitHub sign-in' 'ok'
    return $true
}

# --- Stage 3: Polaris plugin --------------------------------------------------

function Invoke-StagePlugin {
    param([bool]$GitHubOk)
    Write-Section 'Stage 3 of 6 - Polaris plugin'

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Warn2 'claude is not available in this window - open a NEW window after stage 1 and re-run, or install inside Claude Code:'
        Write-Host  "      /plugin marketplace add $DistRepoUrl"
        Write-Host  '      /plugin install polaris'
        Set-StageResult 'Polaris plugin' 'skipped (claude missing)'
        return
    }
    if (-not $GitHubOk) {
        Write-Warn2 'GitHub sign-in did not complete - the plugin lives in a private repo, so the install would fail.'
        Write-Warn2 'After fixing the sign-in, re-run this script or run inside Claude Code:'
        Write-Host  "      /plugin marketplace add $DistRepoUrl"
        Write-Host  '      /plugin install polaris'
        Set-StageResult 'Polaris plugin' 'skipped (no GitHub sign-in)'
        return
    }

    if ($DryRun) {
        Write-Plan "claude plugin marketplace add $DistRepoUrl"
        Write-Plan "claude plugin install $PluginSpec"
        Set-StageResult 'Polaris plugin' 'dry-run'
        return
    }

    # Both commands are idempotent from this script's perspective: an
    # already-registered marketplace / already-installed plugin is a skip, not
    # an error.
    Write-Step "Registering the marketplace ($DistRepoUrl)"
    $add = Invoke-Native -Exe 'claude' -Arguments @('plugin', 'marketplace', 'add', $DistRepoUrl)
    if ($add.ExitCode -eq 0) {
        Write-Ok 'Marketplace registered'
    } elseif ($add.Output -match 'already') {
        Write-Skip 'Marketplace already registered'
    } else {
        Write-Warn2 "claude plugin marketplace add failed: $($add.Output.Trim())"
        Write-Warn2 "Most common cause: no Read access to $DistRepo yet (stage 2 prints how to get it)."
        Set-StageResult 'Polaris plugin' 'failed (marketplace add)'
        return
    }

    Write-Step "Installing the plugin ($PluginSpec)"
    $install = Invoke-Native -Exe 'claude' -Arguments @('plugin', 'install', $PluginSpec)
    if ($install.ExitCode -eq 0) {
        Write-Ok 'Polaris plugin installed - it loads at the next Claude Code session start'
    } elseif ($install.Output -match 'already') {
        Write-Skip 'Polaris plugin already installed'
    } else {
        Write-Warn2 "claude plugin install failed: $($install.Output.Trim())"
        Write-Warn2 'Run it inside Claude Code instead: /plugin install polaris'
        Set-StageResult 'Polaris plugin' 'failed (install)'
        return
    }
    Set-StageResult 'Polaris plugin' 'ok'
}

# --- Stage 4: Dashboard -------------------------------------------------------

function Get-InstalledDashboardVersion {
    foreach ($exe in @($VelopackExePath, (Join-Path $LegacyInstallDir $LegacyExeName))) {
        if (-not (Test-Path $exe)) { continue }
        try {
            $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
            if ($version) { return [pscustomobject]@{ Path = $exe; Version = ($version -split '\+')[0].Trim() } }
        } catch { }
        return [pscustomobject]@{ Path = $exe; Version = $null }
    }
    return $null
}

function New-DesktopShortcut {
    param([Parameter(Mandatory)][string]$TargetPath)
    try {
        $desktop = [Environment]::GetFolderPath('DesktopDirectory')
        $lnkPath = Join-Path $desktop $ShortcutName
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = $TargetPath
        $shortcut.WorkingDirectory = (Split-Path $TargetPath -Parent)
        $shortcut.Save()
        Write-Ok "Desktop shortcut created - $lnkPath"
    } catch {
        Write-Warn2 "Could not create the desktop shortcut: $($_.Exception.Message)"
    }
}

function Invoke-StageDashboard {
    param([bool]$GitHubOk)
    Write-Section 'Stage 4 of 6 - Polaris Dashboard'

    if ($SkipDashboard) {
        Write-Skip 'Skipped (-SkipDashboard)'
        Set-StageResult 'Dashboard' 'skipped'
        return
    }
    if (-not $GitHubOk -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warn2 'GitHub sign-in did not complete - the Dashboard release lives in the private dist repo.'
        Write-Warn2 'After fixing the sign-in, re-run this script (or, with the plugin installed, run /polaris:update-dashboard --apply inside Claude Code).'
        Set-StageResult 'Dashboard' 'skipped (no GitHub sign-in)'
        return
    }

    # Latest release tag (mirrors the plugin's own update check).
    $latest = Invoke-Native -Exe 'gh' -Arguments @('release', 'list', '--repo', $DistRepo, '--limit', '1', '--json', 'tagName', '--jq', '.[0].tagName')
    $latestTag = $latest.Output.Trim()
    if ($latest.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($latestTag)) {
        Write-Warn2 "Could not read the latest release of $DistRepo - check access (stage 2) and network, then re-run."
        Set-StageResult 'Dashboard' 'failed (release lookup)'
        return
    }
    $latestVersion = $latestTag.TrimStart('v')
    Write-Ok "Latest release: $latestTag"

    $installed = Get-InstalledDashboardVersion
    if ($installed -and $installed.Version -eq $latestVersion) {
        Write-Ok "Dashboard $($installed.Version) is already current - $($installed.Path)"
        Set-StageResult 'Dashboard' 'ok (already current)'
        return
    }
    if ($installed) {
        $shown = $installed.Version
        if (-not $shown) { $shown = 'unknown version' }
        Write-Step "Installed: $shown - updating to $latestVersion"
    }

    if ($DryRun) {
        Write-Plan "gh release download $latestTag --repo $DistRepo -p '$SetupAssetPattern'  (Setup package, preferred)"
        Write-Plan "Setup would run per-user and silent ($SetupSilentArg)."
        Write-Plan "Fallback for releases without a Setup package: gh release download -p '$LegacyExeName' to $LegacyInstallDir + desktop shortcut."
        Set-StageResult 'Dashboard' 'dry-run'
        return
    }

    $tempDir = Join-Path $env:TEMP ("polaris-install-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        # Preferred path: the Velopack Setup package (per-user install with an
        # Apps & Features entry, uninstaller, and in-app delta updates).
        Write-Step "Downloading the Setup package from $latestTag"
        $dl = Invoke-Native -Exe 'gh' -Arguments @('release', 'download', $latestTag, '--repo', $DistRepo, '-p', $SetupAssetPattern, '-D', $tempDir)
        $setupExe = Get-ChildItem -Path $tempDir -Filter '*Setup.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($setupExe) {
            Write-Step "Running $($setupExe.Name) (per-user, silent - no admin prompt)"
            $proc = Start-Process -FilePath $setupExe.FullName -ArgumentList $SetupSilentArg -Wait -PassThru
            if ($proc.ExitCode -eq 0) {
                Write-Ok 'Dashboard installed (Apps & Features: Polaris AI Dashboard)'
                Set-StageResult 'Dashboard' 'ok (Setup package)'
            } else {
                Write-Warn2 "Setup exited with $($proc.ExitCode) - re-run it manually from $($setupExe.FullName) to see its output."
                Set-StageResult 'Dashboard' "failed (Setup exit $($proc.ExitCode))"
            }
            return
        }

        # Fallback: releases that predate the Setup package ship a plain EXE.
        Write-Skip "No Setup package on $latestTag - falling back to the plain-EXE install"
        $dl = Invoke-Native -Exe 'gh' -Arguments @('release', 'download', $latestTag, '--repo', $DistRepo, '-p', $LegacyExeName, '-D', $tempDir)
        $plainExe = Join-Path $tempDir $LegacyExeName
        if ($dl.ExitCode -ne 0 -or -not (Test-Path $plainExe)) {
            Write-Warn2 "Could not download $LegacyExeName from $latestTag - $($dl.Output.Trim())"
            Set-StageResult 'Dashboard' 'failed (download)'
            return
        }

        # Best-effort integrity check against the release's SHA256SUMS.
        $sums = Invoke-Native -Exe 'gh' -Arguments @('release', 'download', $latestTag, '--repo', $DistRepo, '-p', 'SHA256SUMS', '-D', $tempDir)
        $sumsFile = Join-Path $tempDir 'SHA256SUMS'
        if ($sums.ExitCode -eq 0 -and (Test-Path $sumsFile)) {
            $expected = $null
            foreach ($line in (Get-Content $sumsFile)) {
                if ($line -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($LegacyExeName))\s*$") { $expected = $Matches[1]; break }
            }
            if ($expected) {
                $actual = (Get-FileHash -LiteralPath $plainExe -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -ne $expected) {
                    Write-Warn2 'Downloaded EXE does not match SHA256SUMS - aborting the Dashboard install. Re-run to retry.'
                    Set-StageResult 'Dashboard' 'failed (checksum mismatch)'
                    return
                }
                Write-Ok 'SHA256 checksum verified'
            }
        }

        New-Item -ItemType Directory -Path $LegacyInstallDir -Force | Out-Null
        $finalPath = Join-Path $LegacyInstallDir $LegacyExeName
        Move-Item -LiteralPath $plainExe -Destination $finalPath -Force
        Write-Ok "Dashboard installed - $finalPath"
        New-DesktopShortcut -TargetPath $finalPath
        Write-Skip 'Agent host not installed on this path - the Dashboard repairs it on demand (or run /polaris:update-dashboard --apply).'
        Set-StageResult 'Dashboard' 'ok (plain EXE)'
    } finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Stage 5: Claude (Anthropic) sign-in --------------------------------------

# Policy (C063, settled 2026-08-07): detect, guide, decouple. The person
# running this installer is often not the person with the Anthropic seat, so
# machine setup NEVER hard-fails on a missing sign-in - Claude Code asks again
# on first use. Credentials are checked for PRESENCE only; values are never
# read into variables, printed, or persisted.
function Invoke-StageAnthropicSignIn {
    Write-Section 'Stage 5 of 6 - Claude sign-in (optional today, needed on first use)'

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Skip 'claude is not available in this window - sign-in happens on first use instead.'
        Set-StageResult 'Claude sign-in' 'deferred to first use'
        return
    }

    $envCredential = $null
    if (Test-Path Env:ANTHROPIC_API_KEY)        { $envCredential = 'ANTHROPIC_API_KEY' }
    elseif (Test-Path Env:CLAUDE_CODE_OAUTH_TOKEN) { $envCredential = 'CLAUDE_CODE_OAUTH_TOKEN' }
    if ($envCredential) {
        Write-Ok "$envCredential is set - Claude Code will use it (value not checked or shown)."
    }

    if ($DryRun) {
        if (-not $envCredential) { Write-Plan 'No ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN in the environment.' }
        Write-Plan 'Would probe authentication with a minimal claude -p call and, if unauthenticated, offer a guided browser sign-in (never required).'
        Set-StageResult 'Claude sign-in' 'dry-run'
        return
    }

    # Cheap probe: an unauthenticated claude -p exits non-zero with sign-in
    # guidance; an authenticated one answers. Nothing here parses or stores
    # credentials.
    Write-Step 'Probing Claude authentication (one tiny request)'
    $probe = Invoke-Native -Exe 'claude' -Arguments @('-p', 'Reply with the single word ok')
    if ($probe.ExitCode -eq 0) {
        Write-Ok 'Claude is signed in and working.'
        Set-StageResult 'Claude sign-in' 'ok'
        return
    }

    Write-Warn2 'Claude is not signed in yet on this account/machine.'
    Write-Host  '    Signing in is a browser flow inside Claude Code (an Anthropic account with Claude access is needed).'
    Write-Host  '    If someone else will use this machine, skip - Claude asks them on their first use.'
    $choice = Read-Choice -Prompt 'Sign in now? (y=launch Claude Code for sign-in, n=later)' -Options 'y','n' -Default 'n'
    if ($choice -eq 'y') {
        Write-Step 'Launching Claude Code - complete the sign-in it offers, then leave it with /exit'
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & claude
        } finally {
            $ErrorActionPreference = $prev
        }
        $reprobe = Invoke-Native -Exe 'claude' -Arguments @('-p', 'Reply with the single word ok')
        if ($reprobe.ExitCode -eq 0) {
            Write-Ok 'Claude sign-in verified.'
            Set-StageResult 'Claude sign-in' 'ok'
            return
        }
        Write-Warn2 'Still not signed in - no problem, Claude asks again on first use.'
    } else {
        Write-Skip 'Sign-in deferred - Claude asks on first use.'
    }
    Set-StageResult 'Claude sign-in' 'deferred to first use'
}

# --- Stage 6: finish ----------------------------------------------------------

function Invoke-StageFinish {
    Write-Section 'Stage 6 of 6 - done'

    $script:StageResults | Format-Table -AutoSize | Out-Host

    $installed = Get-InstalledDashboardVersion
    if ($installed) {
        Write-Host  '    Open the Polaris Dashboard to continue.'
        Write-Host  "      Start menu / desktop: Polaris AI Dashboard   (or: $($installed.Path))"
        if (-not $DryRun) {
            $choice = Read-Choice -Prompt 'Open the Polaris Dashboard now? (y/n)' -Options 'y','n' -Default 'n'
            if ($choice -eq 'y') { Start-Process -FilePath $installed.Path | Out-Null }
        }
    } else {
        Write-Host '    The Dashboard is not installed yet - re-run this script once the warnings above are fixed.'
    }

    Write-Host ''
    Write-Host '    Working from the command line instead? In a Claude Code session inside your repo:'
    Write-Host '      /healthcheck        # should be all green'
    Write-Host '      /initial-planning   # first time in a repo: solution bootstrap + first workspace'
    Write-Host '      /moin               # start a normal working session'
    Write-Host ''
    Write-Host 'Polaris install finished.' -ForegroundColor Green
}

# --- Main ---------------------------------------------------------------------

# $IsWindows only exists from PowerShell 6 on; 5.1 is Windows by definition.
$onWindows = $true
if ($PSVersionTable.PSVersion.Major -ge 6) { $onWindows = $IsWindows }

if (-not $onWindows) {
    Write-Section 'Not Windows - manual install'
    Write-Host '    macOS   : brew install node git gh          (agents: brew install --cask docker)'
    Write-Host '              curl -fsSL https://claude.ai/install.sh | bash'
    Write-Host '    Debian  : sudo apt install -y git gh        (Node 18+: nodesource or nvm)'
    Write-Host '              curl -fsSL https://claude.ai/install.sh | bash'
    Write-Host ''
    Write-Host '    Then: gh auth login --web --git-protocol https --scopes "read:packages"'
    Write-Host '          gh auth setup-git'
    Write-Host "          claude plugin marketplace add $DistRepoUrl"
    Write-Host '          claude plugin install polaris'
    Write-Host ''
    Write-Host '    The Dashboard is Windows-only today.'
    return
}

$modeSuffix = ''
if ($DryRun) { $modeSuffix = ' (dry run - nothing will be changed)' }
Write-Host ''
Write-Host "Polaris AI installer $script:BootstrapVersion$modeSuffix" -ForegroundColor Cyan
Write-Host 'Six stages: prerequisites, GitHub sign-in, plugin, Dashboard, Claude sign-in, finish.'
Write-Host 'Idempotent - re-running skips whatever is already done.'

Invoke-StagePrerequisites
$gitHubOk = Invoke-StageGitHubAuth
Invoke-StagePlugin -GitHubOk $gitHubOk
Invoke-StageDashboard -GitHubOk $gitHubOk
if ($SkipAnthropicSignIn) {
    Write-Section 'Stage 5 of 6 - Claude sign-in'
    Write-Skip 'Skipped (-SkipAnthropicSignIn) - Claude asks on first use.'
    Set-StageResult 'Claude sign-in' 'skipped'
} else {
    Invoke-StageAnthropicSignIn
}
Invoke-StageFinish
