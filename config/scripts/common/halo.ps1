# Send a report to a HaloPSA ticket as a private note from the "MAV Tech Tools" agent.
# Input from the window (never logged): Url, Tenant, ClientId, Secret, Outcome,
# Ticket, NoteHtml, Html (report file), AttachPdf. Keep this file ASCII-only.

$in = Get-TTInput
if (-not $in -or -not $in.Secret) { throw 'HaloPSA is not set up in TechTools.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$base = ([string]$in.Url).TrimEnd('/')
if ($base -notmatch '^https://') { throw 'The HaloPSA address must start with https://' }
$ticket = [int]([string]$in.Ticket).Trim().TrimStart('#')

function Get-HaloError {
    param($Err, [string]$Step)
    $code = 0
    try { $code = [int]$Err.Exception.Response.StatusCode } catch { }
    $detail = ''
    try { $detail = [string]$Err.ErrorDetails.Message } catch { }
    if (-not $detail) {
        try {
            $sr = New-Object System.IO.StreamReader($Err.Exception.Response.GetResponseStream())
            $detail = $sr.ReadToEnd()
        } catch { }
    }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + '...' }
    $msg = $Step + ' failed'
    if ($code) { $msg += ' (HTTP ' + $code + ')' }
    if ($code -eq 401 -or $code -eq 403) { $msg += ': HaloPSA refused the TechTools key or its permissions' }
    elseif ($code -eq 404) { $msg += ': not found' }
    else { $msg += ': ' + $Err.Exception.Message }
    if ($detail) { $msg += ' Halo said: ' + $detail }
    return $msg
}

function New-TTHaloPdf {
    # Prints the HTML report to PDF with Edge (headless). Waits for the file itself,
    # because msedge.exe can exit before the PDF is written. Returns $true when made.
    param([string]$Html, [string]$Pdf)
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $edge) { Write-Warn 'Microsoft Edge not found, so no PDF.'; return $false }
    foreach ($extra in @(@(), @('--no-sandbox'))) {
        $prof = Join-Path $env:TEMP ('MAVTechTools-pdf-' + [guid]::NewGuid().ToString('N'))
        $argList = @('--headless', '--disable-gpu', '--no-first-run', '--no-pdf-header-footer') + $extra +
            @(('--user-data-dir="' + $prof + '"'), ('--print-to-pdf="' + $Pdf + '"'), ('"' + ([Uri]$Html).AbsoluteUri + '"'))
        $p = Start-Process -FilePath $edge -WindowStyle Hidden -PassThru -ArgumentList $argList
        $until = (Get-Date).AddSeconds(45)
        $exitedAt = $null
        while ((Get-Date) -lt $until) {
            if ((Test-Path -LiteralPath $Pdf) -and (Get-Item -LiteralPath $Pdf).Length -gt 0 -and $p.HasExited) { break }
            if ($p.HasExited) {
                if (-not $exitedAt) { $exitedAt = Get-Date }
                elseif (((Get-Date) - $exitedAt).TotalSeconds -gt 5) { break }
            }
            Start-Sleep -Milliseconds 300
        }
        Start-Sleep -Milliseconds 300
        Remove-Item -Path $prof -Recurse -Force -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $Pdf) -and (Get-Item -LiteralPath $Pdf).Length -gt 0) { return $true }
        $code = ''
        try { if ($p.HasExited) { $code = ' (Edge exit code ' + $p.ExitCode + ')' } } catch { }
        Write-Info ('PDF attempt did not produce a file' + $code)
    }
    return $false
}

Write-Step 'Connecting to HaloPSA'
$tokenUrl = $base + '/auth/token'
if ($in.Tenant) { $tokenUrl += '?tenant=' + [Uri]::EscapeDataString([string]$in.Tenant) }
$scope = 'read:tickets edit:tickets'
if ($in.Scope) { $scope = [string]$in.Scope }
$form = @{ grant_type = 'client_credentials'; client_id = [string]$in.ClientId; client_secret = [string]$in.Secret; scope = $scope }
try { $tok = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $form -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 -UseBasicParsing }
catch { throw (Get-HaloError $_ 'Sign-in to HaloPSA') }
if (-not $tok.access_token) { throw 'HaloPSA did not return a sign-in token.' }
$headers = @{ Authorization = 'Bearer ' + $tok.access_token }

