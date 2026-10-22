# Check the connection and login to the office server (Windows > Diagnostics).
# Read-only. Keep this file ASCII-only.
Write-Step 'Checking the office server connection and login'
$st = Get-TTServerStatus
if (-not $st.Configured) { throw 'Set up the office server first.' }
foreach ($c in $st.Checks) {
    $line = '{0}: {1}' -f $c.Name, $c.Detail
    if ($c.Level -eq 'ok') { Write-Info $line } else { Write-Warn $line }
}
Set-Result $st
