# Windows > Repair: DISM component store repair. Needs internet. Keep this file ASCII-only.
Write-Step 'DISM: repairing the Windows image (5-20 min, needs internet)'
$r = Invoke-TTWatchedProcess -File (Join-Path $env:windir 'System32\Dism.exe') -Arguments '/Online /Cleanup-Image /RestoreHealth' -Label 'DISM'
$o = Get-TTDismOutcome $r.Text $r.Code
if ($o.Level -eq 'ok') { Write-Info $o.Text } else { throw $o.Text }
