# Re-authenticate to the office server (Windows > Diagnostics).
# Input from the window: Mode ('login' or 'trust') and Credential.
# Order matters: the new login is tested first, and nothing is saved unless the
# server accepts it. Keep this file ASCII-only.

$in = Get-TTInput
if (-not $in -or -not $in.Credential) { throw 'No login was entered.' }
$cfg = Get-TTServerConfig
if (-not $cfg) { throw 'Set up the office server first.' }
$u = Split-TTUnc $cfg.Unc
$cred = $in.Credential
$user = $cred.UserName
$plain = $cred.GetNetworkCredential().Password

if ($in.Mode -eq 'trust') {
    Write-Step 'Repairing the trust between this PC and the domain'
    $ok = Test-ComputerSecureChannel -Repair -Credential $cred
    if (-not $ok) { throw 'The domain did not accept the repair. Check the account has rights to reset computer accounts.' }
    Write-Info 'Domain trust repaired. The user may need to sign out and back in.'
} else {
    Write-Step ('Testing the new login on ' + $u.Root)
    # Drop old connections so Windows does not reuse the old login.
    $null = & net.exe use $u.Root /delete /y 2>&1
    $null = & net.exe use ('\\' + $u.Server + '\IPC$') /delete /y 2>&1
    $global:LASTEXITCODE = 0
    # Only this (admin) session's connections; the user's saved drives are left alone.
    Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.RemotePath -like ('\\' + $u.Server + '\*') } |
        Remove-SmbMapping -Force -ErrorAction SilentlyContinue
    try {
        $null = New-SmbMapping -RemotePath $u.Root -UserName $user -Password $plain -Persistent $false -ErrorAction Stop
    } catch {
        $kind = Get-TTShareProblem $_.Exception.Message
        if ($kind -eq 'auth') { throw ('The server rejected that username or password. Nothing was saved. (' + $_.Exception.Message.Trim() + ')') }
        throw ('Could not connect with the new login: ' + $_.Exception.Message.Trim())
    }
    Remove-SmbMapping -RemotePath $u.Root -Force -ErrorAction SilentlyContinue
    Write-Info ('The server accepted ' + $user)

    $who = Get-TTConsoleUser
    $drives = @(Get-TTUserDrives $u.Server)
    if ($drives.Count -eq 0 -and $cfg.Drive -match '^[A-Za-z]:$') { $drives = @([pscustomobject]@{ Letter = $cfg.Drive.ToUpper(); Path = $u.Path; User = '' }) }

    if ($who.Same) {
        Write-Step 'Saving the login in Credential Manager'
        Save-TTCredential -Target $u.Server -User $user -Password $plain
        Write-Info ('Saved in Credential Manager for ' + $u.Server)
        Write-Step 'Reconnecting mapped drives'
        if ($drives.Count) {
            $console = if ($who.Console) { $who.Console } else { $who.Me }
            $out = Invoke-TTAsUser -User $console -ScriptText (Get-TTRemapScript $drives)
            foreach ($l in ($out -split "`r?`n")) { if ($l -like 'OK *') { Write-Info ('Drive ' + $l.Substring(3) + ' reconnected') } elseif ($l) { Write-Warn $l } }
        } else { Write-Info 'No mapped drives to reconnect' }
    } else {
        # TechTools runs as a different (admin) account: save the login in the
        # signed-in user's own Credential Manager by running as them.
        Write-Step ('Saving the login for ' + $who.Console)
        $text = "Add-Type -TypeDefinition " + (ConvertTo-TTPsString $script:TTCredSource) + " -Language CSharp`r`n" +
            "[TTCred]::Save(" + (ConvertTo-TTPsString $u.Server) + ", " + (ConvertTo-TTPsString $user) + ", " + (ConvertTo-TTPsString $plain) + ")`r`n" +
            "[void]`$log.Add('SAVED')`r`n"
        Write-Step 'Reconnecting mapped drives'
        $text += Get-TTRemapScript $drives
        $out = Invoke-TTAsUser -User $who.Console -ScriptText $text
        if ($out -notmatch 'SAVED') { throw ('Could not save the login for ' + $who.Console + '.') }
        Write-Info ('Saved in Credential Manager for ' + $who.Console)
        foreach ($l in ($out -split "`r?`n")) { if ($l -like 'OK *') { Write-Info ('Drive ' + $l.Substring(3) + ' reconnected') } elseif ($l -like 'FAIL*') { Write-Warn $l } }
    }
}
$plain = $null

Write-Step 'Checking the connection again'
$st = Get-TTServerStatus
if ($st.Level -eq 'fail') { Write-Warn ('Still a problem: ' + $st.Headline) } else { Write-Info $st.Headline }
Set-Result $st
