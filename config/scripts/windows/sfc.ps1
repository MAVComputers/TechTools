# Windows > Repair: System File Checker. Takes 10-20 minutes. Keep this file ASCII-only.
Write-Step 'SFC: scanning and repairing system files (10-20 min)'
$r = Invoke-TTWatchedProcess -File (Join-Path $env:windir 'System32\sfc.exe') -Arguments '/scannow' -Label 'SFC'
$o = Get-TTSfcOutcome $r.Text $r.Code
if ($o.Level -eq 'ok' -or $o.Level -eq 'info') { Write-Info $o.Text } elseif ($o.Level -eq 'warn') { Write-Warn $o.Text } else { throw $o.Text }
