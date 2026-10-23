# Internet > Tools: Ookla speed test. Installs Speedtest CLI with winget the
# first time it is needed. Keep this file ASCII-only.
function Find-TTSpeedtest {
    $c = Get-Command speedtest.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($dir in @((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet'), (Join-Path $env:ProgramFiles 'WinGet'))) {
        if (Test-Path $dir) {
            $f = Get-ChildItem -Path $dir -Recurse -Filter speedtest.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
            if ($f) { return $f }
        }
    }
    return $null
}

Write-Step 'Finding Speedtest CLI'
$exe = Find-TTSpeedtest
if ($exe) { Write-Info ('Found ' + $exe) }

Write-Step 'Installing Speedtest CLI if needed'
if (-not $exe) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Speedtest CLI is missing and winget is not available to install it. Install or update App Installer from the Microsoft Store.' }
    Write-Info 'Speedtest CLI is not installed yet. Installing it with winget (one time).'
    winget install --id 'Ookla.Speedtest.CLI' --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '[A-Za-z]' -and $_ -notmatch '[\u2580-\u259F]' } | ForEach-Object { Write-Info $_.Trim() }
    Assert-TTExit 'winget install Speedtest CLI' -Ok 0, -1978335189, -1978335135
    $exe = Find-TTSpeedtest
    if (-not $exe) { throw 'Speedtest CLI was installed but could not be found. Close TechTools, open it again and retry.' }
} else { Write-Info 'Already installed' }

Write-Step 'Running speed test (about 30 seconds)'
& $exe --accept-license --accept-gdpr 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '[A-Za-z]' } | ForEach-Object { Write-Info $_.TrimEnd() }
Assert-TTExit 'speedtest'
