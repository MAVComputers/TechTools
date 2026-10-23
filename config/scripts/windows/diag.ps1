# More Windows > Diagnostics checks: slow PC, printers and scanners, crash
# history, Windows health repair (SFC + DISM), battery and power, time and
# domain sync. Each Get-TT* check returns a report section (see _shared.ps1),
# and each tool script collects them with Add-TTPart and finishes with
# Complete-TTReport. Keep this file ASCII-only.

$TTReportParts = New-Object System.Collections.ArrayList

function Add-TTPart {
    param([string]$Title, [scriptblock]$Check)
    $s = Invoke-TTHealthPart $Title $Check
    [void]$TTReportParts.Add($s)
    Write-TTHealthSummary $s
    return
}

function Complete-TTReport {
    # Saves the HTML report next to the session log and hands it to the window.
    param([string]$Title, [string]$Prefix, [string]$Tool, [string]$Lead = '', [string]$LeadLevel = '')
    $folder = $env:TEMP
    if ($Sync -and $Sync.LogFile) { $folder = Split-Path -Parent $Sync.LogFile }
    $html = New-TTHealthReport -Sections $TTReportParts -Folder $folder -Title $Title -Prefix $Prefix -Lead $Lead
    Write-Info ('Report saved: ' + $html)
    Set-Result ([pscustomobject]@{
        Sections = @($TTReportParts); Html = $html; At = (Get-Date); Pc = $env:COMPUTERNAME
        Title = $Title; Tool = $Tool; Lead = $Lead; LeadLevel = $LeadLevel
    })
}

function Update-TTProgress {
    # Progress inside a long step (only inside TechTools; tests skip it).
    param([double]$Percent, [string]$Text)
    if (Get-Command Set-TTProgress -ErrorAction SilentlyContinue) { Set-TTProgress -Percent $Percent -Text $Text }
}

function Get-TTReportFolder {
    if ($Sync -and $Sync.LogFile) { return (Split-Path -Parent $Sync.LogFile) }
    return $env:TEMP
}

function Format-TTSpan {
    param([TimeSpan]$Span)
    if ($Span.TotalDays -ge 1) { return ('{0} day(s) {1} h' -f [int][math]::Floor($Span.TotalDays), $Span.Hours) }
    if ($Span.TotalHours -ge 1) { return ('{0} h {1} min' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes) }
    return ('{0} min' -f [int][math]::Floor($Span.TotalMinutes))
}

function Test-TTFastStartup {
    $p = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue
    return ($p -and [int]$p.HiberbootEnabled -eq 1)
}

function Get-TTActivePlan {
    # "Power Scheme GUID: 381b4222-...  (Balanced)" -> name and GUID (works in any language).
    $out = (& powercfg.exe /getactivescheme 2>$null | Out-String)
    $guid = ''; $name = ''
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $guid = $Matches[1] }
    if ($out -match '\(([^)]+)\)\s*$') { $name = $Matches[1].Trim() }
    return [pscustomobject]@{ Guid = $guid; Name = $name }
}

# ---------------------------------------------------------------- Slow PC
function Get-TTUptimeSection {
    $s = New-TTSection 'Uptime'
    $os = Get-CimInstance Win32_OperatingSystem
    $up = (Get-Date) - $os.LastBootUpTime
    $fast = Test-TTFastStartup
    Add-TTFact $s 'Last restart' ($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))
    $lv = ''
    if ($up.TotalDays -ge 30) { $lv = 'fail' } elseif ($up.TotalDays -ge 7) { $lv = 'warn' }
    Add-TTFact $s 'Running for' (Format-TTSpan $up) $lv
    Add-TTFact $s 'Fast startup' $(if ($fast) { 'On (Shut down does not fully restart Windows)' } else { 'Off' })
    $s.Summary = 'Running for ' + (Format-TTSpan $up) + ' since the last restart'
    if ($lv) {
        Set-TTLevel $s $lv
        Add-TTNote $s 'A restart clears memory leaks and finishes pending updates. Use Restart (not Shut down) to fully reset Windows.' $lv
    }
    $s | Add-Member -NotePropertyName Days -NotePropertyValue ([math]::Round($up.TotalDays, 1))
    $s | Add-Member -NotePropertyName FastStartup -NotePropertyValue $fast
    return $s
}

function Get-TTSlowSample {
    # Samples CPU, memory and disk busy time every 2 seconds for $Seconds.
    param([int]$Seconds = 30)
    $cores = [math]::Max(1.0, [double](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors)
    $before = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($p.TotalProcessorTime) { $before[$p.Id] = $p.TotalProcessorTime.TotalSeconds } } catch { }
    }
    $start = Get-Date
    $cpu = New-Object System.Collections.ArrayList
    $mem = New-Object System.Collections.ArrayList
    $disk = New-Object System.Collections.ArrayList
    $n = [math]::Max(1, [int][math]::Ceiling($Seconds / 2.0))
    for ($i = 1; $i -le $n; $i++) {
        $c = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue)[0]
        if ($c) { [void]$cpu.Add([double]$c.PercentProcessorTime) }
        $os = Get-CimInstance Win32_OperatingSystem
        [void]$mem.Add(100.0 * (1 - [double]$os.FreePhysicalMemory / [math]::Max(1.0, [double]$os.TotalVisibleMemorySize)))
        $d = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue)[0]
        if ($d) { [void]$disk.Add([math]::Max(0.0, 100.0 - [double]$d.PercentIdleTime)) }
        Update-TTProgress (100.0 * $i / $n) ('Watching CPU, memory and disk ({0} of {1} s)' -f ($i * 2), ($n * 2))
        if ($i -lt $n) { Start-Sleep -Seconds 2 }
    }
    $elapsed = [math]::Max(1.0, ((Get-Date) - $start).TotalSeconds)
    $procs = foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $t = $null
        try { $t = $p.TotalProcessorTime.TotalSeconds } catch { }
        $cpuPct = 0.0
        if ($null -ne $t -and $before.ContainsKey($p.Id)) { $cpuPct = 100.0 * ($t - $before[$p.Id]) / $elapsed / $cores }
        [pscustomobject]@{ Name = $p.ProcessName; Id = $p.Id; Cpu = [math]::Max(0.0, $cpuPct); Mem = [double]$p.WorkingSet64 }
    }
    $avg = { param($list) if ($list.Count) { ($list | Measure-Object -Average).Average } else { 0.0 } }
    $peak = { param($list) if ($list.Count) { ($list | Measure-Object -Maximum).Maximum } else { 0.0 } }
    return [pscustomobject]@{
        Seconds = [int][math]::Round($elapsed)
        CpuAvg = [math]::Round((& $avg $cpu), 1); CpuPeak = [math]::Round((& $peak $cpu), 1)
        MemAvg = [math]::Round((& $avg $mem), 1); MemPeak = [math]::Round((& $peak $mem), 1)
        DiskAvg = [math]::Round((& $avg $disk), 1); DiskPeak = [math]::Round((& $peak $disk), 1)
        TopCpu = @($procs | Where-Object { $_.Name -ne 'Idle' } | Sort-Object Cpu -Descending | Select-Object -First 8)
        TopMem = @($procs | Sort-Object Mem -Descending | Select-Object -First 8)
    }
}

