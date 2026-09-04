# Get Polaris AI

<!-- This repository is a publish target: its content is generated from the private
     Polaris AI source repo (docs/onboarding/) by the release pipeline on every
     release. Do not edit it here - changes would be overwritten. -->

Polaris AI is a proprietary planning and development copilot: a Claude Code plugin and a Windows
Dashboard. This public repository carries exactly one thing, the bootstrap installer for
developers and CI.

## Most people want the installer, not this script

Download **`PolarisAI-Setup.exe`** from the Polaris AI download page and double-click it. It needs
no terminal, no GitHub account and no sign-in, it installs per-user, and the only elevation prompt
you may see is Git for Windows installing itself.

> **Download page**: `https://polaris.chrisnowottny.com/download/` - live after the Cloudflare
> setup; until then the GitHub release remains the source, so ask the maintainer for the installer
> directly.

The same page carries the portable zip and a machine-wide `.msi` for IT deployment. Everything on
it is Authenticode-signed and covered by a published `SHA256SUMS`.

## This script is the developer and CI path

Use it for machines you script: your own dev box, a build agent, an IT provisioning run, a
container image. Open a normal PowerShell window (no admin) on Windows 10/11:

```powershell
irm https://raw.githubusercontent.com/polaris-ai-org/get-polaris/main/install.ps1 | iex
```

Six idempotent stages, safe to re-run at any time:

1. **Prerequisites** - Git for Windows via winget, Claude Code via its native installer. Node.js is
   detected only and never installed: the Dashboard package brings its own private copy. The GitHub
   CLI comes only with `-WithAgentTools`, Docker Desktop only with `-IncludeDocker`.
2. **GitHub sign-in** - only for agent/Docker users, or while no public download host is configured.
   One browser device-flow login; the known pitfalls get guided fixes.
3. **Polaris plugin** - skipped on the public download path, because the installed Dashboard bundles
   the plugin and registers it on first run.
4. **Polaris Dashboard** - downloads and runs the signed Setup package, silent and per-user.
5. **Claude sign-in** - detected and offered, never required to finish the install.
6. **Finish** - open the Dashboard.

### Passing options

`irm | iex` runs the default flow. To pass switches, wrap it:

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
| `-DownloadBaseUrl <url>` | Fetch the Dashboard from the public download route, `https://polaris.chrisnowottny.com/download` (live after the Cloudflare setup; until then the GitHub release remains the source). Takes GitHub off the run entirely |
| `-WithAgentTools` | Install the GitHub CLI and run the GitHub sign-in stage (Docker/agent users only) |
| `-IncludeDocker` | Also install Docker Desktop and sign it in to the container registry. Implies `-WithAgentTools` |
| `-SkipClaudeCode` | Do not install Claude Code (report only) |
| `-SkipDashboard` | Skip the Dashboard install |
| `-SkipAnthropicSignIn` | Skip the Claude sign-in offer (IT provisioning for someone else) |

### Before you run it

- **You need a Polaris licence.** The Dashboard runs, and updates, on a signed licence file the
  maintainer issues per firm. Without one it opens on its Setup Doctor and asks for it.
  [Request a licence](#requesting-a-licence) before you install.
- **You need a Claude account** (Pro, Max or Team) for the Claude Code CLI.
- **Reading before running is encouraged** - the script is this repository's
  [`install.ps1`](install.ps1), plain PowerShell, nothing minified and Authenticode-signed.
- winget is required for the prerequisite installs (preinstalled on Windows 11; on Windows 10
  install "App Installer" from the Microsoft Store).
- The Git for Windows install is machine-wide and raises a UAC prompt. Everything else is per-user.
- **Until the public download host is live**, stage 4 falls back to the private distribution
  release and needs `gh auth login` plus read access granted by the maintainer. Pass
  `-DownloadBaseUrl` once the host exists and that requirement disappears.

## Requesting a licence

Polaris AI is licensed per firm. Write to the maintainer with the firm's name and how many people
will use it; you get back an activation link and a `.lic` file. Activation happens inside the
Dashboard - paste the link, open the file, or paste the licence text - and never in this script or
in the installer.

An expired licence never locks anyone out: the Dashboard keeps running at the version it has, and
only updates pause until a renewal is activated.

## Licence terms and privacy

- The **end user licence agreement** is shown by `PolarisAI-Setup.exe` before anything is installed,
  and again by the Dashboard's activation station. It is also published on the download page.
- The **privacy notice** (Art. 13 GDPR) covers the one thing the Dashboard sends anywhere: on an
  update check it presents its licence, a per-install identifier and the running version. No
  hardware fingerprint is collected, ever. It is published alongside the licence agreement.
- Both documents exist in English and German.

## License

Polaris AI is proprietary software; all rights reserved. Use requires a licence issued by the
Licensor - see [Requesting a licence](#requesting-a-licence).
