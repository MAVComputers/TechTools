# Office server connection check and re-authentication (Windows > Diagnostics).
# The server path is saved per PC in C:\ProgramData\MAVTechTools\server.json,
# never in this repo. Passwords are only held in memory and in Windows
# Credential Manager. Keep this file ASCII-only.

function Get-TTServerConfigPath { return (Join-Path $env:ProgramData 'MAVTechTools\server.json') }

function Get-TTServerConfig {
    $p = Get-TTServerConfigPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $c = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { return $null }
    if (-not $c.Unc) { return $null }
    return $c
}

function Split-TTUnc {
    # '\\OFFICE-SRV\Data\Sub' -> Server OFFICE-SRV, Share Data, Root \\OFFICE-SRV\Data
    param([string]$Path)
    $p = ([string]$Path).Trim().TrimEnd('\')
    if ($p -notmatch '^\\\\([^\\/:*?"<>|]+)\\([^\\/:*?"<>|]+)') { return $null }
    [pscustomobject]@{ Server = $Matches[1]; Share = $Matches[2]; Root = ('\\' + $Matches[1] + '\' + $Matches[2]); Path = $p }
}

function Test-TTPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 2500)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

function Get-TTConsoleUser {
    # The person signed in at the PC (may differ from the account TechTools runs as).
    $u = [string](Get-CimInstance Win32_ComputerSystem).UserName
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    [pscustomobject]@{ Console = $u; Me = $me; Same = (-not $u) -or ($u -eq $me) }
}

function Get-TTSavedLogin {
    # Returns the user name saved in Credential Manager for this server, or ''.
    param([string]$Server)
    $out = @(& cmdkey.exe "/list:$Server" 2>&1 | ForEach-Object { [string]$_ })
    $global:LASTEXITCODE = 0
    foreach ($l in $out) { if ($l -match '^\s*User:\s*(.+)$') { return $Matches[1].Trim() } }
    return ''
}

function Get-TTUserDrives {
    # Persistent mapped drives of the signed-in user (from their registry hive).
    param([string]$Server)
    $root = 'HKCU:\Network'
    $who = Get-TTConsoleUser
    if (-not $who.Same -and $who.Console) {
        try {
            $sid = (New-Object Security.Principal.NTAccount($who.Console)).Translate([Security.Principal.SecurityIdentifier]).Value
            $root = 'Registry::HKEY_USERS\' + $sid + '\Network'
        } catch { }
    }
    if (-not (Test-Path $root)) { return @() }
    $list = foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p.RemotePath) { continue }
        $u = Split-TTUnc $p.RemotePath
        if ($Server -and (-not $u -or $u.Server -ne $Server)) { continue }
        [pscustomobject]@{ Letter = ($k.PSChildName.ToUpper() + ':'); Path = [string]$p.RemotePath; User = [string]$p.UserName }
    }
    return @($list)
}

function Get-TTShareProblem {
    # Turns a Windows file-sharing error into a plain reason.
    param([string]$Message)
    $m = [string]$Message
    if ($m -match 'password|logon failure|access is denied|unknown user name|credentials|not have permission|account') { return 'auth' }
    if ($m -match 'network name cannot be found|bad network name') { return 'share' }
    if ($m -match 'network path was not found|cannot find the path|not reachable|no longer available') { return 'reach' }
    return 'other'
}

function Test-TTShareAccess {
    param([string]$Path)
    try {
        $null = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{ Ok = $true; Kind = ''; Message = '' }
    } catch {
        $msg = $_.Exception.Message
        return [pscustomobject]@{ Ok = $false; Kind = (Get-TTShareProblem $msg); Message = $msg }
    }
}

