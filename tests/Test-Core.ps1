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
Check 'every category has its own color' (@($catalog | Where-Object { $_.Color -notmatch '^#[0-9A-Fa-f]{6}$' }).Count -eq 0 -and @($catalog.Color | Select-Object -Unique).Count -eq $catalog.Count)

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
    (New-TTJob -Category $cat -Tool (& $mk 'r' "Write-Step 'x'")),
    (New-TTJob -Category $cat -Tool (& $mk 'prog' "Write-Step 'a'`nWrite-Step 'b'`nSet-TTProgress 50 'half way'`nSet-Result @(`$script:TTJob.Percent, `$script:TTJob.StepText)"))
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
Check 'progress inside a step' ($byId.prog.Result[0] -eq 75 -and $byId.prog.Result[1] -eq 'half way') ("(got $($byId.prog.Result -join ', '))")
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

Write-Host 'More diagnostics'
foreach ($id in @('slowpc', 'printscan', 'printclear', 'crashes', 'repair', 'battery', 'timesync')) {
    $t = @($win.Tools | Where-Object { $_.Id -eq $id })[0]
    Check "$id is a report button on Diagnostics" ($t -and $t.Type -eq 'quick' -and $t.Tab -eq 'diag' -and $t.Effect -eq 'healthreport' -and -not $t.Hidden -and (Get-TTStepCount $t.Script) -ge 3)
}
$base = [pscustomobject]@{ CpuAvg = 10; CpuTop = ''; MemAvg = 40; MemTop = 'chrome'; DiskAvg = 5; Kind = 'M.2 NVMe SSD'; FreePct = 60; FreeGb = 200; Days = 1; FastStartup = $false; Startup = 5; Plan = 'Balanced' }
$c = Get-TTSlowCause $base
Check 'healthy PC: no clear cause' ($c.Level -eq 'ok' -and $c.Text -match 'No clear cause')
$x = $base.PSObject.Copy(); $x.FreePct = 4; $x.FreeGb = 9; $x.Days = 20
$c = Get-TTSlowCause $x
Check 'full C: drive is the likely cause' ($c.Level -eq 'fail' -and $c.Text -match 'nearly full' -and @($c.All).Count -eq 2)
$x = $base.PSObject.Copy(); $x.DiskAvg = 95; $x.Kind = 'HDD (SATA)'
Check 'busy hard drive blames the HDD' ((Get-TTSlowCause $x).Text -match 'SSD would fix')
$x = $base.PSObject.Copy(); $x.CpuAvg = 92; $x.CpuTop = 'MsMpEng'
Check 'busy CPU names the process' ((Get-TTSlowCause $x).Text -match 'MsMpEng')
$x = $base.PSObject.Copy(); $x.Days = 12; $x.FastStartup = $true
Check 'long uptime says Restart not Shut down' ((Get-TTSlowCause $x).Text -match 'Restart, not Shut down')
Check 'bugcheck 0x116 is the graphics driver' ((Get-TTBugcheckInfo '0x00000116').Name -eq 'VIDEO_TDR_FAILURE')
Check 'bugcheck 0x9F named' ((Get-TTBugcheckInfo '0x0000009f').Name -eq 'DRIVER_POWER_STATE_FAILURE')
Check 'unknown bugcheck kept as code' ((Get-TTBugcheckInfo '0x00000abc').Name -match '0xABC')
$off = ConvertFrom-TTStripchart @('Tracking time.windows.com [1.2.3.4:123].', '14:05:01, +00.0153257s', '14:05:03, error: 0x800705B4', '14:05:05, -01.5000000s')
Check 'clock offsets read from w32tm' ($off.Count -eq 2 -and [math]::Abs($off[0] - 0.0153257) -lt 0.0001 -and $off[1] -eq -1.5)
Check 'SFC clean result' ((Get-TTSfcOutcome 'Windows Resource Protection did not find any integrity violations.').Level -eq 'ok')
Check 'SFC repaired result' ((Get-TTSfcOutcome 'Windows Resource Protection found corrupt files and successfully repaired them.').Repaired)
Check 'SFC partial result fails' ((Get-TTSfcOutcome 'Windows Resource Protection found corrupt files but was unable to fix some of them.').Level -eq 'fail')
Check 'DISM missing source explained' ((Get-TTDismOutcome 'Error: 0x800f081f The source files could not be found.' 1).Text -match 'download repair files')
$req = ConvertFrom-TTPowerRequests @('DISPLAY:', 'None.', '', 'SYSTEM:', '[DRIVER] Realtek High Definition Audio (HDAUDIO\FUNC_01)', 'An audio stream is currently in use.', '[PROCESS] \Device\HarddiskVolume3\Program Files\App\app.exe', '', 'AWAYMODE:', 'None.')
Check 'sleep blockers read from powercfg' ($req.Count -eq 2 -and $req[0].Blocks -eq 'SYSTEM' -and $req[0].Reason -match 'audio' -and $req[1].Who -eq 'app.exe')
$rep = New-TTHealthReport -Sections @($sec) -Folder $tmp -Title 'Slow PC Check' -Prefix 'SlowPC' -Lead 'Likely cause: test'
$html = [System.IO.File]::ReadAllText($rep)
Check 'report uses its own title and name' ((Split-Path -Leaf $rep) -like 'SlowPC-*' -and $html -match '<h1>Slow PC Check:' -and $html -match 'Likely cause: test')
Remove-Item $rep -Force

