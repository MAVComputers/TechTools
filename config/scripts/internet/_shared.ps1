# Shared helpers for every Internet Issues tool.
# Loaded before each Internet tool runs, so tools can call these functions.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

function Get-TTActiveNet {
    # The adapter that carries internet traffic: up, has a gateway, lowest metric.
    $all = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
    $cfg = $all |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' } |
        Sort-Object { [int]$_.NetIPv4Interface.InterfaceMetric + [int](@($_.IPv4DefaultGateway)[0].RouteMetric) } |
        Select-Object -First 1
    if (-not $cfg) {
        # Connected but no gateway (for example no DHCP answer): still return the adapter.
        $cfg = $all | Where-Object { $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    }
    return $cfg
}

function Get-TTActiveAlias {
    $c = Get-TTActiveNet
    if (-not $c) { throw 'No connected network adapter found. Check the cable or Wi-Fi connection.' }
    return $c.InterfaceAlias
}

function Measure-TTPing {
    param([string]$Target, [int]$Count = 4, [int]$TimeoutMs = 1500)
    $ping = New-Object System.Net.NetworkInformation.Ping
    $times = @()
    $lost = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, $TimeoutMs)
            if ($r.Status -eq 'Success') { $times += [int]$r.RoundtripTime } else { $lost++ }
        } catch { $lost++ }
    }
    $avg = $null
    if ($times.Count -gt 0) { $avg = [int][math]::Round(($times | Measure-Object -Average).Average) }
    return [pscustomobject]@{ Target = $Target; Sent = $Count; Lost = $lost; AvgMs = $avg }
}

function Measure-TTDns {
    param([string[]]$Names = @('microsoft.com', 'google.com', 'cloudflare.com'))
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $times = @()
    $failed = 0
    foreach ($n in $Names) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Resolve-DnsName -Name $n -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null
            $times += [int]$sw.ElapsedMilliseconds
        } catch { $failed++ }
    }
    $avg = $null
    if ($times.Count -gt 0) { $avg = [int][math]::Round(($times | Measure-Object -Average).Average) }
    return [pscustomobject]@{ AvgMs = $avg; Failed = $failed; Total = $Names.Count }
}

function Get-TTNetSnapshot {
    # One pass over everything the status panel and diagnosis need.
    $s = [ordered]@{
        Adapter = $null; AdapterDetail = ''; IPv4 = $null; Dhcp = $null; Apipa = $false
        Gateway = $null; GatewayMs = $null; GatewayLost = 0; GatewaySent = 0
        Dns = @(); DnsMs = $null; DnsFailed = 0; DnsTotal = 0
        InternetMs = $null; InternetOk = $false; HttpOk = $false; CaptivePortal = $false
        PublicIp = $null; ProxyOn = $false; ProxyDetail = ''
    }
    $cfg = Get-TTActiveNet
    if ($cfg) {
        $s.Adapter = $cfg.InterfaceAlias
        $s.AdapterDetail = ('{0}, {1}' -f $cfg.NetAdapter.InterfaceDescription, $cfg.NetAdapter.LinkSpeed)
        $ip = @($cfg.IPv4Address)[0]
        if ($ip) {
            $s.IPv4 = $ip.IPAddress
            $s.Apipa = ($ip.IPAddress -like '169.254.*')
            $s.Dhcp = ([string]$ip.PrefixOrigin -eq 'Dhcp')
        }
        $gw = @($cfg.IPv4DefaultGateway)[0]
        if ($gw) { $s.Gateway = $gw.NextHop }
        $s.Dns = @(@($cfg.DNSServer) | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })
    }
    if ($s.Gateway) {
        $p = Measure-TTPing -Target $s.Gateway -Count 4
        $s.GatewayMs = $p.AvgMs; $s.GatewayLost = $p.Lost; $s.GatewaySent = $p.Sent
    }
    $d = Measure-TTDns
    $s.DnsMs = $d.AvgMs; $s.DnsFailed = $d.Failed; $s.DnsTotal = $d.Total

    $best = $null
    foreach ($t in @('1.1.1.1', '8.8.8.8')) {
        $p = Measure-TTPing -Target $t -Count 2
        if ($null -ne $p.AvgMs -and ($null -eq $best -or $p.AvgMs -lt $best)) { $best = $p.AvgMs }
    }
    $s.InternetMs = $best
    $s.InternetOk = ($null -ne $best)

    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 6
        $s.HttpOk = $true
        $s.CaptivePortal = ([string]$r.Content -notmatch 'Microsoft Connect Test')
    } catch { }
    try { $s.PublicIp = [string](Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 6) } catch { }

    $notes = @()
    $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($is -and $is.ProxyEnable -eq 1) { $notes += ('user proxy ' + $is.ProxyServer) }
    if ($is -and $is.AutoConfigURL) { $notes += ('auto-config script ' + $is.AutoConfigURL) }
    $wh = (netsh winhttp show proxy) -join ' '
    if ($wh -and $wh -notmatch 'Direct access') { $notes += 'WinHTTP proxy' }
    $s.ProxyOn = ($notes.Count -gt 0)
    $s.ProxyDetail = ($notes -join '; ')

    return [pscustomobject]$s
}