Write-Step ('Finding ticket #' + $ticket)
try { $t = Invoke-RestMethod -Method Get -Uri ($base + '/api/Tickets/' + $ticket) -Headers $headers -TimeoutSec 30 -UseBasicParsing }
catch { throw (Get-HaloError $_ ('Finding ticket #' + $ticket)) }
Write-Info ('Ticket #' + $ticket + ': ' + [string]$t.summary)

Write-Step 'Adding a private note'
$outcome = 'Private Note'
if ($in.Outcome) { $outcome = [string]$in.Outcome }
$action = @(@{ ticket_id = $ticket; outcome = $outcome; note_html = [string]$in.NoteHtml; hiddenfromuser = $true })
$body = ConvertTo-Json -InputObject $action -Depth 4
try { $res = Invoke-RestMethod -Method Post -Uri ($base + '/api/Actions') -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 -UseBasicParsing }
catch { throw (Get-HaloError $_ 'Adding the note') }
$actionId = $null
try { $actionId = @($res)[0].id } catch { }

Write-Step 'Attaching the report'
$file = [string]$in.Html
if (-not $file -or -not (Test-Path -LiteralPath $file)) { Write-Warn 'The report file was not found, so only the note was added.' }
else {
    if ($in.AttachPdf) {
        $pdf = [System.IO.Path]::ChangeExtension($file, '.pdf')
        if (-not (Test-Path -LiteralPath $pdf)) { $null = New-TTHaloPdf -Html $file -Pdf $pdf }
        if ((Test-Path -LiteralPath $pdf) -and (Get-Item -LiteralPath $pdf).Length -gt 0) { $file = $pdf }
        else { Write-Warn 'Could not make a PDF, attaching the HTML report instead.' }
    }
    $name = [System.IO.Path]::GetFileName($file)
    $data = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file))
    $sent = $false
    $lastErr = ''
    $mime = 'text/html'
    if ($name -like '*.pdf') { $mime = 'application/pdf' }
    # Halo versions differ in the attachment format they accept. Try the known
    # shapes in turn and stop at the first one Halo takes.
    $shapes = @(
        @{ Array = $true;  DataUri = $false; Action = $true },
        @{ Array = $true;  DataUri = $true;  Action = $false },
        @{ Array = $false; DataUri = $true;  Action = $false },
        @{ Array = $false; DataUri = $false; Action = $false },
        @{ Array = $true;  DataUri = $false; Action = $false }
    )
    $n = 0
    foreach ($sh in $shapes) {
        $n++
        if ($sh.Action -and -not $actionId) { continue }
        $att = @{ ticket_id = $ticket; filename = $name; data_base64 = $data }
        if ($sh.DataUri) { $att.data_base64 = 'data:' + $mime + ';base64,' + $data }
        if ($sh.Action) { $att.action_id = [int]$actionId }
        if ($sh.Array) { $abody = ConvertTo-Json -InputObject @($att) -Depth 3 } else { $abody = ConvertTo-Json -InputObject $att -Depth 3 }
        try {
            $null = Invoke-RestMethod -Method Post -Uri ($base + '/api/Attachment') -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($abody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60 -UseBasicParsing
            $sent = $true
            Write-Info ('Halo took attachment format ' + $n)
            break
        } catch { $lastErr = Get-HaloError $_ ('Attaching the report (format ' + $n + ')') }
    }
    if ($sent) { Write-Info ('Attached ' + $name) }
    else { Write-Warn ('The note was added but the attachment failed. ' + $lastErr) }
}
Write-Info ('Sent to HaloPSA ticket #' + $ticket + ' as MAV Tech Tools')