Write-Host 'Dental'
$den = $catalog | Where-Object { $_.Id -eq 'dental' }
Check 'dental category is live' ($den -and -not $den.ComingSoon)
$mw = @($den.Tools | Where-Object { $_.Id -eq 'mouthwatch' })[0]
Check 'MouthWatch IOC is a quick button on 3rd Party Apps' ($mw -and $mw.Type -eq 'quick' -and $mw.Tab -eq '3p' -and $mw.Label -eq 'MouthWatch IOC')
Check 'MouthWatch downloads over https from mouthwatch.com' ($mw.Script -match "https://mouthwatch\.com/wp-content/uploads/downloads/setupmouthwatch\.exe")
Check 'MouthWatch shows the installer password to copy' ($mw.Notice -and $mw.Notice.Copy -eq 'YP9RQH')
# Worker-only helpers the install scripts call
if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) { function Write-Info { param([string]$Text) } }
if (-not (Get-Command Write-Warn -ErrorAction SilentlyContinue)) { function Write-Warn { param([string]$Text) } }
. ([scriptblock]::Create($den.Shared))
$threw = $false; try { Save-TTDownload -Url 'http://example.com/x.exe' -Name 'x.exe' } catch { $threw = $_.Exception.Message -match 'https' }
Check 'plain http downloads refused' $threw
$threw = $false; try { Save-TTDownload -Url 'https://example.com/x.exe' -Name '..\x.exe' } catch { $threw = $_.Exception.Message -match 'Bad file name' }
Check 'download file names checked' $threw
if ($env:OS -eq 'Windows_NT') {
    $dl = Save-TTDownload -Url 'https://www.microsoft.com/favicon.ico' -Name 'tt-test.ico'
    Check 'live download works' ((Test-Path $dl) -and (Get-Item $dl).Length -gt 0)
    Remove-Item $dl -Force
    $acl = (Get-Acl (Get-TTDownloadFolder)).Access | Where-Object { $_.IdentityReference -match 'Users|Everyone|Authenticated' }
    Check 'download folder is admin-only' (@($acl).Count -eq 0)
    $ok = $true; try { Assert-TTSignature (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') } catch { $ok = $false }
    Check 'signed Windows file passes the signature check' $ok
}

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

    $more = [ordered]@{ Uptime = { Get-TTUptimeSection }; 'Slow sample' = { Get-TTPressureSection (Get-TTSlowSample -Seconds 4) }
        'C: drive' = { Get-TTSystemDriveSection }; Startup = { Get-TTStartupSection }; Spooler = { Get-TTSpoolerSection }
        'Printer reach' = { Get-TTPrintersSection }; 'Print queue' = { Get-TTPrintJobsSection }; Scanners = { Get-TTScannersSection }
        BSOD = { Get-TTBsodSection }; Shutdowns = { Get-TTShutdownSection }; 'App crashes' = { Get-TTAppCrashSection }
        Battery = { Get-TTBatterySection -Folder $tmp }; 'Power plan' = { Get-TTPowerPlanSection -HasBattery $false }; Sleep = { Get-TTSleepSection }
        Domain = { Get-TTDomainSection }; Clock = { Get-TTTimeSection -Dc '' } }
    foreach ($k in $more.Keys) {
        $r = Invoke-TTHealthPart $k $more[$k]
        Check "live check runs: $k" ($r.Summary -notmatch '^Could not check') ("($($r.Summary))")
        Write-Host ('       {0}: {1}' -f $r.Level, $r.Summary)
    }
    # Whole tool scripts through the real worker (the read-only ones).
    $wsync = New-TTSync -LogFile (Join-Path $tmp 'tt-test.log')
    foreach ($id in @('printscan', 'crashes', 'battery', 'timesync')) {
        [void]$wsync.Jobs.Add((New-TTJob -Category $win -Tool (@($win.Tools | Where-Object { $_.Id -eq $id })[0])))
    }
    Invoke-TTJobsNow -Sync $wsync
    foreach ($j in $wsync.Jobs) {
        $ok = $j.Status -eq 'done' -and $j.Result -and $j.Result.Tool -and (Test-Path $j.Result.Html) -and @($j.Result.Sections).Count -ge 1
        Check "tool runs end to end: $($j.ToolId)" $ok ("($($j.Status) $($j.Error))")
        if ($j.Result -and $j.Result.Html) { Remove-Item $j.Result.Html -Force -ErrorAction SilentlyContinue }
    }
    $l = $null; while ($wsync.Log.TryDequeue([ref]$l)) { if ($l.Tone -eq 'fail') { Write-Host ('       ' + $l.Text) } }

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

# Startup password: only a salted hash ships, right password opens, wrong ones do not
$authFile = Join-Path (Join-Path $root 'config') 'auth.json'
$auth = Read-TTJson $authFile
Check 'password file is a PBKDF2 hash' ([string]$auth.kdf -eq 'pbkdf2-sha256' -and [int]$auth.iterations -ge 100000 -and [Convert]::FromBase64String([string]$auth.hash).Length -eq 32)
Check 'password file holds no plain password' (@($auth.PSObject.Properties.Name | Where-Object { $_ -notin @('kdf', 'iterations', 'salt', 'hash') }).Count -eq 0)
$rec = New-TTAuthRecord -Password 'correct horse battery' -Iterations 100000
$recObj = [pscustomobject]$rec
Check 'right password unlocks' (Test-TTPassword -Password 'correct horse battery' -Auth $recObj)
Check 'wrong password is refused' (-not (Test-TTPassword -Password 'correct horse batterY' -Auth $recObj))
Check 'empty password is refused' (-not (Test-TTPassword -Password '' -Auth $recObj))
Check 'weak hash settings are refused' (-not (Test-TTPassword -Password 'x' -Auth ([pscustomobject]@{ kdf = 'pbkdf2-sha256'; iterations = 1; salt = 'AA=='; hash = 'AA==' })))
$sec = New-Object Security.SecureString; foreach ($ch in 'abc'.ToCharArray()) { $sec.AppendChar($ch) }
Check 'secure text converts for hashing' ((ConvertFrom-TTSecure $sec) -eq 'abc')

# HaloPSA: key locked with the team password, note text, and the send script (Halo API mocked)
$box = Protect-TTSecret -Secret 'halo-client-secret' -Password 'team pass 123' -Iterations 100000
Check 'locked key opens with the team password' ((Unprotect-TTSecret -Box $box -Password 'team pass 123') -eq 'halo-client-secret')
Check 'locked key stays shut with a wrong password' ($null -eq (Unprotect-TTSecret -Box $box -Password 'team pass 124'))
$tampered = [pscustomobject]$box; $tampered.data = [Convert]::ToBase64String((New-Object byte[] 32))
Check 'changed key data is refused' ($null -eq (Unprotect-TTSecret -Box $tampered -Password 'team pass 123'))
Check 'locked key file holds no plain secret' (-not (($box | ConvertTo-Json) -match 'halo-client-secret'))
$rep = [pscustomobject]@{ Title = 'Slow PC Check'; Lead = 'Likely cause: <disk> full'; Sections = @(
    [pscustomobject]@{ Title = 'Drives'; Level = 'fail'; Summary = 'C: 2 GB free' },
    [pscustomobject]@{ Title = 'RAM'; Level = 'warn'; Summary = '91% used' },
    [pscustomobject]@{ Title = 'System'; Level = 'ok'; Summary = 'fine' }) }
$noteHtml = ConvertTo-TTHaloNote -Report $rep -Headline '1 problem(s) and 1 warning(s) found' -Pc 'PC-1' -RunBy 'DOM\tech'
Check 'Halo note lists problems and warnings only' ($noteHtml -match 'PROBLEM</b> Drives' -and $noteHtml -match 'WARNING</b> RAM' -and $noteHtml -notmatch 'System')
Check 'Halo note escapes HTML' ($noteHtml -match '&lt;disk&gt;' -and $noteHtml -notmatch '<disk>')
Check 'ticket numbers are checked' ((Test-TTTicketNumber '10482') -and (Test-TTTicketNumber '#77') -and -not (Test-TTTicketNumber '12a') -and -not (Test-TTTicketNumber ''))
$haloCalls = New-Object System.Collections.ArrayList
$haloFile = Join-Path ([System.IO.Path]::GetTempPath()) ('tt-halo-' + [guid]::NewGuid().ToString('N') + '.html')
[System.IO.File]::WriteAllText($haloFile, '<html>report</html>')
& {
    function Get-TTInput { @{ Url = 'https://example.halopsa.com'; Tenant = ''; ClientId = 'cid'; Secret = 'sec'; Outcome = ''; Ticket = '#10482'; NoteHtml = '<p>n</p>'; Html = $haloFile; AttachPdf = $false } }
    function Write-Step { param($Text) }
    function Write-Info { param($Text) }
    function Write-Warn { param($Text) [void]$haloCalls.Add('WARN ' + $Text) }
    function Invoke-RestMethod {
        param($Method, $Uri, $Body, $Headers, $ContentType, $TimeoutSec, [switch]$UseBasicParsing)
        $b = $Body; if ($b -is [byte[]]) { $b = [Text.Encoding]::UTF8.GetString($b) }
        [void]$haloCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $b; Auth = $(if ($Headers) { $Headers.Authorization } else { '' }) })
        if ($Uri -like '*/auth/token*') { return [pscustomobject]@{ access_token = 'tok' } }
        if ($Uri -like '*/api/Tickets/*') { return [pscustomobject]@{ id = 10482; summary = 'PC slow' } }
        if ($Uri -like '*/api/Actions') { return [pscustomobject]@{ id = 555 } }
        return $null
    }
    . (Join-Path $root 'config/scripts/common/halo.ps1')
}
Remove-Item $haloFile -Force -ErrorAction SilentlyContinue
$calls = @($haloCalls | Where-Object { $_ -isnot [string] })
Check 'Halo send signs in, finds the ticket, adds a note, attaches' ($calls.Count -eq 4 -and $calls[0].Uri -eq 'https://example.halopsa.com/auth/token' -and $calls[1].Uri -like '*/api/Tickets/10482' -and $calls[2].Uri -like '*/api/Actions' -and $calls[3].Uri -like '*/api/Attachment')
Check 'Halo note is private, on the right ticket' ($calls.Count -ge 3 -and $calls[2].Body -match '"hiddenfromuser":\s*true' -and $calls[2].Body -match '"ticket_id":\s*10482' -and $calls[2].Body -match 'Private Note')
Check 'Halo attachment is linked to the note' ($calls.Count -ge 4 -and $calls[3].Body -match '"action_id":\s*555' -and $calls[3].Body -match 'data_base64')
Check 'Halo asks only for ticket permissions' ($calls.Count -ge 1 -and $calls[0].Body.scope -eq 'read:tickets edit:tickets')
Check 'Halo calls use the token' ($calls.Count -ge 4 -and $calls[1].Auth -eq 'Bearer tok' -and $calls[3].Auth -eq 'Bearer tok')
Check 'Halo send logged no warnings' (@($haloCalls | Where-Object { $_ -is [string] }).Count -eq 0) (@($haloCalls | Where-Object { $_ -is [string] }) -join '; ')

