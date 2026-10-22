# Rebuilds manifest.json from the files under app/ and config/.
# Run after adding or removing a file:   pwsh -File tools/Update-Manifest.ps1 [-Version 0.2.0]
param([string]$Version)
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'manifest.json'
if (-not $Version) { $Version = (Get-Content -Raw -Path $path | ConvertFrom-Json).version }
$files = Get-ChildItem -Path (Join-Path $root 'app'), (Join-Path $root 'config') -Recurse -File |
    ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') } | Sort-Object
$json = [ordered]@{ version = $Version; files = @($files) } | ConvertTo-Json
[System.IO.File]::WriteAllText($path, $json + "`n")
Write-Host "manifest.json: v$Version, $(@($files).Count) files"
