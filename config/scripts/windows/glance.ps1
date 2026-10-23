# Home page "This PC at a glance" (read-only, a few seconds). Keep this file ASCII-only.
Write-Step 'Reading Windows, uptime and memory'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$boot = $os.LastBootUpTime
$up = (Get-Date) - $boot
$memGB = [math]::Round($cs.TotalPhysicalMemory / 1GB)
$memPct = [int](100 - (100 * $os.FreePhysicalMemory / [math]::Max(1, $os.TotalVisibleMemorySize)))
$console = [string]$cs.UserName
Write-Step 'Reading drive C:'
$c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$cTotal = [math]::Round($c.Size / 1GB); $cFree = [math]::Round($c.FreeSpace / 1GB)
$cPct = [int](100 - (100 * $c.FreeSpace / [math]::Max(1, $c.Size)))
Write-Step 'Reading the network'
$adapter = ''; $ip = ''; $speed = ''
foreach ($n in @(Get-TTNetConfigs | Where-Object { $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway })) {
    $adapter = [string]$n.InterfaceAlias
    $ip = [string](@($n.IPv4Address)[0].IPAddress)
    $speed = [string]$n.NetAdapter.LinkSpeed
    break
}
Write-Step 'Checking antivirus and restarts'
$av = @()
foreach ($p in @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)) {
    $state = [int]$p.productState
    $av += [pscustomobject]@{ Name = [string]$p.displayName; On = (($state -band 0x1000) -ne 0); Current = (($state -band 0x10) -eq 0) }
}
$why = @(Test-TTRebootPending)
$r = [pscustomobject]@{
    Pc = $env:COMPUTERNAME; User = $console; Os = ([string]$os.Caption -replace '^Microsoft\s+', ''); Build = [string]$os.BuildNumber
    Model = (([string]$cs.Manufacturer + ' ' + [string]$cs.Model).Trim()); UptimeDays = [int][math]::Floor($up.TotalDays); LastBoot = $boot
    MemGB = $memGB; MemPct = $memPct; CTotalGB = $cTotal; CFreeGB = $cFree; CPct = $cPct
    Adapter = $adapter; IPv4 = $ip; Speed = $speed; Domain = [string]$cs.Domain; OnDomain = [bool]$cs.PartOfDomain
    Antivirus = $av; RebootWhy = $why; At = (Get-Date)
}
Write-Info ('{0}: up {1} days, C: {2}% used, memory {3}% used' -f $r.Pc, $r.UptimeDays, $r.CPct, $r.MemPct)
Set-Result $r