# Halo attachment falls back to other formats when Halo rejects the first
$haloCalls2 = New-Object System.Collections.ArrayList
$haloFile2 = Join-Path ([System.IO.Path]::GetTempPath()) ('tt-halo2-' + [guid]::NewGuid().ToString('N') + '.html')
[System.IO.File]::WriteAllText($haloFile2, '<html>report</html>')
& {
    function Get-TTInput { @{ Url = 'https://example.halopsa.com'; ClientId = 'cid'; Secret = 'sec'; Ticket = '5'; NoteHtml = 'n'; Html = $haloFile2; AttachPdf = $false } }
    function Write-Step { param($Text) }
    function Write-Info { param($Text) [void]$haloCalls2.Add('INFO ' + $Text) }
    function Write-Warn { param($Text) [void]$haloCalls2.Add('WARN ' + $Text) }
    function Invoke-RestMethod {
        param($Method, $Uri, $Body, $Headers, $ContentType, $TimeoutSec, [switch]$UseBasicParsing)
        if ($Uri -like '*/auth/token*') { return [pscustomobject]@{ access_token = 'tok' } }
        if ($Uri -like '*/api/Tickets/*') { return [pscustomobject]@{ id = 5; summary = 's' } }
        if ($Uri -like '*/api/Actions') { return [pscustomobject]@{ id = 9 } }
        $b = [Text.Encoding]::UTF8.GetString($Body)
        [void]$haloCalls2.Add('ATT ' + $b.TrimStart().Substring(0, 1))
        if ($b.TrimStart().StartsWith('{') -and $b -match 'data:text/html;base64,') { return $null }
        throw 'HTTP 500'
    }
    . (Join-Path $root 'config/scripts/common/halo.ps1')
}
Remove-Item $haloFile2 -Force -ErrorAction SilentlyContinue
Check 'Halo attachment tries other formats until one works' ((@($haloCalls2 | Where-Object { $_ -like 'ATT *' }).Count -eq 3) -and ($haloCalls2 -contains 'INFO Halo took attachment format 3') -and -not (@($haloCalls2 | Where-Object { $_ -like 'WARN*' }).Count))

