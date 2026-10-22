# Shared helpers for the Windows category.
# PC Health Check: each Get-TTHealth* function returns one report section:
#   Title, Level (ok / warn / fail / info), Summary, Facts (label/value pairs),
#   Tables (Caption, Columns, Rows), Notes.
# A section that cannot be read comes back as Level 'fail' instead of
# stopping the whole check. Keep this file ASCII-only.

function New-TTSection {
    param([string]$Title)
    [pscustomobject]@{
        Title   = $Title
        Level   = 'ok'
        Summary = ''
        Facts   = New-Object System.Collections.ArrayList
        Tables  = New-Object System.Collections.ArrayList
        Notes   = New-Object System.Collections.ArrayList
    }
}

function Set-TTLevel {
    # Raise a section's level; never lowers it (fail > warn > ok > info).
    param($Section, [string]$Level)
    $rank = @{ info = 0; ok = 1; warn = 2; fail = 3 }
    if ($rank[$Level] -gt $rank[$Section.Level]) { $Section.Level = $Level }
}

function Add-TTFact {
    param($Section, [string]$Label, $Value, [string]$Level = '')
    [void]$Section.Facts.Add([pscustomobject]@{ Label = $Label; Value = [string]$Value; Level = $Level })
}

function Add-TTTable {
    # Rows are objects; Columns picks and orders their properties.
    # A row property named _Level (ok/warn/fail) colors the row.
    param($Section, [string]$Caption, [string[]]$Columns, $Rows)
    [void]$Section.Tables.Add([pscustomobject]@{ Caption = $Caption; Columns = $Columns; Rows = @($Rows) })
}

function Add-TTNote {
    param($Section, [string]$Text, [string]$Level = 'info')
    [void]$Section.Notes.Add([pscustomobject]@{ Text = $Text; Level = $Level })
}

function Invoke-TTHealthPart {
    # Runs one check; a crash becomes a failed section, not a failed job.
    param([string]$Title, [scriptblock]$Check)
    try {
        $s = & $Check
        if ($null -eq $s) { throw 'no result' }
        return $s
    } catch {
        $s = New-TTSection $Title
        $s.Level = 'fail'
        $s.Summary = 'Could not check: ' + $_.Exception.Message
        return $s
    }
}

function Format-TTBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function ConvertTo-TTMask {
    param([int]$Prefix)
    if ($Prefix -le 0) { return '0.0.0.0' }
    $bits = ([uint32]::MaxValue -shl (32 - $Prefix)) -band [uint32]::MaxValue
    $b = [BitConverter]::GetBytes([uint32]$bits)
    return ('{0}.{1}.{2}.{3}' -f $b[3], $b[2], $b[1], $b[0])
}

# ---------------------------------------------------------------- System
function Get-TTHealthSystem {
    $s = New-TTSection 'System'
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $bios = Get-CimInstance Win32_BIOS
    $total = [double]$cs.TotalPhysicalMemory
    $free = [double]$os.FreePhysicalMemory * 1KB
    $used = $total - $free
    $pct = [math]::Round(100 * $used / [math]::Max(1.0, $total))
    $uptime = (Get-Date) - $os.LastBootUpTime
    $memLevel = 'ok'
    if ($pct -ge 90) { $memLevel = 'fail' } elseif ($pct -ge 80) { $memLevel = 'warn' }

    Add-TTFact $s 'PC name' $env:COMPUTERNAME
    $domain = if ($cs.PartOfDomain) { $cs.Domain + ' (domain)' } else { $cs.Workgroup + ' (workgroup)' }
    Add-TTFact $s 'Domain / workgroup' $domain
    Add-TTFact $s 'Signed-in user' ([string]$cs.UserName)
    Add-TTFact $s 'Model' (($cs.Manufacturer + ' ' + $cs.Model).Trim())
    Add-TTFact $s 'Serial number' ([string]$bios.SerialNumber)
    Add-TTFact $s 'Windows' ('{0} ({1}, build {2})' -f $os.Caption, $os.OSArchitecture, $os.BuildNumber)
    Add-TTFact $s 'Processor' (([string]$cpu.Name).Trim() + ' - ' + $cpu.NumberOfLogicalProcessors + ' threads')
    Add-TTFact $s 'RAM installed' (Format-TTBytes $total)
    Add-TTFact $s 'RAM in use' ('{0} of {1} ({2}%)' -f (Format-TTBytes $used), (Format-TTBytes $total), $pct) $memLevel
    $upLevel = if ($uptime.TotalDays -ge 14) { 'warn' } else { '' }
    Add-TTFact $s 'Up since last restart' ('{0} days {1} hours' -f [int][math]::Floor($uptime.TotalDays), $uptime.Hours) $upLevel

    $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    if ($sticks.Count -gt 0) {
        $rows = foreach ($m in $sticks) {
            [pscustomobject]@{ Slot = $m.DeviceLocator; Size = Format-TTBytes ([double]$m.Capacity); Speed = ([string]$m.ConfiguredClockSpeed + ' MHz'); Maker = ([string]$m.Manufacturer).Trim() }
        }
        Add-TTTable $s 'Memory modules' @('Slot', 'Size', 'Speed', 'Maker') $rows
    }

    Set-TTLevel $s $memLevel
    if ($upLevel) { Set-TTLevel $s 'warn'; Add-TTNote $s 'Not restarted in over 14 days. A restart may clear slowness and finish updates.' 'warn' }
    $s.Summary = '{0} - {1} RAM, {2}% in use' -f $env:COMPUTERNAME, (Format-TTBytes $total), $pct
    return $s
}