function Get-TTPressureSection {
    param($Sample)
    $s = New-TTSection 'CPU, memory and disk'
    $lvCpu = ''; if ($Sample.CpuAvg -ge 85) { $lvCpu = 'fail' } elseif ($Sample.CpuAvg -ge 60) { $lvCpu = 'warn' }
    $lvMem = ''; if ($Sample.MemAvg -ge 90) { $lvMem = 'fail' } elseif ($Sample.MemAvg -ge 80) { $lvMem = 'warn' }
    $lvDisk = ''; if ($Sample.DiskAvg -ge 80) { $lvDisk = 'fail' } elseif ($Sample.DiskAvg -ge 50) { $lvDisk = 'warn' }
    Add-TTFact $s 'CPU busy' ('{0:N0}% average, {1:N0}% peak' -f $Sample.CpuAvg, $Sample.CpuPeak) $lvCpu
    Add-TTFact $s 'Memory used' ('{0:N0}% average, {1:N0}% peak' -f $Sample.MemAvg, $Sample.MemPeak) $lvMem
    Add-TTFact $s 'Disk busy' ('{0:N0}% average, {1:N0}% peak' -f $Sample.DiskAvg, $Sample.DiskPeak) $lvDisk
    foreach ($lv in @($lvCpu, $lvMem, $lvDisk)) { if ($lv) { Set-TTLevel $s $lv } }
    Add-TTTable $s ('Top CPU users over {0} seconds' -f $Sample.Seconds) @('Process', 'PID', 'CPU', 'Memory') @($Sample.TopCpu | ForEach-Object {
        [pscustomobject]@{ Process = $_.Name; PID = $_.Id; CPU = ('{0:N1}%' -f $_.Cpu); Memory = Format-TTBytes $_.Mem; _Level = $(if ($_.Cpu -ge 50) { 'warn' } else { '' }) } })
    Add-TTTable $s 'Top memory users' @('Process', 'PID', 'Memory') @($Sample.TopMem | ForEach-Object {
        [pscustomobject]@{ Process = $_.Name; PID = $_.Id; Memory = Format-TTBytes $_.Mem } })
    $s.Summary = 'Over {0} s: CPU {1:N0}%, memory {2:N0}%, disk {3:N0}% busy on average' -f $Sample.Seconds, $Sample.CpuAvg, $Sample.MemAvg, $Sample.DiskAvg
    return $s
}

function Get-TTSystemDriveSection {
    $s = New-TTSection 'C: drive'
    $sys = ($env:SystemDrive).TrimEnd(':')
    $v = Get-Volume -DriveLetter $sys
    $freePct = 100.0 * [double]$v.SizeRemaining / [math]::Max(1.0, [double]$v.Size)
    $freeGb = [double]$v.SizeRemaining / 1GB
    $lv = ''
    if ($freePct -lt 10 -or $freeGb -lt 10) { $lv = 'fail' } elseif ($freePct -lt 15 -or $freeGb -lt 20) { $lv = 'warn' }
    Add-TTFact $s 'Free space' ('{0} free of {1} ({2:N0}%)' -f (Format-TTBytes $v.SizeRemaining), (Format-TTBytes $v.Size), $freePct) $lv
    $kind = ''
    try {
        $part = @(Get-Partition -DriveLetter $sys -ErrorAction Stop)[0]
        $pd = @(Get-PhysicalDisk | Where-Object { [string]$_.DeviceId -eq [string]$part.DiskNumber })[0]
        if ($pd) { $kind = Get-TTDiskKind $pd }
    } catch { }
    if ($kind) { Add-TTFact $s 'Drive type' $kind $(if ($kind -match '^HDD') { 'warn' } else { '' }) }
    if ($lv) {
        Set-TTLevel $s $lv
        Add-TTNote $s 'Windows slows down when C: is nearly full. Empty the Recycle Bin, run Disk Cleanup, or move large files.' $lv
    }
    if ($kind -match '^HDD') { Set-TTLevel $s 'warn'; Add-TTNote $s 'Windows is on a spinning hard drive. Moving to an SSD is the biggest speed upgrade.' 'warn' }
    $s.Summary = '{0} free ({1:N0}%){2}' -f (Format-TTBytes $v.SizeRemaining), $freePct, $(if ($kind) { ', ' + $kind } else { '' })
    $s | Add-Member -NotePropertyName FreePct -NotePropertyValue ([math]::Round($freePct, 1))
    $s | Add-Member -NotePropertyName FreeGb -NotePropertyValue ([math]::Round($freeGb, 1))
    $s | Add-Member -NotePropertyName Kind -NotePropertyValue $kind
    return $s
}

function Test-TTStartupDisabled {
    # Task Manager keeps its Enabled/Disabled switch in StartupApproved (odd first byte = disabled).
    param([string]$Name)
    foreach ($k in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')) {
        $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($p) {
            foreach ($prop in $p.PSObject.Properties) {
                if ($prop.Name -eq $Name -or $prop.Name -eq ($Name + '.lnk')) {
                    $b = $prop.Value
                    if ($b -is [byte[]] -and $b.Length -gt 0) { return (($b[0] -band 1) -eq 1) }
                }
            }
        }
    }
    return $false
}

function Get-TTStartupSection {
    $s = New-TTSection 'Startup apps'
    $items = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Sort-Object Name)
    $rows = foreach ($i in $items) {
        $off = Test-TTStartupDisabled $i.Name
        [pscustomobject]@{
            App = $i.Name; Status = $(if ($off) { 'Disabled' } else { 'Enabled' }); User = [string]$i.User
            Command = Get-TTShortText ([string]$i.Command) 120; From = [string]$i.Location
        }
    }
    $on = @($rows | Where-Object { $_.Status -eq 'Enabled' }).Count
    Add-TTTable $s 'Programs that start with Windows' @('App', 'Status', 'User', 'Command', 'From') $rows
    $s.Summary = '{0} startup app(s) enabled' -f $on
    if ($on -ge 15) { Set-TTLevel $s 'warn'; Add-TTNote $s 'Many apps start with Windows. Disable the ones the office does not need (Task Manager > Startup apps).' 'warn' }
    $s | Add-Member -NotePropertyName Enabled -NotePropertyValue $on
    return $s
}

function Get-TTSlowCause {
    # Turns the measurements into one "likely cause" line, worst first.
    # $D: CpuAvg, CpuTop, MemAvg, MemTop, DiskAvg, Kind, FreePct, FreeGb, Days, FastStartup, Startup, Plan
    param($D)
    $causes = New-Object System.Collections.ArrayList
    $add = { param($lv, $text) [void]$causes.Add([pscustomobject]@{ Level = $lv; Text = $text }) }
    if ($null -ne $D.FreePct -and ($D.FreePct -lt 10 -or $D.FreeGb -lt 10)) { & $add 'fail' ('C: drive is nearly full ({0:N0} GB free). Free up space first.' -f $D.FreeGb) }
    if ($D.MemAvg -ge 90) { & $add 'fail' ('Not enough memory: RAM was {0:N0}% used{1}. Close programs or add RAM.' -f $D.MemAvg, $(if ($D.MemTop) { ', mostly by ' + $D.MemTop } else { '' })) }
    if ($D.CpuAvg -ge 85) { & $add 'fail' ('The processor was {0:N0}% busy{1}.' -f $D.CpuAvg, $(if ($D.CpuTop) { ', mostly ' + $D.CpuTop } else { '' })) }
    if ($D.DiskAvg -ge 80) {
        if ([string]$D.Kind -match '^HDD') { & $add 'fail' ('The hard drive is the bottleneck ({0:N0}% busy). An SSD would fix this.' -f $D.DiskAvg) }
        else { & $add 'fail' ('The drive was {0:N0}% busy. Something is reading or writing heavily (updates, antivirus scan, sync).' -f $D.DiskAvg) }
    }
    if ($D.MemAvg -ge 80 -and $D.MemAvg -lt 90) { & $add 'warn' ('Memory is tight ({0:N0}% used). More RAM would help.' -f $D.MemAvg) }
    if ($D.CpuAvg -ge 60 -and $D.CpuAvg -lt 85) { & $add 'warn' ('The processor was fairly busy ({0:N0}%){1}.' -f $D.CpuAvg, $(if ($D.CpuTop) { ', mostly ' + $D.CpuTop } else { '' })) }
    if ($D.DiskAvg -ge 50 -and $D.DiskAvg -lt 80) { & $add 'warn' ('The drive was often busy ({0:N0}%).' -f $D.DiskAvg) }
    if ([string]$D.Kind -match '^HDD' -and $D.DiskAvg -lt 80) { & $add 'warn' 'Windows is on a spinning hard drive. An SSD is the biggest speed upgrade.' }
    if ($null -ne $D.FreePct -and $D.FreePct -ge 10 -and $D.FreeGb -ge 10 -and ($D.FreePct -lt 15 -or $D.FreeGb -lt 20)) { & $add 'warn' ('C: drive is getting full ({0:N0} GB free).' -f $D.FreeGb) }
    if ($D.Days -ge 7) { & $add 'warn' ('Not restarted in {0:N0} days. Restart the PC{1}.' -f $D.Days, $(if ($D.FastStartup) { ' (Restart, not Shut down)' } else { '' })) }
    if ($D.Startup -ge 15) { & $add 'warn' ('{0} apps start with Windows. Disable the ones not needed.' -f $D.Startup) }
    if ([string]$D.Plan -match 'saver') { & $add 'warn' 'The Power saver plan is on, which slows the processor. Switch to Balanced.' }

    $first = @($causes | Where-Object { $_.Level -eq 'fail' }) + @($causes | Where-Object { $_.Level -eq 'warn' })
    if ($first.Count -eq 0) {
        return [pscustomobject]@{ Level = 'ok'; Text = 'No clear cause: the PC looked healthy while it was watched. If only one program is slow, check that program or its server.'; All = @() }
    }
    return [pscustomobject]@{ Level = $first[0].Level; Text = $first[0].Text; All = @($first) }
}