Write-Host 'Dental programs'
$dentalDoc = Read-TTJson (Join-Path $root 'config/dental/programs.json')
$dprogs = @($dentalDoc.programs)
$fixTypes = @('porttest', 'sharetest', 'odconfig', 'perm', 'firewall', 'setup', 'services', 'usbpower', 'sensorreset', 'openurl', 'shortcut')
$fixScript = [System.IO.File]::ReadAllText((Join-Path $root 'config/scripts/dental/fix.ps1'))
$seen = @{}; $badProg = @()
foreach ($p in $dprogs) {
    if (-not $p.id -or $seen[$p.id] -or -not $p.name -or @('pm', 'cloud', 'img', 'imgcloud') -notcontains $p.kind) { $badProg += [string]$p.id }
    $seen[$p.id] = $true
    foreach ($f in @($p.fixes)) { if ($fixTypes -notcontains $f.type -or -not $f.label -or $fixScript -notmatch ("'" + $f.type + "'")) { $badProg += ($p.id + '/' + $f.id) } }
    if ($p.match) { try { [void]('x' -match $p.match) } catch { $badProg += ($p.id + ' match') } }
}
Check 'programs.json entries are valid' ($badProg.Count -eq 0) ($badProg -join ', ')
foreach ($id in @('opendental', 'eaglesoft', 'dentrix', 'practiceworks', 'dexis9', 'dexis10', 'dtxstudio', 'xvweb', 'csimaging')) {
    Check "main program listed: $id" (@($dprogs | Where-Object { $_.id -eq $id -and $_.main }).Count -eq 1)
}
Check 'programs.json is ASCII' (([System.IO.File]::ReadAllText((Join-Path $root 'config/dental/programs.json'))) -notmatch '[^\x00-\x7F]')
. (Join-Path $root 'config/scripts/dental/_dental.ps1')
$fakeApps = @([pscustomobject]@{ Name = 'Dentrix Ascend Imaging Bridge'; Version = '1.0' }, [pscustomobject]@{ Name = 'DEXIS'; Version = '10.4.2' },
    [pscustomobject]@{ Name = 'Open Dental'; Version = '24.3.10.0' })
