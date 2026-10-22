# MAV TechTools - core logic (no UI).
# Loads the tool catalog, turns selections into jobs, and runs jobs on a
# background worker so the window never freezes.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$script:TTValidTypes = @('check', 'choice', 'quick', 'winget')

function Read-TTJson {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($text | ConvertFrom-Json)
}

function Join-TTLines {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    return (@($Value) -join "`n")
}

function Get-TTProp {
    # Safe property read for objects from ConvertFrom-Json (missing -> default).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-TTStepCount {
    param([string]$Script)
    $n = ([regex]::Matches($Script, '\bWrite-Step\b')).Count
    if ($n -lt 1) { $n = 1 }
    return $n
}

function ConvertTo-TTTool {
    param($Raw, [string]$ConfigDir)
    $type = [string](Get-TTProp $Raw 'type' 'check')
    $script = Join-TTLines (Get-TTProp $Raw 'script')
    $scriptFile = Get-TTProp $Raw 'scriptFile'
    if ($scriptFile) {
        $script = [System.IO.File]::ReadAllText((Join-Path $ConfigDir $scriptFile), [System.Text.Encoding]::UTF8)
    }
    $options = @()
    foreach ($o in @(Get-TTProp $Raw 'options' @())) {
        $os = Join-TTLines (Get-TTProp $o 'script')
        $options += [pscustomobject]@{
            Value   = [string](Get-TTProp $o 'value')
            Label   = [string](Get-TTProp $o 'label')
            Script  = $os
            Restart = [bool](Get-TTProp $o 'restart' $false)
        }
    }
    $default = Get-TTProp $Raw 'default'
    if ($type -eq 'choice') { if (-not $default) { $default = 'none' } } else { $default = [bool]$default }
    $package = [string](Get-TTProp $Raw 'package' '')
    $cmd = [string](Get-TTProp $Raw 'cmd' '')
    # notice: a card shown after the button is pressed, e.g. an installer password with a Copy button.
    $notice = $null
    $n = Get-TTProp $Raw 'notice'
    if ($n) {
        $notice = [pscustomobject]@{ Title = [string](Get-TTProp $n 'title' ''); Text = [string](Get-TTProp $n 'text' ''); Copy = [string](Get-TTProp $n 'copy' '') }
    }
    if (-not $cmd -and $type -eq 'winget') { $cmd = $package }
    return [pscustomobject]@{
        Id       = [string](Get-TTProp $Raw 'id')
        Label    = [string](Get-TTProp $Raw 'label')
        Type     = $type
        Tab      = [string](Get-TTProp $Raw 'tab' '')
        Section  = [string](Get-TTProp $Raw 'section' '')
        Default  = $default
        Info     = [string](Get-TTProp $Raw 'info' '')
        Cmd      = $cmd
        Restart  = [bool](Get-TTProp $Raw 'restart' $false)
        Hidden   = [bool](Get-TTProp $Raw 'hidden' $false)
        Effect   = [string](Get-TTProp $Raw 'effect' '')
        Package  = $package
        Script   = $script
        Options  = $options
        Notice   = $notice
        Group    = [string](Get-TTProp $Raw 'group' '')
        Icon     = [string](Get-TTProp $Raw 'icon' '')
    }
}

function Import-TTCatalog {
    # Root = folder that holds config/ (repo root or the launcher's download folder).
    param([string]$Root)
    $configDir = Join-Path $Root 'config'
    $index = Read-TTJson (Join-Path $configDir 'categories.json')
    $cats = New-Object System.Collections.ArrayList
    foreach ($c in $index.categories) {
        $title = [string](Get-TTProp $c 'title')
        $cat = [ordered]@{
            Id           = [string](Get-TTProp $c 'id')
            Title        = $title
            LongTitle    = [string](Get-TTProp $c 'longTitle' $title)
            Blurb        = [string](Get-TTProp $c 'blurb' '')
            Tiles        = [string](Get-TTProp $c 'tiles' '')
            Icon         = [string](Get-TTProp $c 'icon' '')
            RestorePoint = [bool](Get-TTProp $c 'restorePoint' $false)
            ComingSoon   = $true
            StatusPanel  = $false
            Shared       = ''
            Tabs         = @()
            Tools        = @()
        }
        $file = Get-TTProp $c 'file'
        if ($file) {
            $doc = Read-TTJson (Join-Path $configDir $file)
            $cat.ComingSoon = $false
            $cat.StatusPanel = [bool](Get-TTProp $doc 'statusPanel' $false)
            $shared = Join-TTLines (Get-TTProp $doc 'shared')
            # sharedFile: one path or a list of paths, loaded in order before 'shared'.
            $files = @(Get-TTProp $doc 'sharedFile' @())
            [array]::Reverse($files)
            foreach ($sf in $files) {
                if ($sf) { $shared = [System.IO.File]::ReadAllText((Join-Path $configDir $sf), [System.Text.Encoding]::UTF8) + "`n" + $shared }
            }
            $cat.Shared = $shared
            $cat.Tabs = @(@(Get-TTProp $doc 'tabs' @()) | ForEach-Object { [pscustomobject]@{ Id = [string]$_.id; Title = [string]$_.title } })
            if ($cat.Tabs.Count -eq 0) { $cat.Tabs = @([pscustomobject]@{ Id = 'main'; Title = 'All tools' }) }
            $tools = @()
            foreach ($t in @(Get-TTProp $doc 'tools' @())) {
                $tool = ConvertTo-TTTool -Raw $t -ConfigDir $configDir
                if (-not $tool.Tab) { $tool.Tab = $cat.Tabs[0].Id }
                $tools += $tool
            }
            $cat.Tools = $tools
        }
        [void]$cats.Add([pscustomobject]$cat)
    }
    return ,$cats
}

