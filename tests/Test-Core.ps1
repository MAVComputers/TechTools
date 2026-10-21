# Checks the catalog and the core engine. Runs on Windows PowerShell 5.1 and
# PowerShell 7 (Windows, macOS or Linux), so it can run in CI and locally.
#   pwsh -File tests/Test-Core.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'app/TechTools.Core.ps1')

$failures = New-Object System.Collections.ArrayList
function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  ok   $Name" }
    else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; [void]$failures.Add($Name) }
}

Write-Host 'Catalog'
$catalog = Import-TTCatalog -Root $root
Check 'categories load' ($catalog.Count -ge 1)
$problems = Test-TTCatalog -Catalog $catalog
foreach ($p in $problems) { Write-Host "       $p" -ForegroundColor Yellow }
Check 'catalog has no problems' ($problems.Count -eq 0) "($($problems.Count) problems)"
$net = $catalog | Where-Object { $_.Id -eq 'internet' }
Check 'internet category is live' ($net -and -not $net.ComingSoon)
Check 'internet has tools' (@($net.Tools).Count -gt 10)

Write-Host 'Files'
$ps1 = Get-ChildItem -Path $root -Recurse -Include *.ps1 -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
foreach ($f in $ps1) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
    Check "ASCII only: $($f.Name)" ($nonAscii -eq 0) '(Windows PowerShell 5.1 misreads non-ASCII in BOM-less files)'
    Check "parses: $($f.Name)" ((Test-TTScriptSyntax ([System.IO.File]::ReadAllText($f.FullName))).Count -eq 0)
}
$manifest = Read-TTJson (Join-Path $root 'manifest.json')
$needed = Get-ChildItem -Path (Join-Path $root 'app'), (Join-Path $root 'config') -Recurse -File |
    ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') }
foreach ($n in $needed) { Check "manifest lists $n" (@($manifest.files) -contains $n) }
foreach ($m in $manifest.files) { Check "manifest file exists: $m" (Test-Path (Join-Path $root $m)) }

Write-Host 'Jobs'
$sel = @{ 'internet:flushdns' = $true; 'internet:w_putty' = $true }
$choice = @{ 'internet:dns' = 'cloudflare' }
$jobs = Get-TTSelectionJobs -Category $net -Sel $sel -Choice $choice
Check 'selection builds 3 jobs' ($jobs.Count -eq 3) "(got $($jobs.Count))"
Check 'choice job is named after option' (@($jobs | Where-Object { $_.Name -like '*Cloudflare*' }).Count -eq 1)
Check 'winget job installs package' (@($jobs | Where-Object { $_.Script -match "--id 'PuTTY.PuTTY'" }).Count -eq 1)
Check 'step count read from script' ((@($jobs | Where-Object { $_.ToolId -eq 'flushdns' })[0]).Steps -eq 1)
$fakeWin = [pscustomobject]@{ Id = 'win'; Title = 'W'; Shared = ''; RestorePoint = $true; Tools = @(
    [pscustomobject]@{ Id = 'a'; Label = 'A'; Type = 'check'; Script = "Write-Step 'x'"; Restart = $false; Effect = ''; Options = @() }) }
$rp = Get-TTSelectionJobs -Category $fakeWin -Sel @{ 'win:a' = $true } -Choice @{}
Check 'restore point added first when category asks' ($rp.Count -eq 2 -and $rp[0].ToolId -eq '_restorepoint')

