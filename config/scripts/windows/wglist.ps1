# List apps installed on this PC (winget). Read-only. Keep this file ASCII-only.
Write-Step 'Checking winget'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget is not available. Install or update App Installer from the Microsoft Store.' }
Write-Step 'Listing installed apps'
winget list --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '[A-Za-z]' -and $_ -notmatch '[\u2580-\u259F]' } | ForEach-Object { Write-Info $_.TrimEnd() }
Assert-TTExit 'winget list'
