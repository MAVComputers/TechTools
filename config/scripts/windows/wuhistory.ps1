# Last 15 installed Windows updates. Read-only. Keep this file ASCII-only.
Write-Step 'Reading update history'
$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$n = $searcher.GetTotalHistoryCount()
if ($n -lt 1) { Write-Info 'No update history on this PC' }
else {
    foreach ($h in @($searcher.QueryHistory(0, [math]::Min(15, [int]$n)))) {
        $res = @{ 1 = 'in progress'; 2 = 'installed'; 3 = 'installed with errors'; 4 = 'FAILED'; 5 = 'cancelled' }[[int]$h.ResultCode]
        if (-not $h.Title) { continue }
        $line = '{0}  {1}  {2}' -f $h.Date.ToLocalTime().ToString('yyyy-MM-dd'), $res, $h.Title
        if ([int]$h.ResultCode -eq 4) { Write-Warn $line } else { Write-Info $line }
    }
}
