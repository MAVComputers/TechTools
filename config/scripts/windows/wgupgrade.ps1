# Upgrade every app winget can upgrade. Keep this file ASCII-only.
Write-Step 'Checking winget'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget is not available. Install or update App Installer from the Microsoft Store.' }
Write-Step 'Upgrading all apps (can take several minutes)'
winget upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '[A-Za-z]' -and $_ -notmatch '[\u2580-\u259F]' } | ForEach-Object { Write-Info $_.Trim() }
# 0 = done, -1978335189 = nothing to upgrade, -1978335135 = some packages need a newer installer
Assert-TTExit 'winget upgrade' -Ok 0, -1978335189, -1978335135