function Get-TTFindings {
    # Turns a snapshot into plain-English findings plus the fixes to pre-select.
    param($S)
    $findings = New-Object System.Collections.ArrayList
    $rec = New-Object System.Collections.ArrayList
    $addF = { param($Level, $Text) [void]$findings.Add([pscustomobject]@{ Level = $Level; Text = $Text }) }
    $addR = { param($Id, $Value) if (-not ($rec | Where-Object { $_.Id -eq $Id })) { [void]$rec.Add([pscustomobject]@{ Id = $Id; Value = $Value }) } }

    if (-not $S.Adapter) {
        & $addF 'fail' 'No connected network adapter. Check the cable or Wi-Fi connection.'
        & $addR 'adapters' $null
    } else {
        & $addF 'ok' ('Adapter connected: {0} ({1})' -f $S.Adapter, $S.AdapterDetail)

        if ($S.Apipa) {
            & $addF 'fail' ('No address from the router ({0}). DHCP is not answering.' -f $S.IPv4)
            & $addR 'renew' $null; & $addR 'adapters' $null
        } elseif (-not $S.IPv4) {
            & $addF 'fail' 'The adapter has no IPv4 address.'
            & $addR 'renew' $null
        } else {
            $kind = 'static'
            if ($S.Dhcp) { $kind = 'DHCP' }
            & $addF 'ok' ('IP address {0} ({1})' -f $S.IPv4, $kind)
        }

        if (-not $S.Gateway) {
            & $addF 'fail' 'No default gateway (router address).'
            & $addR 'renew' $null
        } elseif ($S.GatewaySent -gt 0 -and $S.GatewayLost -ge $S.GatewaySent) {
            & $addF 'fail' ('The router ({0}) is not answering.' -f $S.Gateway)
            & $addR 'adapters' $null; & $addR 'arp' $null
        } elseif ($S.GatewayLost -gt 0) {
            & $addF 'warn' ('The router ({0}) dropped {1} of {2} pings. Possible cable or Wi-Fi signal problem.' -f $S.Gateway, $S.GatewayLost, $S.GatewaySent)
        } else {
            & $addF 'ok' ('Router {0} answers in {1} ms' -f $S.Gateway, $S.GatewayMs)
        }
    }

    $servers = ($S.Dns -join ', ')
    if (-not $servers) { $servers = 'none set' }
    if ($S.DnsTotal -gt 0 -and $S.DnsFailed -ge $S.DnsTotal) {
        & $addF 'fail' ('DNS lookups are failing (servers: {0}).' -f $servers)
        & $addR 'flushdns' $null; & $addR 'dns' 'cloudflare'
    } elseif ($S.DnsFailed -gt 0 -or ($null -ne $S.DnsMs -and $S.DnsMs -gt 250)) {
        & $addF 'warn' ('DNS lookups are slow or unreliable: {0} ms average, {1} of {2} failed (servers: {3}).' -f $S.DnsMs, $S.DnsFailed, $S.DnsTotal, $servers)
        & $addR 'flushdns' $null; & $addR 'dns' 'cloudflare'
    } else {
        & $addF 'ok' ('DNS lookups answer in {0} ms (servers: {1})' -f $S.DnsMs, $servers)
    }

    if ($S.InternetOk -or $S.HttpOk) {
        if ($S.CaptivePortal) {
            & $addF 'warn' 'This network wants a sign-in page (guest or hotel Wi-Fi). Open a browser to sign in.'
        } elseif ($S.InternetOk) {
            & $addF 'ok' ('Internet reachable ({0} ms)' -f $S.InternetMs)
        } else {
            & $addF 'ok' 'Internet reachable (ping is blocked, but web traffic works)'
        }
    } elseif ($S.Adapter -and $S.Gateway -and $S.GatewayLost -lt $S.GatewaySent) {
        & $addF 'fail' 'The router answers but the internet does not. Check the modem, ISP or firewall.'
        & $addR 'winsock' $null
    } elseif ($S.Adapter) {
        & $addF 'fail' 'The internet is not reachable.'
    }

    if ($S.ProxyOn) {
        & $addF 'warn' ('A proxy is set ({0}). Leftover proxies from old VPNs or adware often break browsing.' -f $S.ProxyDetail)
        & $addR 'proxyreset' $null
    }

    $problems = @($findings | Where-Object { $_.Level -ne 'ok' }).Count
    return [pscustomobject]@{ Findings = @($findings); Recommend = @($rec); Problems = $problems }
}
