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
$go = [System.IO.File]::ReadAllText((Join-Path $root 'go.html'))
Check 'go.html is ASCII' ($go -notmatch '[^\x00-\x7F]')
Check 'go.html parses as PowerShell' ((Test-TTScriptSyntax $go).Count -eq 0)
Check 'go.html hides HTML in a block comment' ($go.StartsWith('<#') -and ([regex]::Matches($go, '#>')).Count -eq 1)
Check 'go.html runs the launcher' ($go -match "irm 'https://techtools\.mavcomputers\.com/run\.ps1' \| iex")
$launcher = [System.IO.File]::ReadAllText((Join-Path $root 'run.ps1'))
$appMain = [System.IO.File]::ReadAllText((Join-Path $root 'app/TechTools.ps1'))
Check 'launcher restarts elevated before downloading' ($launcher.IndexOf('-Verb RunAs') -gt 0 -and $launcher.IndexOf('-Verb RunAs') -lt $launcher.IndexOf('# Download the app.'))
Check 'app restarts elevated and exits when not admin' ($appMain -match '(?s)if \(-not \$script:IsAdmin -and -not \$SmokeTest\).{0,400}-Verb RunAs.{0,600}\bexit\b')
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

Write-Host 'PC health check'
$win = $catalog | Where-Object { $_.Id -eq 'windows' }
Check 'windows category is live' ($win -and -not $win.ComingSoon)
$hc = @($win.Tools | Where-Object { $_.Id -eq 'healthcheck' })[0]
Check 'health check is a quick action on Diagnostics' ($hc -and $hc.Type -eq 'quick' -and $hc.Tab -eq 'diag' -and $hc.Effect -eq 'healthreport')
Check 'health check has a step per check' ($hc.Script -and (Get-TTStepCount $hc.Script) -ge 12)
# Load the helpers in this session to test them directly.
. ([scriptblock]::Create($win.Shared))
$sec = New-TTSection 'Demo'
Add-TTFact $sec 'RAM in use' '90%' 'warn'
Add-TTTable $sec 'Drives' @('Disk', 'Problems') @([pscustomobject]@{ Disk = '0'; Problems = '<b>bad</b> & worse'; _Level = 'fail' })
Set-TTLevel $sec 'fail'; Set-TTLevel $sec 'warn'
Check 'section level only goes up' ($sec.Level -eq 'fail')
$crash = Invoke-TTHealthPart 'Broken' { throw 'boom' }
Check 'a crashing check becomes a failed section' ($crash.Level -eq 'fail' -and $crash.Summary -match 'boom')
Check 'subnet mask from prefix' ((ConvertTo-TTMask 24) -eq '255.255.255.0' -and (ConvertTo-TTMask 20) -eq '255.255.240.0')
$tmp = [System.IO.Path]::GetTempPath()
$report = New-TTHealthReport -Sections @($sec, $crash) -Folder $tmp
$html = [System.IO.File]::ReadAllText($report)
Check 'report file written' (Test-Path $report)
Check 'report escapes HTML' ($html -match '&lt;b&gt;bad&lt;/b&gt; &amp; worse' -and $html -notmatch '<b>bad')
Check 'report shows problem count' ($html -match '2 problem\(s\)')
Remove-Item $report -Force

Write-Host 'Office server'
$x = Split-TTUnc '\\OFFICE-SRV\Data\Sub\'
Check 'UNC path split' ($x.Server -eq 'OFFICE-SRV' -and $x.Share -eq 'Data' -and $x.Root -eq '\\OFFICE-SRV\Data')
Check 'bad UNC rejected' ($null -eq (Split-TTUnc 'OFFICE-SRV\Data'))
Check 'wrong password is a login problem' ((Get-TTShareProblem 'The user name or password is incorrect.') -eq 'auth')
Check 'access denied is a login problem' ((Get-TTShareProblem 'Access is denied.') -eq 'auth')
Check 'missing share detected' ((Get-TTShareProblem 'The network name cannot be found.') -eq 'share')
Check 'unreachable detected' ((Get-TTShareProblem 'The network path was not found.') -eq 'reach')
$tricky = 'p@ss "word" $x `y %z'
Check 'secrets embed safely in helper scripts' ((Invoke-Expression (ConvertTo-TTPsString $tricky)) -eq $tricky)
$remap = Get-TTRemapScript @([pscustomobject]@{ Letter = 'S:'; Path = '\\OFFICE-SRV\Data' }, [pscustomobject]@{ Letter = 'bad'; Path = 'x' })
Check 'drive remap script parses' ((Test-TTScriptSyntax ('$log = @()' + "`n" + $remap)).Count -eq 0)
Check 'drive remap skips bad letters' ($remap -notmatch 'net use bad')

# On Windows, run the read-only checks for real (skips speed test and Windows Update, which are slow).
if ($env:OS -eq 'Windows_NT') {
    $PSDefaultParameterValues['*:ErrorAction'] = 'Stop'
    $parts = [ordered]@{ System = { Get-TTHealthSystem }; Drives = { Get-TTHealthDisks }; Network = { Get-TTHealthNetwork }
        Events = { Get-TTHealthEvents }; Processes = { Get-TTHealthProcesses }; Shares = { Get-TTHealthShares }
        Printers = { Get-TTHealthPrinters }; Security = { Get-TTHealthSecurity } }
    foreach ($k in $parts.Keys) {
        $r = Invoke-TTHealthPart $k $parts[$k]
        Check "live check runs: $k" ($r.Summary -notmatch '^Could not check') ("($($r.Summary))")
        Write-Host ('       {0}: {1}' -f $r.Level, $r.Summary)
    }

    if (-not ('TTCred' -as [type])) { Add-Type -TypeDefinition $script:TTCredSource -Language CSharp }
    Check 'Credential Manager helper compiles' ([bool]('TTCred' -as [type]))
    # Point the server check at this PC's own admin share and run it.
    $cfgPath = Get-TTServerConfigPath
    $hadCfg = Test-Path $cfgPath
    if (-not $hadCfg) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $cfgPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($cfgPath, '{"Unc":"\\\\localhost\\C$","Drive":""}')
        $st = Invoke-TTHealthPart 'Server' { Get-TTServerStatus }
        Check 'live server check runs' ($st.Configured -and @($st.Checks).Count -ge 2) ("($($st.Summary))")
        foreach ($c in @($st.Checks)) { Write-Host ('       {0}: {1} - {2}' -f $c.Level, $c.Name, $c.Detail) }
        Remove-Item $cfgPath -Force
    }
    $PSDefaultParameterValues.Remove('*:ErrorAction')
}

Write-Host ''
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
