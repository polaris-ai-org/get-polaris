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
                          its native installer. Verifies Git Bash and reports
                          which of the two Windows bash.exe shadows (if any)
                          sits in front of it on PATH.
      2. GitHub sign-in - one browser device-flow login, `gh auth setup-git`,
                          and (when Docker is present) GHCR. Known traps -
                          a shadowing GH_TOKEN, a fine-grained PAT, the WSL
                          bash app execution alias - get guided fixes with a
                          re-check loop.
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

# Windows PowerShell decodes native-tool stdout per [Console]::OutputEncoding,
# which defaults to the OEM codepage - UTF-8 symbols from piped tools (the
# Claude installer's checkmarks/arrows, winget's block glyphs) degrade into
# O-circumflex mojibake sequences (v3.0.2 bare-machine field report). UTF-8 is
# PowerShell 7's default anyway; intentionally not restored on exit.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

# Stamped by the release pipeline; 'dev' when run from a working tree.
$script:BootstrapVersion = '3.1.1'

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

# Anthropic's native Claude Code installer drops claude.exe into ~\.local\bin
# but does NOT persist that directory to the user PATH - its own closing hint
# says to add it via System Properties. Update-SessionPath covers only THIS
# window, so every NEW terminal lost `claude` again: on the v3.1.0 bare-machine
# run the Setup Doctor's terminal handoff broke on a fresh terminal, and each
# re-run of this script re-ran the whole native installer. Persist the entry
# ourselves - carefully, the user Path value is a known Windows footgun:
#   * read it RAW (DoNotExpandEnvironmentNames) so existing %VAR% entries
#     survive the round-trip,
#   * write it back preserving the registry value kind - never
#     [Environment]::SetEnvironmentVariable('Path', ..., 'User'), which
#     rewrites REG_EXPAND_SZ as REG_SZ and kills %VAR% expansion, and never
#     setx, which truncates at 1024 characters,
#   * broadcast WM_SETTINGCHANGE so windows opened after this see the change.
function Add-UserPathEntry {
    param([Parameter(Mandatory)][string]$Directory)

    $envKey = Get-Item 'HKCU:\Environment'
    $rawPath = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

    # Idempotence: compare case-insensitively, tolerate a trailing backslash,
    # and accept the literal form as well as a %USERPROFILE% spelling.
    $wanted = $Directory.TrimEnd('\')
    $wantedAsVar = $null
    $profileRoot = "$env:USERPROFILE".TrimEnd('\')
    if ($profileRoot -and $wanted.StartsWith($profileRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $wantedAsVar = '%USERPROFILE%' + $wanted.Substring($profileRoot.Length)
    }
    foreach ($rawEntry in ($rawPath -split ';')) {
        $entry = $rawEntry.Trim().TrimEnd('\')
        if (-not $entry) { continue }
        if ($entry -eq $wanted -or ($wantedAsVar -and $entry -eq $wantedAsVar) -or
            ([Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\') -eq $wanted)) {
            Write-Skip "$Directory is already in the user PATH"
            return
        }
    }

    if ($DryRun) {
        Write-Plan "Would append $Directory to the user Path in the registry (persists for new windows)."
        return
    }

    $newPath = $wanted
    if (-not [string]::IsNullOrWhiteSpace($rawPath)) { $newPath = $rawPath.TrimEnd(';') + ';' + $wanted }

    # Preserve REG_EXPAND_SZ; a value carrying %VAR% entries must stay (or
    # become) expandable or those entries turn into dead literals.
    $kind = [Microsoft.Win32.RegistryValueKind]::String
    if (($envKey.GetValueNames() -contains 'Path' -and $envKey.GetValueKind('Path') -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) -or
        $newPath -like '*%*') {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    }
    Set-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -Value $newPath -Type $kind
    Write-Ok "$Directory added to the user PATH (new terminals will see it)"

    # Nudge running apps (Explorer above all) to reload the environment so
    # terminals spawned from the taskbar/Start menu pick the new PATH up
    # without a sign-out. Best effort: a hung window must not fail the install.
    try {
        if (-not ('PolarisBootstrap.NativeMethods' -as [type])) {
            Add-Type -Namespace PolarisBootstrap -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5 s timeout.
        [void][PolarisBootstrap.NativeMethods]::SendMessageTimeout([IntPtr]0xFFFF, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
    } catch {
        Write-Warn2 "Environment-change broadcast failed ($($_.Exception.Message)) - already-open apps keep the old PATH; new sign-ins see the new one."
    }
}

function Out-WingetLine {
    # winget animates a spinner (- \ | /) and a block-glyph progress bar via
    # bare carriage-return redraws. Piped (as below), every redraw frame lands
    # as its own line - hundreds of junk lines per package (v3.0.2 bare-machine
    # field report). --disable-interactivity does NOT suppress the animations
    # (verified against winget 1.11), so filter the frames out of the pipeline:
    # drop lines that are only whitespace/spinner glyphs and lines carrying the
    # bar's block characters; every informative winget line passes through.
    process {
        $line = "$_"
        if ($line -match '^[\s\\|/-]*$') { return }
        # Bar glyphs: FULL BLOCK U+2588, LIGHT SHADE U+2591, MEDIUM SHADE
        # U+2592 - .NET regex unicode escapes keep this file pure ASCII.
        if ($line -match '[\u2588\u2591\u2592]') { return }
        Out-Host -InputObject $line
    }
}

function Invoke-WingetInstall {
    param([Parameter(Mandatory)][string]$Id, [switch]$Upgrade)

    $verb = 'install'
    if ($Upgrade) { $verb = 'upgrade' }
    $wingetArgs = @($verb, '--id', $Id, '--exact', '--source', 'winget',
                    '--accept-source-agreements', '--accept-package-agreements',
                    # Suppresses interactive PROMPTS (not the animations - see
                    # Out-WingetLine for those). Exists since winget 1.4 (2023).
                    '--disable-interactivity')

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        winget @wingetArgs --silent | Out-WingetLine
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            # Some installers refuse an unattended run - retry showing their UI.
            Write-Warn2 "winget $verb --silent exited with $code - retrying with the installer UI"
            winget @wingetArgs | Out-WingetLine
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
        # Where the native installer puts the exe - probed when PATH lacks it.
        KnownPath = (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
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

    $exe = $Tool.Command
    $status = 'Ok'
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        # Off PATH is not the same as not installed: Claude Code's native
        # installer leaves ~\.local\bin unpersisted (see Add-UserPathEntry),
        # so every fresh window used to land here, report "not found" and
        # re-run the whole installer (v3.1.0 bare-machine field report).
        # Probe the known install location by absolute path instead; the
        # caller repairs PATH rather than reinstalling. Indexer access - see
        # the MinMajor note below.
        $known = $Tool['KnownPath']
        if (-not ($known -and (Test-Path -LiteralPath $known))) {
            return [pscustomobject]@{ Status = 'Missing'; Version = '' }
        }
        $exe = $known
        $status = 'NotOnPath'
    }

    $probe = Invoke-Native -Exe $exe -Arguments @($Tool.VersionArg)
    $version = ''
    if ($probe.Output -match '\d+(\.\d+)+') { $version = $Matches[0] }
    # Present but not answering - treat as absent so it gets (re)installed.
    if ($probe.ExitCode -ne 0 -and -not $version) {
        return [pscustomobject]@{ Status = 'Missing'; Version = '' }
    }

    # Indexer, not member access: only the Node entry defines MinMajor, and a
    # leaked Set-StrictMode (see the Claude-installer containment note) turns
    # $Tool.MinMajor on the other entries into PropertyNotFoundStrict.
    if ($Tool['MinMajor'] -and $version) {
        $major = [int](($version -split '\.')[0])
        if ($major -lt $Tool['MinMajor']) {
            return [pscustomobject]@{ Status = 'Outdated'; Version = $version }
        }
    }
    return [pscustomobject]@{ Status = $status; Version = $version }
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

# Classifies what a bare `bash` on PATH resolves to. Windows ships two very
# different bash.exe shadows and only one of them is fixable from Settings:
#   AppAlias    - %LOCALAPPDATA%\Microsoft\WindowsApps\bash.exe, the WSL app
#                 execution alias. The Settings toggle deletes this stub.
#   WslLauncher - %SystemRoot%\System32\bash.exe, the "Microsoft Bash Launcher"
#                 hardlinked out of WinSxS by the Windows Subsystem for Linux
#                 optional feature. The Settings toggle does NOT touch it, and
#                 the feature itself cannot simply be turned off on machines
#                 whose Docker Desktop runs on the WSL2 backend.
function Get-PathBashKind {
    $onPath = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $onPath) { return 'None' }
    if ($onPath.Source -like '*\WindowsApps\*') { return 'AppAlias' }
    if ($onPath.Source -like "$env:SystemRoot\System32\bash.exe") { return 'WslLauncher' }
    return 'Other'
}

# Handles a shadowed `bash`. Only the app execution alias gets the guided
# Settings fix with a re-check loop - pointing a WslLauncher machine at that
# toggle produces a loop that can never clear, because the toggle does not own
# that file. WslLauncher is informational instead: both Polaris consumers reach
# Git Bash by absolute path anyway (Claude Code prepends Git's bin directories
# to PATH inside its own sessions, and the Dashboard's ShellPathResolver probes
# %ProgramFiles%\Git\bin\bash.exe before it ever consults PATH), so the shadow
# only matters when Git Bash is genuinely absent.
function Repair-BashShadowing {
    param([string]$GitBashPath = (Find-GitBash))

    while ((Get-PathBashKind) -eq 'AppAlias') {
        $source = (Get-Command bash -ErrorAction SilentlyContinue).Source
        Write-Warn2 "bash on PATH resolves to $source - that is the WSL app execution alias, not Git Bash."
        Write-Warn2 'The Polaris plugin runs its hooks through Git Bash; the alias shadows it and fails without a WSL distro.'
        Write-Host  '    Fix: Settings > Apps > Advanced app settings > App execution aliases > turn OFF bash.exe.'
        if ($DryRun) { Write-Plan 'Would open the App execution aliases Settings page and re-check.'; return $false }
        $choice = Read-Choice -Prompt 'Open that Settings page now, then press Enter here after toggling? (o=open, r=re-check, s=skip)' -Options 'o','r','s' -Default 's'
        if ($choice -eq 's') {
            Write-Warn2 'Continuing with the alias in place - plugin hooks may fail until it is turned off.'
            return $false
        }
        if ($choice -eq 'o') {
            Start-Process 'ms-settings:appsfeatures-app' | Out-Null
            [void](Read-Host '    Press Enter when you have turned the bash.exe alias OFF')
        }
        # 'r' (and the post-'o' path) fall through to the loop re-check.
    }

    switch (Get-PathBashKind) {
        'WslLauncher' {
            if (-not $GitBashPath) {
                Write-Warn2 "bash on PATH is $env:SystemRoot\System32\bash.exe - the WSL launcher, which fails without a WSL distro - and Git Bash was not found."
                Write-Warn2 'Install Git for Windows (https://git-scm.com/download/win) and re-run; the plugin hooks need a real bash.'
                return $false
            }
            Write-Ok "bash on PATH is the WSL launcher, but Polaris uses $GitBashPath directly - nothing to fix."
            Write-Skip 'That System32\bash.exe belongs to the Windows Subsystem for Linux feature; the App execution aliases toggle does not remove it.'
            return $true
        }
        'None' {
            if (-not $GitBashPath) {
                Write-Warn2 'No bash on PATH and no Git Bash found - install Git for Windows and re-run.'
                return $false
            }
            Write-Ok "No bash on PATH, but Polaris uses $GitBashPath directly - nothing to fix."
            return $true
        }
        default {
            Write-Ok 'bash on PATH is not a WSL shadow'
            return $true
        }
    }
}

function Invoke-StagePrerequisites {
    Write-Section 'Stage 1 of 6 - prerequisites'

    $probed = @()
    foreach ($tool in $Prerequisites) {
        $state = Get-ToolStatus -Tool $tool
        $probed += [pscustomobject]@{ Definition = $tool; Status = $state.Status; Version = $state.Version }
        switch ($state.Status) {
            'Ok'        { Write-Ok    "$($tool.Name) - $($state.Version)" }
            'Outdated'  { Write-Warn2 "$($tool.Name) - found $($state.Version), need $($tool.MinMajor) or newer" }
            'NotOnPath' { Write-Warn2 "$($tool.Name) - installed ($($state.Version)) but not on PATH" }
            'Missing'   { Write-Warn2 "$($tool.Name) - not found" }
        }
    }

    $wingetWork = @()
    $nativeWork = @()
    $pathRepairWork = @()
    foreach ($entry in $probed) {
        if ($entry.Status -eq 'Ok') { continue }
        $def = $entry.Definition
        if ($entry.Status -eq 'NotOnPath') {
            # On disk, only PATH is broken - reinstalling would change nothing
            # (the installer leaves PATH unpersisted); repair the PATH instead.
            $pathRepairWork += $entry
            continue
        }
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
        if ($wingetWork.Count -eq 0 -and $nativeWork.Count -eq 0 -and $pathRepairWork.Count -eq 0) {
            Write-Plan 'Nothing to install - every required prerequisite is already satisfied.'
        }
        foreach ($entry in $wingetWork) {
            $verb = 'install'
            if ($entry.Status -eq 'Outdated') { $verb = 'upgrade' }
            Write-Plan "winget $verb --id $($entry.Definition.WingetId) --exact --source winget --silent"
        }
        foreach ($entry in $nativeWork) {
            Write-Plan 'irm https://claude.ai/install.ps1 | iex   (Claude Code native installer, per-user)'
            Write-Plan "Would then persist $(Join-Path $env:USERPROFILE '.local\bin') to the user PATH (the native installer does not)."
        }
        foreach ($entry in $pathRepairWork) {
            Write-Plan "$($entry.Definition.Name) is installed but not on PATH - would repair PATH instead of reinstalling:"
            Add-UserPathEntry -Directory (Split-Path $entry.Definition['KnownPath'] -Parent)
        }
        [void](Repair-BashShadowing)
        Set-StageResult 'Prerequisites' 'dry-run'
        return
    }

    $restartPending = $false
    if ($wingetWork.Count -eq 0 -and $nativeWork.Count -eq 0 -and $pathRepairWork.Count -eq 0) {
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
                # Contained in a child scope on purpose: Anthropic's installer
                # calls Set-StrictMode, and Invoke-Expression would apply that
                # to THIS scope - the verify pass below then dies on the first
                # hashtable member-miss (PropertyNotFoundStrict on MinMajor,
                # v3.0.2 bare-machine field report). Invoking a scriptblock
                # keeps their strict mode inside their own scope.
                $claudeInstaller = Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -UseBasicParsing
                & ([scriptblock]::Create($claudeInstaller)) | Out-Host
            } catch {
                Write-Warn2 "Claude Code installer failed: $($_.Exception.Message)"
                Write-Warn2 'Install it manually later: irm https://claude.ai/install.ps1 | iex'
            } finally {
                $ErrorActionPreference = $prev
            }
            Update-SessionPath
            # The native installer extends PATH only for itself - it does NOT
            # persist ~\.local\bin to the user Path (its closing output says
            # to add it via System Properties). Without this, `claude` was
            # gone again in every new terminal, which broke the Setup
            # Doctor's terminal handoff (v3.1.0 bare-machine field report).
            $claudeBinDir = Join-Path $env:USERPROFILE '.local\bin'
            if (Test-Path -LiteralPath (Join-Path $claudeBinDir 'claude.exe')) {
                Add-UserPathEntry -Directory $claudeBinDir
            }
            if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Ok 'Claude Code installed' }
        }
    }

    # Installed but missing from PATH: reinstalling is pure noise - the v3.1.0
    # bare-machine run re-ran the whole native installer on every re-run while
    # each new terminal still could not resolve `claude`. Fix this window now
    # (the verify below then shows Ok with the real version), persist the
    # entry for the windows that follow.
    foreach ($entry in $pathRepairWork) {
        Write-Step "$($entry.Definition.Name) is installed but not on PATH - repairing PATH instead of reinstalling"
        Update-SessionPath
        Add-UserPathEntry -Directory (Split-Path $entry.Definition['KnownPath'] -Parent)
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
    [void](Repair-BashShadowing -GitBashPath $gitBash)

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

# SIG # Begin signature block
# MIIoYAYJKoZIhvcNAQcCoIIoUTCCKE0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA0qL3S8awAeTLE
# KiSwY2dXoT+BNg7uHG6lW17HLA2Yu6CCDQowggZJMIIEMaADAgECAhARy6Iv4IFR
# C33xpE+8TXf+MA0GCSqGSIb3DQEBCwUAMFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQK
# ExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0NlcnR1bSBDb2Rl
# IFNpZ25pbmcgMjAyMSBDQTAeFw0yNjA4MTIwOTE0MDBaFw0yNzA4MTIwOTEzNTla
# MG8xCzAJBgNVBAYTAkRFMRAwDgYDVQQIDAdIYW1idXJnMRAwDgYDVQQHDAdIYW1i
# dXJnMR0wGwYDVQQKDBRDaHJpc3RvcGhlciBOb3dvdHRueTEdMBsGA1UEAwwUQ2hy
# aXN0b3BoZXIgTm93b3R0bnkwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIB
# gQCQIH+8QfrzGZFYk3UJv3ELLXTEtk8K3iMPTKDBF8UZ2S4lVA8SKFNLRUJ1dK81
# AsuWCesy395oaDfZWPLQXtTRoc12mkMlR6hzg+C5Oi3ELYi5jrXPOwan8Lih3g7e
# fi+1PpG3KY8Ocz9b3EWGEsRGSgqlL4CEH1QRBKGMmkdIslEXPZzyqBgqMZKs3u70
# ngfx+Ta8CoR9soTW5Mao1Vim+xUtKjGXsPcpZXv9X0WIWpFRwzvJq6X/+20dey7G
# ys9ecPG9qRI/ajajA2F6mE3QV4U3fPCY07b7mRtw3Wx43J4VyiKsl9FzZ4P6Tb0Y
# cjA4fNC2OXfgY5clZZPoHOi2wuQFUzQWYTm8ABQSRr4Jv67j/jgsKL5LsmjXbAyC
# VURj4fL12nZQZXQA2BQM2G2acyTf0VZKDoKjxYNyEvPjNItGw+VDBJBZ1KTmrQce
# rm7lamQnmSbPL4wp/XklFr7tB7UQ+jXytgZtTjxBfJ+4KqlBIanD2hDAwPhBO6Tu
# 5LECAwEAAaOCAXgwggF0MAwGA1UdEwEB/wQCMAAwPQYDVR0fBDYwNDAyoDCgLoYs
# aHR0cDovL2Njc2NhMjAyMS5jcmwuY2VydHVtLnBsL2Njc2NhMjAyMS5jcmwwcwYI
# KwYBBQUHAQEEZzBlMCwGCCsGAQUFBzABhiBodHRwOi8vY2NzY2EyMDIxLm9jc3At
# Y2VydHVtLmNvbTA1BggrBgEFBQcwAoYpaHR0cDovL3JlcG9zaXRvcnkuY2VydHVt
# LnBsL2Njc2NhMjAyMS5jZXIwHwYDVR0jBBgwFoAU3XRdTADbe5+gdMqxbvc8wDLA
# cM0wHQYDVR0OBBYEFF3Jjthux6nGppOUGtjWh5EIgSC5MEsGA1UdIAREMEIwCAYG
# Z4EMAQQBMDYGCyqEaAGG9ncCBQEEMCcwJQYIKwYBBQUHAgEWGWh0dHBzOi8vd3d3
# LmNlcnR1bS5wbC9DUFMwEwYDVR0lBAwwCgYIKwYBBQUHAwMwDgYDVR0PAQH/BAQD
# AgeAMA0GCSqGSIb3DQEBCwUAA4ICAQB5ucbLNaikn2eTxdzDq2QBsiP+OPT6BfNj
# lL7FhXdKUOCRCKyWOHhTmL1KfWAIu0HB2GJL0sHYnb09FRbVUafhph5pFwn3ISAc
# UXwGlbuZNGacbPyv6gBo/dRTDSlNLE2vDpkoljoB2CIjOHymc2HQ3NV/fUO43VO6
# AiGzjJgl0GIgIAnmk71Yh8dL6ir71GKwQgXimBXN94E35VhlMJ3li+dePmYoJUwR
# pmQOeMLDAKdjMmHD12VzoVpYXxdvlgnui3Nq67uJvNIsi1qgJi/+uYPMKCwVa/A0
# RKEb8j2AeSHSxAX/YRkda71pHDH+8PbsmTJvXicD7DT81LfFOteV4IU7rJ2q6AfZ
# NJKm6vIvFMu/Ayxmkg8BF6j17BqPwr505tDdhuC5m7cEv1P9UACmV82lvNegEetG
# KvZUX8+2GOnXhnPesM3hg+1QlDbnq246hQ1ThfSLIx8QzeQsxb5gwP/8wzx34VsR
# TgeZDseiJrT3b1w9HQ61y+tXHghXW2I1oW5HONoPy5/nsK8dToDqnWtpTY7lpmnI
# 5RrNJZVxP6/vm6esK/QwDFMjahybrkNeDPG5CkCThFlr3InqdpPp9dnYS9SdwT1F
# tvzC6suHeLcTKscsg3bXT7oKlR+b++cAAhXGpTy+a79unWPo8kliQoVwAqskuBVr
# bz8E3ZarxzCCBrkwggShoAMCAQICEQCZo4AKJlU7ZavcboSms+o5MA0GCSqGSIb3
# DQEBDAUAMIGAMQswCQYDVQQGEwJQTDEiMCAGA1UEChMZVW5pemV0byBUZWNobm9s
# b2dpZXMgUy5BLjEnMCUGA1UECxMeQ2VydHVtIENlcnRpZmljYXRpb24gQXV0aG9y
# aXR5MSQwIgYDVQQDExtDZXJ0dW0gVHJ1c3RlZCBOZXR3b3JrIENBIDIwHhcNMjEw
# NTE5MDUzMjE4WhcNMzYwNTE4MDUzMjE4WjBWMQswCQYDVQQGEwJQTDEhMB8GA1UE
# ChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0dW0gQ29k
# ZSBTaWduaW5nIDIwMjEgQ0EwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQCdI88EMCM7wUYs5zNzPmNdenW6vlxNur3rLfi+5OZ+U3iZIB+AspO+CC/bj+ta
# JUbMbFP1gQBJUzDUCPx7BNLgid1TyztVLn52NKgxxu8gpyTr6EjWyGzKU/gnIu+b
# HAse1LCitX3CaOE13rbuHbtrxF2tPU8f253QgX6eO8yTbGps1Mg+yda3DcTsOYOh
# SYNCJiL+5wnjZ9weoGRtvFgMHtJg6i671OPXIciiHO4Lwo2p9xh/tnj+JmCQEn5Q
# U0NxzrOiRna4kjFaA9ZcwSaG7WAxeC/xoZSxF1oK1UPZtKVt+yrsGKqWONoK6f5E
# mBOAVEK2y4ATDSkb34UD7JA32f+Rm0wsr5ajzftDhA5mBipVZDjHpwzv8bTKzCDU
# SUuUmPo1govD0RwFcTtMXcfJtm1i+P2UNXadPyYVKRxKQATHN3imsfBiNRdN5kiV
# VeqP55piqgxOkyt+HkwIA4gbmSc3hD8ke66t9MjlcNg73rZZlrLHsAIV/nJ0mmgS
# jBI/TthoGJDydekOQ2tQD2Dup/+sKQptalDlui59SerVSJg8gAeV7N/ia4mrGoie
# z+SqV3olVfxyLFt3o/OQOnBmjhKUANoKLYlKmUpKEFI0PfoT8Q1W/y6s9LTI6ekb
# i0igEbFUIBE8KDUGfIwnisEkBw5KcBZ3XwnHmfznwlKo8QIDAQABo4IBVTCCAVEw
# DwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU3XRdTADbe5+gdMqxbvc8wDLAcM0w
# HwYDVR0jBBgwFoAUtqFUOQLDoD+Oirz61PgcptE6Dv0wDgYDVR0PAQH/BAQDAgEG
# MBMGA1UdJQQMMAoGCCsGAQUFBwMDMDAGA1UdHwQpMCcwJaAjoCGGH2h0dHA6Ly9j
# cmwuY2VydHVtLnBsL2N0bmNhMi5jcmwwbAYIKwYBBQUHAQEEYDBeMCgGCCsGAQUF
# BzABhhxodHRwOi8vc3ViY2Eub2NzcC1jZXJ0dW0uY29tMDIGCCsGAQUFBzAChiZo
# dHRwOi8vcmVwb3NpdG9yeS5jZXJ0dW0ucGwvY3RuY2EyLmNlcjA5BgNVHSAEMjAw
# MC4GBFUdIAAwJjAkBggrBgEFBQcCARYYaHR0cDovL3d3dy5jZXJ0dW0ucGwvQ1BT
# MA0GCSqGSIb3DQEBDAUAA4ICAQB1iFgP5Y9QKJpTnxDsQ/z0O23JmoZifZdEOEmQ
# vo/79PQg9nLF/GJe6ZiUBEyDBHMtFRK0mXj3Qv3gL0sYXe+PPMfwmreJHvgFGWQ7
# XwnfMh2YIpBrkvJnjwh8gIlNlUl4KENTK5DLqsYPEtRQCw7R6p4s2EtWyDDr/M58
# iY2UBEqfUU/ujR9NuPyKk0bEcEi62JGxauFYzZ/yld13fHaZskIoq2XazjaD0pQk
# cQiIueL0HKiohS6XgZuUtCKA7S6CHttZEsObQJ1j2s0urIDdqF7xaXFVaTHKtAuM
# fwi0jXtF3JJphrJfc+FFILgCbX/uYBPBlbBIP4Ht4xxk2GmfzMn7oxPITpigQFJF
# WuzTMUUgdRHTxaTSKRJ/6Uh7ki/pFjf9sUASWgxT69QF9Ki4JF5nBIujxZ2sOU9e
# 1HSCJwOfK07t5nnzbs1LbHuAIGJsRJiQ6HX/DW1XFOlXY1rc9HufFhWU+7Uk+hFk
# JsfzqBz3pRO+5aI6u5abI4Qws4YaeJH7H7M8X/YNoaArZbV4Ql+jarKsE0+8XvC4
# DJB+IVcvC9Ydqahi09mjQse4fxfef0L7E3hho2O3bLDM6v60rIRUCi2fJT2/IRU5
# ohgyTch4GuYWefSBsp5NPJh4QRTP9DC3gc5QEKtbrTY0Ka87Web7/zScvLmvQBm8
# JDFpDjGCGqwwghqoAgEBMGowVjELMAkGA1UEBhMCUEwxITAfBgNVBAoTGEFzc2Vj
# byBEYXRhIFN5c3RlbXMgUy5BLjEkMCIGA1UEAxMbQ2VydHVtIENvZGUgU2lnbmlu
# ZyAyMDIxIENBAhARy6Iv4IFRC33xpE+8TXf+MA0GCWCGSAFlAwQCAQUAoHwwEAYK
# KwYBBAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYB
# BAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIJDsS20GkCNP
# 4W9/UXhpwrTXcUPbWafjoXE+qh2Xvrr3MA0GCSqGSIb3DQEBAQUABIIBgGjnp7+/
# wMYBo29tNwO459pMvSScsmGrQViZWDFucBYgRSjJipgDljeUMtBZPGJA0TV/Z4HG
# DG9cNWEVcojjzJW7f/0pFj6zkoSYVk1mvDQVZkbq3nKkDfsL8C510K16QBrmcOpR
# Cn+0DS72KvqvFT2irjIvUr88F8ocxJY2mSSqZP3RO2jB4mM+OeYTS4kqxdm9xPa+
# 6Bb9lfS8mPuckSMRZOW5LQkqMrH3vZ0TqmUya0Qwq6n8HIQxyECI/Gr5hK+chbsX
# IYR4MCyhSMQb2/I05mh03z4x9ycb8KwOAVgmnVKhVIuBVPAiLMGCzCqJv+LygY3c
# CouCwfMgOo0h94fQ/+5oa0kxBk1fOxCtX5T+DZ9iTqrQ8gGZppFo4Patav7PlMpL
# b8wtmx6hLCWAGtqFjJvPeZrTZ02tqz5p5Jpbr3SKuR68nQUcsPRsRVkR/gN3Ueqp
# JQ3Nl5PmG37Zl5YoD6/5PhZVduQr9kEHFXA2q2r65JCLVp6ebGaLbTlgdKGCGBUw
# ghgRBgorBgEEAYI3AwMBMYIYATCCF/0GCSqGSIb3DQEHAqCCF+4wghfqAgEDMQ0w
# CwYJYIZIAWUDBAICMIHOBgsqhkiG9w0BCRABBKCBvgSBuzCBuAIBAQYLKoRoAYb2
# dwIFAQswMTANBglghkgBZQMEAgEFAAQgr8ragfjncEKzC/FHf9cjokfz+dxzAFIy
# F4DCMhzaNTECBwqofG83K84YDzIwMjYwODEzMjE0NDM4WjADAgEBoFSkUjBQMQsw
# CQYDVQQGEwJQTDEhMB8GA1UECgwYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMR4w
# HAYDVQQDDBVDZXJ0dW0gVGltZXN0YW1wIDIwMjagghMQMIIGgjCCBGqgAwIBAgIQ
# KPB3wRw2vf5fdDJHcCcuAzANBgkqhkiG9w0BAQwFADBWMQswCQYDVQQGEwJQTDEh
# MB8GA1UEChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0
# dW0gVGltZXN0YW1waW5nIDIwMjEgQ0EwHhcNMjYwMzExMDczNDU0WhcNMzYwMjI3
# MDczNDU0WjBQMQswCQYDVQQGEwJQTDEhMB8GA1UECgwYQXNzZWNvIERhdGEgU3lz
# dGVtcyBTLkEuMR4wHAYDVQQDDBVDZXJ0dW0gVGltZXN0YW1wIDIwMjYwggIiMA0G
# CSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC4vc3wcPsSNdoYthfbjUATTkk5EyIt
# d37odw4lsmyOd/dmwXycOrTu8w7O1Kj/63o1X+MRU1N1zTj7LjhZD+UjxbJ1sJ91
# SS/jYTYbLro72LELWkJ7zaNcJOOq3k4MLNS/DhRHSmsYMqk+MzkMfNZi8DWUqlzV
# PUa2/aACViReDMnc/gtXm7tA9Pr4DN7agEPE1NtN36oCgj6iHR5aGhah/XskfvLZ
# 6ZstoZ5zefWTrZrLh3kcH+YkzoZYX9Hf6qqrizkiBj4BlS9R4+VwVKMdjhO7UEa/
# pf8cTWy+jrsATuAGthG7sWIN+3KV7+Ytv5Uy+DQEgf3bn/VuH4wN0aPhj/mwueJ9
# jmIjNwqvM/dno8fBeR1jtnuP++XgveQfbTMP3qu9dPRg8ltvtrreQZ9KPDFyUxEZ
# MsrLVm6nJ1JKJgPe6n4gwsL6VrjjHX0zpLF3vUvsQ8TiWgm4sk4r4D7pcXE/rX0E
# 0Vwa+VMLT73PiDZ2nzhIpc1RwNdbb/qR3Mpa8sQXNPHFIoX/7bapGUtG5sd1cUGs
# vLqIWk6dP/xAgPb2BludUinSTCYV7ysiHQS8vFmDXIU7fMkSE7/QHcYPSahro4fk
# 5z9W1t2kIxbZRJe0s4DXiPDlQPwiQFllLkU9wLvU6DqR8v35a65J4TeIXhMO/+iC
# zL+B0rI9GGeKLQIDAQABo4IBUDCCAUwwdQYIKwYBBQUHAQEEaTBnMDsGCCsGAQUF
# BzAChi9odHRwOi8vc3ViY2EucmVwb3NpdG9yeS5jZXJ0dW0ucGwvY3RzY2EyMDIx
# LmNlcjAoBggrBgEFBQcwAYYcaHR0cDovL3N1YmNhLm9jc3AtY2VydHVtLmNvbTAf
# BgNVHSMEGDAWgBS+VAIvv0Bsc0POrAklTp5DRBru4DAMBgNVHRMBAf8EAjAAMDkG
# A1UdHwQyMDAwLqAsoCqGKGh0dHA6Ly9zdWJjYS5jcmwuY2VydHVtLnBsL2N0c2Nh
# MjAyMS5jcmwwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MCIGA1UdIAQbMBkwCAYGZ4EMAQQCMA0GCyqEaAGG9ncCBQELMB0GA1UdDgQWBBQj
# OWooq5oSp6Sn8h/5RZq/jf6CAzANBgkqhkiG9w0BAQwFAAOCAgEAZv6Tm6wL3k6m
# BTwkrYcTVcAR01uE37gUGNihgnTJR+gC41T2H9lwETRjE10nEdCUNv3Ni8S6aBx4
# UcMRX93fd9w4RUteua2I+oj0kCpuNa3PQDKUwozHZmotWivaPO9KTs08y0YVhVSM
# ZvuUH/reFec9eLT6FLAFnX0Sg9Wc7833uQB5RPa8TmXBkTolC8bNxHX+2SfEWSNI
# 8w/Y7o9qBF9l0uwVSrjQitVtIdZo2qb9NvMqqPFLWYef9SG+PGMqfPAQ2EoYeT0h
# lFLkubWF1X3HbiDwXtz3TU2EWHU+VTcZMC4IzMyHK/+kh9n3oxSQ45wsY71y7mqx
# KyYPyHSPoV3RiAQ1Thr9c65BeJLaELxWSKeQyAGIdBsMlIXPO6qp+VGmE49vosog
# Q0jYe2hgq5LgJ6oO0Ie364V/kITBnifUqS6Zxu+qjfOYS8o72EeoEWIi04/BuH8Y
# 6leNNP27j8NKwaPciWcqv/HBnQjizzmH/aqXn03K2SnjvaYPlCR8fFAAW2k6os0c
# ZvLFEhMnHHAghYSIrdwCP98BrkjgA3ogOu+jXEO/nbD9OGL873Te6U2TcoOu9lqQ
# QyXYNHiLR5eMqJrzXiDlodarOEKjlukyPDnLIuLkg0y6K8S1A5wU8CkM86cXdWFH
# LRIEYd9kdCfRZBZHhK7iVPeEZYxa9bgwgga5MIIEoaADAgECAhEA5/9pxzs1zkuR
# Jth0fGilhzANBgkqhkiG9w0BAQwFADCBgDELMAkGA1UEBhMCUEwxIjAgBgNVBAoT
# GVVuaXpldG8gVGVjaG5vbG9naWVzIFMuQS4xJzAlBgNVBAsTHkNlcnR1bSBDZXJ0
# aWZpY2F0aW9uIEF1dGhvcml0eTEkMCIGA1UEAxMbQ2VydHVtIFRydXN0ZWQgTmV0
# d29yayBDQSAyMB4XDTIxMDUxOTA1MzIwN1oXDTM2MDUxODA1MzIwN1owVjELMAkG
# A1UEBhMCUEwxITAfBgNVBAoTGEFzc2VjbyBEYXRhIFN5c3RlbXMgUy5BLjEkMCIG
# A1UEAxMbQ2VydHVtIFRpbWVzdGFtcGluZyAyMDIxIENBMIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEA6RIfBDXtuV16xaaVQb6KZX9Od9FtJXXTZo7b+GEo
# f3+3g0ChWiKnO7R4+6MfrvLyLCWZa6GpFHjEt4t0/GiUQvnkLOBRdBqr5DOvlmTv
# JJs2X8ZmWgWJjC7PBZLYBWAs8sJl3kNXxBMX5XntjqWx1ZOuuXl0R4x+zGGSMzZ4
# 5dpvB8vLpQfZkfMC/1tL9KYyjU+htLH68dZJPtzhqLBVG+8ljZ1ZFilOKksS79ep
# CeqFSeAUm2eMTGpOiS3gfLM6yvb8Bg6bxg5yglDGC9zbr4sB9ceIGRtCQF1N8dqT
# gM/dSViiUgJkcv5dLNJeWxGCqJYPgzKlYZTgDXfGIeZpEFmjBLwURP5ABsyKoFoc
# MzdjrCiFbTvJn+bD1kq78qZUgAQGGtd6zGJ88H4NPJ5Y2R4IargiWAmv8RyvWnHr
# /VA+2PrrK9eXe5q7M88YRdSTq9TKbqdnITUgZcjjm4ZUjteq8K331a4P0s2in0p3
# UubMEYa/G5w6jSWPUzchGLwWKYBfeSu6dIOC4LkeAPvmdZxSB1lWOb9HzVWZoM8Q
# /blaP4LWt6JxjkI9yQsYGMdCqwl7uMnPUIlcExS1mzXRxUowQref/EPaS7kYVaHH
# Qrp4XB7nTEtQhkP0Z9Puz/n8zIFnUSnxDof4Yy650PAXSYmK2TcbyDoTNmmt8xAx
# zcMCAwEAAaOCAVUwggFRMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFL5UAi+/
# QGxzQ86sCSVOnkNEGu7gMB8GA1UdIwQYMBaAFLahVDkCw6A/joq8+tT4HKbROg79
# MA4GA1UdDwEB/wQEAwIBBjATBgNVHSUEDDAKBggrBgEFBQcDCDAwBgNVHR8EKTAn
# MCWgI6Ahhh9odHRwOi8vY3JsLmNlcnR1bS5wbC9jdG5jYTIuY3JsMGwGCCsGAQUF
# BwEBBGAwXjAoBggrBgEFBQcwAYYcaHR0cDovL3N1YmNhLm9jc3AtY2VydHVtLmNv
# bTAyBggrBgEFBQcwAoYmaHR0cDovL3JlcG9zaXRvcnkuY2VydHVtLnBsL2N0bmNh
# Mi5jZXIwOQYDVR0gBDIwMDAuBgRVHSAAMCYwJAYIKwYBBQUHAgEWGGh0dHA6Ly93
# d3cuY2VydHVtLnBsL0NQUzANBgkqhkiG9w0BAQwFAAOCAgEAuJNZd8lMFf2UBwig
# p3qgLPBBk58BFCS3Q6aJDf3TISoytK0eal/JyCB88aUEd0wMNiEcNVMbK9j5Yht2
# whaknUE1G32k6uld7wcxHmw67vUBY6pSp8QhdodY4SzRRaZWzyYlviUpyU4dXyhK
# hHSncYJfa1U75cXxCe3sTp9uTBm3f8Bj8LkpjMUSVTtMJ6oEu5JqCYzRfc6nnoRU
# gwz/GVZFoOBGdrSEtDN7mZgcka/tS5MI47fALVvN5lZ2U8k7Dm/hTX8CWOw0uBZl
# oZEW4HB0Xra3qE4qzzq/6M8gyoU/DE0k3+i7bYOrOk/7tPJg1sOhytOGUQ30PbG+
# +0FfJioDuOFhj99b151SqFlSaRQYz74y/P2XJP+cF19oqozmi0rRTkfyEJIvhIZ+
# M5XIFZttmVQgTxfpfJwMFFEoQrSrklOxpmSygppsUDJEoliC05vBLVQ+gMZyYaKv
# BJ4YxBMlKH5ZHkRdloRYlUDplk8GUa+OCMVhpDSQurU6K1ua5dmZftnvSSz2H96U
# rQDzA6DyiI1V3ejVtvn2azVAXg6NnjmuRZ+wa7Pxy0H3+V4K4rOTHlG3VYA6xfLs
# TunCz72T6Ot4+tkrDYOeaU1pPX1CBfYj6EW2+ELq46GP8KCNUQDirWLU4nOmgCat
# 7vN0SD6RlwUiSsMeCiQDmZwgwrUwggXJMIIEsaADAgECAhAbtY8lKt8jAEkoya49
# fu0nMA0GCSqGSIb3DQEBDAUAMH4xCzAJBgNVBAYTAlBMMSIwIAYDVQQKExlVbml6
# ZXRvIFRlY2hub2xvZ2llcyBTLkEuMScwJQYDVQQLEx5DZXJ0dW0gQ2VydGlmaWNh
# dGlvbiBBdXRob3JpdHkxIjAgBgNVBAMTGUNlcnR1bSBUcnVzdGVkIE5ldHdvcmsg
# Q0EwHhcNMjEwNTMxMDY0MzA2WhcNMjkwOTE3MDY0MzA2WjCBgDELMAkGA1UEBhMC
# UEwxIjAgBgNVBAoTGVVuaXpldG8gVGVjaG5vbG9naWVzIFMuQS4xJzAlBgNVBAsT
# HkNlcnR1bSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTEkMCIGA1UEAxMbQ2VydHVt
# IFRydXN0ZWQgTmV0d29yayBDQSAyMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAvfl4+ObVgAxknYYblmRnPyI6HnUBfe/7XGeMycxca6mR5rlC5SBLm9qb
# e7mZXdmbgEvXhEArJ9PoujC7Pgkap0mV7ytAJMKXx6fumyXvqAoAl4Vaqp3cKcni
# NQfrcE1K1sGzVrihQTib0fsxf4/gX+GxPw+OFklg1waNGPmqJhCrKtPQ0WeNG0a+
# RzDVLnLRxWPa52N5RH5LYySJhi40PylMUosqp8DikSiJucBb+R3Z5yet/5oCl8HG
# UJKbAiy9qbk0WQq/hEr/3/6zn+vZnuCYI+yma3cWKtvMrTscpIfcRnNeGWJoRVfk
# kIJCu0LW8GHgwaM9ZqNd9BjuiMmNF0UpmTJ1AjHuKSbIawLmtWJFfzcVWiNoidQ+
# 3k4nsPBADLxNF8tNorMe0AZa3faTz1d1mfX6hhpneLO/lv403L3nUlbls+V1e9dB
# kQXcXWnjlQ1DufyDljmVe2yAWk8TcsbXfSl6RLpSpCrVQUYJIP4ioLZbMI28iQzV
# 13D4h1L92u+sUS4Hs07+0AnacO+Y+lbmbdu1V0vc5SwlFcieLnhO+NqcnoYsylfz
# GuXIkosagpZ6w7xQEmnYDlpGizrrJvojybawgb5CAKT41v4wLsfSRvbljnX98sy5
# 0IdbzAYQYLuDNbdeZ95H7JlI8aShFf6tjGKOOVVPORa5sWOd/7cCAwEAAaOCAT4w
# ggE6MA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFLahVDkCw6A/joq8+tT4HKbR
# Og79MB8GA1UdIwQYMBaAFAh2zcsH/yT2xc3tu5C84oQ3RnX3MA4GA1UdDwEB/wQE
# AwIBBjAvBgNVHR8EKDAmMCSgIqAghh5odHRwOi8vY3JsLmNlcnR1bS5wbC9jdG5j
# YS5jcmwwawYIKwYBBQUHAQEEXzBdMCgGCCsGAQUFBzABhhxodHRwOi8vc3ViY2Eu
# b2NzcC1jZXJ0dW0uY29tMDEGCCsGAQUFBzAChiVodHRwOi8vcmVwb3NpdG9yeS5j
# ZXJ0dW0ucGwvY3RuY2EuY2VyMDkGA1UdIAQyMDAwLgYEVR0gADAmMCQGCCsGAQUF
# BwIBFhhodHRwOi8vd3d3LmNlcnR1bS5wbC9DUFMwDQYJKoZIhvcNAQEMBQADggEB
# AFHCoVgWIhCL/IYx1MIy01z4S6Ivaj5N+KsIHu3V6PrnCA3st8YeDrJ1BXqxC/rX
# dGoABh+kzqrya33YEcARCNQOTWHFOqj6seHjmOriY/1B9ZN9DbxdkjuRmmW60F9M
# vkyNaAMQFtXx0ASKhTP5N+dbLiZpQjy6zbzUeulNndrnQ/tjUoCFBMQllVXwfqef
# AcVbKPjgzoZwpic7Ofs4LphTZSJ1Ldf23SIikZbr3WjtP6MZl9M7JYjsNhI9qX7O
# Ao0FmpKnJ25FspxihjcNpDOO16hO0EoXQ0zF8ads0h5YbBRRfopUofbvn3l6XYGa
# FpAP4bvxSgD5+d2+7arszgoxggPvMIID6wIBATBqMFYxCzAJBgNVBAYTAlBMMSEw
# HwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0NlcnR1
# bSBUaW1lc3RhbXBpbmcgMjAyMSBDQQIQKPB3wRw2vf5fdDJHcCcuAzANBglghkgB
# ZQMEAgIFAKCCAVYwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqGSIb3
# DQEJBTEPFw0yNjA4MTMyMTQ0MzhaMDcGCyqGSIb3DQEJEAIvMSgwJjAkMCIEIIW+
# kOEK0kONfMkotq9IsJqyCBd87PiwEmxY05EFJcQ8MD8GCSqGSIb3DQEJBDEyBDDt
# N3Uu1js/MXkDWgw4OKWwm9RoRrT9v6WmWaQZk9mZ/sSkAw+YGY9oZVvc763Nn3Uw
# gZ8GCyqGSIb3DQEJEAIMMYGPMIGMMIGJMIGGBBRXFGhBDKha80JO+RZKUTYQ9NON
# mDBuMFqkWDBWMQswCQYDVQQGEwJQTDEhMB8GA1UEChMYQXNzZWNvIERhdGEgU3lz
# dGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0dW0gVGltZXN0YW1waW5nIDIwMjEgQ0EC
# ECjwd8EcNr3+X3QyR3AnLgMwDQYJKoZIhvcNAQEBBQAEggIArJKNMnorGBB/ZXXf
# GoOtbDktH0hoosJCYzAlvAp2TdIJ8B5HcvSRq2Lv5ifiUiMpTU6JlvIrruklbVww
# KLLy/JxphmjK+7SmuidVc9pROduftaT9sGPjoEEGMllCSsZQInoOlqp1kcGXgLmZ
# j/w5zMUtNPzIp+AJO8GH/SVQZKZrppEi3bU7ptwizy+9ril06shRER7VNgmOkPhb
# 7OXOvAgPehBdoDRNWKuRGi6p9FU3YUh0zcVMzCyuQek+1YSi23yL9Za6Pr3NI/4i
# PdbDMaBhP/zYs4Tlq+p9scOB98vg57tIfnAOxgqByCr+PLiskuVEMzXk360hfn5j
# w6Bzdm81m7cgpB81VUX0vUa9eA4HIhC2XJmTWEPvZXvXMEZMJyFog6naOna2BFvN
# Ho6jpTrDy+CwW6GDKOMm7OuF60af/YUlLwtmrjdR8ZZVLoo4UnP9Yh6tXx7+ksxw
# A8MjE25ftgWPy6iD9bO9TnJn9kL33n1Jo9oXe/4dsLDBeGwsKR2je6POepOvByTw
# nwg9YWRPOfw+NAN7FrWl7eBTMz6wYh98KRizr1KnfxZMwOVC23ykSQ5Fxzg2YrZk
# T2FVU2AGDE6snYQQQol0KLjZg2u6VsF/qna+4+Qa+e8QoOPH7o7vKYzbr0Wi3RSp
# UuTlfXVncpt3ih1oBg6Bv0xhcKI=
# SIG # End signature block