function Get-TTLikelyCauseSection {
    param($Cause)
    $s = New-TTSection 'Likely cause'
    $s.Level = $Cause.Level
    $s.Summary = $Cause.Text
    $i = 0
    foreach ($c in @($Cause.All)) {
        $i++
        if ($i -gt 1) { Add-TTNote $s ('Also: ' + $c.Text) $c.Level }
    }
    return $s
}

# ---------------------------------------------------------------- Printers and scanners
function Get-TTSpoolerSection {
    $s = New-TTSection 'Print Spooler'
    $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if (-not $svc) { $s.Level = 'fail'; $s.Summary = 'Print Spooler service is missing'; return $s }
    $start = [string](Get-CimInstance Win32_Service -Filter "Name='Spooler'").StartMode
    Add-TTFact $s 'Status' ([string]$svc.Status) $(if ($svc.Status -ne 'Running') { 'fail' } else { 'ok' })
    Add-TTFact $s 'Starts' $start $(if ($start -eq 'Disabled') { 'fail' } else { '' })
    $folder = Join-Path $env:windir 'System32\spool\PRINTERS'
    $files = @(Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue)
    Add-TTFact $s 'Spool folder' ('{0} file(s) waiting' -f $files.Count)
    if ($svc.Status -ne 'Running') {
        $s.Level = 'fail'
        $s.Summary = 'The Print Spooler is ' + [string]$svc.Status + ': nothing can print'
        Add-TTNote $s 'Press "Clear stuck print jobs" to restart the spooler and clear the queue.' 'fail'
    } else {
        $s.Summary = 'Running'
    }
    return $s
}

function Get-TTPrinterReach {
    # Is the printer's network address answering? (raw 9100, LPD 515, IPP 631, then ping)
    param([string]$HostName)
    foreach ($port in @(9100, 631, 515, 80)) { if (Test-TTPort $HostName $port 1200) { return ('Answering (port {0})' -f $port) } }
    try { if (Test-Connection -ComputerName $HostName -Count 1 -Quiet -ErrorAction SilentlyContinue) { return 'Answers ping only' } } catch { }
    return ''
}

function Get-TTPrintersSection {
    $s = New-TTSection 'Printers'
    $wmi = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Sort-Object Name)
    $ports = @{}
    foreach ($p in @(Get-PrinterPort -ErrorAction SilentlyContinue)) { $ports[$p.Name] = $p }
    $offline = 0
    $real = 0
    $rows = foreach ($p in $wmi) {
        $virtual = [string]$p.DriverName -match 'Microsoft (Print To PDF|XPS|Shared Fax)|OneNote|Fax|Send To'
        if (-not $virtual) { $real++ }
        $where = [string]$p.PortName
        $reach = ''
        $lv = ''
        $state = switch ([int]$p.PrinterStatus) { 3 { 'Ready' } 4 { 'Printing' } 5 { 'Warming up' } 7 { 'Offline' } 1 { 'Ready' } 2 { 'Unknown' } default { 'Status ' + $p.PrinterStatus } }
        if ($p.WorkOffline) { $state = 'Set to Use Offline' }
        if ([int]$p.DetectedErrorState -gt 2 -and [int]$p.DetectedErrorState -ne 3) {
            $err = @{ 4 = 'Paper jam'; 5 = 'Out of paper'; 6 = 'Needs service'; 7 = 'No toner'; 8 = 'Door open'; 9 = 'Jammed'; 10 = 'Offline'; 11 = 'Service requested'; 12 = 'Output bin full' }[[int]$p.DetectedErrorState]
            if ($err) { $state += ' - ' + $err; $lv = 'warn' }
        }
        if (-not $virtual) {
            $port = $ports[$p.PortName]
            $hostName = ''
            if ($port -and $port.PrinterHostAddress) { $hostName = [string]$port.PrinterHostAddress }
            elseif ($p.Network -and [string]$p.Name -match '^\\\\([^\\]+)\\') { $hostName = $Matches[1] }
            if ($hostName) {
                $where = $hostName
                if ($p.Network -and [string]$p.Name -match '^\\\\') {
                    $reach = $(if (Test-TTPort $hostName 445 1500) { 'Print server answering' } else { '' })
                } else { $reach = Get-TTPrinterReach $hostName }
                if (-not $reach) { $reach = 'NOT answering'; $lv = 'fail' }
            } elseif ([string]$p.PortName -match '^WSD') { $reach = 'WSD (not tested)' }
            elseif ([string]$p.PortName -match '^USB') { $reach = 'USB' }
            if ($p.WorkOffline -or [int]$p.PrinterStatus -eq 7) { if (-not $lv) { $lv = 'warn' } }
            if ($lv) { $offline++ }
        }
        [pscustomobject]@{
            Printer = [string]$p.Name + $(if ($p.Default) { ' (default)' } else { '' })
            State = $state; Address = $where; Network = $reach; Driver = [string]$p.DriverName; _Level = $lv
        }
    }
    Add-TTTable $s 'Installed printers' @('Printer', 'State', 'Address', 'Network', 'Driver') $rows
    $s.Summary = '{0} printer(s), {1} with a problem' -f $real, $offline
    if ($offline) {
        Set-TTLevel $s $(if (@($rows | Where-Object { $_._Level -eq 'fail' }).Count) { 'fail' } else { 'warn' })
        Add-TTNote $s 'A printer is offline or not answering on the network. Check its power, cable or Wi-Fi, and that its IP address has not changed.' $s.Level
    }
    if (@($wmi | Where-Object { $_.WorkOffline }).Count) { Add-TTNote $s 'A printer is set to "Use Printer Offline". Untick it in the print queue window.' 'warn' }
    return $s
}