# ---------------------------------------------------------------- Drives
function Get-TTDiskKind {
    param($Disk)
    $bus = [string]$Disk.BusType
    $media = [string]$Disk.MediaType
    if ($bus -eq 'NVMe') { return 'M.2 NVMe SSD' }
    if ($media -eq 'SSD') { return ('SSD (' + $bus + ')') }
    if ($media -eq 'HDD') { return ('HDD (' + $bus + ')') }
    if ($bus -eq 'USB') { return 'USB drive' }
    return ('Unknown (' + $bus + ')')
}

function Get-TTHealthDisks {
    $s = New-TTSection 'Drives and health'
    $disks = @(Get-PhysicalDisk | Sort-Object { [int]$_.DeviceId })

    # SMART "predict failure" flags from the disk drivers (needs admin).
    $predict = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue |
        Where-Object { $_.PredictFailure })

    $rows = foreach ($d in $disks) {
        $rel = $null
        try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $problems = @()
        $level = 'ok'
        if ([string]$d.HealthStatus -ne 'Healthy') { $problems += ('Health: ' + $d.HealthStatus); $level = 'fail' }
        $ops = @($d.OperationalStatus | ForEach-Object { [string]$_ }) | Where-Object { $_ -ne 'OK' }
        if ($ops) { $problems += ('Status: ' + ($ops -join ', ')); if ($level -ne 'fail') { $level = 'warn' } }
        $wear = ''
        $temp = ''
        $hours = ''
        if ($rel) {
            if ($null -ne $rel.Wear) { $wear = [string]$rel.Wear + '%'; if ($rel.Wear -ge 90) { $problems += 'SSD life nearly used up'; $level = 'fail' } elseif ($rel.Wear -ge 70) { $problems += 'SSD wear high'; if ($level -eq 'ok') { $level = 'warn' } } }
            if ($rel.Temperature) { $temp = [string]$rel.Temperature + ' C'; if ($rel.Temperature -ge 60) { $problems += 'Running hot'; if ($level -eq 'ok') { $level = 'warn' } } }
            if ($rel.PowerOnHours) { $hours = '{0:N0}' -f $rel.PowerOnHours }
            if ($rel.ReadErrorsUncorrected -gt 0) { $problems += ('{0} uncorrected read errors' -f $rel.ReadErrorsUncorrected); $level = 'fail' }
            if ($rel.WriteErrorsUncorrected -gt 0) { $problems += ('{0} uncorrected write errors' -f $rel.WriteErrorsUncorrected); $level = 'fail' }
        }
        Set-TTLevel $s $level
        [pscustomobject]@{
            Disk     = [string]$d.DeviceId
            Model    = ([string]$d.FriendlyName).Trim()
            Type     = Get-TTDiskKind $d
            Size     = Format-TTBytes ([double]$d.Size)
            Health   = [string]$d.HealthStatus
            Wear     = $wear
            Temp     = $temp
            Hours    = $hours
            Problems = if ($problems) { $problems -join '; ' } else { 'None found' }
            _Level   = $level
        }
    }
    Add-TTTable $s 'Physical drives' @('Disk', 'Model', 'Type', 'Size', 'Health', 'Wear', 'Temp', 'Hours', 'Problems') $rows

    if ($predict.Count -gt 0) {
        Set-TTLevel $s 'fail'
        Add-TTNote $s ('SMART predicts failure on {0} drive(s). Back up now and plan a replacement.' -f $predict.Count) 'fail'
    }

    # Volumes: used and free space.
    $vols = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
    $vrows = foreach ($v in $vols) {
        $size = [double]$v.Size
        $free = [double]$v.FreeSpace
        $pctFree = if ($size -gt 0) { [math]::Round(100 * $free / $size) } else { 0 }
        $lv = 'ok'
        if ($pctFree -lt 5 -or $free -lt 5GB) { $lv = 'fail' } elseif ($pctFree -lt 15) { $lv = 'warn' }
        Set-TTLevel $s $lv
        [pscustomobject]@{
            Drive  = $v.DeviceID
            Label  = [string]$v.VolumeName
            Format = [string]$v.FileSystem
            Size   = Format-TTBytes $size
            Used   = Format-TTBytes ($size - $free)
            Free   = ('{0} ({1}%)' -f (Format-TTBytes $free), $pctFree)
            _Level = $lv
        }
    }
    Add-TTTable $s 'Space on each drive' @('Drive', 'Label', 'Format', 'Size', 'Used', 'Free') $vrows

    # Disk and file system errors in the last 30 days are an early warning sign.
    $since = (Get-Date).AddDays(-30)
    $diskEvents = @()
    try {
        $diskEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = @('disk', 'Ntfs', 'storahci', 'stornvme', 'iaStorA', 'iaStorAC'); Level = @(1, 2, 3); StartTime = $since } -MaxEvents 200 -ErrorAction Stop |
            Where-Object { @(7, 11, 15, 51, 52, 55, 98, 129, 153, 157) -contains $_.Id })
    } catch { }
    if ($diskEvents.Count -gt 0) {
        $lvl = if ($diskEvents.Count -ge 10 -or @($diskEvents | Where-Object { @(7, 55) -contains $_.Id }).Count -gt 0) { 'fail' } else { 'warn' }
        Set-TTLevel $s $lvl
        Add-TTNote $s ('{0} disk or file system warnings/errors in the last 30 days (bad blocks, timeouts, corruption). See the table below.' -f $diskEvents.Count) $lvl
        $erows = $diskEvents | Select-Object -First 10 | ForEach-Object {
            [pscustomobject]@{ Time = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm'); Source = $_.ProviderName; Id = $_.Id; Message = Get-TTShortText $_.Message 160 }
        }
        Add-TTTable $s 'Recent disk errors' @('Time', 'Source', 'Id', 'Message') $erows
    }

    $bad = @($rows | Where-Object { $_._Level -ne 'ok' }).Count
    $s.Summary = '{0} drive(s), {1} volume(s)' -f $disks.Count, $vols.Count
    if ($s.Level -eq 'fail') { $s.Summary += ' - FAILURE SIGNS FOUND' }
    elseif ($s.Level -eq 'warn') { $s.Summary += ' - needs attention' }
    else { $s.Summary += ' - no failure signs' }
    if ($bad -eq 0 -and $s.Level -eq 'ok') { Add-TTNote $s 'No SMART warnings, read errors or recent disk errors found.' 'ok' }
    return $s
}

