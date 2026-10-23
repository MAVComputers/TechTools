# Shared helpers for Windows > Updates and Repair (loaded before every Windows tool).
# Keep this file ASCII-only.

function Set-TTReg {
    # Creates the key if needed and writes one value (DWord by default).
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -Path $Path -Force) }
    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force)
    Write-Info ('Set ' + $Path + '\' + $Name + ' = ' + $Value)
}

function Remove-TTReg {
    param([string]$Path, [string[]]$Name)
    foreach ($n in $Name) {
        if (Test-Path -LiteralPath $Path) {
            if ($null -ne (Get-ItemProperty -LiteralPath $Path -Name $n -ErrorAction SilentlyContinue)) {
                Remove-ItemProperty -LiteralPath $Path -Name $n -Force -ErrorAction SilentlyContinue
                Write-Info ('Removed ' + $Path + '\' + $n)
            }
        }
    }
}

# ---- Windows Update through the built-in Windows Update Agent (no extra modules)
function Find-TTUpdates {
    # Kind: 'Software' (quality, security, feature-on-demand) or 'Driver'.
    param([string]$Kind = 'Software')
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'MAV TechTools'
    $searcher = $session.CreateUpdateSearcher()
    $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='" + $Kind + "'")
    $list = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $res.Updates) {
        if ($u.InstallationBehavior.CanRequestUserInput) { Write-Info ('Skipped (needs someone at the PC): ' + $u.Title); continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$list.Add($u)
        Write-Info ('Found: ' + $u.Title)
    }
    if ($list.Count -eq 0) { Write-Info 'Nothing to install. Windows Update has no pending updates of this kind.' }
    return [pscustomobject]@{ Session = $session; List = $list }
}

function Save-TTUpdates {
    param($Found)
    if ($Found.List.Count -eq 0) { return }
    $dl = $Found.Session.CreateUpdateDownloader()
    $dl.Updates = $Found.List
    $r = $dl.Download()
    if ($r.ResultCode -gt 3) { throw ('Download failed (result code ' + $r.ResultCode + ')') }
    Write-Info ('Downloaded ' + $Found.List.Count + ' update(s)')
}

function Install-TTUpdates {
    param($Found)
    if ($Found.List.Count -eq 0) { return }
    $inst = $Found.Session.CreateUpdateInstaller()
    $inst.Updates = $Found.List
    $r = $inst.Install()
    $ok = 0
    for ($i = 0; $i -lt $Found.List.Count; $i++) {
        $code = $r.GetUpdateResult($i).ResultCode
        $title = $Found.List.Item($i).Title
        if ($code -eq 2 -or $code -eq 3) { $ok++; Write-Info ('Installed: ' + $title) } else { Write-Warn ('Not installed (result ' + $code + '): ' + $title) }
    }
    Write-Info ('Installed {0} of {1}' -f $ok, $Found.List.Count)
    if ($r.RebootRequired) { Write-Warn 'Restart the PC to finish installing updates' }
}
