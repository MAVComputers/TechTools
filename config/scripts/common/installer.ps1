# Download a vendor installer and start it. Used by install buttons.
# Files go to a folder only administrators can write to, so a standard user
# cannot swap the installer before TechTools (running as admin) starts it.
# Keep this file ASCII-only.

function Get-TTDownloadFolder {
    $dir = Join-Path $env:ProgramData 'MAVTechTools\Downloads'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Administrators and SYSTEM only (no inherited Users: write access).
    $null = & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' 2>&1
    return $dir
}

function Save-TTDownload {
    # Streams $Url to $Name in the download folder, with progress. Returns the full path.
    param([string]$Url, [string]$Name)
    if ($Url -notmatch '^https://') { throw 'Downloads must use https.' }
    if ($Name -notmatch '^[A-Za-z0-9_\-.]+$') { throw "Bad file name: $Name" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $dir = Get-TTDownloadFolder
    $target = Join-Path $dir $Name
    $part = $target + '.part'
    foreach ($f in @($target, $part)) { if (Test-Path $f) { Remove-Item -LiteralPath $f -Force } }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'MAV-TechTools'
    $req.Timeout = 30000
    $resp = $req.GetResponse()
    $total = [double]$resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [System.IO.File]::Create($part)
    try {
        $buf = New-Object byte[] 262144
        $got = 0.0
        $lastPct = -1
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $got += $n
            if ($total -gt 0) {
                $pct = [int][math]::Floor(100.0 * $got / $total)
                if ($pct -ne $lastPct -and (Get-Command Set-TTProgress -ErrorAction SilentlyContinue)) {
                    $lastPct = $pct
                    Set-TTProgress $pct ('Downloading {0} ({1:N1} of {2:N1} MB)' -f $Name, ($got / 1MB), ($total / 1MB))
                }
            }
        }
    } finally { $out.Dispose(); $in.Dispose(); $resp.Dispose() }
    if ($total -gt 0 -and $got -ne $total) { throw ('Download was cut off ({0:N1} of {1:N1} MB). Try again.' -f ($got / 1MB), ($total / 1MB)) }
    Move-Item -LiteralPath $part -Destination $target -Force
    Write-Info ('Downloaded {0:N1} MB to {1}' -f ($got / 1MB), $target)
    return $target
}

function Assert-TTSignature {
    # Valid signature: fine. Not signed: warn and continue (some vendors do not sign).
    # Anything else (tampered, bad certificate): stop.
    param([string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $who = ''
    if ($sig.SignerCertificate) { $who = ($sig.SignerCertificate.Subject -split ',')[0] -replace '^CN=', '' }
    switch ([string]$sig.Status) {
        'Valid' { Write-Info ('Signature: valid (' + $who + ')') }
        'NotSigned' { Write-Warn 'The installer is not digitally signed. It came from the vendor''s https site; continuing.' }
        default {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            throw ('The installer signature is ' + $sig.Status + ' (' + $sig.StatusMessage + '). It was deleted and not run.')
        }
    }
}

function Start-TTInstaller {
    # Starts the installer on screen and returns; the tech finishes it.
    param([string]$Path, [string]$Arguments = '')
    if ($Arguments) { Start-Process -FilePath $Path -ArgumentList $Arguments -WorkingDirectory (Split-Path -Parent $Path) }
    else { Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) }
    Write-Info 'Installer started. Finish it on screen.'
}