function Get-TTShortText {
    param([string]$Text, [int]$Max = 200)
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    return $t
}

# ---------------------------------------------------------------- Network
function Get-TTHealthNetwork {
    $s = New-TTSection 'Network'
    $cfgs = @(Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' })
    if ($cfgs.Count -eq 0) {
        $s.Level = 'fail'
        $s.Summary = 'No connected network adapter'
        return $s
    }
    $rows = foreach ($c in $cfgs) {
        $ip4 = @($c.IPv4Address)[0]
        $dhcp = ''
        try { $dhcp = [string](Get-NetIPInterface -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).Dhcp } catch { }
        $gw = @($c.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ', '
        $dns = @($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', '
        $lv = 'ok'
        if ($ip4 -and ([string]$ip4.IPAddress).StartsWith('169.254.')) { $lv = 'fail' }
        Set-TTLevel $s $lv
        [pscustomobject]@{
            Adapter = $c.InterfaceAlias
            Device  = $c.InterfaceDescription
            IP      = if ($ip4) { $ip4.IPAddress } else { '' }
            Subnet  = if ($ip4) { ConvertTo-TTMask ([int]$ip4.PrefixLength) } else { '' }
            Gateway = $gw
            DNS     = $dns
            DHCP    = $dhcp
            MAC     = [string]$c.NetAdapter.MacAddress
            Speed   = [string]$c.NetAdapter.LinkSpeed
            _Level  = $lv
        }
    }
    Add-TTTable $s 'Connected adapters' @('Adapter', 'Device', 'IP', 'Subnet', 'Gateway', 'DNS', 'DHCP', 'MAC', 'Speed') $rows
    if (@($rows | Where-Object { $_.IP -like '169.254.*' }).Count -gt 0) { Add-TTNote $s 'A 169.254.x.x address means the PC did not get an address from DHCP.' 'fail' }
    $main = @($rows | Where-Object { $_.Gateway })[0]
    if ($main) { $s.Summary = '{0} on {1}, gateway {2}' -f $main.IP, $main.Adapter, $main.Gateway }
    else { $s.Summary = 'Connected, but no default gateway'; Set-TTLevel $s 'warn'; Add-TTNote $s 'No adapter has a default gateway, so this PC cannot reach the internet.' 'warn' }
    return $s
}

function Measure-TTHostPing {
    param([string]$Target, [int]$Count = 4)
    $p = New-Object System.Net.NetworkInformation.Ping
    $times = @()
    $ip = ''
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $p.Send($Target, 2000)
            if ($r.Status -eq 'Success') { $times += [int]$r.RoundtripTime; $ip = [string]$r.Address }
        } catch { }
    }
    $p.Dispose()
    $lost = $Count - $times.Count
    [pscustomobject]@{
        Target  = $Target
        Address = $ip
        Replies = ('{0}/{1}' -f $times.Count, $Count)
        Average = if ($times.Count) { ('{0} ms' -f [int](($times | Measure-Object -Average).Average)) } else { '-' }
        Best    = if ($times.Count) { ('{0} ms' -f ($times | Measure-Object -Minimum).Minimum) } else { '-' }
        Worst   = if ($times.Count) { ('{0} ms' -f ($times | Measure-Object -Maximum).Maximum) } else { '-' }
        Lost    = $lost
        AvgMs   = if ($times.Count) { [int](($times | Measure-Object -Average).Average) } else { -1 }
    }
}

function Get-TTHealthPing {
    $s = New-TTSection 'Ping tests'
    $rows = foreach ($t in @('google.com', 'yahoo.com', 'msn.com')) {
        $r = Measure-TTHostPing $t
        $lv = 'ok'
        if ($r.Lost -eq 4) { $lv = 'fail' } elseif ($r.Lost -gt 0 -or $r.AvgMs -gt 150) { $lv = 'warn' }
        Set-TTLevel $s $lv
        $r | Add-Member -NotePropertyName _Level -NotePropertyValue $lv -PassThru
    }
    Add-TTTable $s '4 pings to each site' @('Target', 'Address', 'Replies', 'Average', 'Best', 'Worst') $rows
    $ok = @($rows | Where-Object { $_.Lost -lt 4 }).Count
    $s.Summary = '{0} of 3 sites answered' -f $ok
    if ($ok -gt 0) { $s.Summary += (', average ' + (@($rows | Where-Object { $_.AvgMs -ge 0 } | ForEach-Object { $_.Average }) -join ' / ')) }
    if (@($rows | Where-Object { $_.Lost -gt 0 -and $_.Lost -lt 4 }).Count -gt 0) { Add-TTNote $s 'Some pings were lost: possible Wi-Fi interference, a bad cable or an overloaded connection.' 'warn' }
    return $s
}

# ---------------------------------------------------------------- Speed test
function Measure-TTTransfer {
    # Times a download or upload against Cloudflare's speed test endpoints.
    param([ValidateSet('down', 'up')][string]$Direction, [int]$Bytes)
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'MAV-TechTools')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Direction -eq 'down') {
        [void]$wc.DownloadData('https://speed.cloudflare.com/__down?bytes=' + $Bytes)
    } else {
        $wc.Headers.Add('Content-Type', 'application/octet-stream')
        [void]$wc.UploadData('https://speed.cloudflare.com/__up', 'POST', (New-Object byte[] $Bytes))
    }
    $sw.Stop()
    $wc.Dispose()
    $sec = [math]::Max(0.05, $sw.Elapsed.TotalSeconds)
    return [math]::Round(($Bytes * 8 / $sec) / 1e6, 1)
}