Write-Host 'Worker'
$cat = [pscustomobject]@{ Id = 't'; Title = 'Test'; Shared = 'function Get-Two { 2 }'; RestorePoint = $false }
$mk = { param($id, $script) [pscustomobject]@{ Id = $id; Label = $id; Type = 'check'; Script = $script; Restart = ($id -eq 'r'); Effect = ''; Options = @() } }
$sync = New-TTSync
foreach ($j in @(
    (New-TTJob -Category $cat -Tool (& $mk 'good' "Write-Step 'one'`nWrite-Step 'two'`n'hello'`nSet-Result (Get-Two)")),
    (New-TTJob -Category $cat -Tool (& $mk 'bad' "Write-Step 'boom'`nthrow 'broken on purpose'")),
    (New-TTJob -Category $cat -Tool (& $mk 'cmdletfail' "Write-Step 'missing'`nGet-Item -Path '/definitely/not/here'")),
    (New-TTJob -Category $cat -Tool (& $mk 'warn' "Write-Step 'w'`nWrite-Warn 'careful'")),
    (New-TTJob -Category $cat -Tool (& $mk 'r' "Write-Step 'x'"))
)) { [void]$sync.Jobs.Add($j) }
$sync.Jobs[4].Status = 'cancelled'
Invoke-TTJobsNow -Sync $sync
$byId = @{}; foreach ($j in $sync.Jobs) { $byId[$j.ToolId] = $j }
Check 'good job done' ($byId.good.Status -eq 'done' -and $byId.good.Percent -eq 100)
Check 'shared functions visible to tools' ($byId.good.Result -eq 2)
Check 'steps counted' ($byId.good.Step -eq 2 -and $byId.good.Steps -eq 2)
Check 'throw marks job failed' ($byId.bad.Status -eq 'failed' -and $byId.bad.Error -match 'broken on purpose')
Check 'cmdlet error fails job' ($byId.cmdletfail.Status -eq 'failed')
Check 'warnings counted' ($byId.warn.Status -eq 'done' -and $byId.warn.Warnings -eq 1)
Check 'cancelled job skipped' ($byId.r.Status -eq 'cancelled')
$lines = @(); $l = $null; while ($sync.Log.TryDequeue([ref]$l)) { $lines += $l }
Check 'log has output line' (@($lines | Where-Object { $_.Text -eq 'hello' }).Count -eq 1)
Check 'log has failure line' (@($lines | Where-Object { $_.Tone -eq 'fail' }).Count -eq 2)

Write-Host 'Diagnosis'
. (Join-Path $root 'config/scripts/internet/_shared.ps1')
$healthy = [pscustomobject]@{ Adapter = 'Ethernet'; AdapterDetail = 'Intel, 1 Gbps'; IPv4 = '192.168.1.42'; Dhcp = $true; Apipa = $false
    Gateway = '192.168.1.1'; GatewayMs = 2; GatewayLost = 0; GatewaySent = 4; Dns = @('192.168.1.1'); DnsMs = 20; DnsFailed = 0; DnsTotal = 3
    InternetMs = 14; InternetOk = $true; HttpOk = $true; CaptivePortal = $false; PublicIp = '203.0.113.24'; ProxyOn = $false; ProxyDetail = '' }
$r = Get-TTFindings $healthy
Check 'healthy PC has no problems' ($r.Problems -eq 0 -and @($r.Recommend).Count -eq 0)
$slow = $healthy.PSObject.Copy(); $slow.DnsMs = 380
$r = Get-TTFindings $slow
Check 'slow DNS is a warning' ($r.Problems -eq 1)
Check 'slow DNS recommends flush + Cloudflare' ((@($r.Recommend | ForEach-Object { $_.Id }) -join ',') -eq 'flushdns,dns' -and (@($r.Recommend)[1].Value -eq 'cloudflare'))
$apipa = $healthy.PSObject.Copy(); $apipa.IPv4 = '169.254.10.2'; $apipa.Apipa = $true; $apipa.Gateway = $null; $apipa.InternetOk = $false; $apipa.HttpOk = $false
$r = Get-TTFindings $apipa
Check 'no DHCP recommends renew' (@($r.Recommend | Where-Object { $_.Id -eq 'renew' }).Count -eq 1)
$proxy = $healthy.PSObject.Copy(); $proxy.ProxyOn = $true; $proxy.ProxyDetail = 'user proxy 10.0.0.1:8080'
$r = Get-TTFindings $proxy
Check 'proxy recommends proxy reset' (@($r.Recommend | Where-Object { $_.Id -eq 'proxyreset' }).Count -eq 1)
$ids = @($net.Tools | ForEach-Object { $_.Id })
foreach ($s in @($slow, $apipa, $proxy)) { foreach ($x in (Get-TTFindings $s).Recommend) { Check "recommended tool exists: $($x.Id)" ($ids -contains $x.Id) } }
$cards = Get-TTStatusCards $slow
Check 'six status cards' ($cards.Count -eq 6)
Check 'DNS card warns when slow' ((@($cards | Where-Object { $_.Label -eq 'DNS' })[0]).Level -eq 'warn')

Write-Host ''
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