function Get-TTServerStatus {
    $cfg = Get-TTServerConfig
    if (-not $cfg) { return [pscustomobject]@{ Configured = $false } }
    $u = Split-TTUnc $cfg.Unc
    $checks = New-Object System.Collections.ArrayList
    $add = { param($n, $lv, $d) [void]$checks.Add([pscustomobject]@{ Name = $n; Level = $lv; Detail = $d }) }
    $needsAuth = $false
    $needsTrust = $false
    $headline = ''

    # 1. Name lookup
    $isIp = $u.Server -match '^\d{1,3}(\.\d{1,3}){3}$'
    $resolved = $true
    if (-not $isIp) {
        try {
            $ips = @([System.Net.Dns]::GetHostAddresses($u.Server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
            & $add 'Server name' 'ok' ('{0} is {1}' -f $u.Server, ($ips -join ', '))
        } catch {
            $resolved = $false
            & $add 'Server name' 'fail' ('{0} could not be found. Check the name, or that this PC is on the office network.' -f $u.Server)
            $headline = 'Cannot find the server by name'
        }
    }

    # 2. File sharing port
    $reach = $false
    if ($resolved) {
        $reach = Test-TTPort $u.Server 445
        if ($reach) { & $add 'File sharing' 'ok' 'Server answers on file sharing (port 445)' }
        else {
            & $add 'File sharing' 'fail' 'Server does not answer on file sharing (port 445): it may be off, asleep, or blocked by a firewall.'
            if (-not $headline) { $headline = 'Server is not reachable' }
        }
    }

    # 3. Saved login
    $saved = Get-TTSavedLogin $u.Server
    $who = Get-TTConsoleUser
    if ($saved) { & $add 'Saved login' 'ok' ('Credential Manager has a login for {0}: {1}' -f $u.Server, $saved) }
    else { & $add 'Saved login' 'warn' ('No saved login for {0}. Windows will try the signed-in account.' -f $u.Server) }
    if (-not $who.Same) { & $add 'Signed-in user' 'warn' ('TechTools runs as {0} but {1} is signed in. Saved logins and drives belong to {1}; Re-authenticate saves them for {1}.' -f $who.Me, $who.Console) }

    # 4. Share access
    if ($reach) {
        $t = Test-TTShareAccess $u.Path
        if ($t.Ok) { & $add 'Share access' 'ok' ('Opened {0}' -f $u.Path) }
        else {
            switch ($t.Kind) {
                'auth' { $needsAuth = $true; & $add 'Share access' 'fail' ('The server rejected the login: ' + $t.Message.Trim()); if (-not $headline) { $headline = 'Login problem: the server rejected the saved login' } }
                'share' { & $add 'Share access' 'fail' ('The share "{0}" does not exist on {1}. Check the path.' -f $u.Share, $u.Server); if (-not $headline) { $headline = 'Share not found on the server' } }
                default { & $add 'Share access' 'fail' $t.Message.Trim(); if (-not $headline) { $headline = 'Could not open the share' } }
            }
        }
    }

    # 5. Mapped drives of the signed-in user
    $drives = @(Get-TTUserDrives $u.Server)
    if ($drives.Count) {
        foreach ($d in $drives) {
            $lv = 'ok'; $txt = ('{0} -> {1}' -f $d.Letter, $d.Path)
            if ($reach -and -not (Test-TTShareAccess $d.Path).Ok) { $lv = 'fail'; $txt += ' (cannot open)'; $needsAuth = $true }
            & $add ('Drive ' + $d.Letter) $lv $txt
        }
    } elseif ($cfg.Drive) {
        & $add 'Mapped drive' 'warn' ('{0} is not mapped to {1} for the signed-in user. Re-authenticate maps it.' -f $cfg.Drive, $u.Path)
    }

    # 6. Domain trust (domain-joined PCs only)
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        $ok = $false
        try { $ok = Test-ComputerSecureChannel -ErrorAction Stop } catch { $ok = $false }
        if ($ok) { & $add 'Domain trust' 'ok' ('Trust with {0} is working' -f $cs.Domain) }
        else {
            $needsTrust = $true
            & $add 'Domain trust' 'fail' ('The trust between this PC and {0} is broken (users see "trust relationship failed"). Use Repair domain trust.' -f $cs.Domain)
            if (-not $headline) { $headline = 'Domain trust is broken' }
        }
    }

    $fails = @($checks | Where-Object { $_.Level -eq 'fail' }).Count
    $warns = @($checks | Where-Object { $_.Level -eq 'warn' }).Count
    $level = 'ok'
    if ($fails) { $level = 'fail' } elseif ($warns) { $level = 'warn' }
    if (-not $headline) {
        $as = if ($saved) { ' as ' + $saved } else { '' }
        $headline = 'Connected to {0}{1}' -f $u.Server, $as
    }
    [pscustomobject]@{
        Configured = $true; Unc = $u.Path; Server = $u.Server; Share = $u.Share; Drive = [string]$cfg.Drive
        Level = $level; Headline = $headline; Checks = @($checks); NeedsAuth = $needsAuth; NeedsTrust = $needsTrust
        SavedUser = $saved; ConsoleUser = $who.Console; SameUser = $who.Same; Drives = $drives; At = (Get-Date)
    }
}

# ---------------------------------------------------------------- Fixing
$script:TTCredSource = @'
using System;
using System.Runtime.InteropServices;
public static class TTCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL c, int flags);
    // Same kind of entry as "cmdkey /add": a Windows (domain password) credential, kept across restarts.
    public static void Save(string target, string user, string password) {
        CREDENTIAL c = new CREDENTIAL();
        c.Type = 2; c.Persist = 2; c.TargetName = target; c.UserName = user;
        byte[] b = System.Text.Encoding.Unicode.GetBytes(password);
        c.CredentialBlobSize = b.Length;
        c.CredentialBlob = Marshal.AllocHGlobal(b.Length);
        try {
            Marshal.Copy(b, 0, c.CredentialBlob, b.Length);
            if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(c.CredentialBlob); }
    }
}
'@