function Get-TTHealthSpeed {
    $s = New-TTSection 'Internet speed'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # A small sample first, then a test sized to take about 5 seconds.
    $probe = Measure-TTTransfer down 2000000
    $size = [int][math]::Min(100000000.0, [math]::Max(5000000.0, $probe * 1e6 / 8 * 5))
    $down = Measure-TTTransfer down $size
    $upProbe = Measure-TTTransfer up 1000000
    $upSize = [int][math]::Min(25000000.0, [math]::Max(2000000.0, $upProbe * 1e6 / 8 * 5))
    $up = Measure-TTTransfer up $upSize
    $lv = 'ok'
    if ($down -lt 5) { $lv = 'fail' } elseif ($down -lt 25 -or $up -lt 3) { $lv = 'warn' }
    $s.Level = $lv
    Add-TTFact $s 'Download' ('{0} Mbps' -f $down) $lv
    Add-TTFact $s 'Upload' ('{0} Mbps' -f $up)
    Add-TTFact $s 'Test server' 'speed.cloudflare.com (nearest Cloudflare location)'
    Add-TTFact $s 'Data used' (Format-TTBytes ($size + $upSize + 3000000))
    $s.Summary = '{0} Mbps down / {1} Mbps up' -f $down, $up
    if ($lv -ne 'ok') { Add-TTNote $s 'Slower than expected. Compare with the plan the office pays for, and re-test on a cable if this PC is on Wi-Fi.' $lv }
    return $s
}

# ---------------------------------------------------------------- Events and processes
function Get-TTHealthEvents {
    $s = New-TTSection 'Event log'
    $s.Level = 'info'
    $events = @()
    foreach ($log in @('System', 'Application')) {
        try { $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = @(1, 2) } -MaxEvents 10 -ErrorAction Stop) } catch { }
    }
    $events = @($events | Sort-Object TimeCreated -Descending | Select-Object -First 10)
    $rows = foreach ($e in $events) {
        [pscustomobject]@{
            Time    = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm')
            Log     = $e.LogName
            Level   = $e.LevelDisplayName
            Source  = $e.ProviderName
            Id      = $e.Id
            Message = Get-TTShortText $e.Message 220
            _Level  = if ($e.Level -eq 1) { 'fail' } else { '' }
        }
    }
    Add-TTTable $s 'Last 10 errors and critical events (System and Application logs)' @('Time', 'Log', 'Level', 'Source', 'Id', 'Message') $rows
    $day = @($events | Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-24) }).Count
    $s.Summary = if ($events.Count) { '{0} of the last 10 errors were in the past 24 hours' -f $day } else { 'No errors logged' }
    if (@($events | Where-Object { $_.Level -eq 1 }).Count -gt 0) { $s.Level = 'warn'; Add-TTNote $s 'Critical events found (often an unexpected shutdown or crash).' 'warn' }
    return $s
}

