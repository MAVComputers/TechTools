# Windows > Repair: online disk check of C: (no restart, no fixing). Keep this file ASCII-only.
Write-Step 'Checking drive C: for file system errors (online scan)'
$out = & chkdsk.exe ($env:SystemDrive) /scan 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '[A-Za-z]' -and $_ -notmatch 'percent complete|% complete' }
$code = $LASTEXITCODE
$out | Select-Object -Last 8 | ForEach-Object { Write-Info $_.Trim() }
if ($code -eq 0) { Write-Info 'No problems found on C:' }
elseif ($code -eq 1) { Write-Info 'Errors were found and fixed' }
elseif ($code -eq 2) { Write-Info 'No errors; chkdsk did some routine cleanup' }
elseif ($code -eq 3) { Write-Warn 'Problems found that need an offline repair. Schedule chkdsk C: /f and restart after hours.' }
else { throw ('chkdsk failed (exit code ' + $code + ')') }
$global:LASTEXITCODE = 0