function Get-TTPrintJobsSection {
    $s = New-TTSection 'Print queue'
    $jobs = @(Get-CimInstance Win32_PrintJob -ErrorAction SilentlyContinue)
    $now = Get-Date
    $stuck = 0
    $rows = foreach ($j in $jobs) {
        $age = $null
        if ($j.TimeSubmitted) { $age = $now - [datetime]$j.TimeSubmitted }
        $status = (@([string]$j.JobStatus, [string]$j.Status) | Where-Object { $_ }) -join ', '
        $bad = ($status -match 'Error|Paused|Blocked|Offline|Deleting|User intervention') -or ($age -and $age.TotalMinutes -ge 10)
        if ($bad) { $stuck++ }
        [pscustomobject]@{
            Printer = ([string]$j.Name -replace ',\s*\d+$', ''); Document = Get-TTShortText ([string]$j.Document) 60
            Owner = [string]$j.Owner; Waiting = $(if ($age) { Format-TTSpan $age } else { '' }); Status = $status
            _Level = $(if ($bad) { 'fail' } else { '' })
        }
    }
    Add-TTTable $s 'Jobs waiting to print' @('Printer', 'Document', 'Owner', 'Waiting', 'Status') $rows
    if ($stuck) {
        $s.Level = 'fail'
        $s.Summary = '{0} stuck job(s) of {1} in the queue' -f $stuck, $jobs.Count
        Add-TTNote $s 'Press "Clear stuck print jobs" to restart the spooler and empty the queue. It removes every waiting job on this PC.' 'fail'
    } elseif ($jobs.Count) { $s.Summary = '{0} job(s) printing normally' -f $jobs.Count }
    else { $s.Summary = 'Queue is empty' }
    $s | Add-Member -NotePropertyName Stuck -NotePropertyValue $stuck
    return $s
}

function Get-TTScannersSection {
    $s = New-TTSection 'Scanners and imaging devices'
    $s.Level = 'info'
    $wia = Get-Service -Name stisvc -ErrorAction SilentlyContinue
    if ($wia) {
        $wiaStart = [string](Get-CimInstance Win32_Service -Filter "Name='stisvc'").StartMode
        $lv = ''
        if ($wia.Status -ne 'Running') { $lv = 'warn' }
        if ($wiaStart -eq 'Disabled') { $lv = 'fail' }
        Add-TTFact $s 'Windows Image Acquisition' ('{0} ({1})' -f $wia.Status, $wiaStart) $lv
        if ($lv) { Set-TTLevel $s $lv; Add-TTNote $s 'WIA scanners need the Windows Image Acquisition service. Start it and set it to Automatic.' $lv }
    }
    $devs = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Image' OR PNPClass='Camera'" -ErrorAction SilentlyContinue | Sort-Object Name)
    $bad = 0
    $rows = foreach ($d in $devs) {
        $code = [int]$d.ConfigManagerErrorCode
        $lv = ''
        if ($code -ne 0) { $lv = 'fail'; $bad++ }
        [pscustomobject]@{
            Device = [string]$d.Name; Kind = [string]$d.PNPClass; Status = [string]$d.Status
            Problem = $(if ($code -eq 0) { '' } elseif ($code -eq 22) { 'Disabled' } elseif ($code -eq 28) { 'No driver' } elseif ($code -eq 10) { 'Cannot start' } else { 'Code ' + $code })
            _Level = $lv
        }
    }
    Add-TTTable $s 'Scanners, cameras and imaging devices (Device Manager)' @('Device', 'Kind', 'Status', 'Problem') $rows
    $wiaNames = @()
    try {
        $dm = New-Object -ComObject WIA.DeviceManager
        foreach ($info in $dm.DeviceInfos) {
            $name = ''
            try { $name = [string]$info.Properties.Item('Name').Value } catch { }
            $kind = switch ([int]$info.Type) { 1 { 'Scanner' } 2 { 'Camera' } 3 { 'Video' } default { 'Device' } }
            $wiaNames += ('{0} ({1})' -f $name, $kind)
        }
    } catch { }
    Add-TTFact $s 'WIA scanners ready' $(if ($wiaNames.Count) { $wiaNames -join '; ' } else { 'None' })
    $twain = @()
    foreach ($dir in @((Join-Path $env:windir 'twain_32'), (Join-Path $env:windir 'twain_64'))) {
        $twain += @(Get-ChildItem -Path $dir -Filter *.ds -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Source = $_.BaseName; Folder = $_.Directory.Name; Bits = $(if ($dir -match '64') { '64-bit' } else { '32-bit' }); Date = $_.LastWriteTime.ToString('yyyy-MM-dd') } })
    }
    Add-TTTable $s 'TWAIN drivers installed (used by imaging and practice software)' @('Source', 'Folder', 'Bits', 'Date') $twain
    if ($bad) { Set-TTLevel $s 'fail'; Add-TTNote $s 'A scanner or imaging device has a driver problem. Reconnect it, then reinstall its driver.' 'fail' }
    $s.Summary = '{0} imaging device(s), {1} WIA scanner(s), {2} TWAIN driver(s){3}' -f $devs.Count, $wiaNames.Count, $twain.Count, $(if ($bad) { ', ' + $bad + ' with a problem' } else { '' })
    return $s
}

function Clear-TTPrintQueue {
    # Stops the spooler, deletes every waiting job, starts it again.
    $folder = Join-Path $env:windir 'System32\spool\PRINTERS'
    $s = New-TTSection 'Clear stuck print jobs'
    $before = @(Get-CimInstance Win32_PrintJob -ErrorAction SilentlyContinue).Count
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Service -Name Spooler).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    $files = @(Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue)
    $removed = 0
    foreach ($f in $files) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++ } catch { } }
    Start-Service -Name Spooler -ErrorAction Stop
    Start-Sleep -Seconds 2
    $after = @(Get-CimInstance Win32_PrintJob -ErrorAction SilentlyContinue).Count
    Add-TTFact $s 'Jobs before' $before
    Add-TTFact $s 'Spool files removed' ('{0} of {1}' -f $removed, $files.Count)
    Add-TTFact $s 'Spooler' ([string](Get-Service -Name Spooler).Status)
    Add-TTFact $s 'Jobs now' $after
    if ($removed -lt $files.Count) { $s.Level = 'warn'; Add-TTNote $s 'Some spool files were locked. Restart the PC if jobs still will not clear.' 'warn' }
    $s.Summary = 'Spooler restarted; {0} spool file(s) removed, {1} job(s) left' -f $removed, $after
    return $s
}

# ---------------------------------------------------------------- Crash and BSOD history
function Get-TTBugcheckInfo {
    # Plain-English name and usual cause for common blue-screen codes.
    param([string]$Code)
    $n = 0
    try { $n = [Convert]::ToInt64(($Code -replace '^0x', ''), 16) } catch { return [pscustomobject]@{ Name = 'Unknown'; Hint = '' } }
    $map = @{
        0x0A = @('IRQL_NOT_LESS_OR_EQUAL', 'A driver or bad RAM')
        0x1A = @('MEMORY_MANAGEMENT', 'Bad RAM or a faulty driver; test the memory')
        0x1E = @('KMODE_EXCEPTION_NOT_HANDLED', 'A faulty driver')
        0x3B = @('SYSTEM_SERVICE_EXCEPTION', 'A faulty driver (often graphics or antivirus)')
        0x50 = @('PAGE_FAULT_IN_NONPAGED_AREA', 'Bad RAM, disk or a driver')
        0x7A = @('KERNEL_DATA_INPAGE_ERROR', 'Failing drive or loose cable')
        0x77 = @('KERNEL_STACK_INPAGE_ERROR', 'Failing drive')
        0x7E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'A faulty driver')
        0x7F = @('UNEXPECTED_KERNEL_MODE_TRAP', 'Hardware (RAM, overheating) or a driver')
        0x9C = @('MACHINE_CHECK_EXCEPTION', 'Hardware fault (CPU, overheating)')
        0x9F = @('DRIVER_POWER_STATE_FAILURE', 'A driver failing on sleep or wake (often USB, network or graphics)')
        0xC2 = @('BAD_POOL_CALLER', 'A faulty driver')
        0xD1 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'A faulty driver (often network)')
        0xEF = @('CRITICAL_PROCESS_DIED', 'Corrupt system files or failing drive; run Windows health repair')
        0xF4 = @('CRITICAL_OBJECT_TERMINATION', 'Failing drive or cable')
        0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'CPU or BIOS problem')
        0x109 = @('CRITICAL_STRUCTURE_CORRUPTION', 'Bad RAM or a driver')
        0x116 = @('VIDEO_TDR_FAILURE', 'Graphics driver or graphics card')
        0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'Graphics driver')
        0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'Hardware fault (CPU, RAM, overheating, power)')
        0x133 = @('DPC_WATCHDOG_VIOLATION', 'Storage or other driver; update SSD firmware and chipset drivers')
        0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'A faulty driver or bad RAM')
        0x13A = @('KERNEL_MODE_HEAP_CORRUPTION', 'A faulty driver')
        0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'Failing drive or antivirus conflict')
        0x19 = @('BAD_POOL_HEADER', 'A faulty driver or bad RAM')
        0x3D5 = @('DRIVER_PNP_WATCHDOG', 'A device driver hung')
    }
    $v = $null
    foreach ($k in $map.Keys) { if ([int64]$k -eq $n) { $v = $map[$k]; break } }
    if ($v) { return [pscustomobject]@{ Name = $v[0]; Hint = $v[1] } }
    return [pscustomobject]@{ Name = ('Stop code 0x{0:X}' -f $n); Hint = '' }
}