function Test-TTScriptSyntax {
    param([string]$Script)
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)
    return @($errors | ForEach-Object { $_.Message })
}

function Test-TTCatalog {
    # Returns a list of problems. Empty list = catalog is good.
    param($Catalog)
    $problems = New-Object System.Collections.ArrayList
    $catIds = @{}
    foreach ($cat in $Catalog) {
        if (-not $cat.Id) { [void]$problems.Add('A category has no id'); continue }
        if ($catIds[$cat.Id]) { [void]$problems.Add("Duplicate category id '$($cat.Id)'") }
        $catIds[$cat.Id] = $true
        if ($cat.Shared) {
            foreach ($e in (Test-TTScriptSyntax $cat.Shared)) { [void]$problems.Add("$($cat.Id) shared script: $e") }
        }
        $tabIds = @($cat.Tabs | ForEach-Object { $_.Id })
        $ids = @{}
        foreach ($t in $cat.Tools) {
            $where = "$($cat.Id)/$($t.Id)"
            if (-not $t.Id) { [void]$problems.Add("$($cat.Id): a tool has no id"); continue }
            if ($t.Id -notmatch '^[A-Za-z0-9_\-]+$') { [void]$problems.Add("${where}: id may only use letters, digits, - and _") }
            if ($ids[$t.Id]) { [void]$problems.Add("${where}: duplicate id") }
            $ids[$t.Id] = $true
            if (-not $t.Label) { [void]$problems.Add("${where}: missing label") }
            if ($script:TTValidTypes -notcontains $t.Type) { [void]$problems.Add("${where}: unknown type '$($t.Type)'") }
            if ($tabIds -notcontains $t.Tab) { [void]$problems.Add("${where}: tab '$($t.Tab)' is not defined") }
            if ($t.Type -ne 'quick' -and -not $t.Section) { [void]$problems.Add("${where}: missing section") }
            switch ($t.Type) {
                'winget' {
                    if ($t.Package -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_+]*$') { [void]$problems.Add("${where}: bad winget package id '$($t.Package)'") }
                }
                'choice' {
                    if (@($t.Options).Count -lt 1) { [void]$problems.Add("${where}: choice needs options") }
                    foreach ($o in $t.Options) {
                        if (-not $o.Value -or $o.Value -eq 'none') { [void]$problems.Add("${where}: option value missing or 'none' (reserved)") }
                        if (-not $o.Script.Trim()) { [void]$problems.Add("${where}/$($o.Value): option has no script") }
                        foreach ($e in (Test-TTScriptSyntax $o.Script)) { [void]$problems.Add("${where}/$($o.Value): $e") }
                    }
                }
                default {
                    if (-not $t.Script.Trim()) { [void]$problems.Add("${where}: missing script") }
                    foreach ($e in (Test-TTScriptSyntax $t.Script)) { [void]$problems.Add("${where}: $e") }
                }
            }
        }
    }
    return ,$problems
}

function Get-TTWingetScript {
    param([string]$Package, [string]$Label)
    # Exit codes 0x8A15002B (no newer version) and 0x8A150061 (already installed) count as success.
    $lines = @(
        "Write-Step 'Checking winget'",
        "if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget is not available. Install or update App Installer from the Microsoft Store.' }",
        ("Write-Step 'Installing {0} ({1})'" -f ($Label -replace "'", "''"), $Package),
        ("winget install --id '{0}' --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object {{ [string]`$_ }} | Where-Object {{ `$_ -match '[A-Za-z]' -and `$_ -notmatch '[\u2580-\u259F]' }}" -f $Package),
        "Assert-TTExit 'winget install' -Ok 0,-1978335189,-1978335135"
    )
    return ($lines -join "`n")
}

