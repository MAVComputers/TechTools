# Free up space on C: (temp files and the Windows Update download cache). Keep this file ASCII-only.
function Get-TTFreeGB { [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 1) }
function Remove-TTOld {
    # Deletes files older than a day under a folder; files in use are skipped.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $cut = (Get-Date).AddDays(-1)
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch { }
    }
    return $n
}
$before = Get-TTFreeGB
Write-Info ('Free on C: before: ' + $before + ' GB')
Write-Step 'Deleting Windows temp files'
Write-Info ('Windows temp: ' + (Remove-TTOld (Join-Path $env:SystemRoot 'Temp')) + ' file(s)')
Write-Step 'Deleting temp files in each user profile'
foreach ($u in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -Force -ErrorAction SilentlyContinue)) {
    $t = Join-Path $u.FullName 'AppData\Local\Temp'
    if (Test-Path -LiteralPath $t) { $n = Remove-TTOld $t; if ($n) { Write-Info ($u.Name + ': ' + $n + ' file(s)') } }
}
Write-Step 'Clearing the Windows Update download cache'
try {
    Stop-Service -Name wuauserv -Force -ErrorAction Stop
    Stop-Service -Name bits -Force -ErrorAction SilentlyContinue
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction Stop; $n++ } catch { }
    }
    Write-Info ('Update downloads removed: ' + $n + ' item(s). Windows downloads them again if still needed.')
} catch { Write-Warn ('Could not stop Windows Update: ' + $_.Exception.Message) }
finally { Start-Service -Name bits -ErrorAction SilentlyContinue; Start-Service -Name wuauserv -ErrorAction SilentlyContinue }
Write-Step 'Clearing the Delivery Optimization cache'
try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; Write-Info 'Delivery Optimization cache cleared' } catch { Write-Info 'Delivery Optimization cache: nothing to clear' }
$after = Get-TTFreeGB
Write-Info ('Free on C: after: ' + $after + ' GB (' + [math]::Round($after - $before, 1) + ' GB freed)')
