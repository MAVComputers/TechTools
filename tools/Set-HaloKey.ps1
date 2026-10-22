# Saves the HaloPSA connection for "Send to ticket" in config/halo.json.
# The client secret is encrypted with the team password; only techs who know
# that password can unlock it. Commit config/halo.json and merge to main.
#   pwsh -File tools/Set-HaloKey.ps1
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'app/TechTools.Core.ps1')
$auth = Read-TTJson (Join-Path $root 'config/auth.json')
$team = ConvertFrom-TTSecure (Read-Host -AsSecureString 'Team password (the one TechTools asks for)')
if (-not (Test-TTPassword -Password $team -Auth $auth)) { throw 'That is not the current team password.' }
$url = (Read-Host 'HaloPSA address, for example https://mavcomputers.halopsa.com').Trim().TrimEnd('/')
if ($url -notmatch '^https://[A-Za-z0-9.-]+$') { throw 'Enter the address as https://name.halopsa.com' }
$tenant = (Read-Host 'Tenant (leave empty unless Halo shows one on the API page)').Trim()
$clientId = (Read-Host 'Client ID of the "MAV Tech Tools" API application').Trim()
$secret = ConvertFrom-TTSecure (Read-Host -AsSecureString 'Client secret')
if (-not $clientId -or -not $secret) { throw 'Client ID and secret are both needed.' }
$outcome = (Read-Host 'Action outcome for the note [Private Note]').Trim()
if (-not $outcome) { $outcome = 'Private Note' }
$cfg = [ordered]@{ url = $url; tenant = $tenant; clientId = $clientId; outcome = $outcome; secret = (Protect-TTSecret -Secret $secret -Password $team) }
[System.IO.File]::WriteAllText((Join-Path $root 'config/halo.json'), (($cfg | ConvertTo-Json -Depth 4) + "`n"))
Write-Host 'config/halo.json saved. Run tools/Update-Manifest.ps1, then commit and merge.'