function New-TTJob {
    param($Category, $Tool, [string]$OptionValue)
    $name = $Tool.Label
    $script = $Tool.Script
    $restart = $Tool.Restart
    if ($Tool.Type -eq 'winget') {
        $name = 'Install ' + $Tool.Label
        $script = Get-TTWingetScript -Package $Tool.Package -Label $Tool.Label
    } elseif ($Tool.Type -eq 'choice') {
        $opt = @($Tool.Options | Where-Object { $_.Value -eq $OptionValue })[0]
        if (-not $opt) { throw "Tool '$($Tool.Id)' has no option '$OptionValue'" }
        $name = $Tool.Label + ': ' + $opt.Label
        $script = $opt.Script
        $restart = ($restart -or $opt.Restart)
    }
    return [hashtable]::Synchronized(@{
        Id            = [guid]::NewGuid().ToString('N')
        ToolId        = $Tool.Id
        Category      = $Category.Id
        CategoryTitle = $Category.Title
        Name          = $name
        Shared        = $Category.Shared
        Script        = $script
        Steps         = (Get-TTStepCount $script)
        Step          = 0
        StepText      = 'waiting'
        Percent       = 0
        Status        = 'queued'
        Restart       = $restart
        Effect        = $Tool.Effect
        Input         = $null
        Result        = $null
        Error         = $null
        Handled       = $false
        Queued        = Get-Date
    })
}

function New-TTRestorePointJob {
    param($Category)
    $tool = [pscustomobject]@{
        Id = '_restorepoint'; Label = 'Create system restore point'; Type = 'check'; Restart = $false; Effect = ''
        Script = (@(
            "Write-Step 'Making sure System Restore is on for C:'",
            "Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction SilentlyContinue",
            "Write-Step 'Creating restore point'",
            "try { Checkpoint-Computer -Description 'MAV TechTools' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Write-Info 'Restore point created' }",
            "catch { Write-Warn ('Restore point skipped: ' + $_.Exception.Message) }"
        ) -join "`n")
        Options = @()
    }
    return New-TTJob -Category $Category -Tool $tool
}

function Get-TTSelectionJobs {
    # Builds jobs for everything picked in one category, in catalog order.
    # $Sel: hashtable "catId:toolId" -> $true. $Choice: "catId:toolId" -> option value.
    param($Category, [hashtable]$Sel, [hashtable]$Choice)
    $jobs = @()
    $needsRestorePoint = $false
    foreach ($t in $Category.Tools) {
        $key = $Category.Id + ':' + $t.Id
        if ($t.Type -eq 'choice') {
            $v = $Choice[$key]
            if ($v -and $v -ne 'none') { $jobs += (New-TTJob -Category $Category -Tool $t -OptionValue $v); $needsRestorePoint = $true }
        } elseif ($t.Type -eq 'check' -or $t.Type -eq 'winget') {
            if ($Sel[$key]) {
                $jobs += (New-TTJob -Category $Category -Tool $t)
                if ($t.Type -ne 'winget') { $needsRestorePoint = $true }
            }
        }
    }
    if ($Category.RestorePoint -and $needsRestorePoint) { $jobs = @(New-TTRestorePointJob -Category $Category) + $jobs }
    return ,$jobs
}

function New-TTSync {
    param([string]$LogFile)
    return [hashtable]::Synchronized(@{
        Jobs    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Log     = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Version = 0
        Stop    = $false
        RunOnce = $false
        LogFile = $LogFile
    })
}

# The worker runs in its own runspace. It is a string so it can be started on
# any runspace and tested on its own.
$script:TTWorkerScript = @'
param($Sync)

function Send-TTLog {
    param([string]$Text, [string]$Tone = 'plain')
    $line = [pscustomobject]@{ Time = (Get-Date).ToString('HH:mm:ss'); Text = $Text; Tone = $Tone }
    $Sync.Log.Enqueue($line)
    if ($Sync.LogFile) {
        try { [System.IO.File]::AppendAllText($Sync.LogFile, ('{0} [{1}] {2}{3}' -f $line.Time, $Tone, $Text, [Environment]::NewLine)) } catch { }
    }
}

