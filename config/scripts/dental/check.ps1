# Checks one dental program on this PC (read-only). Keep this file ASCII-only.
$in = Get-TTInput
$p = $in.Program
$server = [string]$in.Server
$share = [string]$in.Share
$kind = [string]$p.kind
$checks = New-Object System.Collections.ArrayList
function Add-TTCheck { param($Name, $Level, $Value, $Detail, $Fix = '')
    [void]$checks.Add([pscustomobject]@{ Name = $Name; Level = $Level; Value = $Value; Detail = $Detail; Fix = $Fix })
    $line = $Name + ': ' + $Value + $(if ($Detail) { ' (' + $Detail + ')' } else { '' })
    if ($Level -eq 'ok' -or $Level -eq 'info') { Write-Info $line } else { Write-Warn $line } }
$fixIds = @(@($p.fixes) | ForEach-Object { [string]$_.id })

Write-Step 'Checking the install'
$ver = Find-TTProgram $p (Get-TTInstalledApps)
if ($kind -eq 'cloud') { }
elseif ($ver) { Add-TTCheck 'Installed' 'ok' $ver 'On this PC' }
else { Add-TTCheck 'Installed' 'fail' 'Not on this PC' ('No ' + $p.name + ' found') $(if ($fixIds -contains 'setup') { 'setup' } else { '' }) }

if ($kind -eq 'cloud' -or $kind -eq 'imgcloud') {
    Write-Step 'Checking the login address'
    $url = [string]$in.Url
    if (-not $url) { Add-TTCheck 'Login address' 'warn' 'Not set' 'Enter it above' }
    else {
        try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Head -TimeoutSec 15 -MaximumRedirection 5; Add-TTCheck 'Login address' 'ok' 'Opens' $url }
        catch { $code = ''; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code) { Add-TTCheck 'Login address' 'ok' 'Answers' ($url + ' (HTTP ' + $code + ')') } else { Add-TTCheck 'Login address' 'fail' 'Does not answer' $url } }
    }
} else {
    Write-Step 'Checking the server'
    $port = [int](Get-TTProgProp $p 'port' 445)
    if (-not $server) { Add-TTCheck 'Server' 'warn' 'No server set' 'Enter the server name above' }
    elseif (Test-TTTcp $server $port) { Add-TTCheck 'Server' 'ok' ($server + ' answers') ('Port ' + $port) }
    else { Add-TTCheck 'Server' 'fail' ($server + ' does not answer') ('Port ' + $port) $(if ($fixIds -contains 'test') { 'test' } else { '' }) }

    Write-Step 'Checking the data share'
    if ($server -and $share) {
        $unc = '\\' + $server + '\' + $share
        switch (Test-TTShareWrite $unc) {
            'ok' { Add-TTCheck 'Data share' 'ok' $unc 'Opens, write test OK' }
            'readonly' { Add-TTCheck 'Data share' 'warn' $unc 'Opens, but this account cannot write to it' }
            default { Add-TTCheck 'Data share' 'fail' $unc 'Cannot open the share' }
        }
    } else { Add-TTCheck 'Data share' 'info' 'Not tested' 'Needs the server and share name' }
}

$perm = [string](Get-TTProgProp $p 'perm' '')
if ($perm -and $ver -and (Test-Path -LiteralPath $perm)) {
    Write-Step 'Checking folder permissions'
    $w = Test-TTUsersCanWrite $perm
    if ($w) { Add-TTCheck 'Folder permissions' 'ok' 'Users can write' $perm }
    elseif ($null -ne $w) { Add-TTCheck 'Folder permissions' 'warn' 'Users cannot write' ($perm + '. Non-admin users may get "access denied".') 'perm' }
}

if ((Get-TTProgProp $p 'odconfig' $false) -and $ver) {
    Write-Step 'Reading FreeDentalConfig.xml'
    $cfgPath = Join-Path ([string]$p.folder) 'FreeDentalConfig.xml'
    $cur = ''
    try { [xml]$x = [System.IO.File]::ReadAllText($cfgPath); $cur = [string]$x.SelectSingleNode('//DatabaseConnection/ComputerName').InnerText } catch { }
    if (-not $cur) { Add-TTCheck 'Client config' 'warn' 'Not readable' $cfgPath 'point' }
    elseif ($server -and $cur -ne $server) { Add-TTCheck 'Client config' 'warn' ('Points at ' + $cur) ('Not ' + $server) 'point' }
    else { Add-TTCheck 'Client config' 'ok' ('Points at ' + $cur) 'FreeDentalConfig.xml' }
}

if ($kind -eq 'img' -or $kind -eq 'imgcloud') {
    Write-Step 'Looking for the sensor and USB power settings'
    $sens = Get-TTSensors ([string](Get-TTProgProp $p 'sensorMatch' ''))
    if ($sens.Count -eq 0) { Add-TTCheck 'Sensor' 'warn' 'Not found on USB' 'Plug the sensor in, then check again' }
    else {
        $bad = @($sens | Where-Object { $_.Status -ne 'OK' })
        if ($bad.Count) { Add-TTCheck 'Sensor' 'fail' $bad[0].FriendlyName ('Driver problem: ' + $bad[0].Status) 'sensor' }
        else { Add-TTCheck 'Sensor' 'ok' $sens[0].FriendlyName 'On USB, driver OK' }
    }
    $u = Get-TTUsbPower
    if ($u.SuspendOn -or $u.HubsCanSleep -gt 0) { Add-TTCheck 'USB power saving' 'warn' 'On' 'The sensor can drop out mid-exam' 'usb' }
    else { Add-TTCheck 'USB power saving' 'ok' 'Off' 'Sensor keeps power' }
}
Set-Result ([pscustomobject]@{ Id = [string]$p.id; At = (Get-Date); Version = $ver; Checks = @($checks) })
