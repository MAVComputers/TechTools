# Finds which dental programs are installed (read-only). Keep this file ASCII-only.
Write-Step 'Reading installed programs'
$apps = Get-TTInstalledApps
Write-Step 'Matching dental programs'
$found = @()
foreach ($p in @((Get-TTInput).Programs)) {
    $v = Find-TTProgram $p $apps
    if ($v) { $found += [pscustomobject]@{ Id = [string]$p.id; Name = [string]$p.name; Version = $v }; Write-Info ('Found ' + $p.name + ' ' + $v) }
}
if (-not $found.Count) { Write-Info 'No dental programs found on this PC' }
Set-Result ([pscustomobject]@{ At = (Get-Date); Found = $found })