# ---- helpers available to every tool script ----
function Write-Step {
    param([string]$Text)
    $j = $script:TTJob
    $j.Step = [int]$j.Step + 1
    if ($j.Step -gt $j.Steps) { $j.Steps = $j.Step }
    $j.StepText = $Text
    $j.Percent = [int][math]::Floor(100 * ($j.Step - 1) / [math]::Max(1, $j.Steps))
    $Sync.Version++
    Send-TTLog $Text 'step'
}
# Progress inside the current step (0-100), for long steps like SFC or a 30 s sample.
function Set-TTProgress {
    param([double]$Percent, [string]$Text = '')
    $j = $script:TTJob
    $p = [math]::Min(100.0, [math]::Max(0.0, $Percent))
    $j.Percent = [int][math]::Floor(100 * (([int]$j.Step - 1) + $p / 100.0) / [math]::Max(1.0, [double]$j.Steps))
    if ($Text) { $j.StepText = $Text }
    $Sync.Version++
}
function Write-Info { param([string]$Text) Send-TTLog $Text 'plain' }
function Write-Warn { param([string]$Text) $script:TTJob.Warnings = [int]$script:TTJob.Warnings + 1; Send-TTLog $Text 'warn' }
function Set-Result { param($Value) $script:TTJob.Result = $Value }
# Values the window hands to a job (for example a login typed by the tech). Never logged.
function Get-TTInput { return $script:TTJob.Input }
function Assert-TTExit {
    param([string]$What, [int[]]$Ok = @(0))
    $code = $global:LASTEXITCODE
    if ($null -eq $code) { return }
    if ($Ok -notcontains [int]$code) { throw ('{0} failed (exit code {1})' -f $What, $code) }
}

function Invoke-TTJob {
    param($Job)
    $script:TTJob = $Job
    $Job.Status = 'running'
    $Job.StepText = 'starting'
    $Job.Started = Get-Date
    $Sync.Version++
    Send-TTLog ('>> ' + $Job.Name) 'info'
    $global:LASTEXITCODE = 0
    $Job.Warnings = 0
    # Cmdlet errors stop the job unless the tool says -ErrorAction SilentlyContinue.
    # (Native commands like netsh are checked with Assert-TTExit instead.)
    $PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }
    try {
        $sb = [scriptblock]::Create([string]$Job.Shared + "`n" + [string]$Job.Script)
        & $sb *>&1 | ForEach-Object {
            $item = $_
            if ($item -is [System.Management.Automation.ErrorRecord]) { $Job.Warnings = [int]$Job.Warnings + 1; Send-TTLog $item.ToString() 'warn' }
            elseif ($item -is [System.Management.Automation.WarningRecord]) { $Job.Warnings = [int]$Job.Warnings + 1; Send-TTLog $item.Message 'warn' }
            elseif ($item -is [System.Management.Automation.VerboseRecord] -or $item -is [System.Management.Automation.DebugRecord]) { }
            elseif ($null -ne $item) {
                $text = ($item | Out-String -Width 200).TrimEnd()
                foreach ($ln in ($text -split "`r?`n")) { if ($ln.Trim()) { Send-TTLog $ln.TrimEnd() 'plain' } }
            }
        }
        $Job.Percent = 100
        $Job.StepText = 'finished'
        $Job.Status = 'done'
        Send-TTLog ('OK  ' + $Job.Name) 'ok'
    } catch {
        $Job.Status = 'failed'
        $Job.Error = $_.Exception.Message
        $Job.StepText = 'failed'
        Send-TTLog ('FAILED  ' + $Job.Name + ': ' + $Job.Error) 'fail'
    }
    $Job.Input = $null
    $Job.Finished = Get-Date
    $Sync.Version++
}

while (-not $Sync.Stop) {
    $next = $null
    foreach ($j in $Sync.Jobs.ToArray()) { if ($j.Status -eq 'queued') { $next = $j; break } }
    if ($null -eq $next) {
        if ($Sync.RunOnce) { break }
        Start-Sleep -Milliseconds 200
        continue
    }
    Invoke-TTJob -Job $next
}
'@

function Start-TTWorker {
    param($Sync)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:TTWorkerScript).AddArgument($Sync)
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ PowerShell = $ps; Runspace = $rs; Handle = $handle }
}

function Stop-TTWorker {
    param($Worker, $Sync)
    $Sync.Stop = $true
    try {
        if (-not $Worker.Handle.AsyncWaitHandle.WaitOne(1500)) { $Worker.PowerShell.Stop() }
        $Worker.PowerShell.Dispose()
        $Worker.Runspace.Close()
    } catch { }
}

