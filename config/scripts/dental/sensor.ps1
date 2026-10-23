# X-ray sensor check: USB device, driver, USB power saving (read-only). Keep this file ASCII-only.
$in = Get-TTInput
$rows = New-Object System.Collections.ArrayList
function Add-TTRow { param($Name, $Level, $Detail, $Fix = '')
    [void]$rows.Add([pscustomobject]@{ Name = $Name; Level = $Level; Detail = $Detail; Fix = $Fix })
    if ($Level -eq 'ok') { Write-Info ($Name + ': ' + $Detail) } else { Write-Warn ($Name + ': ' + $Detail) } }
Write-Step 'Looking for X-ray sensors on USB'
$sens = Get-TTSensors ([string]$in.Pattern)
if ($sens.Count) {
    Add-TTRow 'USB device' 'ok' (($sens | ForEach-Object { $_.FriendlyName }) -join ', ')
    Write-Step 'Checking the driver'
    $bad = @($sens | Where-Object { $_.Status -ne 'OK' })
    if ($bad.Count) { Add-TTRow 'Driver' 'fail' ($bad[0].FriendlyName + ': ' + $bad[0].Status + '. Use Reset the sensor on the program page.') }
    else { Add-TTRow 'Driver' 'ok' 'Loaded, no errors in Device Manager' }
} else { Add-TTRow 'USB device' 'warn' 'No X-ray sensor found. Plug it in, then check again.' }
Write-Step 'Reading USB power settings'
$u = Get-TTUsbPower
if ($null -eq $u.SuspendOn) { Add-TTRow 'USB selective suspend' 'ok' 'Not used by this power plan' }
elseif ($u.SuspendOn) { Add-TTRow 'USB selective suspend' 'warn' 'On. The sensor can drop out mid-exam.' 'usb' }
else { Add-TTRow 'USB selective suspend' 'ok' 'Off' }
if ($u.HubsCanSleep -gt 0) { Add-TTRow 'USB hub power saving' 'warn' ('Windows can switch off ' + $u.HubsCanSleep + ' USB device(s) to save power') 'usb' }
else { Add-TTRow 'USB hub power saving' 'ok' 'Off' }
if ($in.Software) { Add-TTRow 'Imaging software' 'ok' ([string]$in.Software) } else { Add-TTRow 'Imaging software' 'warn' 'No imaging software found on this PC' }
Set-Result ([pscustomobject]@{ At = (Get-Date); Rows = @($rows) })