function Get-TTHealthProcesses {
    $s = New-TTSection 'Top processes'
    $s.Level = 'info'
    $cores = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $procs = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
        Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' })
    $toRow = {
        param($p)
        [pscustomobject]@{
            Process = ($p.Name -replace '#\d+$', '')
            PID     = $p.IDProcess
            CPU     = ('{0:N1}%' -f ([double]$p.PercentProcessorTime / [math]::Max(1.0, $cores)))
            Memory  = Format-TTBytes ([double]$p.WorkingSetPrivate)
        }
    }
    $byCpu = $procs | Sort-Object @{ Expression = { [double]$_.PercentProcessorTime }; Descending = $true }, @{ Expression = { [double]$_.WorkingSetPrivate }; Descending = $true } | Select-Object -First 10
    $byMem = $procs | Sort-Object { [double]$_.WorkingSetPrivate } -Descending | Select-Object -First 10
    Add-TTTable $s 'Top 10 by CPU (right now)' @('Process', 'PID', 'CPU', 'Memory') @($byCpu | ForEach-Object { & $toRow $_ })
    Add-TTTable $s 'Top 10 by memory' @('Process', 'PID', 'CPU', 'Memory') @($byMem | ForEach-Object { & $toRow $_ })
    $total = ($procs | Measure-Object -Property PercentProcessorTime -Sum).Sum / [math]::Max(1.0, $cores)
    $top = @($byMem)[0]
    $s.Summary = 'CPU {0:N0}% busy; biggest memory user: {1} ({2})' -f $total, ($top.Name -replace '#\d+$', ''), (Format-TTBytes ([double]$top.WorkingSetPrivate))
    if ($total -ge 90) { $s.Level = 'warn'; Add-TTNote $s 'CPU is almost fully busy.' 'warn' }
    return $s
}

# ---------------------------------------------------------------- Shares and printers
function Get-TTHealthShares {
    $s = New-TTSection 'Shared folders'
    $s.Level = 'info'
    $shares = @(Get-SmbShare | Sort-Object Name)
    $user = @($shares | Where-Object { -not $_.Special -and $_.Name -notmatch '\$$' })
    $rows = foreach ($sh in $shares) {
        $isDefault = $sh.Special -or $sh.Name -match '\$$'
        $access = ''
        if (-not $isDefault) {
            try {
                $access = @(Get-SmbShareAccess -Name $sh.Name -ErrorAction Stop | ForEach-Object { '{0}: {1} {2}' -f $_.AccountName, $_.AccessControlType, $_.AccessRight }) -join '; '
            } catch { }
        }
        [pscustomobject]@{
            Share  = $sh.Name
            Path   = [string]$sh.Path
            Kind   = if ($isDefault) { 'Windows default (hidden)' } else { 'Shared by a user' }
            Access = $access
            _Level = if (-not $isDefault -and $access -match 'Everyone: Allow Full') { 'warn' } else { '' }
        }
    }
    Add-TTTable $s 'All shares on this PC' @('Share', 'Path', 'Kind', 'Access') $rows
    if (@($rows | Where-Object { $_._Level -eq 'warn' }).Count) { $s.Level = 'warn'; Add-TTNote $s 'A share gives Everyone full control. Check that this is intended.' 'warn' }
    $s.Summary = if ($user.Count) { '{0} shared folder(s): {1}' -f $user.Count, (($user | ForEach-Object { $_.Name }) -join ', ') } else { 'No user shared folders (only Windows defaults)' }
    return $s
}

