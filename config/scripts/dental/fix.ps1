# Runs one fix for a dental program. Keep this file ASCII-only.
$in = Get-TTInput
$p = $in.Program
$f = $in.Fix
$server = [string]$in.Server
$share = [string]$in.Share
$unc = ''
if ($server -and $share) { $unc = '\\' + $server + '\' + $share }
function Assert-TTServer { if (-not $server) { throw 'Enter the server name on this page first.' } }
function Assert-TTShare { if (-not $unc) { throw 'Enter the server and share name on this page first.' } }

switch ([string]$f.type) {
    'porttest' {
        Assert-TTServer
        $port = [int](Get-TTProgProp $f 'port' 445)
        Write-Step ('Testing ' + $server + ' on port ' + $port)
        try { $ip = @([System.Net.Dns]::GetHostAddresses($server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0]; if ($ip) { Write-Info ($server + ' is ' + $ip) } } catch { throw ('The name ' + $server + ' does not resolve. Check the server name or use its IP address.') }
        if (-not (Test-TTTcp $server $port)) { throw ($server + ' does not answer on port ' + $port + '. Check the server is on and its firewall allows this port.') }
        Write-Info ($server + ' answers on port ' + $port)
    }
    'sharetest' {
        Assert-TTShare
        Write-Step ('Opening ' + $unc)
        switch (Test-TTShareWrite $unc) {
            'ok' { Write-Info ($unc + ' opens and the write test worked') }
            'readonly' { Write-Warn ($unc + ' opens, but this account cannot write to it. Check the share and folder permissions on the server.') }
            default { throw ('Cannot open ' + $unc + '. Check the share name, or use Windows > Diagnostics > Re-authenticate if the login was rejected.') }
        }
    }
    'odconfig' {
        Assert-TTServer
        $path = Join-Path ([string]$p.folder) 'FreeDentalConfig.xml'
        Write-Step 'Backing up FreeDentalConfig.xml'
        if (-not (Test-Path -LiteralPath $path)) { throw ('Not found: ' + $path + '. Install Open Dental first.') }
        $bak = $path + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
        Copy-Item -LiteralPath $path -Destination $bak
        Write-Info ('Backup: ' + $bak)
        Write-Step ('Setting the server to ' + $server)
        [xml]$x = [System.IO.File]::ReadAllText($path)
        $node = $x.SelectSingleNode('//DatabaseConnection/ComputerName')
        if (-not $node) { throw 'FreeDentalConfig.xml has no DatabaseConnection/ComputerName entry. Set the server in Open Dental instead.' }
        Write-Info ('Was: ' + $node.InnerText)
        $node.InnerText = $server
        $x.Save($path)
        Write-Info ('Now: ' + $server)
    }
    'perm' {
        $path = [string](Get-TTProgProp $p 'perm' '')
        Write-Step ('Letting users write to ' + $path)
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw ('Folder not found: ' + $path) }
        & icacls.exe $path /grant '*S-1-5-32-545:(OI)(CI)M' /C /Q
        Assert-TTExit 'icacls'
        Write-Info 'Users can now modify the folder and everything in it'
    }
    'firewall' {
        $dir = [string]$p.folder
        Write-Step ('Adding firewall rules for ' + $p.name)
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { throw ('Client folder not found: ' + $dir) }
        $exes = @(Get-ChildItem -LiteralPath $dir -Filter *.exe -File -ErrorAction SilentlyContinue)
        if (-not $exes.Count) { throw ('No programs found in ' + $dir) }
        $added = 0
        foreach ($e in $exes) {
            $name = 'MAV TechTools - ' + $p.name + ' - ' + $e.Name
            if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) { continue }
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Program $e.FullName -Action Allow -Profile Domain, Private | Out-Null
            $added++
        }
        Write-Info ('Rules added: ' + $added + ' (already there: ' + ($exes.Count - $added) + ')')
    }
    'setup' {
        Assert-TTShare
        Write-Step ('Looking for the workstation setup on ' + $unc)
        if (-not (Test-Path -LiteralPath $unc)) { throw ('Cannot open ' + $unc) }
        $found = @(Get-ChildItem -LiteralPath $unc -Filter *.exe -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'setup|install|workstation|client' } | Select-Object -First 5)
        if ($found.Count -eq 1) {
            Write-Info ('Starting ' + $found[0].FullName)
            Start-Process -FilePath $found[0].FullName -WorkingDirectory $found[0].DirectoryName
            Write-Info 'Finish the setup on screen.'
        } else {
            if ($found.Count) { foreach ($x in $found) { Write-Info ('Possible setup: ' + $x.FullName) } } else { Write-Info 'No setup file found in the top folders.' }
            Start-Process -FilePath 'explorer.exe' -ArgumentList $unc
            Write-Warn ('Opened ' + $unc + ' so you can pick the setup.')
        }
    }
    'services' {
        $names = @(Get-TTProgProp $p 'services' @())
        Write-Step ('Restarting ' + $p.name + ' services')
        if (-not $names.Count) { throw ('No services are listed for ' + $p.name + ' yet.') }
        $svcs = @(foreach ($n in $names) { Get-Service -Name $n -ErrorAction SilentlyContinue })
        if (-not $svcs.Count) { throw ('No ' + $p.name + ' services found on this PC.') }
        foreach ($s in $svcs) { Restart-Service -InputObject $s -Force; Write-Info ('Restarted ' + $s.DisplayName) }
    }
    'usbpower' {
        Write-Step 'Turning off USB power saving'
        Set-TTUsbPowerOff
    }
    'sensorreset' {
        Write-Step 'Looking for the sensor'
        $sens = Get-TTSensors ([string](Get-TTProgProp $p 'sensorMatch' ''))
        if (-not $sens.Count) { throw 'No sensor found on USB. Plug it in and try again.' }
        foreach ($d in $sens) {
            Write-Step ('Resetting ' + $d.FriendlyName)
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
            Start-Sleep -Seconds 2
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
        }
        & pnputil.exe /scan-devices | Out-Null
        $global:LASTEXITCODE = 0
        Start-Sleep -Seconds 2
        foreach ($d in (Get-TTSensors ([string](Get-TTProgProp $p 'sensorMatch' '')))) { Write-Info ($d.FriendlyName + ': ' + $d.Status) }
    }
    'openurl' {
        $url = [string]$in.Url
        Write-Step 'Opening the login page'
        if (-not $url) { throw 'Enter the login address on this page first.' }
        Start-Process $url
        Write-Info ('Opened ' + $url)
    }
    'shortcut' {
        $url = [string]$in.Url
        Write-Step 'Creating the desktop shortcut'
        if (-not $url) { throw 'Enter the login address on this page first.' }
        $desk = Join-Path $env:PUBLIC 'Desktop'
        $file = Join-Path $desk ([string]$p.name + '.url')
        [System.IO.File]::WriteAllText($file, "[InternetShortcut]`r`nURL=" + $url + "`r`n")
        Write-Info ('Created ' + $file)
    }
    default { throw ('Unknown fix type: ' + $f.type) }
}