function Find-TTKernelDebugger {
    foreach ($p in @("${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\kd.exe", "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\kd.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Get-TTDumpDriver {
    # Only when the Windows debugger is installed: asks it which driver crashed.
    param([string]$Kd, [string]$Dump)
    $out = Join-Path $env:TEMP ('tt-kd-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $p = Start-Process -FilePath $Kd -ArgumentList @('-z', ('"' + $Dump + '"'), '-y', 'srv*C:\ProgramData\MAVTechTools\Symbols*https://msdl.microsoft.com/download/symbols', '-c', '"!analyze -v; q"', '-logo', ('"' + $out + '"')) -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; return '' }
        $txt = [System.IO.File]::ReadAllText($out)
        if ($txt -match 'IMAGE_NAME:\s+(\S+)') { return $Matches[1] }
        if ($txt -match 'MODULE_NAME:\s+(\S+)') { return $Matches[1] }
    } catch { } finally { Remove-Item $out -Force -ErrorAction SilentlyContinue }
    return ''
}

function Get-TTBsodSection {
    param([int]$Days = 30)
    $s = New-TTSection 'Blue screens'
    $since = (Get-Date).AddDays(-$Days)
    $ev = @()
    try { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -ErrorAction Stop) } catch { }
    $dumpDir = Join-Path $env:windir 'Minidump'
    $dumps = @(Get-ChildItem -Path $dumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending)
    $kd = Find-TTKernelDebugger
    $analyzed = 0
    $rows = foreach ($e in $ev) {
        $code = ''
        if ($e.Message -match '(0x[0-9a-fA-F]{8,16})') { $code = $Matches[1] }
        $info = Get-TTBugcheckInfo $code
        $dumpFile = ''
        if ($e.Message -match 'saved in:\s*(.+?\.dmp)') { $dumpFile = $Matches[1].Trim() }
        if (-not $dumpFile) {
            $near = @($dumps | Where-Object { [math]::Abs(($_.LastWriteTime - $e.TimeCreated).TotalMinutes) -lt 30 })[0]
            if ($near) { $dumpFile = $near.FullName }
        }
        $driver = ''
        if ($kd -and $dumpFile -and (Test-Path $dumpFile) -and $analyzed -lt 3) {
            $analyzed++
            Update-TTProgress (100.0 * $analyzed / 3) 'Asking the Windows debugger which driver crashed'
            $driver = Get-TTDumpDriver $kd $dumpFile
        }
        [pscustomobject]@{
            When = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'); 'Stop code' = $info.Name
            'Faulting driver' = $(if ($driver) { $driver } elseif ($kd) { 'not found in dump' } else { 'needs WinDbg' })
            'Usual cause' = $info.Hint; Dump = $(if ($dumpFile) { Split-Path -Leaf $dumpFile } else { 'none saved' })
            _Level = 'fail'
        }
    }
    Add-TTTable $s ('Blue screens in the last {0} days' -f $Days) @('When', 'Stop code', 'Faulting driver', 'Usual cause', 'Dump') $rows
    $whea = @()
    try { $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction Stop) } catch { }
    Add-TTFact $s 'Hardware errors (WHEA)' $whea.Count $(if ($whea.Count) { 'warn' } else { '' })
    Add-TTFact $s 'Crash dumps saved' $dumps.Count
    if (-not $kd -and $ev.Count) { Add-TTNote $s 'To name the faulting driver, install WinDbg (Windows SDK debugging tools) and run this again, or open the dump in WinDbg and run !analyze -v.' 'info' }
    if ($whea.Count) { Set-TTLevel $s 'warn'; Add-TTNote $s 'Windows logged hardware errors. Check temperatures, RAM and the power supply.' 'warn' }
    if ($ev.Count) {
        $recent = @($ev | Where-Object { $_.TimeCreated -ge (Get-Date).AddDays(-7) }).Count
        Set-TTLevel $s $(if ($recent) { 'fail' } else { 'warn' })
        $s.Summary = '{0} blue screen(s) in {1} days, last {2}' -f $ev.Count, $Days, $ev[0].TimeCreated.ToString('yyyy-MM-dd')
    } else { $s.Summary = 'No blue screens in the last {0} days' -f $Days }
    return $s
}

function Get-TTShutdownSection {
    param([int]$Days = 30)
    $s = New-TTSection 'Unexpected shutdowns'
    $since = (Get-Date).AddDays(-$Days)
    $ev = @()
    try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -ErrorAction Stop) } catch { }
    $count41 = $ev.Count
    try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'EventLog'; Id = 6008; StartTime = $since } -ErrorAction Stop) } catch { }
    $ev = @($ev | Sort-Object TimeCreated -Descending)
    $rows = foreach ($e in $ev) {
        [pscustomobject]@{
            When = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm')
            What = $(if ($e.Id -eq 41) { 'Restarted without a clean shutdown (power loss, hard reset or crash)' } else { 'Windows noticed the last shutdown was unexpected' })
            Event = ('{0} {1}' -f $e.ProviderName, $e.Id)
        }
    }
    Add-TTTable $s ('Unexpected shutdowns in the last {0} days' -f $Days) @('When', 'What', 'Event') $rows
    $n = $count41
    if ($n -eq 0) { $n = @($ev | Where-Object { $_.Id -eq 6008 }).Count }
    if ($n -ge 3) { $s.Level = 'fail' } elseif ($n -ge 1) { $s.Level = 'warn' }
    if ($n) { Add-TTNote $s 'Repeated power losses point to the power supply, a UPS, loose power cable, overheating, or users holding the power button.' $s.Level }
    $s.Summary = $(if ($n) { '{0} unexpected shutdown(s) in {1} days' -f $n, $Days } else { 'None in the last {0} days' -f $Days })
    return $s
}