function Get-TTPrinterDriverDate {
    param([string]$Driver)
    foreach ($env_ in @('Windows x64', 'Windows NT x86', 'Windows ARM64')) {
        foreach ($ver in @('Version-3', 'Version-4')) {
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\{0}\Drivers\{1}\{2}' -f $env_, $ver, $Driver
            $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($p -and $p.DriverDate) {
                $d = [datetime]::MinValue
                $raw = ([string]$p.DriverDate).Split(' ')[0]
                if ([datetime]::TryParseExact($raw, 'MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { return $d }
            }
        }
    }
    return $null
}

function Get-TTHealthPrinters {
    $s = New-TTSection 'Printers'
    $s.Level = 'info'
    $printers = @(Get-Printer | Sort-Object Name)
    $default = @(Get-CimInstance Win32_Printer -Filter 'Default=TRUE' -ErrorAction SilentlyContinue)[0]
    $drivers = @{}
    foreach ($d in @(Get-PrinterDriver -ErrorAction SilentlyContinue)) { $drivers[$d.Name] = $d }
    $rows = foreach ($p in $printers) {
        $drv = $drivers[$p.DriverName]
        $ver = ''
        if ($drv -and $drv.DriverVersion) {
            $v = [uint64]$drv.DriverVersion
            $ver = '{0}.{1}.{2}.{3}' -f (($v -shr 48) -band 0xFFFF), (($v -shr 32) -band 0xFFFF), (($v -shr 16) -band 0xFFFF), ($v -band 0xFFFF)
        }
        $date = Get-TTPrinterDriverDate $p.DriverName
        $lv = ''
        if ([string]$p.PrinterStatus -match 'Error|Offline') { $lv = 'warn' }
        [pscustomobject]@{
            Printer      = $p.Name + $(if ($default -and $default.Name -eq $p.Name) { ' (default)' } else { '' })
            Status       = [string]$p.PrinterStatus
            Port         = [string]$p.PortName
            Driver       = [string]$p.DriverName
            'Driver ver' = $ver
            'Driver date' = if ($date) { $date.ToString('yyyy-MM-dd') } else { 'unknown' }
            Shared       = if ($p.Shared) { 'Yes' } else { 'No' }
            _Level       = $lv
        }
    }
    Add-TTTable $s 'Installed printers' @('Printer', 'Status', 'Port', 'Driver', 'Driver ver', 'Driver date', 'Shared') $rows
    $real = @($printers | Where-Object { $_.DriverName -notmatch 'Microsoft (Print To PDF|XPS|Shared Fax)|OneNote|Fax' })
    $s.Summary = '{0} printer(s), {1} not built in' -f $printers.Count, $real.Count
    if (@($rows | Where-Object { $_._Level -eq 'warn' }).Count) { $s.Level = 'warn'; Add-TTNote $s 'A printer reports an error or offline status.' 'warn' }
    return $s
}

# ---------------------------------------------------------------- Updates and security
function Test-TTRebootPending {
    $why = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $why += 'Windows component servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $why += 'Windows Update' }
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) { $why += 'pending file renames' }
    return $why
}

function Get-TTHealthUpdates {
    $s = New-TTSection 'Windows Update'
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $rows = foreach ($u in @($result.Updates)) {
        $kb = @($u.KBArticleIDs) | ForEach-Object { 'KB' + $_ }
        [pscustomobject]@{
            Update   = $u.Title
            KB       = ($kb -join ', ')
            Severity = if ($u.MsrcSeverity) { [string]$u.MsrcSeverity } else { '' }
            Size     = Format-TTBytes ([double]$u.MaxDownloadSize)
            _Level   = if ($u.MsrcSeverity -eq 'Critical') { 'warn' } else { '' }
        }
    }
    $rows = @($rows)
    if ($rows.Count) { Add-TTTable $s 'Pending updates' @('Update', 'KB', 'Severity', 'Size') $rows }
    $reboot = @(Test-TTRebootPending)
    if ($reboot.Count) { Add-TTFact $s 'Restart pending' ('Yes - ' + ($reboot -join ', ')) 'warn'; Set-TTLevel $s 'warn' }
    else { Add-TTFact $s 'Restart pending' 'No' }
    $last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($last) {
        $age = ((Get-Date) - $last.InstalledOn).Days
        $lv = if ($age -gt 60) { 'warn' } else { '' }
        Add-TTFact $s 'Last update installed' ('{0} on {1} ({2} days ago)' -f $last.HotFixID, $last.InstalledOn.ToString('yyyy-MM-dd'), $age) $lv
        if ($lv) { Set-TTLevel $s 'warn' }
    }
    if ($rows.Count) {
        Set-TTLevel $s 'warn'
        $s.Summary = '{0} update(s) waiting to install' -f $rows.Count
    } else {
        $s.Summary = 'Up to date'
    }
    if ($reboot.Count) { $s.Summary += '; restart pending' }
    return $s
}

function Get-TTHealthSecurity {
    $s = New-TTSection 'Antivirus and EDR'
    # Main service of each product we support. Installed = service exists; operational = running.
    $products = @(
        @{ Name = 'Webroot SecureAnywhere'; Services = @('WRSVC', 'WRCoreService', 'WRSkyClient') },
        @{ Name = 'SentinelOne'; Services = @('SentinelAgent', 'SentinelStaticEngine') },
        @{ Name = 'Bitdefender'; Services = @('EPSecurityService', 'EPProtectedService', 'VSSERV', 'bdredline') },
        @{ Name = 'CrowdStrike Falcon'; Services = @('CSFalconService') }
    )
    $rows = foreach ($p in $products) {
        $svcs = @(Get-Service -Name $p.Services -ErrorAction SilentlyContinue)
        $running = @($svcs | Where-Object { $_.Status -eq 'Running' })
        $state = 'Not installed'
        $lv = ''
        if ($svcs.Count -gt 0) {
            if ($running.Count -gt 0) { $state = 'Installed and running'; $lv = 'ok' }
            else { $state = 'Installed but NOT running'; $lv = 'fail' }
        }
        [pscustomobject]@{
            Product  = $p.Name
            State    = $state
            Services = if ($svcs.Count) { (($svcs | ForEach-Object { $_.Name + '=' + $_.Status }) -join ', ') } else { '' }
            _Level   = $lv
        }
    }
    $rows = @($rows)
    Add-TTTable $s 'Managed security products' @('Product', 'State', 'Services') $rows

    # What Windows Security Center sees (workstations only).
    $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
    if ($av.Count) {
        $crows = foreach ($a in $av) {
            $hex = '{0:X6}' -f [int]$a.productState
            $on = $hex.Substring(2, 2) -in @('10', '11')
            $current = $hex.Substring(4, 2) -eq '00'
            [pscustomobject]@{
                Product      = $a.displayName
                Protection   = if ($on) { 'On' } else { 'Off' }
                Definitions  = if ($current) { 'Up to date' } else { 'Out of date' }
                _Level       = if ($on -and $current) { '' } elseif ($on) { 'warn' } else { '' }
            }
        }
        Add-TTTable $s 'Windows Security Center' @('Product', 'Protection', 'Definitions') $crows
    }

    $installed = @($rows | Where-Object { $_.State -ne 'Not installed' })
    $broken = @($rows | Where-Object { $_._Level -eq 'fail' })
    if ($broken.Count) {
        $s.Level = 'fail'
        $s.Summary = ($broken | ForEach-Object { $_.Product }) -join ', '
        $s.Summary += ' installed but not running'
    } elseif ($installed.Count) {
        $s.Level = 'ok'
        $s.Summary = (($installed | ForEach-Object { $_.Product }) -join ', ') + ' running'
    } else {
        $s.Level = 'warn'
        $s.Summary = 'None of Webroot, SentinelOne, Bitdefender or CrowdStrike found'
        $active = @($av | Where-Object { ('{0:X6}' -f [int]$_.productState).Substring(2, 2) -in @('10', '11') } | ForEach-Object { $_.displayName })
        if ($active.Count) { $s.Summary += ('; active: ' + ($active -join ', ')) }
    }
    return $s
}

# ---------------------------------------------------------------- Report
function ConvertTo-TTHtml {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function New-TTHealthReport {
    # Writes a self-contained HTML report and returns its path.
    param($Sections, [string]$Folder, [string]$Title = 'PC Health Check', [string]$Prefix = 'Health', [string]$Lead = '')
    $now = Get-Date
    $file = Join-Path $Folder ('{0}-{1}-{2}.html' -f $Prefix, $env:COMPUTERNAME, $now.ToString('yyyyMMdd-HHmmss'))
    $fails = @($Sections | Where-Object { $_.Level -eq 'fail' }).Count
    $warns = @($Sections | Where-Object { $_.Level -eq 'warn' }).Count
    $overall = if ($fails) { 'fail' } elseif ($warns) { 'warn' } else { 'ok' }
    $headline = if ($fails) { '{0} problem(s), {1} warning(s)' -f $fails, $warns } elseif ($warns) { '{0} warning(s), nothing failing' -f $warns } else { 'Everything checked looks healthy' }
    $label = @{ ok = 'OK'; warn = 'CHECK'; fail = 'PROBLEM'; info = 'INFO' }

    $sb = New-Object System.Text.StringBuilder
    $css = @'
:root{--bg:#070B12;--panel:#0A1019;--card:#0E1520;--line:#1E2A3B;--text:#E6EDF5;--muted:#8A99AD;--accent:#24A7E0;--ok:#34D399;--warn:#FBBF24;--fail:#F87171}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:1200px;margin:0 auto;padding:28px 20px 60px}
header{display:flex;flex-wrap:wrap;justify-content:space-between;gap:16px;align-items:flex-end;border-bottom:1px solid var(--line);padding-bottom:18px;margin-bottom:20px}
.brand{font:12px Consolas,monospace;letter-spacing:.14em;color:var(--accent)}h1{margin:4px 0 0;font-size:28px}
.meta{color:var(--muted);font-size:13px;text-align:right}
.banner{display:flex;align-items:center;gap:12px;padding:14px 16px;border-radius:12px;border:1px solid var(--line);background:var(--panel);margin-bottom:18px;font-size:16px;font-weight:600}
.dot{width:12px;height:12px;border-radius:50%;flex:none}
.d-ok{background:var(--ok)}.d-warn{background:var(--warn)}.d-fail{background:var(--fail)}.d-info{background:var(--muted)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:10px;margin-bottom:24px}
.tile{display:block;padding:12px 14px;border:1px solid var(--line);border-radius:12px;background:var(--card);color:inherit;text-decoration:none}
.tile b{display:flex;align-items:center;gap:8px;font-size:13px}.tile span{display:block;color:var(--muted);font-size:12px;margin-top:4px}
section{border:1px solid var(--line);border-radius:14px;background:var(--card);padding:18px;margin-bottom:16px}
section h2{display:flex;align-items:center;gap:10px;margin:0 0 4px;font-size:18px}
.chip{font:11px Consolas,monospace;padding:2px 8px;border-radius:99px;border:1px solid}
.c-ok{color:var(--ok);border-color:#1F5C46}.c-warn{color:var(--warn);border-color:#5A4A1F}.c-fail{color:var(--fail);border-color:#5C2A2A}.c-info{color:var(--muted);border-color:var(--line)}
.sum{color:var(--muted);margin:0 0 12px}
dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 18px;margin:0 0 12px}dt{color:var(--muted)}dd{margin:0}
.lv-warn{color:var(--warn)}.lv-fail{color:var(--fail);font-weight:600}.lv-ok{color:var(--ok)}
.note{padding:8px 12px;border-radius:8px;margin:0 0 10px;background:var(--panel);border-left:3px solid var(--muted)}
.n-warn{border-color:var(--warn)}.n-fail{border-color:var(--fail)}.n-ok{border-color:var(--ok)}
.tw{overflow-x:auto;margin-bottom:12px}table{width:100%;border-collapse:collapse;font-size:13px}
caption{text-align:left;color:var(--muted);font:11px Consolas,monospace;letter-spacing:.08em;text-transform:uppercase;padding:6px 0}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600;white-space:nowrap}
tr.r-warn td{background:rgba(251,191,36,.08)}tr.r-fail td{background:rgba(248,113,113,.12)}
footer{color:var(--muted);font-size:12px;margin-top:24px}
@media print{:root{--bg:#fff;--panel:#f6f7f9;--card:#fff;--line:#d5dbe3;--text:#111;--muted:#555;--accent:#0b7fb3;--ok:#0a7d55;--warn:#a16207;--fail:#b91c1c}
*{-webkit-print-color-adjust:exact;print-color-adjust:exact}main{padding:0}.tile{break-inside:avoid}section{break-inside:auto}tr{break-inside:avoid}
tr.r-warn td{background:#fdf6e3}tr.r-fail td{background:#fdecec}.c-ok{border-color:#9fd9c2}.c-warn{border-color:#e8cf8f}.c-fail{border-color:#efb1b1}}
@page{margin:12mm}
'@
    [void]$sb.Append('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.Append('<title>' + (ConvertTo-TTHtml $Title) + ' - ' + (ConvertTo-TTHtml $env:COMPUTERNAME) + '</title><style>' + $css + '</style></head><body><main>')
    [void]$sb.Append('<header><div><div class="brand">MAV COMPUTERS LLC - TECHTOOLS</div><h1>' + (ConvertTo-TTHtml $Title) + ': ' + (ConvertTo-TTHtml $env:COMPUTERNAME) + '</h1></div>')
    [void]$sb.Append('<div class="meta">' + $now.ToString('yyyy-MM-dd HH:mm') + '<br>Run by ' + (ConvertTo-TTHtml ($env:USERDOMAIN + '\' + $env:USERNAME)) + '</div></header>')
    [void]$sb.Append('<div class="banner"><span class="dot d-' + $overall + '"></span>' + (ConvertTo-TTHtml $headline) + '</div>')
    if ($Lead) { [void]$sb.Append('<p class="note n-' + $overall + '" style="font-size:15px">' + (ConvertTo-TTHtml $Lead) + '</p>') }

    [void]$sb.Append('<div class="grid">')
    $i = 0
    foreach ($sec in $Sections) {
        $i++
        [void]$sb.Append('<a class="tile" href="#s' + $i + '"><b><span class="dot d-' + $sec.Level + '"></span>' + (ConvertTo-TTHtml $sec.Title) + '</b><span>' + (ConvertTo-TTHtml $sec.Summary) + '</span></a>')
    }
    [void]$sb.Append('</div>')

    $i = 0
    foreach ($sec in $Sections) {
        $i++
        [void]$sb.Append('<section id="s' + $i + '"><h2>' + (ConvertTo-TTHtml $sec.Title) + ' <span class="chip c-' + $sec.Level + '">' + $label[$sec.Level] + '</span></h2>')
        [void]$sb.Append('<p class="sum">' + (ConvertTo-TTHtml $sec.Summary) + '</p>')
        foreach ($n in $sec.Notes) { [void]$sb.Append('<p class="note n-' + $n.Level + '">' + (ConvertTo-TTHtml $n.Text) + '</p>') }
        if ($sec.Facts.Count) {
            [void]$sb.Append('<dl>')
            foreach ($f in $sec.Facts) {
                $cls = if ($f.Level) { ' class="lv-' + $f.Level + '"' } else { '' }
                [void]$sb.Append('<dt>' + (ConvertTo-TTHtml $f.Label) + '</dt><dd' + $cls + '>' + (ConvertTo-TTHtml $f.Value) + '</dd>')
            }
            [void]$sb.Append('</dl>')
        }
        foreach ($t in $sec.Tables) {
            [void]$sb.Append('<div class="tw"><table><caption>' + (ConvertTo-TTHtml $t.Caption) + '</caption><thead><tr>')
            foreach ($c in $t.Columns) { [void]$sb.Append('<th>' + (ConvertTo-TTHtml $c) + '</th>') }
            [void]$sb.Append('</tr></thead><tbody>')
            if (@($t.Rows).Count -eq 0) { [void]$sb.Append('<tr><td colspan="' + $t.Columns.Count + '">None</td></tr>') }
            foreach ($r in $t.Rows) {
                $lv = [string]$r._Level
                $cls = if ($lv -eq 'warn' -or $lv -eq 'fail') { ' class="r-' + $lv + '"' } else { '' }
                [void]$sb.Append('<tr' + $cls + '>')
                foreach ($c in $t.Columns) { [void]$sb.Append('<td>' + (ConvertTo-TTHtml $r.$c) + '</td>') }
                [void]$sb.Append('</tr>')
            }
            [void]$sb.Append('</tbody></table></div>')
        }
        [void]$sb.Append('</section>')
    }
    [void]$sb.Append('<footer>Saved to ' + (ConvertTo-TTHtml $file) + '</footer></main></body></html>')
    [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $file
}

function Write-TTHealthSummary {
    # One console line per section; warnings and problems turn the job amber.
    param($Section)
    $tag = @{ ok = 'OK     '; warn = 'CHECK  '; fail = 'PROBLEM'; info = 'INFO   ' }[$Section.Level]
    $line = '{0} {1}: {2}' -f $tag, $Section.Title, $Section.Summary
    if ($Section.Level -eq 'warn' -or $Section.Level -eq 'fail') { Write-Warn $line } else { Write-Info $line }
}
