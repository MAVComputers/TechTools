# MAV TechTools

Field toolkit for MAV Computers LLC technicians. One window with a top menu of
categories, tabs for each area, checkboxes and dropdowns for fixes, and an
Action Center that shows every job with a progress bar and a live log.

Built with PowerShell and WPF, the same approach as Chris Titus's WinUtil:
nothing to install, a few hundred KB to download, and every fix is a plain
PowerShell script you can read.

## For techs: starting TechTools

On the PC you are working on, open **Terminal (Admin)** or **Windows PowerShell (Admin)** and run:

```powershell
irm techtools.mavcomputers.com/go | iex
```

(`/go` is a short alias for `irm techtools.mavcomputers.com/run.ps1 | iex`, which
also still works. See `go.html`.)

The launcher downloads the latest version to `%TEMP%\MAVTechTools`, asks for
admin rights if needed, and opens the window. TechTools always runs as
administrator, so every script and install has admin rights: if it is started
without them it restarts through the Windows (UAC) prompt, where a tech without
admin rights can enter an admin account. If the prompt is refused, it does not
start. (One step runs as the signed-in user on purpose: after a server
re-authenticate, drives are remapped in that user's own session.) Each session writes a log to
`C:\ProgramData\MAVTechTools\Logs` (the **Open logs** button opens it).

Before the window opens, TechTools asks for the **MAV team password** (5 tries,
then it closes). The password itself is never stored: `config/auth.json` holds
only a salted PBKDF2-SHA256 hash. To change it, run
`pwsh -File tools/Set-TeamPassword.ps1` (12+ characters, because the repo is
public), commit `config/auth.json` and merge. This stops casual use only;
anyone can still read the scripts in this public repo.

**Send to ticket (HaloPSA).** Every report has a **Send to ticket** button: the
tech enters the ticket number and TechTools adds a private note (report title,
PC, result, each problem and warning) and attaches the report as a PDF, posted
by the "MAV Tech Tools" API agent, so techs do not sign in to Halo. The Halo
client secret is in `config/halo.json`, encrypted (AES-256 + HMAC) with a key
derived from the team password, and is unlocked in memory when the password is
entered. Anyone with the team password can unlock it, so give the Halo agent the
smallest role possible. Set it up with `pwsh -File tools/Set-HaloKey.ps1`;
`tools/Set-TeamPassword.ps1` re-locks it when the password changes.

How it works on screen:

1. Pick a category in the top menu, then a tab.
2. Use a quick action, or tick options and press **Run selected**.
   Picks stay ticked when you switch tabs and run together.
3. Watch the Action Center: each job shows its steps, progress and result.
   Options marked **RESTART** show a restart banner when they finish.

## What is in v0.2

| Category | Status |
| --- | --- |
| Internet Issues | Live: connection status, full diagnosis with recommended fixes, 31 tools across Diagnose & Repair, Wi-Fi and Tools |
| Windows | Live: Diagnostics tab with **PC health check** (system, RAM, drives and drive health, free space, network, pings, speed test, event log errors, top processes, shares, printers and driver dates, pending updates, Webroot / SentinelOne / Bitdefender / CrowdStrike). Results show in the app and save as HTML or PDF. More report buttons on the same tab: **Slow PC check** (uptime, 30-second CPU/RAM/disk sample, C: space, startup apps, ends with a likely cause), **Printer and scanner check** (spooler, printers not answering on the network, stuck jobs, WIA/TWAIN scanners and imaging devices) with **Clear stuck print jobs**, **Crash and BSOD history** (30 days: stop codes, faulting driver when WinDbg is installed, unexpected shutdowns, app crashes), **Windows health repair** (DISM RestoreHealth then SFC, lists repaired files), **Battery and power report** (battery wear, power plan, sleep blockers, wake sources) and **Time and domain sync** (clock drift vs the DC or time.windows.com, time source, domain controller and trust). Also **Check server connection**: tests reachability, saved login, share access, mapped drives and domain trust for the office server, with **Re-authenticate** to save a new login in Credential Manager for the signed-in user and reconnect their drives (server path saved per PC in `C:\ProgramData\MAVTechTools\server.json`, never in this repo). Tweaks, Updates, Configurations, Installs and Repair come next. |
| Home | **This PC at a glance**: PC name, user, Windows, uptime, C: space, memory, network, domain, antivirus, pending restart and office server; a **Needs attention** list with one-click actions (restart, free up space, set up server, re-authenticate, office profile); favorite tools; this office; recent actions on this PC (`C:\ProgramData\MAVTechTools\history.json`). |
| Dental | Live: **Practice Management** and **Imaging** tabs. Finds installed dental software, office profile per PC, a page per program with a server/share box, **Check status** (install, server port, data share write test, folder permissions, Open Dental config, sensor and USB power) and program fixes. **X-ray sensor check** on Imaging. Programs are listed in `config/dental/programs.json`; details marked (confirm) still need MAV notes. Plus **3rd Party Apps** (MouthWatch). |
| Ophthalmic | Planned |

## Repository layout

```
run.ps1                     launcher (what techs run)
index.html                  landing page at techtools.mavcomputers.com
manifest.json               version + list of files the launcher downloads
app/TechTools.ps1           the window
app/TechTools.Core.ps1      catalog loading, jobs, background worker
app/MainWindow.xaml         layout and theme
config/categories.json      top menu: categories and their tool files
config/tools/*.json         tools for one category
config/dental/programs.json dental programs: detection, paths, ports, fixes, notes
app/TechTools.Pages.ps1     Home page and Dental program pages
config/scripts/<category>/  shared PowerShell helpers for a category
tests/Test-Core.ps1         checks (run locally or in CI)
tools/Update-Manifest.ps1   rebuilds manifest.json
```

## Adding a tool

Tools live in `config/tools/<category>.json`. Add one entry, no UI code needed.

```json
{
  "id": "flushdns",
  "type": "check",
  "tab": "fix",
  "section": "Network Repair",
  "label": "Flush DNS cache",
  "default": true,
  "cmd": "ipconfig /flushdns",
  "info": "Shown when the tech hovers over the option.",
  "restart": false,
  "script": [
    "Write-Step 'Flushing DNS resolver cache'",
    "Clear-DnsClientCache",
    "ipconfig /flushdns",
    "Assert-TTExit 'ipconfig /flushdns'"
  ]
}
```

| Field | Meaning |
| --- | --- |
| `type` | `check` (checkbox), `choice` (dropdown with `options`), `quick` (one-click button), `winget` (app install, needs `package`) |
| `tab`, `section` | Where it shows. Tabs are listed at the top of the category file. Quick actions have no section. |
| `default` | Ticked by **Select defaults** (for `choice`, the option `value`) |
| `cmd` | Short text shown under the label |
| `restart` | Shows the restart banner when the job finishes |
| `script` | PowerShell, as a list of lines. Runs as admin on a background thread. |

Helpers every script can use:

| Helper | What it does |
| --- | --- |
| `Write-Step 'text'` | Starts the next step. The progress bar counts the `Write-Step` calls in the script. |
| `Write-Info 'text'` / `Write-Warn 'text'` | Adds a line to the console (warnings turn the job amber) |
| `Assert-TTExit 'what' [-Ok 0,1]` | Fails the job if the last program returned an unexpected exit code |
| `Set-Result $object` | Hands data back to the window (used by the status panel) |

Anything a script prints also goes to the console. A cmdlet error or `throw`
marks the job **Failed** with the message; add `-ErrorAction SilentlyContinue`
where a failure is expected and fine.

After adding or removing files, run `pwsh -File tools/Update-Manifest.ps1`,
then `pwsh -File tests/Test-Core.ps1`. CI runs the same checks on Windows,
plus a smoke test that builds every page of the window.

Keep `.ps1` files ASCII-only: Windows PowerShell 5.1 misreads other characters.

## Hosting (GitHub Pages)

1. In the repo: **Settings > Pages > Build and deployment**, source **Deploy from a branch**, branch `main`, folder `/ (root)`.
2. In your DNS: a `CNAME` record `techtools` pointing to `mavcomputers.github.io`.
3. Back in **Settings > Pages**, confirm the custom domain `techtools.mavcomputers.com` and tick **Enforce HTTPS** once it is offered.

Until the domain is live, the launcher falls back to
`raw.githubusercontent.com`, so this also works:

```powershell
irm https://raw.githubusercontent.com/MAVComputers/TechTools/main/run.ps1 | iex
```

## Safety rules

- This repo is public. Never commit client names, server names, passwords, license keys or vendor credentials. Scripts should ask for them at run time or read them from the PC.
- Anything merged to `main` reaches every tech on their next launch, so changes go through pull requests and CI.
- Fixes that remove data or settings (firewall reset, forgetting Wi-Fi, TCP/IP reset) are never ticked by default and say so in their hover text.
