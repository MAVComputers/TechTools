# Sets the password TechTools asks for when it opens. Stores only a salted hash
# in config/auth.json (safe to commit). Use 12+ characters: the repo is public.
#   pwsh -File tools/Set-TeamPassword.ps1
# Then commit config/auth.json and merge to main.
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'app/TechTools.Core.ps1')
$a = Read-Host -AsSecureString 'New team password'
$b = Read-Host -AsSecureString 'Type it again'
$pa = ConvertFrom-TTSecure $a; $pb = ConvertFrom-TTSecure $b
if ($pa -ne $pb) { throw 'The two passwords do not match.' }
if ($pa.Length -lt 12) { throw 'Use at least 12 characters.' }
$rec = New-TTAuthRecord -Password $pa
[System.IO.File]::WriteAllText((Join-Path $root 'config/auth.json'), (($rec | ConvertTo-Json) + "`n"))
Write-Host 'config/auth.json updated. Commit it to change the password for every tech.'