function Get-TTAppCrashSection {
    param([int]$Days = 30)
    $s = New-TTSection 'App crashes and hangs'
    $since = (Get-Date).AddDays(-$Days)
    $ev = @()
    try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction Stop) } catch { }
    try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002; StartTime = $since } -ErrorAction Stop) } catch { }
    $items = foreach ($e in $ev) {
        $p = $e.Properties
        $app = ''; $mod = ''
        if ($p.Count -gt 0) { $app = [string]$p[0].Value }
        if ($e.Id -eq 1000 -and $p.Count -gt 3) { $mod = [string]$p[3].Value }
        [pscustomobject]@{ App = $app; Kind = $(if ($e.Id -eq 1000) { 'Crash' } else { 'Hang' }); Module = $mod; At = $e.TimeCreated }
    }
    $groups = @($items | Group-Object App, Kind, Module | Sort-Object Count -Descending | Select-Object -First 15)
    $rows = foreach ($g in $groups) {
        $f = $g.Group[0]
        $last = ($g.Group | Sort-Object At -Descending)[0].At
        [pscustomobject]@{
            App = $f.App; Kind = $f.Kind; 'Faulting module' = $(if ($f.Module) { $f.Module } else { '-' }); Times = $g.Count
            Last = $last.ToString('yyyy-MM-dd HH:mm'); _Level = $(if ($g.Count -ge 5) { 'warn' } else { '' })
        }
    }
    Add-TTTable $s ('Programs that crashed or froze in the last {0} days' -f $Days) @('App', 'Kind', 'Faulting module', 'Times', 'Last') $rows
    $total = @($items).Count
    if ($total -ge 10) { $s.Level = 'warn' } elseif ($total -eq 0) { $s.Level = 'ok' } else { $s.Level = 'info' }
    if ($groups.Count) {
        $top = $groups[0].Group[0]
        $s.Summary = '{0} crash(es)/hang(s) in {1} days; most: {2} ({3}x)' -f $total, $Days, $top.App, $groups[0].Count
        if (@($items | Where-Object { $_.Module -match '^(ntdll|KERNELBASE|ucrtbase)\.dll$' }).Count -ge 5) {
            Add-TTNote $s 'Several crashes are in core Windows files. Run "Windows health repair" and update the program.' 'warn'
        }
    } else { $s.Summary = 'No program crashes in the last {0} days' -f $Days }
    return $s
}

# ---------------------------------------------------------------- Windows health repair
function Invoke-TTWatchedProcess {
    # Runs sfc or dism hidden, passes its % to the progress bar, returns its text and exit code.
    param([string]$File, [string]$Arguments, [string]$Label)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object char[] 512
    $last = -1
    while ($true) {
        $n = $proc.StandardOutput.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        [void]$sb.Append($buf, 0, $n)
        # sfc writes UTF-16: drop the zero bytes so the text reads normally.
        $tail = $sb.ToString([math]::Max(0, $sb.Length - 400), [math]::Min(400, [int]$sb.Length)) -replace "`0", ''
        $m = [regex]::Matches($tail, '(\d{1,3}(?:[.,]\d)?)\s?%')
        if ($m.Count) {
            $pct = [double]($m[$m.Count - 1].Groups[1].Value -replace ',', '.')
            if ($pct -le 100 -and [int]$pct -ne $last) { $last = [int]$pct; Update-TTProgress $pct ('{0} {1}%' -f $Label, $last) }
        }
    }
    $proc.WaitForExit()
    $text = ($sb.ToString() -replace "`0", '') -replace "`r", "`n"
    $text = (($text -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\[?[=\s\d.,%-]*\]?$' -and $_ -notmatch '% complete' }) -join "`n"
    return [pscustomobject]@{ Text = $text; Code = $proc.ExitCode }
}

function Get-TTSfcOutcome {
    param([string]$Text, [int]$Code = 0)
    $t = ($Text -replace '\s+', ' ')
    if ($t -match 'did not find any integrity violations') { return [pscustomobject]@{ Level = 'ok'; Repaired = $false; Text = 'No damaged system files found' } }
    if ($t -match 'found corrupt files and successfully repaired') { return [pscustomobject]@{ Level = 'ok'; Repaired = $true; Text = 'Damaged system files were found and repaired' } }
    if ($t -match 'unable to fix some') { return [pscustomobject]@{ Level = 'fail'; Repaired = $false; Text = 'Damaged system files were found, and some could not be repaired' } }
    if ($t -match 'repair pending|restart') { return [pscustomobject]@{ Level = 'warn'; Repaired = $false; Text = 'A repair is waiting for a restart. Restart the PC and run this again.' } }
    if ($t -match 'could not perform|could not start') { return [pscustomobject]@{ Level = 'fail'; Repaired = $false; Text = 'SFC could not run. Try again in Safe Mode or after a restart.' } }
    return [pscustomobject]@{ Level = $(if ($Code -eq 0) { 'info' } else { 'fail' }); Repaired = $false; Text = ('SFC finished (exit code {0})' -f $Code) }
}

function Get-TTDismOutcome {
    param([string]$Text, [int]$Code = 0)
    $t = ($Text -replace '\s+', ' ')
    if ($Code -eq 0) { return [pscustomobject]@{ Level = 'ok'; Text = 'Windows component store is healthy (repaired if needed)' } }
    if ($t -match '0x800f081f|0x800f0906|0x800f0950|source files could not be found') {
        return [pscustomobject]@{ Level = 'fail'; Text = 'DISM could not download repair files. Check the internet connection, or a WSUS/update policy blocking it.' }
    }
    $err = ''
    if ($t -match 'Error:\s*(0x[0-9a-fA-F]+|\d+)') { $err = ' (error ' + $Matches[1] + ')' }
    return [pscustomobject]@{ Level = 'fail'; Text = ('DISM could not repair the component store' + $err) }
}

function Get-TTCbsRepairs {
    # Reads the end of CBS.log for files SFC repaired (or could not) since $Since.
    param([datetime]$Since)
    $path = Join-Path $env:windir 'Logs\CBS\CBS.log'
    $found = New-Object System.Collections.ArrayList
    if (-not (Test-Path $path)) { return @() }
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($path, 'Open', 'Read', 'ReadWrite')
        $max = 8MB
        if ($fs.Length -gt $max) { [void]$fs.Seek(-$max, 'End') }
        $sr = New-Object System.IO.StreamReader($fs)
        $stamp = $Since.ToString('yyyy-MM-dd HH:mm:ss')
        while ($null -ne ($line = $sr.ReadLine())) {
            if ($line.Length -lt 19 -or $line.Substring(0, 19) -lt $stamp) { continue }
            if ($line -match '\[SR\] (Repaired file|Repairing corrupted file|Cannot repair member file)\s+(.+?)(\s+from store)?$') {
                $what = $(if ($Matches[1] -match 'Cannot') { 'Could not repair' } else { 'Repaired' })
                $file = ($Matches[2] -replace '^\\\?\?\\', '' -replace '^\[l:\d+\]"?', '' -replace '"$', '')
                if (-not @($found | Where-Object { $_.File -eq $file -and $_.Result -eq $what }).Count) {
                    [void]$found.Add([pscustomobject]@{ File = $file; Result = $what; _Level = $(if ($what -eq 'Repaired') { 'ok' } else { 'fail' }) })
                }
            }
        }
    } catch { } finally { if ($fs) { $fs.Dispose() } }
    return @($found | Select-Object -First 40)
}

# ---------------------------------------------------------------- Battery and power
function Get-TTPowerSetting {
    # AC and DC values (seconds) of one power setting; reads the last two hex values so it works in any language.
    param([string]$Sub, [string]$Setting)
    $out = @(& powercfg.exe /query SCHEME_CURRENT $Sub $Setting 2>$null)
    $hex = @($out | ForEach-Object { if ($_ -match ':\s*0x([0-9a-fA-F]+)\s*$') { [Convert]::ToInt64($Matches[1], 16) } })
    if ($hex.Count -lt 2) { return $null }
    return [pscustomobject]@{ AC = $hex[$hex.Count - 2]; DC = $hex[$hex.Count - 1] }
}

function Format-TTTimeout {
    param($Seconds)
    if ($null -eq $Seconds) { return 'unknown' }
    if ([int64]$Seconds -eq 0) { return 'Never' }
    if ([int64]$Seconds -ge 3600) { return ('{0:N1} h' -f ($Seconds / 3600.0)) }
    return ('{0} min' -f [int][math]::Round($Seconds / 60.0))
}

function Get-TTBatterySection {
    param([string]$Folder)
    $s = New-TTSection 'Battery'
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($bat.Count -eq 0) {
        $s.Level = 'info'
        $s.Summary = 'No battery (desktop PC)'
        return $s
    }
    $design = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue)
    $full = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue)
    $cycles = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue)
    $status = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue)
    $worst = 100.0
    $known = $false
    $rows = for ($i = 0; $i -lt [math]::Max($bat.Count, $full.Count); $i++) {
        $d = if ($i -lt $design.Count) { [double]$design[$i].DesignedCapacity } else { 0.0 }
        $f = if ($i -lt $full.Count) { [double]$full[$i].FullChargedCapacity } else { 0.0 }
        $health = if ($d -gt 0 -and $f -gt 0) { [math]::Min(100.0, 100.0 * $f / $d) } else { -1.0 }
        if ($health -ge 0) { $known = $true; if ($health -lt $worst) { $worst = $health } }
        $b = if ($i -lt $bat.Count) { $bat[$i] } else { $null }
        $st = if ($i -lt $status.Count) { $status[$i] } else { $null }
        $state = ''
        if ($st) { $state = $(if ($st.Charging) { 'Charging' } elseif ($st.PowerOnline) { 'Plugged in' } else { 'On battery' }) }
        [pscustomobject]@{
            Battery = $(if ($b) { [string]$b.Name } else { 'Battery ' + ($i + 1) })
            Charge = $(if ($b) { [string]$b.EstimatedChargeRemaining + '%' } else { '' })
            State = $state
            Health = $(if ($health -ge 0) { '{0:N0}%' -f $health } else { 'unknown' })
            'Full / design' = $(if ($d -gt 0) { '{0:N0} / {1:N0} mWh' -f $f, $d } else { '' })
            Cycles = $(if ($i -lt $cycles.Count -and $cycles[$i].CycleCount) { [string]$cycles[$i].CycleCount } else { '' })
            _Level = $(if ($health -ge 0 -and $health -lt 50) { 'fail' } elseif ($health -ge 0 -and $health -lt 70) { 'warn' } else { '' })
        }
    }
    Add-TTTable $s 'Batteries' @('Battery', 'Charge', 'State', 'Health', 'Full / design', 'Cycles') $rows
    if ($worst -lt 50) { $s.Level = 'fail'; Add-TTNote $s 'The battery holds less than half its original charge. Replace it.' 'fail' }
    elseif ($worst -lt 70) { $s.Level = 'warn'; Add-TTNote $s 'The battery is wearing out (under 70% of its original charge).' 'warn' }
    if ($Folder) {
        $rep = Join-Path $Folder ('Battery-{0}-{1}.html' -f $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd-HHmm'))
        $null = & powercfg.exe /batteryreport /output $rep 2>&1
        if (Test-Path $rep) { Add-TTFact $s 'Full Windows battery report' $rep }
    }
    $s.Summary = $(if ($known) { 'Battery health {0:N0}% of original capacity' -f $worst } else { 'Battery found; health not reported by this model' })
    return $s
}