function Save-TTCredential {
    param([string]$Target, [string]$User, [string]$Password)
    if (-not ('TTCred' -as [type])) { Add-Type -TypeDefinition $script:TTCredSource -Language CSharp }
    [TTCred]::Save($Target, $User, $Password)
}

function Invoke-TTAsUser {
    # Runs a PowerShell script as the signed-in user (not elevated), so saved logins
    # and mapped drives land in their session. Returns what the script wrote.
    param([string]$User, [string]$ScriptText, [int]$TimeoutSec = 45)
    $dir = Join-Path $env:ProgramData 'MAVTechTools\Run'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $ps1 = Join-Path $dir ($id + '.ps1')
    $outFile = Join-Path $dir ($id + '.txt')
    $body = "`$ErrorActionPreference = 'Continue'`r`n`$log = New-Object System.Collections.ArrayList`r`n" + $ScriptText +
        "`r`n[System.IO.File]::WriteAllText('" + $outFile + "', (`$log -join [Environment]::NewLine))`r`n"
    [System.IO.File]::WriteAllText($ps1, $body)
    # Only the user, SYSTEM and Administrators can read it; it is deleted right after.
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($who in @($User, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, 'Modify', 'Allow')))
    }
    (Get-Item -LiteralPath $ps1).SetAccessControl($acl)
    # The user writes the result file into this folder.
    $dacl = Get-Acl -LiteralPath $dir
    $dacl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($User, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    (Get-Item -LiteralPath $dir).SetAccessControl($dacl)
    $task = 'MAVTechTools-' + $id
    $tr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ps1 + '"'
    try {
        $null = & schtasks.exe /Create /TN $task /TR $tr /SC ONCE /ST 23:59 /RU $User /IT /RL LIMITED /F 2>&1
        Assert-TTExit 'Creating the helper task'
        $null = & schtasks.exe /Run /TN $task 2>&1
        Assert-TTExit 'Starting the helper task'
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not (Test-Path -LiteralPath $outFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (-not (Test-Path -LiteralPath $outFile)) { throw ('The helper did not finish within {0} seconds. Is {1} signed in at the PC?' -f $TimeoutSec, $User) }
        Start-Sleep -Milliseconds 300
        return [System.IO.File]::ReadAllText($outFile)
    } finally {
        $null = & schtasks.exe /Delete /TN $task /F 2>&1
        $global:LASTEXITCODE = 0
        Remove-Item -LiteralPath $ps1, $outFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-TTPsString {
    # Embeds text in a generated script without quoting problems.
    param([string]$Text)
    return ("[System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)) + "'))")
}

function Get-TTRemapScript {
    # PowerShell (for the user's session) that reconnects each drive.
    param($Drives)
    $lines = foreach ($d in $Drives) {
        $l = $d.Letter; $p = $d.Path
        if ($l -notmatch '^[A-Za-z]:$') { continue }
        "net use $l /delete /y 2>&1 | Out-Null"
        "`$p = " + (ConvertTo-TTPsString $p)
        "`$r = net use $l `$p /persistent:yes 2>&1"
        "if (`$LASTEXITCODE -eq 0) { [void]`$log.Add('OK $l') } else { [void]`$log.Add('FAIL $l ' + ((`$r | Out-String).Trim())) }"
    }
    return ($lines -join "`r`n")
}

# ---- Set up server: find the shares on a server by name

function ConvertTo-TTServerName {
    # 'OFFICE-SRV', '\\OFFICE-SRV' or '\\OFFICE-SRV\Data' -> Server + Share (may be '').
    param([string]$Text)
    $t = ([string]$Text).Trim().Trim('"').TrimEnd('\')
    $t = $t -replace '^\\\\', '' -replace '/', '\'
    $parts = $t -split '\\'
    $server = $parts[0]
    if ($server -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-_]*$') { return $null }
    $share = ''
    if ($parts.Count -gt 1) { $share = $parts[1] }
    [pscustomobject]@{ Server = $server; Share = $share }
}

function ConvertFrom-TTNetView {
    # Parses 'net view \\server /all' into share names (disk shares only).
    param([string[]]$Lines)
    $shares = New-Object System.Collections.ArrayList
    $inTable = $false
    foreach ($l in $Lines) {
        if ($l -match '^-{10,}') { $inTable = $true; continue }
        if (-not $inTable -or -not $l.Trim()) { continue }
        if ($l -match '^(The command|Der Befehl|La commande|El comando)') { break }
        if ($l -match '^(.+?)\s+(Disk|Print|IPC|Datentr\S*|Drucker|Disque|Imprim\S*)(\s+(.*))?$' -or $l -match '^(.+?)\s{2,}(\S+)(\s+(.*))?$') {
            $name = $Matches[1].Trim(); $type = $Matches[2]; $rest = ([string]$Matches[4]).Trim()
            if ($type -match '^(Print|IPC|Drucker|Imprimer)') { continue }
            if ($name -match '\$$') { continue }
            $comment = ($rest -replace '^[A-Za-z]:(\s+|$)', '').Trim()
            [void]$shares.Add([pscustomobject]@{ Name = $name; Comment = $comment })
        }
    }
    return @($shares)
}

function Get-TTServerShares {
    # Returns @{ Kind = ok|auth|reach|other; Message; Shares }
    param([string]$Server)
    $out = @(& net.exe view ('\\' + $Server) /all 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    $text = ($out -join ' ')
    if ($code -eq 0) {
        $s = @(ConvertFrom-TTNetView $out)
        return [pscustomobject]@{ Kind = 'ok'; Message = ''; Shares = $s }
    }
    $kind = 'other'
    if ($text -match 'error (5|86|1326|1327|1330|1331|1907|2242)\b|access is denied|logon failure|password') { $kind = 'auth' }
    elseif ($text -match 'error (53|67|1231|1232|64)\b|network path was not found|network name') { $kind = 'reach' }
    return [pscustomobject]@{ Kind = $kind; Message = (($out | Where-Object { $_.Trim() }) -join ' ').Trim(); Shares = @() }
}

function Save-TTServerLogin {
    # Saves a tested login in Credential Manager for the person signed in at the PC.
    param([string]$Server, [string]$User, [string]$Password)
    $who = Get-TTConsoleUser
    if ($who.Same) {
        Save-TTCredential -Target $Server -User $User -Password $Password
        Write-Info ('Saved in Credential Manager for ' + $Server)
    } else {
        $text = "Add-Type -TypeDefinition " + (ConvertTo-TTPsString $script:TTCredSource) + " -Language CSharp`r`n" +
            "[TTCred]::Save(" + (ConvertTo-TTPsString $Server) + ", " + (ConvertTo-TTPsString $User) + ", " + (ConvertTo-TTPsString $Password) + ")`r`n" +
            "[void]`$log.Add('SAVED')`r`n"
        $out = Invoke-TTAsUser -User $who.Console -ScriptText $text
        if ($out -notmatch 'SAVED') { throw ('Could not save the login for ' + $who.Console + '.') }
        Write-Info ('Saved in Credential Manager for ' + $who.Console)
    }
}
