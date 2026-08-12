# Get Polaris AI

<!-- This repository is a publish target: its content is generated from the private
     Polaris AI source repo (docs/onboarding/) by the release pipeline on every
     release. Do not edit it here - changes would be overwritten. -->

Polaris AI is a proprietary planning and development copilot (Claude Code plugin +
Windows Dashboard). This public repository carries exactly one thing: the bootstrap
installer that sets up a machine from zero.

## Install

Open a normal PowerShell window (no admin) on Windows 10/11 and run:

```powershell
irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1 | iex
```

The script walks six idempotent stages and is safe to re-run at any time:

1. Prerequisites - Git, Node.js LTS, GitHub CLI via winget (Docker Desktop opt-in),
   Claude Code via its native installer.
2. GitHub sign-in - one browser click (device flow); known pitfalls get guided fixes.
3. Polaris plugin - installed into Claude Code from the private distribution repo.
4. Polaris Dashboard - per-user Setup, silent, with an Apps & Features entry.
5. Claude sign-in - detected and offered, never required to finish the install.
6. Finish - open the Dashboard.

### Passing options

`irm | iex` runs the default flow. To pass switches (e.g. a preview run), wrap it:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1))) -DryRun
```

or download first and run the file:

```powershell
irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun
```

| Switch | Effect |
|---|---|
| `-DryRun` | Probe only - print what every stage would do, change nothing |
| `-IncludeDocker` | Also install Docker Desktop and sign it in to GHCR (agents) |
| `-SkipClaudeCode` | Do not install Claude Code (report only) |
| `-SkipDashboard` | Skip the Dashboard install |
| `-SkipAnthropicSignIn` | Skip the Claude sign-in offer (IT provisioning for someone else) |

### Before you run it

- **You need an invitation.** Polaris ships from a private repository; send the
  maintainer your GitHub username and accept the email invite before stage 3 can
  succeed. Stages 1-2 work regardless.
- **Reading before running is encouraged** - the script is this repository's
  [`install.ps1`](install.ps1), plain PowerShell, nothing minified.
- winget is required (preinstalled on Windows 11; on Windows 10 install
  "App Installer" from the Microsoft Store).
- The winget installs are machine-wide and raise UAC prompts. Everything else is
  per-user.

## License

Polaris AI is proprietary software; all rights reserved. Access is by invitation -
contact the maintainer for licensing.