function Get-TTPowerPlanSection {
    param([bool]$HasBattery)
    $s = New-TTSection 'Power plan'
    $s.Level = 'info'
    $plan = Get-TTActivePlan
    Add-TTFact $s 'Active plan' $(if ($plan.Name) { $plan.Name } else { $plan.Guid }) $(if ($plan.Name -match 'saver') { 'warn' } else { '' })
    $sleep = Get-TTPowerSetting 'SUB_SLEEP' 'STANDBYIDLE'
    $hib = Get-TTPowerSetting 'SUB_SLEEP' 'HIBERNATEIDLE'
    $disp = Get-TTPowerSetting 'SUB_VIDEO' 'VIDEOIDLE'
    $disk = Get-TTPowerSetting 'SUB_DISK' 'DISKIDLE'
    $rows = foreach ($x in @(@('Turn off display', $disp), @('Sleep', $sleep), @('Hibernate', $hib), @('Turn off hard disk', $disk))) {
        $o = [ordered]@{ Setting = $x[0]; 'Plugged in' = $(if ($x[1]) { Format-TTTimeout $x[1].AC } else { 'unknown' }) }
        if ($HasBattery) { $o['On battery'] = $(if ($x[1]) { Format-TTTimeout $x[1].DC } else { 'unknown' }) }
        [pscustomobject]$o
    }
    $cols = @('Setting', 'Plugged in')
    if ($HasBattery) { $cols += 'On battery' }
    Add-TTTable $s 'Timeouts' $cols $rows
    Add-TTFact $s 'Fast startup' $(if (Test-TTFastStartup) { 'On' } else { 'Off' })
    if ($plan.Name -match 'saver') { $s.Level = 'warn'; Add-TTNote $s 'Power saver slows the processor. Use Balanced unless this is a laptop that must last longer.' 'warn' }
    if (-not $HasBattery -and $sleep -and $sleep.AC -gt 0 -and $sleep.AC -le 3600) {
        $s.Level = 'warn'
        Add-TTNote $s ('This desktop sleeps after {0} when idle. Front desk and imaging PCs usually should never sleep: sleep can drop sensors, scanners and practice software connections.' -f (Format-TTTimeout $sleep.AC)) 'warn'
    }
    $s.Summary = '{0}; sleeps after {1} plugged in' -f $(if ($plan.Name) { $plan.Name } else { 'Custom plan' }), $(if ($sleep) { (Format-TTTimeout $sleep.AC).ToLower() } else { 'unknown' })
    return $s
}

function ConvertFrom-TTPowerRequests {
    # powercfg /requests: "DISPLAY:" / "SYSTEM:" headers, then "[PROCESS] path" lines.
    param([string[]]$Lines)
    $kind = ''
    $list = New-Object System.Collections.ArrayList
    foreach ($ln in $Lines) {
        $t = [string]$ln
        if ($t -match '^([A-Z]+):\s*$') { $kind = $Matches[1]; continue }
        if ($t -match '^\[(\w+)\]\s*(.+)$') {
            $who = $Matches[2].Trim()
            if ($Matches[1] -eq 'PROCESS') { $who = Split-Path -Leaf $who }
            [void]$list.Add([pscustomobject]@{ Blocks = $kind; Type = $Matches[1]; Who = $who; Reason = '' })
        } elseif ($t.Trim() -and $list.Count -and -not $list[$list.Count - 1].Reason -and $t -notmatch '^\S+\.\s*$') {
            $list[$list.Count - 1].Reason = $t.Trim()
        }
    }
    return @($list)
}

function Get-TTSleepSection {
    $s = New-TTSection 'Sleep and wake'
    $s.Level = 'info'
    $req = @(ConvertFrom-TTPowerRequests @(& powercfg.exe /requests 2>$null))
    $blocking = @($req | Where-Object { $_.Blocks -in @('SYSTEM', 'EXECUTION', 'AWAYMODE') })
    Add-TTTable $s 'Programs keeping the PC awake right now' @('Blocks', 'Type', 'Who', 'Reason') $req
    $wake = @()
    try { $wake = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } -MaxEvents 5 -ErrorAction Stop) } catch { }
    $rows = foreach ($e in $wake) {
        $src = ''
        if ($e.Message -match 'Wake Source:\s*(.+)') { $src = $Matches[1].Trim() }
        [pscustomobject]@{ Woke = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'); 'Wake source' = $(if ($src) { $src } else { 'unknown' }) }
    }
    Add-TTTable $s 'Last 5 wake-ups from sleep' @('Woke', 'Wake source') $rows
    $since = (Get-Date).AddDays(-14)
    $fails = @()
    try { $fails = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -ErrorAction Stop) } catch { }
    Add-TTFact $s 'Unexpected restarts, 14 days (often a failed wake-up)' $fails.Count $(if ($fails.Count) { 'warn' } else { '' })
    if ($blocking.Count) { $s.Level = 'warn'; Add-TTNote $s ('Sleep is being blocked by: ' + (@($blocking | ForEach-Object { $_.Who }) -join ', ')) 'warn' }
    if ($fails.Count) { $s.Level = 'warn'; Add-TTNote $s 'Windows restarted without a clean shutdown (power loss or a failed wake-up). Update chipset, graphics and network drivers and the BIOS.' 'warn' }
    $s.Summary = '{0} sleep blocker(s); {1} wake-up(s) recorded' -f $blocking.Count, $wake.Count
    return $s
}

