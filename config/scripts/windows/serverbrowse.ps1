# Set up server (Windows > Diagnostics): the tech enters only the server name.
# Checks it answers, checks this PC is logged in (or tests the login the tech
# typed and saves it), then lists the shares to pick from.
# Input: Server (name, IP or \\name\share) and optional Credential. Keep this file ASCII-only.

$in = Get-TTInput
$n = ConvertTo-TTServerName ([string]$in.Server)
if (-not $n) { throw ('"' + [string]$in.Server + '" is not a server name. Enter a name like OFFICE-SRV or an IP like 192.168.1.10.') }
$server = $n.Server
$res = [pscustomobject]@{ Server = $server; Want = $n.Share; Kind = ''; Message = ''; Shares = @(); User = '' }

Write-Step ('Checking that ' + $server + ' answers on file sharing (port 445)')
if (-not (Test-TTPort $server 445)) {
    $res.Kind = 'reach'
    $res.Message = $server + ' did not answer on file sharing (port 445). Check the name, that the server is on, and the network or firewall.'
    Write-Warn $res.Message
    Set-Result $res
    return
}
Write-Info ($server + ' answers')

Write-Step 'Checking the login'
$cred = $in.Credential
if ($cred) {
    $user = $cred.UserName
    $plain = $cred.GetNetworkCredential().Password
    $ipc = '\\' + $server + '\IPC$'
    Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.RemotePath -like ('\\' + $server + '\*') } | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
    $null = & net.exe use $ipc /delete /y 2>&1
    $global:LASTEXITCODE = 0
    try {
        $null = New-SmbMapping -RemotePath $ipc -UserName $user -Password $plain -Persistent $false -ErrorAction Stop
    } catch {
        $plain = $null
        if ((Get-TTShareProblem $_.Exception.Message) -eq 'auth') {
            $res.Kind = 'auth'
            $res.Message = 'The server rejected that username or password. Nothing was saved.'
            Write-Warn $res.Message
            Set-Result $res
            return
        }
        throw ('Could not log in to ' + $server + ': ' + $_.Exception.Message.Trim())
    }
    Write-Info ('The server accepted ' + $user)
    Save-TTServerLogin -Server $server -User $user -Password $plain
    $plain = $null
    $res.User = $user
} else {
    $saved = Get-TTSavedLogin $server
    if ($saved) { Write-Info ('Saved login for ' + $server + ': ' + $saved) } else { Write-Info 'No saved login for this server; trying the current Windows login' }
}

Write-Step ('Listing the shares on ' + $server)
$list = Get-TTServerShares $server
if ($cred) { Remove-SmbMapping -RemotePath ('\\' + $server + '\IPC$') -Force -ErrorAction SilentlyContinue }
$res.Kind = $list.Kind
$res.Shares = @($list.Shares)
if ($list.Kind -eq 'ok') {
    Write-Info ('{0} share(s): {1}' -f $res.Shares.Count, (($res.Shares | ForEach-Object { $_.Name }) -join ', '))
} elseif ($list.Kind -eq 'auth') {
    $res.Message = 'This PC is not logged in to ' + $server + '. Enter a login for it.'
    Write-Warn $res.Message
} else {
    $res.Message = 'Could not list the shares: ' + $list.Message
    Write-Warn $res.Message
}
Set-Result $res