$pd = { param($id) @($dprogs | Where-Object { $_.id -eq $id })[0] }
Check 'finds Open Dental with its version' ((Find-TTProgram (& $pd 'opendental') $fakeApps) -eq '24.3.10.0')
Check 'Dentrix Ascend is not Dentrix' (-not (Find-TTProgram (& $pd 'dentrix') $fakeApps))
Check 'DEXIS 10 found by version' ((Find-TTProgram (& $pd 'dexis10') $fakeApps) -eq '10.4.2')
Check 'DEXIS 10 is not DEXIS 9' (-not (Find-TTProgram (& $pd 'dexis9') $fakeApps))
$dcat = $catalog | Where-Object { $_.Id -eq 'dental' }
$dsync = New-TTSync
$scanJob = New-TTJob -Category $dcat -Tool (@($dcat.Tools | Where-Object { $_.Id -eq 'dscan' })[0])
$scanJob.Input = @{ Programs = @(@{ id = 'opendental'; name = 'Open Dental'; match = '^Open Dental'; verMatch = ''; folder = '' }) }
$cloudJob = New-TTJob -Category $dcat -Tool (@($dcat.Tools | Where-Object { $_.Id -eq 'dcheck' })[0])
$cloudJob.Input = @{ Program = (& $pd 'carestack'); Server = ''; Share = ''; Url = '' }
$fixJob = New-TTJob -Category $dcat -Tool (@($dcat.Tools | Where-Object { $_.Id -eq 'dfix' })[0])
$fixJob.Input = @{ Program = (& $pd 'eaglesoft'); Fix = @((& $pd 'eaglesoft').fixes | Where-Object { $_.id -eq 'test' })[0]; Server = ''; Share = 'DATA'; Url = '' }
foreach ($j in @($scanJob, $cloudJob, $fixJob)) { [void]$dsync.Jobs.Add($j) }
Invoke-TTJobsNow -Sync $dsync
Check 'dental scan job runs' ($scanJob.Status -eq 'done' -and $null -ne $scanJob.Result -and $null -ne $scanJob.Result.Found) $scanJob.Error
Check 'cloud program check asks for the login address' ($cloudJob.Status -eq 'done' -and @($cloudJob.Result.Checks | Where-Object { $_.Name -eq 'Login address' -and $_.Level -eq 'warn' }).Count -eq 1) $cloudJob.Error
Check 'fix without a server name fails with a clear message' ($fixJob.Status -eq 'failed' -and $fixJob.Error -match 'server name')
Check 'dental job input cleared after run' ($null -eq $scanJob.Input -and $null -eq $fixJob.Input)

Write-Host ''
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
