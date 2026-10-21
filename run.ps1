# MAV TechTools launcher.
# Techs start the toolkit from an admin PowerShell window with:
#     irm techtools.mavcomputers.com/run.ps1 | iex
# It downloads the latest app files to a temp folder and opens the window.
# Nothing is installed. Keep this file ASCII-only.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $sources = @('https://techtools.mavcomputers.com', 'https://raw.githubusercontent.com/MAVComputers/TechTools/main')
    if ($env:MAVTT_BASE) { $sources = @($env:MAVTT_BASE) + $sources }

    Write-Host ''
    Write-Host '  MAV Computers LLC - TechTools' -ForegroundColor Cyan
    Write-Host ''

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Write-Host '  TechTools only runs on Windows.' -ForegroundColor Red; return }

    # Find a source that answers.
    $base = $null
    $manifest = $null
    foreach ($s in $sources) {
        try {
            $manifest = Invoke-RestMethod -Uri ($s.TrimEnd('/') + '/manifest.json?t=' + [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 15
            if ($manifest.files) { $base = $s.TrimEnd('/'); break }
        } catch { }
    }
    if (-not $base) { Write-Host '  Could not reach the TechTools download site. Check the internet connection.' -ForegroundColor Red; return }

    # Most repairs need admin rights: restart elevated if needed.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host '  Asking for administrator rights...'
        $cmd = "`$env:MAVTT_BASE='$base'; irm '$base/run.ps1' | iex"
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
        } catch { Write-Host '  Administrator rights were not granted. TechTools needs them for most repairs.' -ForegroundColor Yellow }
        return
    }

    # Download the app.
    $dir = Join-Path $env:TEMP 'MAVTechTools'
    if (Test-Path $dir) { Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ('  Downloading v{0} from {1}' -f $manifest.version, $base)
    foreach ($f in $manifest.files) {
        if ($f -notmatch '^[A-Za-z0-9_\-./]+$' -or $f -match '\.\.') { throw "Bad file name in manifest: $f" }
        $target = Join-Path $dir ($f -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Invoke-WebRequest -Uri ($base + '/' + $f + '?v=' + $manifest.version) -OutFile $target -UseBasicParsing -TimeoutSec 30
    }
    Invoke-WebRequest -Uri ($base + '/manifest.json?v=' + $manifest.version) -OutFile (Join-Path $dir 'manifest.json') -UseBasicParsing -TimeoutSec 30

    # Run the window in Windows PowerShell 5.1 (STA, WPF built in), even if this is PowerShell 7.
    Write-Host '  Starting TechTools...'
    $app = Join-Path $dir 'app\TechTools.ps1'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$app`"", '-ConfigRoot', "`"$dir`"")
}