function Invoke-TTJobsNow {
    # Runs queued jobs on the current thread until none are left (used by tests).
    param($Sync)
    $Sync.RunOnce = $true
    & ([scriptblock]::Create($script:TTWorkerScript)) $Sync
}

function Get-TTStatusCards {
    # Status panel cards from a network snapshot. Level: ok | warn | fail | idle
    param($S)
    if ($null -eq $S) {
        return @(
            foreach ($l in @('Adapter', 'IPv4', 'Gateway', 'DNS', 'Internet', 'Public IP')) {
                [pscustomobject]@{ Label = $l; Value = '...'; Detail = 'Press Refresh'; Level = 'idle' }
            }
        )
    }
    $cards = @()
    if ($S.Adapter) { $cards += [pscustomobject]@{ Label = 'Adapter'; Value = $S.Adapter; Detail = $S.AdapterDetail; Level = 'ok' } }
    else { $cards += [pscustomobject]@{ Label = 'Adapter'; Value = 'Not connected'; Detail = 'No adapter is up'; Level = 'fail' } }

    if ($S.Apipa) { $cards += [pscustomobject]@{ Label = 'IPv4'; Value = $S.IPv4; Detail = 'No DHCP answer'; Level = 'fail' } }
    elseif ($S.IPv4) {
        $kind = 'Static'
        if ($S.Dhcp) { $kind = 'DHCP' }
        $cards += [pscustomobject]@{ Label = 'IPv4'; Value = $S.IPv4; Detail = $kind; Level = 'ok' }
    } else { $cards += [pscustomobject]@{ Label = 'IPv4'; Value = 'None'; Detail = 'No address'; Level = 'fail' } }

    if (-not $S.Gateway) { $cards += [pscustomobject]@{ Label = 'Gateway'; Value = 'None'; Detail = 'No router address'; Level = 'fail' } }
    elseif ($S.GatewaySent -gt 0 -and $S.GatewayLost -ge $S.GatewaySent) { $cards += [pscustomobject]@{ Label = 'Gateway'; Value = $S.Gateway; Detail = 'Not answering'; Level = 'fail' } }
    elseif ($S.GatewayLost -gt 0) { $cards += [pscustomobject]@{ Label = 'Gateway'; Value = $S.Gateway; Detail = ('{0} of {1} pings lost' -f $S.GatewayLost, $S.GatewaySent); Level = 'warn' } }
    else { $cards += [pscustomobject]@{ Label = 'Gateway'; Value = $S.Gateway; Detail = ('Replies in {0} ms' -f $S.GatewayMs); Level = 'ok' } }

    $dnsValue = (@($S.Dns) | Select-Object -First 2) -join ', '
    if (-not $dnsValue) { $dnsValue = 'None set' }
    if ($S.DnsTotal -gt 0 -and $S.DnsFailed -ge $S.DnsTotal) { $cards += [pscustomobject]@{ Label = 'DNS'; Value = $dnsValue; Detail = 'Lookups failing'; Level = 'fail' } }
    elseif ($S.DnsFailed -gt 0 -or ($null -ne $S.DnsMs -and $S.DnsMs -gt 250)) { $cards += [pscustomobject]@{ Label = 'DNS'; Value = $dnsValue; Detail = ('Slow: {0} ms' -f $S.DnsMs); Level = 'warn' } }
    else { $cards += [pscustomobject]@{ Label = 'DNS'; Value = $dnsValue; Detail = ('Lookups in {0} ms' -f $S.DnsMs); Level = 'ok' } }

    if ($S.CaptivePortal) { $cards += [pscustomobject]@{ Label = 'Internet'; Value = 'Sign-in needed'; Detail = 'Guest/hotel network'; Level = 'warn' } }
    elseif ($S.InternetOk) { $cards += [pscustomobject]@{ Label = 'Internet'; Value = 'Reachable'; Detail = ('{0} ms' -f $S.InternetMs); Level = 'ok' } }
    elseif ($S.HttpOk) { $cards += [pscustomobject]@{ Label = 'Internet'; Value = 'Reachable'; Detail = 'Ping blocked, web OK'; Level = 'ok' } }
    else { $cards += [pscustomobject]@{ Label = 'Internet'; Value = 'Unreachable'; Detail = 'No replies'; Level = 'fail' } }

    if ($S.PublicIp) { $cards += [pscustomobject]@{ Label = 'Public IP'; Value = $S.PublicIp; Detail = 'via api.ipify.org'; Level = 'ok' } }
    else { $cards += [pscustomobject]@{ Label = 'Public IP'; Value = 'Unknown'; Detail = 'Lookup failed'; Level = 'warn' } }
    return $cards
}