# ---------------------------------------------------------------- Time and domain sync
function ConvertFrom-TTStripchart {
    # "14:05:01, +00.0153257s" -> offsets in seconds; errors are skipped.
    param([string[]]$Lines)
    $vals = foreach ($ln in $Lines) {
        if ([string]$ln -match ',\s*([+-]\d+[.,]\d+)s') { [double]($Matches[1] -replace ',', '.') }
    }
    return @($vals)
}

function Measure-TTClockOffset {
    # Median offset of this PC's clock against $Server, in seconds.
    param([string]$Server)
    $out = @(& w32tm.exe /stripchart /computer:$Server /samples:3 /dataonly 2>&1 | ForEach-Object { [string]$_ })
    $vals = @(ConvertFrom-TTStripchart $out | Sort-Object)
    if ($vals.Count -eq 0) { return $null }
    return $vals[[int][math]::Floor($vals.Count / 2)]
}

function Measure-TTHttpClockOffset {
    # Backup when NTP (UDP 123) is blocked: compare with a web server's Date header (1 s accuracy).
    try {
        $r = Invoke-WebRequest -Uri 'https://www.microsoft.com/' -Method Head -UseBasicParsing -TimeoutSec 10
        $d = [datetime]::Parse([string]$r.Headers['Date'], [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
        return ($d - [datetime]::UtcNow).TotalSeconds
    } catch { return $null }
}

function Get-TTDomainSection {
    $s = New-TTSection 'Domain'
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) {
        $s.Level = 'info'
        Add-TTFact $s 'Joined to' ('Workgroup ' + $cs.Workgroup)
        $s.Summary = 'Not on a domain (workgroup ' + $cs.Workgroup + ')'
        return $s
    }
    Add-TTFact $s 'Domain' $cs.Domain
    $dc = ''
    $nl = @(& nltest.exe ('/dsgetdc:' + $cs.Domain) 2>&1 | ForEach-Object { [string]$_ })
    foreach ($ln in $nl) { if ($ln -match '^\s*DC:\s*\\\\(\S+)') { $dc = $Matches[1] } }
    Add-TTFact $s 'Domain controller found' $(if ($dc) { $dc } else { 'NONE' }) $(if ($dc) { 'ok' } else { 'fail' })
    $trust = $null
    try { $trust = Test-ComputerSecureChannel -ErrorAction Stop } catch { $trust = $false }
    Add-TTFact $s 'Trust with the domain' $(if ($trust) { 'OK' } else { 'BROKEN' }) $(if ($trust) { 'ok' } else { 'fail' })
    if (-not $dc) { $s.Level = 'fail'; Add-TTNote $s 'No domain controller answered. Check the network and that DNS points to the server.' 'fail' }
    elseif (-not $trust) { $s.Level = 'fail'; Add-TTNote $s 'The PC lost its trust with the domain. Use "Check server connection" then Repair domain trust.' 'fail' }
    $s.Summary = $(if ($dc -and $trust) { 'Joined to {0}; DC {1} answering' -f $cs.Domain, $dc } elseif ($dc) { 'Domain trust is broken' } else { 'No domain controller found' })
    $s | Add-Member -NotePropertyName Dc -NotePropertyValue $dc
    return $s
}

function Get-TTTimeSection {
    param([string]$Dc)
    $s = New-TTSection 'Clock and time sync'
    $svc = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    Add-TTFact $s 'Windows Time service' $(if ($svc) { [string]$svc.Status } else { 'missing' }) $(if ($svc -and $svc.Status -eq 'Running') { '' } else { 'warn' })
    $status = @(& w32tm.exe /query /status 2>&1 | ForEach-Object { [string]$_ })
    $cfg = @(& w32tm.exe /query /configuration 2>&1 | ForEach-Object { [string]$_ })
    $src = ''; $lastSync = ''
    foreach ($ln in $status) {
        if ($ln -match '^Source:\s*(.+)$') { $src = $Matches[1].Trim() }
        if ($ln -match '^Last Successful Sync Time:\s*(.+)$') { $lastSync = $Matches[1].Trim() }
    }
    $type = ''
    foreach ($ln in $cfg) { if ($ln -match '^Type:\s*(\S+)') { $type = $Matches[1] } }
    Add-TTFact $s 'Time source' $(if ($src) { $src } else { 'unknown' }) $(if ($src -match 'Local CMOS|Free-running') { 'warn' } else { '' })
    if ($type) { Add-TTFact $s 'Sync type' $(if ($type -eq 'NT5DS') { 'NT5DS (from the domain)' } elseif ($type -eq 'NTP') { 'NTP (internet time server)' } else { $type }) }
    $syncLv = ''
    if ($lastSync) {
        $when = [datetime]::MinValue
        if ([datetime]::TryParse($lastSync, [ref]$when) -and $when -lt (Get-Date).AddDays(-7)) { $syncLv = 'warn' }
        if ($lastSync -match 'unspecified') { $syncLv = 'warn' }
    }
    Add-TTFact $s 'Last sync' $(if ($lastSync) { $lastSync } else { 'unknown' }) $syncLv
    $tz = Get-TimeZone
    Add-TTFact $s 'Time zone' $tz.DisplayName

    Update-TTProgress 30 'Comparing the clock with a time server'
    $ref = $(if ($Dc) { $Dc } else { 'time.windows.com' })
    $off = Measure-TTClockOffset $ref
    $how = 'NTP vs ' + $ref
    if ($null -eq $off -and $Dc) { $off = Measure-TTClockOffset 'time.windows.com'; $how = 'NTP vs time.windows.com' }
    if ($null -eq $off) { Update-TTProgress 70 'NTP blocked: comparing with a web server clock'; $off = Measure-TTHttpClockOffset; $how = 'web server clock (NTP blocked)' }
    $lv = ''
    if ($null -eq $off) { $lv = 'warn'; Add-TTFact $s 'Clock drift' 'Could not compare (no time server answered)' 'warn' }
    else {
        $abs = [math]::Abs($off)
        if ($abs -ge 300) { $lv = 'fail' } elseif ($abs -ge 5) { $lv = 'warn' } else { $lv = 'ok' }
        Add-TTFact $s 'Clock drift' ('{0:N1} s off ({1})' -f $abs, $how) $lv
    }
    if ($lv -eq 'fail') { Add-TTNote $s 'The clock is off by 5 minutes or more: domain logins (Kerberos), mapped drives and some practice software will fail. Fix with: w32tm /resync /force' 'fail' }
    elseif ($lv -eq 'warn' -and $null -ne $off) { Add-TTNote $s 'The clock is drifting. Resync with: w32tm /resync /force. If it keeps drifting, the CMOS battery may be dying.' 'warn' }
    if ($syncLv) { Set-TTLevel $s 'warn'; Add-TTNote $s 'Windows has not synced its clock in over a week.' 'warn' }
    if (-not $svc -or $svc.Status -ne 'Running') { Set-TTLevel $s 'warn' }
    if ($lv) { Set-TTLevel $s $lv }
    $s.Summary = $(if ($null -ne $off) { 'Clock is {0:N1} s off; source {1}' -f [math]::Abs($off), $(if ($src) { $src } else { 'unknown' }) } else { 'Could not measure drift; source ' + $(if ($src) { $src } else { 'unknown' }) })
    return $s
}
