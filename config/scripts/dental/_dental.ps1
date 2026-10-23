# Shared helpers for Dental > Practice Management and Imaging.
# Program details come from config/dental/programs.json and arrive as job Input.
# Keep this file ASCII-only.

$script:TTUsbSub = '2a737441-1930-4402-8d77-b2bebba308a3'
$script:TTUsbSet = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'

function Get-TTProgProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] } else { return $Default } }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-TTInstalledApps {
    # Installed programs from the 64-bit, 32-bit and current-user uninstall keys.
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $out = @()
    foreach ($k in $keys) {
        foreach ($i in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
            $n = [string](Get-TTProgProp $i 'DisplayName' '')
            if ($n) { $out += [pscustomobject]@{ Name = $n.Trim(); Version = [string](Get-TTProgProp $i 'DisplayVersion' '') } }
        }
    }
    return $out
}

function Find-TTProgram {
    # Returns the installed version (or 'installed') when the program is on this PC, else ''.
    param($Program, $Apps)
    $m = [string](Get-TTProgProp $Program 'match' '')
    $vm = [string](Get-TTProgProp $Program 'verMatch' '')
    if ($m) {
        foreach ($a in @($Apps)) {
            if ($a.Name -match $m -and (-not $vm -or $a.Version -match $vm)) {
                if ($a.Version) { return $a.Version } else { return 'installed' }
            }
        }
    }
    $f = [string](Get-TTProgProp $Program 'folder' '')
    if ($f -and -not $vm -and (Test-Path -LiteralPath $f)) { return 'installed' }
    return ''
}

function Test-TTTcp {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

function Test-TTShareWrite {
    # 'ok', 'readonly' or 'missing' for a \\server\share path.
    param([string]$Unc)
    if (-not (Test-Path -LiteralPath $Unc -ErrorAction SilentlyContinue)) { return 'missing' }
    $f = Join-Path $Unc ('.mavtt-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($f, 'MAV TechTools write test')
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        return 'ok'
    } catch { return 'readonly' }
}

function Test-TTUsersCanWrite {
    # True when the built-in Users group has Modify or Full Control on the folder.
    param([string]$Path)
    try { $acl = Get-Acl -LiteralPath $Path } catch { return $null }
    foreach ($r in $acl.Access) {
        $sid = $null
        try { $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
        if ($sid -eq 'S-1-5-32-545' -and $r.AccessControlType -eq 'Allow' -and
            (($r.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify)) { return $true }
    }
    return $false
}

function Get-TTUsbPower {
    # USB selective suspend (AC) and how many USB hubs Windows may switch off.
    $on = $null
    $q = @(& powercfg.exe /query SCHEME_CURRENT $script:TTUsbSub $script:TTUsbSet 2>$null)
    $global:LASTEXITCODE = 0
    $hex = @($q | ForEach-Object { if ($_ -match ':\s*0x([0-9a-fA-F]+)\s*$') { [Convert]::ToInt64($Matches[1], 16) } })
    if ($hex.Count -ge 2) { $on = ($hex[$hex.Count - 2] -ne 0) }
    $hubs = @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -match '^USB\\' })
    $sleepy = @($hubs | Where-Object { $_.Enable })
    return [pscustomobject]@{ SuspendOn = $on; Hubs = $hubs.Count; HubsCanSleep = $sleepy.Count }
}

function Set-TTUsbPowerOff {
    & powercfg.exe /setacvalueindex SCHEME_CURRENT $script:TTUsbSub $script:TTUsbSet 0 | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT $script:TTUsbSub $script:TTUsbSet 0 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    $global:LASTEXITCODE = 0
    Write-Info 'USB selective suspend: off (plugged in and on battery)'
    $n = 0
    foreach ($h in @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -match '^USB\\' -and $_.Enable })) {
        try { Set-CimInstance -InputObject $h -Property @{ Enable = $false } -ErrorAction Stop; $n++ } catch { Write-Warn ('Could not change ' + $h.InstanceName + ': ' + $_.Exception.Message) }
    }
    Write-Info ('USB devices that Windows may no longer switch off: ' + $n)
}

function Get-TTSensors {
    # USB devices whose name or maker matches the sensor pattern.
    param([string]$Pattern)
    if (-not $Pattern) { $Pattern = 'sensor|Schick|DEXIS|RVG|XIOS|Gendex|Suni|EzSensor|Planmeca|Sirona' }
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB' -and (([string]$_.FriendlyName -match $Pattern) -or ([string]$_.Manufacturer -match $Pattern)) })
}

function Resolve-TTText {
    param([string]$Text, [string]$Server, [string]$Share)
    $s = $Server; if (-not $s) { $s = '<server>' }
    return $Text.Replace('<server>', $s).Replace('<share>', $Share)
}
