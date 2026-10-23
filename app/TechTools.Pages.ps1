<#
  MAV TechTools - Home ("This PC at a glance") and the Dental program pages.
  Dot-sourced by TechTools.ps1 after its helpers. Keep this file ASCII-only.
#>

$script:OfficePath = Join-Path $env:ProgramData 'MAVTechTools\office.json'
$script:HistoryPath = Join-Path $env:ProgramData 'MAVTechTools\history.json'
$script:Glance = $null
$script:Dental = @{ Programs = @(); Found = @{}; ScanAt = $null; Open = ''; Checks = @{}; Sensor = $null; Boxes = @{} }
try {
    $doc = Read-TTJson (Join-Path (Join-Path $ConfigRoot 'config') 'dental\programs.json')
    $script:Dental.Programs = @($doc.programs)
} catch { }

# ---------------------------------------------------------------- shared ---
function Get-PProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] } else { return $Default } }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function New-Label {
    # Small uppercase mono label (section eyebrow).
    param([string]$Text, [string]$Color = '#24A7E0', [string]$Margin = '0')
    return (New-Text $Text.ToUpper() -Size 11 -Color $Color -Mono -Margin $Margin)
}

function New-StatTile {
    # Small status tile: dot + label, value, detail line.
    param([string]$Label, [string]$Value, [string]$Sub, [string]$Level = 'ok', [double]$Width = 200)
    $c = New-Card -Width $Width -Padding '12'
    $c.Margin = '0,0,10,10'
    $hot = ($Level -eq 'warn' -or $Level -eq 'fail')
    if ($hot) { $c.Background = Get-Brush (Get-Tint $script:Colors[$Level] 0.07) }
    if ($Level -eq 'warn') { $c.BorderBrush = Get-Brush '#8A6B1E' } elseif ($Level -eq 'fail') { $c.BorderBrush = Get-Brush '#8C3535' }
    $sp = New-Object Windows.Controls.StackPanel
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $lv = $Level; if ($lv -eq 'info') { $lv = 'idle' }
    $d = New-Dot $lv 8
    $d.Margin = '0,0,6,0'
    [void]$row.Children.Add($d)
    [void]$row.Children.Add((New-Text $Label.ToUpper() -Size 10 -Color $script:Colors.muted -Mono))
    [void]$sp.Children.Add($row)
    $vc = $script:Colors.text; if ($hot) { $vc = $script:Colors[$Level] }
    [void]$sp.Children.Add((New-Text $Value -Size 15 -Weight SemiBold -Color $vc -Wrap -Margin '0,4,0,2'))
    if ($Sub) { [void]$sp.Children.Add((New-Text $Sub -Size 12 -Color $script:Colors.muted -Wrap)) }
    $c.Child = $sp
    return $c
}

function New-ActionButton {
    # Button whose click runs Invoke-PageAction with the given action table.
    param([string]$Text, [hashtable]$Action, [switch]$Primary, [string]$Icon)
    $style = 'Btn'; $ic = '#E6EDF5'
    if ($Primary) { $style = 'PrimaryBtn'; $ic = '#04121A' }
    if ($Icon) { $b = New-Button $Text -Style $style -Icon $Icon -IconColor $ic } else { $b = New-Button $Text -Style $style }
    $b.Tag = $Action
    $b.Add_Click({ Invoke-PageAction $this.Tag })
    return $b
}

function New-FixTile {
    # Wide tile with an icon, a label and the command it runs.
    param([string]$Label, [string]$Cmd, [string]$Info, [string]$Icon, [hashtable]$Action, [double]$Width = 330)
    $b = New-Object Windows.Controls.Button
    $b.Style = $script:Window.FindResource('Btn')
    $b.Width = $Width
    $b.MinHeight = 64
    $b.Margin = '0,0,10,10'
    $b.Padding = '12,8'
    $b.HorizontalContentAlignment = 'Stretch'
    if ($Info) { $b.ToolTip = $Info }
    $dock = New-Object Windows.Controls.DockPanel
    $box = New-Object Windows.Controls.Border
    $box.Width = 36; $box.Height = 36; $box.CornerRadius = 10
    $pc = Get-PageColor
    $box.BorderThickness = 1; $box.BorderBrush = Get-Brush (Get-Tint $pc 0.4); $box.Background = Get-Brush (Get-Tint $pc 0.12)
    $box.Margin = '0,0,12,0'
    if (-not $script:Icons.ContainsKey($Icon)) { $Icon = 'bolt' }
    $ic = New-Icon -Name $Icon -Size 18 -Color $pc
    $ic.HorizontalAlignment = 'Center'; $ic.VerticalAlignment = 'Center'
    $box.Child = $ic
    [Windows.Controls.DockPanel]::SetDock($box, 'Left')
    [void]$dock.Children.Add($box)
    $tx = New-Object Windows.Controls.StackPanel
    $tx.VerticalAlignment = 'Center'
    [void]$tx.Children.Add((New-Text $Label -Weight SemiBold -Wrap))
    if ($Cmd) { [void]$tx.Children.Add((New-Text $Cmd -Size 11 -Color $script:Colors.muted -Mono -Wrap -Margin '0,3,0,0')) }
    [void]$dock.Children.Add($tx)
    $b.Content = $dock
    $b.Tag = $Action
    $b.Add_Click({ Invoke-PageAction $this.Tag })
    return $b
}

function New-HiddenJob {
    param([string]$CatId, [string]$ToolId, [string]$Name, $JobInput)
    $cat = Get-Cat $CatId
    $tool = @($cat.Tools | Where-Object { $_.Id -eq $ToolId })[0]
    if (-not $tool) { return $null }
    $job = New-TTJob -Category $cat -Tool $tool
    if ($Name) { $job.Name = $Name }
    if ($null -ne $JobInput) { $job.Input = $JobInput }
    return $job
}

function Test-EffectBusy {
    param([string]$Effect, [string]$ProgId = '')
    foreach ($j in $script:Sync.Jobs.ToArray()) {
        if ($j.Effect -eq $Effect -and ($j.Status -eq 'queued' -or $j.Status -eq 'running') -and (-not $ProgId -or $j.ProgId -eq $ProgId)) { return $true }
    }
    return $false
}

function Invoke-RestartPrompt {
    $ans = [Windows.MessageBox]::Show('Restart this PC in 60 seconds? Ask the user to save their work first.', 'MAV TechTools', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    & shutdown.exe /r /t 60 /c 'Restart started by MAV TechTools' | Out-Null
    $script:State.RestartNeeded = $true
    $script:State.RestartScheduled = $true
    Add-ConsoleLine 'Restart scheduled in 60 seconds' 'warn'
    Add-History 'Restart computer' 'done' 'Scheduled from Home'
    Update-RestartBanner
}

function Invoke-ToolOn {
    # Opens a category tab and presses one of its quick tools.
    param([string]$CatId, [string]$ToolId)
    $cat = Get-Cat $CatId
    $tool = @($cat.Tools | Where-Object { $_.Id -eq $ToolId })[0]
    if (-not $tool) { return }
    $script:State.Tab[$CatId] = $tool.Tab
    Show-Page $CatId
    Invoke-QuickTool $ToolId
}

function Invoke-PageAction {
    # One place for every button on Home and the Dental pages (WPF handlers cannot capture locals).
    param([hashtable]$A)
    switch ($A.Do) {
        'tool' { Invoke-ToolOn $A.Cat $A.Tool }
        'goto' { $script:State.Tab[$A.Cat] = $A.Tab; if ($A.ContainsKey('Prog') -and $null -ne $A.Prog) { $script:Dental.Open = [string]$A.Prog }; Show-Page $A.Cat }
        'glance' { Start-Glance; Render-Page }
        'restart' { Invoke-RestartPrompt }
        'serversetup' { $script:State.Tab['windows'] = 'diag'; Show-Page 'windows'; if (Show-ServerSetup) { Invoke-QuickTool 'servercheck' } }
        'reauth' { $script:State.Tab['windows'] = 'diag'; Show-Page 'windows'; Start-ServerReauth 'login' }
        'security' { try { Start-Process 'windowsdefender:' } catch { Add-ConsoleLine 'Could not open Windows Security.' 'warn' } }
        'profile' { if (Show-OfficeProfile) { Render-Page } }
        'scan' { Start-DentalScan; Render-Page }
        'open' { $script:Dental.Open = $A.Prog; Render-Page; $script:UI.MainScroll.ScrollToTop() }
        'back' { $script:Dental.Open = ''; Render-Page }
        'check' { Start-DentalCheck (Get-DentalProgram $A.Prog); Render-Page }
        'fix' { Start-DentalFix (Get-DentalProgram $A.Prog) $A.Fix; Render-Page }
        'savecfg' { Save-ProgramBoxes $A.Prog; Render-Page }
        'sensor' { Start-SensorCheck; Render-Page }
        'usbfix' { $j = New-HiddenJob 'dental' 'dusbfix'; if ($j) { Add-Jobs @($j) }; Render-Page }
    }
}

# --------------------------------------------------------------- history ---
function Get-History {
    if (-not (Test-Path -LiteralPath $script:HistoryPath)) { return @() }
    try { return @([System.IO.File]::ReadAllText($script:HistoryPath) | ConvertFrom-Json) } catch { return @() }
}

function Add-History {
    # Keeps the last 30 actions run on this PC (shown on Home). No passwords or ticket notes.
    param([string]$Name, [string]$Status, [string]$Detail = '')
    try {
        $items = @(Get-History)
        $items = @([pscustomobject]@{ At = (Get-Date).ToString('s'); Name = $Name; Status = $Status; Detail = $Detail; By = $env:USERNAME }) + $items
        if ($items.Count -gt 30) { $items = $items[0..29] }
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:HistoryPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($script:HistoryPath, (ConvertTo-Json -InputObject $items -Depth 3))
    } catch { }
}

# ------------------------------------------------------------ jobs ---
function Start-Glance {
    if (Test-EffectBusy 'pcglance') { return }
    $j = New-HiddenJob 'windows' 'pcglance'
    if ($j) { Add-Jobs @($j) }
}

function Complete-PageJob {
    # Called for each finished job. Returns $true when Home or Dental should redraw.
    param($J)
    $ok = ($J.Status -eq 'done')
    $skip = @('pcglance', 'dscan', 'netstatus', 'dcheck', 'dsensor')
    if ($skip -notcontains [string]$J.Effect -and $J.ToolId -ne 'netstatus') {
        $detail = ''
        if (-not $ok) { $detail = [string]$J.Error }
        Add-History $J.Name $J.Status $detail
    }
    switch ([string]$J.Effect) {
        'pcglance' { if ($ok -and $J.Result) { $script:Glance = $J.Result }; return $true }
        'cleanup' { Start-Glance; return $true }
        'dscan' {
            if ($ok -and $J.Result) {
                $script:Dental.Found = @{}
                foreach ($f in @($J.Result.Found)) { $script:Dental.Found[[string]$f.Id] = [string]$f.Version }
                $script:Dental.ScanAt = Get-Date
            }
            return $true
        }
        'dcheck' {
            if ($ok -and $J.Result) { $script:Dental.Checks[[string]$J.ProgId] = $J.Result }
            elseif (-not $ok) { $script:Dental.Checks[[string]$J.ProgId] = [pscustomobject]@{ Id = $J.ProgId; At = (Get-Date); Error = [string]$J.Error; Checks = @() } }
            return $true
        }
        'dfix' {
            # Re-check the program so its status tiles show the result of the fix.
            $p = Get-DentalProgram ([string]$J.ProgId)
            if ($p -and [string]$p.kind -ne 'cloud') { Start-DentalCheck $p }
            if ($J.FixType -eq 'usbpower' -and $script:Dental.Sensor) { Start-SensorCheck }
            return $true
        }
        'dsensor' { if ($ok -and $J.Result) { $script:Dental.Sensor = $J.Result }; return $true }
        'dusbfix' { Start-SensorCheck; return $true }
        'serverstatus' { return ($script:State.Page -eq 'home') }
    }
    return $false
}

# ---------------------------------------------------------------- dental ---
function Get-DentalProgram { param([string]$Id) return (@($script:Dental.Programs | Where-Object { $_.id -eq $Id })[0]) }

function Get-OfficeConfig {
    $c = $null
    if (Test-Path -LiteralPath $script:OfficePath) { try { $c = [System.IO.File]::ReadAllText($script:OfficePath) | ConvertFrom-Json } catch { } }
    $o = @{ Pm = ''; Img = ''; Programs = @{} }
    if ($c) {
        $o.Pm = [string](Get-PProp $c 'Pm' ''); $o.Img = [string](Get-PProp $c 'Img' '')
        $ps = Get-PProp $c 'Programs'
        if ($ps) { foreach ($pp in $ps.PSObject.Properties) { $o.Programs[$pp.Name] = @{ Server = [string](Get-PProp $pp.Value 'Server' ''); Share = [string](Get-PProp $pp.Value 'Share' ''); Url = [string](Get-PProp $pp.Value 'Url' '') } } }
    }
    return $o
}

function Save-OfficeConfig {
    param([hashtable]$O)
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:OfficePath) -Force | Out-Null
    $progs = [ordered]@{}
    foreach ($k in $O.Programs.Keys) { $progs[$k] = [ordered]@{ Server = $O.Programs[$k].Server; Share = $O.Programs[$k].Share; Url = $O.Programs[$k].Url } }
    $json = [ordered]@{ Pm = $O.Pm; Img = $O.Img; Programs = $progs; Saved = (Get-Date).ToString('s') } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($script:OfficePath, $json)
}

function Get-ProgramTarget {
    # Server, share and login address used for one program on this PC.
    param($P)
    $o = Get-OfficeConfig
    $c = $o.Programs[[string]$P.id]
    $server = ''; $share = ''; $url = ''; $from = 'Not set'
    if ($c) { $server = $c.Server; $share = $c.Share; $url = $c.Url }
    if ($server) { $from = 'Set on this page' }
    else {
        $cfg = Get-ServerConfig
        if ($cfg -and ([string]$cfg.Unc -match '^\\\\([^\\]+)\\')) { $server = $Matches[1]; $from = 'From the office server (Windows > Diagnostics)' }
    }
    if (-not $share) { $share = [string](Get-PProp $P 'share' '') }
    return @{ Server = $server; Share = $share; Url = $url; From = $from }
}

function Start-DentalScan {
    if (Test-EffectBusy 'dscan') { return }
    $list = @($script:Dental.Programs | Where-Object { [string]$_.kind -ne 'cloud' } | ForEach-Object {
        @{ id = [string]$_.id; name = [string]$_.name; match = [string](Get-PProp $_ 'match' ''); verMatch = [string](Get-PProp $_ 'verMatch' ''); folder = [string](Get-PProp $_ 'folder' '') } })
    $j = New-HiddenJob 'dental' 'dscan' 'Scan for dental software' @{ Programs = $list }
    if ($j) { Add-Jobs @($j) }
}

function Start-DentalCheck {
    param($P)
    if (-not $P -or (Test-EffectBusy 'dcheck' ([string]$P.id))) { return }
    $t = Get-ProgramTarget $P
    $j = New-HiddenJob 'dental' 'dcheck' ('Check ' + $P.name) @{ Program = $P; Server = $t.Server; Share = $t.Share; Url = $t.Url }
    if ($j) { $j.ProgId = [string]$P.id; Add-Jobs @($j) }
}

function Start-DentalFix {
    param($P, [string]$FixId)
    if (-not $P) { return }
    $f = @(@($P.fixes) | Where-Object { $_.id -eq $FixId })[0]
    if (-not $f) { return }
    $t = Get-ProgramTarget $P
    $j = New-HiddenJob 'dental' 'dfix' ($P.name + ': ' + $f.label) @{ Program = $P; Fix = $f; Server = $t.Server; Share = $t.Share; Url = $t.Url }
    if ($j) { $j.ProgId = [string]$P.id; $j.FixType = [string]$f.type; Add-Jobs @($j) }
}

function Start-SensorCheck {
    if (Test-EffectBusy 'dsensor') { return }
    $soft = ''
    foreach ($p in @($script:Dental.Programs | Where-Object { [string]$_.kind -like 'img*' })) {
        if ($script:Dental.Found.ContainsKey([string]$p.id)) { $soft = $p.name + ' ' + $script:Dental.Found[[string]$p.id]; break }
    }
    $j = New-HiddenJob 'dental' 'dsensor' 'X-ray sensor check' @{ Pattern = ''; Software = $soft }
    if ($j) { Add-Jobs @($j) }
}

function Save-ProgramBoxes {
    param([string]$Id)
    $p = Get-DentalProgram $Id
    $b = $script:Dental.Boxes
    if (-not $p -or -not $b.Server) { return }
    $o = Get-OfficeConfig
    $c = $o.Programs[$Id]
    if (-not $c) { $c = @{ Server = ''; Share = ''; Url = '' } }
    if ([string]$p.kind -eq 'cloud' -or [string]$p.kind -eq 'imgcloud') {
        $u = $b.Server.Text.Trim()
        if ($u -and $u -notmatch '^https?://') { $u = 'https://' + $u }
        if ($u -and $u -notmatch '^https?://[A-Za-z0-9.\-]+(:\d+)?(/[^\s]*)?$') { [void][Windows.MessageBox]::Show('Enter the login address, for example https://office.example.com', 'MAV TechTools', 'OK', 'Warning'); return }
        $c.Url = $u
        Add-ConsoleLine ($p.name + ' login address saved on this PC: ' + $u) 'info'
    } else {
        $sv = $b.Server.Text.Trim().TrimStart('\').Split('\')[0]
        $sh = $b.Share.Text.Trim().Trim('\')
        if ($sv -and $sv -notmatch '^[A-Za-z0-9._\-]+$') { [void][Windows.MessageBox]::Show('Server name: letters, numbers, dots and dashes only (for example OFFICE-SRV or 192.168.1.10).', 'MAV TechTools', 'OK', 'Warning'); return }
        if ($sh -and $sh -match '[\\/:*?"<>|]') { [void][Windows.MessageBox]::Show('Share name: just the name, for example DATA.', 'MAV TechTools', 'OK', 'Warning'); return }
        $c.Server = $sv; $c.Share = $sh
        $shown = $sh; if (-not $shown) { $shown = [string](Get-PProp $p 'share' '') }
        if ($sv) { Add-ConsoleLine ($p.name + ' server saved on this PC: \\' + $sv + '\' + $shown) 'info' } else { Add-ConsoleLine ($p.name + ': server cleared, using the office server') 'info' }
    }
    $o.Programs[$Id] = $c
    Save-OfficeConfig $o
    $script:Dental.Checks.Remove($Id)
}

function Show-OfficeProfile {
    # Which practice and imaging software this office uses (saved on this PC).
    $o = Get-OfficeConfig
    $d = New-Dialog 'Office profile' 'Saved on this PC only (C:\ProgramData\MAVTechTools\office.json). No client names or passwords.' 'Save'
    $mk = {
        param($label, $kinds, $cur)
        [void]$d.Panel.Children.Add((New-Text $label -Weight SemiBold -Margin '0,8,0,4'))
        $cb = New-Object Windows.Controls.ComboBox
        $none = New-Object Windows.Controls.ComboBoxItem; $none.Content = 'Not set'; $none.Tag = ''
        [void]$cb.Items.Add($none); $cb.SelectedIndex = 0
        foreach ($p in @($script:Dental.Programs | Where-Object { $kinds -contains [string]$_.kind })) {
            $it = New-Object Windows.Controls.ComboBoxItem
            $name = [string]$p.name
            if ($script:Dental.Found.ContainsKey([string]$p.id)) { $name += '  (found on this PC)' }
            $it.Content = $name; $it.Tag = [string]$p.id
            [void]$cb.Items.Add($it)
            if ($cur -eq [string]$p.id) { $cb.SelectedItem = $it }
        }
        if (-not $cur) {
            foreach ($it in $cb.Items) { if ($it.Tag -and $script:Dental.Found.ContainsKey([string]$it.Tag)) { $cb.SelectedItem = $it; break } }
        }
        [void]$d.Panel.Children.Add($cb)
        return $cb
    }
    $pm = & $mk 'Practice software' @('pm', 'cloud') $o.Pm
    $img = & $mk 'Imaging software' @('img', 'imgcloud') $o.Img
    [void]$d.Panel.Children.Add((New-Text 'Server names are set on each program page, or come from the office server on Windows > Diagnostics.' -Size 11 -Color $script:Colors.muted -Wrap -Margin '0,10,0,0'))
    if (-not $d.Window.ShowDialog()) { return $false }
    $o.Pm = [string]$pm.SelectedItem.Tag
    $o.Img = [string]$img.SelectedItem.Tag
    Save-OfficeConfig $o
    Add-ConsoleLine 'Office profile saved on this PC' 'info'
    return $true
}

function Render-DentalTop {
    $p = $script:UI.PagePanel
    $wrap = New-Object Windows.Controls.WrapPanel
    $wrap.Margin = '0,0,0,8'
    # Found on this PC
    $c1 = New-Card -Width 430 -Padding '16'
    $c1.Background = Get-Brush '#0A1019'
    $c1.Margin = '0,0,12,12'
    $s1 = New-Object Windows.Controls.StackPanel
    $h = New-Object Windows.Controls.DockPanel
    $busy = Test-EffectBusy 'dscan'
    $txt = 'Scan again'; if ($busy) { $txt = 'Scanning...' }
    $sb = New-ActionButton $txt @{ Do = 'scan' } -Icon 'refresh'
    $sb.IsEnabled = -not $busy
    [Windows.Controls.DockPanel]::SetDock($sb, 'Right')
    [void]$h.Children.Add($sb)
    $hl = New-Object Windows.Controls.StackPanel
    [void]$hl.Children.Add((New-Label 'Found on this PC'))
    $at = 'Not scanned yet'
    if ($script:Dental.ScanAt) { $at = 'Checked ' + $script:Dental.ScanAt.ToString('HH:mm') }
    [void]$hl.Children.Add((New-Text $at -Size 11 -Color $script:Colors.muted -Mono -Margin '0,2,0,0'))
    [void]$h.Children.Add($hl)
    [void]$s1.Children.Add($h)
    $chips = New-Object Windows.Controls.WrapPanel
    $chips.Margin = '0,10,0,0'
    $any = $false
    foreach ($pr in $script:Dental.Programs) {
        $id = [string]$pr.id
        if (-not $script:Dental.Found.ContainsKey($id)) { continue }
        $any = $true
        $b = New-ActionButton ($pr.name + '  ' + $script:Dental.Found[$id]) @{ Do = 'goto'; Cat = 'dental'; Tab = $(if ([string]$pr.kind -like 'img*') { 'img' } else { 'pm' }); Prog = $id } -Icon 'bolt'
        $b.BorderBrush = Get-Brush '#1F6E52'
        $b.Margin = '0,0,8,8'
        $b.ToolTip = 'Open the ' + $pr.name + ' page'
        [void]$chips.Children.Add($b)
    }
    if (-not $any) {
        $m = 'No dental programs found on this PC.'
        if (-not $script:Dental.ScanAt) { $m = 'Scanning installed programs...' }
        [void]$chips.Children.Add((New-Text $m -Color $script:Colors.muted))
    }
    [void]$s1.Children.Add($chips)
    $c1.Child = $s1
    [void]$wrap.Children.Add($c1)
    # Office profile
    $o = Get-OfficeConfig
    $c2 = New-Card -Width 430 -Padding '16'
    $c2.Background = Get-Brush '#0A1019'
    $c2.Margin = '0,0,12,12'
    $s2 = New-Object Windows.Controls.StackPanel
    $h2 = New-Object Windows.Controls.DockPanel
    $set = ($o.Pm -or $o.Img)
    $eb = New-ActionButton $(if ($set) { 'Edit' } else { 'Set up' }) @{ Do = 'profile' } -Primary:(-not $set)
    [Windows.Controls.DockPanel]::SetDock($eb, 'Right')
    [void]$h2.Children.Add($eb)
    $hl2 = New-Object Windows.Controls.StackPanel
    [void]$hl2.Children.Add((New-Label 'Office profile'))
    [void]$hl2.Children.Add((New-Text 'saved on this PC' -Size 11 -Color $script:Colors.muted -Mono -Margin '0,2,0,0'))
    [void]$h2.Children.Add($hl2)
    [void]$s2.Children.Add($h2)
    if ($set) {
        foreach ($pair in @(@('Practice software', $o.Pm), @('Imaging', $o.Img))) {
            $pp = Get-DentalProgram $pair[1]
            $v = 'Not set'; if ($pp) { $v = [string]$pp.name }
            $r = New-Object Windows.Controls.StackPanel
            $r.Orientation = 'Horizontal'
            $r.Margin = '0,8,0,0'
            $k = New-Text $pair[0] -Color $script:Colors.muted
            $k.Width = 130
            [void]$r.Children.Add($k)
            [void]$r.Children.Add((New-Text $v -Weight SemiBold))
            [void]$s2.Children.Add($r)
        }
    } else {
        [void]$s2.Children.Add((New-Text 'Not set up. Tell TechTools which practice and imaging software this office uses.' -Color $script:Colors.plain -Wrap -Margin '0,10,0,0'))
    }
    $c2.Child = $s2
    [void]$wrap.Children.Add($c2)
    [void]$p.Children.Add($wrap)
}

function Render-DentalGrid {
    param([string]$Tab)
    $p = $script:UI.PagePanel
    $o = Get-OfficeConfig
    if ($Tab -eq 'img') {
        $groups = @(
            @{ Title = 'Main imaging programs'; Sub = 'Status checks, sensor checks and program fixes'; Big = $true; Items = @($script:Dental.Programs | Where-Object { $_.main -and [string]$_.kind -like 'img*' }) },
            @{ Title = 'Other imaging programs'; Sub = 'Standard fixes for now'; Big = $false; Items = @($script:Dental.Programs | Where-Object { -not $_.main -and [string]$_.kind -eq 'img' }) })
    } else {
        $groups = @(
            @{ Title = 'Main programs'; Sub = 'Status checks and program-specific fixes'; Big = $true; Items = @($script:Dental.Programs | Where-Object { $_.main -and [string]$_.kind -eq 'pm' }) },
            @{ Title = 'Other on-site programs'; Sub = 'Standard fixes for now'; Big = $false; Items = @($script:Dental.Programs | Where-Object { -not $_.main -and [string]$_.kind -eq 'pm' }) },
            @{ Title = 'Cloud programs'; Sub = 'Login page and desktop shortcut'; Big = $false; Items = @($script:Dental.Programs | Where-Object { [string]$_.kind -eq 'cloud' }) })
    }
    foreach ($g in $groups) {
        if (-not $g.Items.Count) { continue }
        $head = New-Object Windows.Controls.Border
        $head.BorderBrush = Get-Brush $script:Colors.line
        $head.BorderThickness = '0,0,0,1'
        $head.Padding = '0,0,0,4'
        $head.Margin = '0,6,0,10'
        $hs = New-Object Windows.Controls.StackPanel
        $hs.Orientation = 'Horizontal'
        [void]$hs.Children.Add((New-Text $g.Title -Size 15 -Weight SemiBold -Color $script:Colors.accent))
        [void]$hs.Children.Add((New-Text ('  ' + $g.Sub) -Size 12 -Color $script:Colors.muted -Margin '0,3,0,0'))
        $head.Child = $hs
        [void]$p.Children.Add($head)
        $wp = New-Object Windows.Controls.WrapPanel
        $wp.Margin = '0,0,0,8'
        foreach ($pr in $g.Items) {
            $id = [string]$pr.id
            $b = New-Object Windows.Controls.Button
            $b.Style = $script:Window.FindResource('Btn')
            $b.Width = $(if ($g.Big) { 250 } else { 200 })
            $b.MinHeight = $(if ($g.Big) { 104 } else { 76 })
            $b.Margin = '0,0,10,10'
            $b.Padding = '14,10'
            $b.HorizontalContentAlignment = 'Left'
            $found = $script:Dental.Found.ContainsKey($id)
            $mine = ($o.Pm -eq $id -or $o.Img -eq $id)
            if ($mine) { $b.BorderBrush = Get-Brush '#1E5562' } elseif ($found) { $b.BorderBrush = Get-Brush '#1F6E52' }
            $sp = New-Object Windows.Controls.StackPanel
            [void]$sp.Children.Add((New-Text $pr.name -Size $(if ($g.Big) { 17 } else { 14 }) -Weight SemiBold))
            [void]$sp.Children.Add((New-Text $pr.vendor -Size 12 -Color $script:Colors.muted -Margin '0,2,0,6'))
            $bw = New-Object Windows.Controls.WrapPanel
            $badge = {
                param($t, $fg, $bd)
                $x = New-Object Windows.Controls.Border
                $x.BorderBrush = Get-Brush $bd; $x.BorderThickness = 1; $x.CornerRadius = 9; $x.Padding = '7,0'; $x.Margin = '0,0,6,4'
                $x.Child = (New-Text $t -Size 10 -Color $fg -Mono)
                [void]$bw.Children.Add($x)
            }
            if ($found) { & $badge ('ON THIS PC ' + $script:Dental.Found[$id]) '#34D399' '#1F6E52' }
            if ($mine) { & $badge 'THIS OFFICE' '#22D3EE' '#1E5562' }
            if (Get-PProp $pr 'generic' $false) { & $badge 'STANDARD FIXES' '#8A99AD' '#263449' }
            [void]$sp.Children.Add($bw)
            $b.Content = $sp
            $b.Tag = @{ Do = 'open'; Prog = $id }
            $b.Add_Click({ Invoke-PageAction $this.Tag })
            [void]$wp.Children.Add($b)
        }
        [void]$p.Children.Add($wp)
    }
}

function Render-SensorCard {
    $p = $script:UI.PagePanel
    $st = $script:Dental.Sensor
    $busy = (Test-EffectBusy 'dsensor') -or (Test-EffectBusy 'dusbfix')
    $card = New-Card -Padding '16'
    $card.Background = Get-Brush '#0A1019'
    $card.Margin = '0,0,0,16'
    $warn = @()
    if ($st) { $warn = @($st.Rows | Where-Object { $_.Level -ne 'ok' }) }
    if ($st -and -not $busy) { if ($warn.Count) { $card.BorderBrush = Get-Brush '#8A6B1E' } else { $card.BorderBrush = Get-Brush '#1F6E52' } } else { $card.BorderBrush = Get-Brush '#1D5A78' }
    $sp = New-Object Windows.Controls.StackPanel
    $dock = New-Object Windows.Controls.DockPanel
    $btns = New-Object Windows.Controls.StackPanel
    $btns.Orientation = 'Horizontal'
    [Windows.Controls.DockPanel]::SetDock($btns, 'Right')
    $fixable = @($warn | Where-Object { $_.Fix -eq 'usb' })
    if ($fixable.Count -and -not $busy) {
        $fb = New-ActionButton 'Fix USB power saving' @{ Do = 'usbfix' } -Primary
        $fb.Margin = '0,0,8,0'
        [void]$btns.Children.Add($fb)
    }
    $rt = 'Check sensor'; if ($st) { $rt = 'Check again' }; if ($busy) { $rt = 'Checking...' }
    $rb = New-ActionButton $rt @{ Do = 'sensor' } -Icon 'refresh'
    $rb.IsEnabled = -not $busy
    [void]$btns.Children.Add($rb)
    [void]$dock.Children.Add($btns)
    $hl = New-Object Windows.Controls.StackPanel
    [void]$hl.Children.Add((New-Label 'X-ray sensor check'))
    $head = 'Not checked yet'; $hc = $script:Colors.muted
    if ($busy) { $head = 'Checking the sensor...'; $hc = $script:Colors.step }
    elseif ($st) {
        if ($warn.Count) { $head = ([string]$warn.Count + ' thing(s) can make the sensor drop out or fail'); $hc = $script:Colors.warn } else { $head = 'Sensor ready'; $hc = $script:Colors.ok }
    }
    [void]$hl.Children.Add((New-Text $head -Size 14 -Weight SemiBold -Color $hc -Margin '0,4,0,0'))
    [void]$dock.Children.Add($hl)
    [void]$sp.Children.Add($dock)
    if ($st -and -not $busy) {
        $g = New-Object Windows.Controls.Grid
        $g.Margin = '0,12,0,0'
        foreach ($w in @('22', 'Auto', '*')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
        $i = 0
        foreach ($r in @($st.Rows)) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = 'Auto'; [void]$g.RowDefinitions.Add($rd)
            $mark = [string][char]0x2713
            if ($r.Level -eq 'warn') { $mark = '!' } elseif ($r.Level -eq 'fail') { $mark = [string][char]0x2715 }
            $m = New-Text $mark -Weight Bold -Color $script:Colors[[string]$r.Level] -Mono -Margin '0,3,0,3'
            [Windows.Controls.Grid]::SetRow($m, $i); [void]$g.Children.Add($m)
            $n = New-Text $r.Name -Weight SemiBold -Margin '0,3,18,3'
            [Windows.Controls.Grid]::SetRow($n, $i); [Windows.Controls.Grid]::SetColumn($n, 1); [void]$g.Children.Add($n)
            $dc = $script:Colors.plain; if ($r.Level -ne 'ok') { $dc = $script:Colors[[string]$r.Level] }
            $t = New-Text $r.Detail -Color $dc -Wrap -Margin '0,3,0,3'
            [Windows.Controls.Grid]::SetRow($t, $i); [Windows.Controls.Grid]::SetColumn($t, 2); [void]$g.Children.Add($t)
            $i++
        }
        [void]$sp.Children.Add($g)
    } elseif (-not $busy) {
        [void]$sp.Children.Add((New-Text 'Plug in the sensor, then press Check sensor. It checks the USB connection, the driver, and the Windows power settings that make sensors drop out.' -Color $script:Colors.muted -Wrap -Margin '0,8,0,0'))
    }
    $card.Child = $sp
    [void]$p.Children.Add($card)
}

function Render-DentalProgram {
    param($P)
    $page = $script:UI.PagePanel
    $id = [string]$P.id
    $kind = [string]$P.kind
    $isImg = $kind -like 'img*'
    $isCloud = ($kind -eq 'cloud' -or $kind -eq 'imgcloud')
    $t = Get-ProgramTarget $P
    $found = $script:Dental.Found.ContainsKey($id)
    $chk = $script:Dental.Checks[$id]
    $busy = Test-EffectBusy 'dcheck' $id

    $back = New-ActionButton $(if ($isImg) { 'All imaging software' } else { 'All practice software' }) @{ Do = 'back' }
    $back.HorizontalAlignment = 'Left'
    $back.Margin = '0,0,0,12'
    [void]$page.Children.Add($back)

    $card = New-Card -Padding '18'
    $card.Background = Get-Brush '#0A1019'
    $card.Margin = '0,0,0,14'
    $sp = New-Object Windows.Controls.StackPanel
    $dock = New-Object Windows.Controls.DockPanel
    $ct = 'Check status'; if ($chk) { $ct = 'Check again' }; if ($busy) { $ct = 'Checking...' }
    $cb = New-ActionButton $ct @{ Do = 'check'; Prog = $id } -Primary -Icon 'play'
    $cb.IsEnabled = -not $busy
    $cb.VerticalAlignment = 'Top'
    [Windows.Controls.DockPanel]::SetDock($cb, 'Right')
    [void]$dock.Children.Add($cb)
    $hl = New-Object Windows.Controls.StackPanel
    $kl = @{ pm = 'Practice software - on-site server'; cloud = 'Practice software - cloud'; img = 'Imaging software'; imgcloud = 'Imaging software - cloud' }[$kind]
    [void]$hl.Children.Add((New-Label $kl))
    $nm = New-Object Windows.Controls.WrapPanel
    [void]$nm.Children.Add((New-Text $P.name -Size 24 -Weight SemiBold -Margin '0,2,12,0'))
    [void]$nm.Children.Add((New-Text $P.vendor -Color $script:Colors.muted -Margin '0,10,0,0'))
    [void]$hl.Children.Add($nm)
    $head = ''; $hc = $script:Colors.muted
    $levels = @()
    if ($chk) { $levels = @(@($chk.Checks) | ForEach-Object { [string]$_.Level }) }
    if ($busy) { $head = 'Checking...'; $hc = $script:Colors.step }
    elseif ($chk -and (Get-PProp $chk 'Error' '')) { $head = 'Check failed: ' + $chk.Error; $hc = $script:Colors.fail }
    elseif ($chk) {
        $w = @($levels | Where-Object { $_ -eq 'warn' }).Count
        if ($levels -contains 'fail') { $head = 'Needs attention'; $hc = $script:Colors.fail; $card.BorderBrush = Get-Brush '#8C3535' }
        elseif ($w) { $head = ('Mostly OK, ' + $w + ' to fix'); $hc = $script:Colors.warn; $card.BorderBrush = Get-Brush '#8A6B1E' }
        else { $head = 'All checks passed'; $hc = $script:Colors.ok; $card.BorderBrush = Get-Brush '#1F6E52' }
    } elseif ($isCloud -and $kind -eq 'cloud') { $head = 'Runs in the browser' }
    elseif ($found) { $head = 'Installed: ' + $script:Dental.Found[$id]; $hc = $script:Colors.ok }
    else { $head = 'Not found on this PC' }
    $hr = New-Object Windows.Controls.StackPanel
    $hr.Orientation = 'Horizontal'
    $hr.Margin = '0,6,0,0'
    [void]$hr.Children.Add((New-Text $head -Size 14 -Weight SemiBold -Color $hc))
    if ($chk -and -not $busy) { [void]$hr.Children.Add((New-Text ('Checked ' + ([datetime]$chk.At).ToString('HH:mm')) -Size 11 -Color $script:Colors.muted -Mono -Margin '12,3,0,0')) }
    [void]$hl.Children.Add($hr)
    [void]$dock.Children.Add($hl)
    [void]$sp.Children.Add($dock)

    # Server and share (or login address) for this program, saved on this PC
    $box = New-Object Windows.Controls.Border
    $box.Background = Get-Brush '#0E1520'; $box.BorderBrush = Get-Brush $script:Colors.line; $box.BorderThickness = 1; $box.CornerRadius = 10
    $box.Padding = '12'; $box.Margin = '0,14,0,0'
    $bs = New-Object Windows.Controls.StackPanel
    $row = New-Object Windows.Controls.WrapPanel
    $mkBox = {
        param($label, $value, $hint, $width)
        $col = New-Object Windows.Controls.StackPanel
        $col.Margin = '0,0,10,0'
        [void]$col.Children.Add((New-Text $label -Size 12 -Weight SemiBold -Margin '0,0,0,4'))
        $tb = New-Object Windows.Controls.TextBox
        $tb.Style = $script:Window.FindResource('SearchBox')
        $tb.Tag = $hint
        $tb.Text = $value
        $tb.Width = $width
        [void]$col.Children.Add($tb)
        [void]$row.Children.Add($col)
        return $tb
    }
    $o = Get-OfficeConfig
    $c = $o.Programs[$id]
    if ($isCloud) {
        $u = ''; if ($c) { $u = $c.Url }
        $script:Dental.Boxes = @{ Server = (& $mkBox 'Login address' $u 'https://office.example.com' 360); Share = $null }
    } else {
        $sv = ''; $sh = ''
        if ($c) { $sv = $c.Server; $sh = $c.Share }
        $script:Dental.Boxes = @{ Server = (& $mkBox 'Server name' $sv 'SERVERNAME or 192.168.1.10' 230); Share = (& $mkBox 'Share name' $sh ([string](Get-PProp $P 'shareHint' 'DATA')) 190) }
    }
    $save = New-ActionButton 'Save' @{ Do = 'savecfg'; Prog = $id } -Primary
    $save.VerticalAlignment = 'Bottom'
    [void]$row.Children.Add($save)
    [void]$bs.Children.Add($row)
    if ($isCloud) { $now = $t.Url; if (-not $now) { $now = 'No address yet' } }
    elseif ($t.Server) { $now = '\\' + $t.Server + '\' + $t.Share + '   (' + $t.From + ')' }
    else { $now = 'No server yet. Enter it here, or set up the office server on Windows > Diagnostics.' }
    [void]$bs.Children.Add((New-Text ('Using: ' + $now + '. Saved on this PC only.') -Size 12 -Color $script:Colors.muted -Wrap -Margin '0,8,0,0'))
    $box.Child = $bs
    [void]$sp.Children.Add($box)

    # Status tiles from the last check
    if ($chk -and -not $busy -and @($chk.Checks).Count) {
        $tw = New-Object Windows.Controls.WrapPanel
        $tw.Margin = '0,14,0,0'
        foreach ($x in @($chk.Checks)) {
            $lv = [string]$x.Level
            $tile = New-StatTile $x.Name ([string]$x.Value) ([string]$x.Detail) $lv 210
            if ($x.Fix -and $lv -ne 'ok') {
                $f = @(@($P.fixes) | Where-Object { $_.id -eq $x.Fix })[0]
                if ($f) {
                    $fb = New-ActionButton $(if ($f.type -eq 'setup') { 'Install' } else { 'Fix' }) @{ Do = 'fix'; Prog = $id; Fix = [string]$f.id } -Primary
                    $fb.HorizontalAlignment = 'Left'; $fb.Margin = '0,8,0,0'; $fb.MinHeight = 30
                    $fb.ToolTip = $f.label
                    [void]$tile.Child.Children.Add($fb)
                }
            }
            [void]$tw.Children.Add($tile)
        }
        [void]$sp.Children.Add($tw)
    } elseif (-not $busy -and -not $chk) {
        $idle = 'Press Check status to test the install, the server and the data share.'
        if ($isImg) { $idle = 'Press Check status to test the install, the image data, the sensor and USB power saving.' }
        if ($kind -eq 'cloud') { $idle = 'Press Check status to test the login address.' }
        [void]$sp.Children.Add((New-Text $idle -Color $script:Colors.muted -Wrap -Margin '0,12,0,0'))
    }
    $card.Child = $sp
    [void]$page.Children.Add($card)

    # Fixes (left) and program notes (right)
    $cols = New-Object Windows.Controls.WrapPanel
    $left = New-Object Windows.Controls.StackPanel
    $left.Width = 350
    $left.Margin = '0,0,16,0'
    [void]$left.Children.Add((New-Label 'Fixes - run immediately' $script:Colors.muted '0,0,0,8'))
    $icons = @{ porttest = 'server'; sharetest = 'folder'; odconfig = 'file'; perm = 'wrench'; firewall = 'windows'; setup = 'play'; services = 'refresh'; usbpower = 'bolt'; sensorreset = 'refresh'; openurl = 'home'; shortcut = 'file' }
    foreach ($f in @($P.fixes)) {
        $cmd = ([string]$f.cmd).Replace('<server>', $(if ($t.Server) { $t.Server } else { '<server>' })).Replace('<share>', $t.Share).Replace('<url>', $(if ($t.Url) { $t.Url } else { '<login address>' }))
        [void]$left.Children.Add((New-FixTile $f.label $cmd ([string]$f.info) $icons[[string]$f.type] @{ Do = 'fix'; Prog = $id; Fix = [string]$f.id } 340))
    }
    [void]$cols.Children.Add($left)
    $notes = New-Card -Width 430 -Padding '16'
    $ns = New-Object Windows.Controls.StackPanel
    [void]$ns.Children.Add((New-Label 'Program notes' $script:Colors.muted))
    $nb = New-Object Windows.Controls.Border
    $nb.CornerRadius = 8; $nb.BorderThickness = 1; $nb.Padding = '10,6'; $nb.Margin = '0,10,0,10'
    if (Get-PProp $P 'confirmed' $false) { $nb.BorderBrush = Get-Brush '#1F6E52'; $nb.Background = Get-Brush '#0E1A18'; $ncol = $script:Colors.ok }
    else { $nb.BorderBrush = Get-Brush '#8A6B1E'; $nb.Background = Get-Brush '#17140A'; $ncol = $script:Colors.warn }
    $nb.Child = (New-Text ([string]$P.note) -Size 12 -Color $ncol -Wrap)
    [void]$ns.Children.Add($nb)
    [void]$ns.Children.Add((New-Text ([string]$P.about) -Color $script:Colors.plain -Wrap -Margin '0,0,0,10'))
    $facts = @(Get-PProp $P 'facts' @())
    foreach ($fa in $facts) {
        $r = New-Object Windows.Controls.DockPanel
        $r.Margin = '0,3,0,3'
        $k = New-Text $fa[0] -Size 12 -Color $script:Colors.muted
        $k.Width = 110
        [Windows.Controls.DockPanel]::SetDock($k, 'Left')
        [void]$r.Children.Add($k)
        [void]$r.Children.Add((New-Text (([string]$fa[1]).Replace('<server>', $(if ($t.Server) { $t.Server } else { '<server>' })).Replace('<share>', $t.Share)) -Size 12 -Mono -Wrap))
        [void]$ns.Children.Add($r)
    }
    $sup = New-Object Windows.Controls.Border
    $sup.BorderBrush = Get-Brush $script:Colors.line; $sup.BorderThickness = '0,1,0,0'; $sup.Margin = '0,10,0,0'; $sup.Padding = '0,10,0,0'
    $ss = New-Object Windows.Controls.StackPanel
    [void]$ss.Children.Add((New-Text 'Vendor support' -Weight SemiBold -Margin '0,0,0,4'))
    foreach ($su in @(Get-PProp $P 'support' @())) {
        $r = New-Object Windows.Controls.DockPanel
        $k = New-Text $su[0] -Size 12 -Color $script:Colors.muted
        $k.Width = 110
        [Windows.Controls.DockPanel]::SetDock($k, 'Left')
        [void]$r.Children.Add($k)
        $v = New-Object Windows.Controls.TextBox
        $v.Text = [string]$su[1]; $v.IsReadOnly = $true; $v.BorderThickness = 0; $v.Background = Get-Brush '#0E1520'
        $v.Foreground = Get-Brush $script:Colors.text; $v.FontFamily = 'Consolas'; $v.FontSize = 13
        [void]$r.Children.Add($v)
        [void]$ss.Children.Add($r)
    }
    $sup.Child = $ss
    [void]$ns.Children.Add($sup)
    $notes.Child = $ns
    [void]$cols.Children.Add($notes)
    [void]$page.Children.Add($cols)
}

function Render-Dental {
    param([string]$Tab)
    if (-not $script:Dental.Programs.Count) {
        [void]$script:UI.PagePanel.Children.Add((New-Text 'The dental program list (config/dental/programs.json) could not be read.' -Color $script:Colors.fail -Wrap))
        return
    }
    $open = $null
    if ($script:Dental.Open) {
        $open = Get-DentalProgram $script:Dental.Open
        if ($open -and ([string]$open.kind -like 'img*') -ne ($Tab -eq 'img')) { $open = $null }
    }
    if ($open) { Render-DentalProgram $open; return }
    Render-DentalTop
    if ($Tab -eq 'img') { Render-SensorCard }
    Render-DentalGrid $Tab
}

# ------------------------------------------------------------------ home ---
function Render-Home {
    $p = $script:UI.PagePanel
    $g = $script:Glance
    $busy = Test-EffectBusy 'pcglance'
    # Header: PC name, user, Windows, model + Refresh
    $dock = New-Object Windows.Controls.DockPanel
    $dock.Margin = '0,0,0,16'
    $rb = New-ActionButton $(if ($busy) { 'Reading...' } else { 'Refresh' }) @{ Do = 'glance' } -Icon 'refresh'
    $rb.IsEnabled = -not $busy
    $rb.VerticalAlignment = 'Bottom'
    [Windows.Controls.DockPanel]::SetDock($rb, 'Right')
    [void]$dock.Children.Add($rb)
    $hs = New-Object Windows.Controls.StackPanel
    [void]$hs.Children.Add((New-Label 'This PC at a glance'))
    [void]$hs.Children.Add((New-Text $env:COMPUTERNAME -Size 30 -Weight SemiBold -Margin '0,6,0,4'))
    $sub = 'Reading this PC...'
    if ($g) {
        $u = [string]$g.User; if (-not $u) { $u = 'nobody signed in' }
        $sub = ('Signed in: {0}   {1} (build {2})   {3}' -f $u, $g.Os, $g.Build, $g.Model)
        $sub += '   Read ' + ([datetime]$g.At).ToString('HH:mm')
    }
    [void]$hs.Children.Add((New-Text $sub -Size 13 -Color $script:Colors.muted -Wrap))
    [void]$dock.Children.Add($hs)
    [void]$p.Children.Add($dock)

    # Status tiles
    $tiles = New-Object Windows.Controls.WrapPanel
    $tiles.Margin = '0,0,0,8'
    $att = New-Object System.Collections.ArrayList
    $cfg = Get-ServerConfig
    $sv = $script:State.Server
    if ($g) {
        $why = @($g.RebootWhy)
        $upLv = 'ok'; if ($g.UptimeDays -ge 7 -or $why.Count) { $upLv = 'warn' }
        $upSub = 'Since ' + ([datetime]$g.LastBoot).ToString('MMM d'); if ($why.Count) { $upSub = 'Restart pending: ' + ($why -join ', ') }
        [void]$tiles.Children.Add((New-StatTile 'Uptime' ([string]$g.UptimeDays + ' days') $upSub $upLv))
        $cLv = 'ok'; if ($g.CPct -ge 95) { $cLv = 'fail' } elseif ($g.CPct -ge 85) { $cLv = 'warn' }
        [void]$tiles.Children.Add((New-StatTile 'C: drive' ([string]$g.CPct + '% used') ([string]$g.CFreeGB + ' GB free of ' + $g.CTotalGB + ' GB') $cLv))
        $mLv = 'ok'; if ($g.MemPct -ge 90) { $mLv = 'warn' }
        [void]$tiles.Children.Add((New-StatTile 'Memory' ([string]$g.MemPct + '% in use') ([string]$g.MemGB + ' GB installed') $mLv))
        if ($g.IPv4) { [void]$tiles.Children.Add((New-StatTile 'Network' ([string]$g.IPv4) ([string]$g.Adapter + '  ' + $g.Speed) 'ok')) }
        else { [void]$tiles.Children.Add((New-StatTile 'Network' 'Not connected' 'No adapter with a gateway' 'fail')) }
        $dv = 'Workgroup'; if ($g.OnDomain) { $dv = 'Domain' }
        [void]$tiles.Children.Add((New-StatTile 'Domain' $dv ([string]$g.Domain) 'ok'))
        $avs = @($g.Antivirus)
        $avOn = @($avs | Where-Object { $_.On })
        if ($avOn.Count) {
            $old = @($avOn | Where-Object { -not $_.Current })
            $aLv = 'ok'; $aSub = 'Running, up to date'
            if ($old.Count) { $aLv = 'warn'; $aSub = 'Running, out of date' }
            [void]$tiles.Children.Add((New-StatTile 'Antivirus' (($avOn | ForEach-Object { $_.Name }) -join ', ') $aSub $aLv))
        } elseif ($avs.Count) { [void]$tiles.Children.Add((New-StatTile 'Antivirus' (($avs | ForEach-Object { $_.Name }) -join ', ') 'Installed but turned off' 'fail')) }
        else { [void]$tiles.Children.Add((New-StatTile 'Antivirus' 'Not reported' 'Windows Security Center lists none' 'warn')) }
        if ($why.Count -or $g.UptimeDays -ge 7) {
            $t = 'Not restarted in ' + $g.UptimeDays + ' days'
            if ($why.Count) { $t = 'Restart pending (' + ($why -join ', ') + ')' }
            [void]$att.Add(@{ Lv = 'warn'; Title = $t; Detail = 'A restart clears slowness and finishes updates'; Btn = 'Restart...'; A = @{ Do = 'restart' } })
        }
        if ($g.CPct -ge 85) { [void]$att.Add(@{ Lv = $cLv; Title = ('C: is ' + $g.CPct + '% full'); Detail = ([string]$g.CFreeGB + ' GB free. Clears temp files and the update cache.'); Btn = 'Free up space'; A = @{ Do = 'tool'; Cat = 'windows'; Tool = 'cleanup' } }) }
        if ($g.MemPct -ge 90) { [void]$att.Add(@{ Lv = 'warn'; Title = ('Memory ' + $g.MemPct + '% in use'); Detail = 'Find what is using it'; Btn = 'Slow PC check'; A = @{ Do = 'tool'; Cat = 'windows'; Tool = 'slowpc' } }) }
        if (-not $avOn.Count) { [void]$att.Add(@{ Lv = 'fail'; Title = 'No antivirus running'; Detail = 'Windows Security Center lists no active antivirus'; Btn = 'Open Windows Security'; A = @{ Do = 'security' } }) }
    } else {
        [void]$tiles.Children.Add((New-Text 'Reading uptime, drive C:, memory, network and antivirus...' -Color $script:Colors.muted -Margin '0,0,0,10'))
    }
    # Office server tile
    if (-not $cfg) {
        [void]$tiles.Children.Add((New-StatTile 'Office server' 'Not set up' 'Set up once per PC' 'warn'))
        [void]$att.Add(@{ Lv = 'warn'; Title = 'Office server not set up on this PC'; Detail = 'Needed for server checks and re-authenticate'; Btn = 'Set up'; A = @{ Do = 'serversetup' } })
    } else {
        $lv = 'info'; $v = 'Not checked'
        if ($sv -and $sv.Configured) { $lv = [string]$sv.Level; $v = @{ ok = 'Connected'; warn = 'Check'; fail = 'Problem' }[$lv] }
        [void]$tiles.Children.Add((New-StatTile 'Office server' $v ([string]$cfg.Unc) $lv))
        if ($sv -and $sv.Configured -and $sv.NeedsAuth) { [void]$att.Add(@{ Lv = 'fail'; Title = 'The office server rejected the saved login'; Detail = [string]$cfg.Unc; Btn = 'Re-authenticate'; A = @{ Do = 'reauth' } }) }
    }
    [void]$p.Children.Add($tiles)
    $o = Get-OfficeConfig
    if ($script:Dental.Found.Count -and -not ($o.Pm -or $o.Img)) {
        $names = @($script:Dental.Programs | Where-Object { $script:Dental.Found.ContainsKey([string]$_.id) } | ForEach-Object { $_.name }) -join ', '
        [void]$att.Add(@{ Lv = 'warn'; Title = 'Dental software found, no office profile'; Detail = $names; Btn = 'Set up profile'; A = @{ Do = 'profile' } })
    }

    # Needs attention
    $ac = New-Card -Padding '16'
    $ac.Background = Get-Brush '#0A1019'
    $ac.Margin = '0,0,0,16'
    if (@($att | Where-Object { $_.Lv -eq 'fail' }).Count) { $ac.BorderBrush = Get-Brush '#8C3535' } elseif ($att.Count) { $ac.BorderBrush = Get-Brush '#8A6B1E' } else { $ac.BorderBrush = Get-Brush '#1F6E52' }
    $as = New-Object Windows.Controls.StackPanel
    $title = 'All good'
    if ($att.Count -eq 1) { $title = '1 thing needs attention' } elseif ($att.Count) { $title = ([string]$att.Count + ' things need attention') }
    if (-not $g) { $title = 'Checking this PC...' }
    [void]$as.Children.Add((New-Text $title -Size 16 -Weight SemiBold))
    [void]$as.Children.Add((New-Text 'Quick read-only checks when TechTools opens. Press Refresh to read again.' -Size 12 -Color $script:Colors.muted -Margin '0,2,0,6'))
    foreach ($a in $att) {
        $row = New-Object Windows.Controls.Border
        $row.Background = Get-Brush '#0E1520'; $row.BorderBrush = Get-Brush $script:Colors.line; $row.BorderThickness = 1; $row.CornerRadius = 10
        $row.Padding = '12,8'; $row.Margin = '0,6,0,0'
        $rd = New-Object Windows.Controls.DockPanel
        $b = New-ActionButton $a.Btn $a.A -Primary
        $b.MinHeight = 32
        [Windows.Controls.DockPanel]::SetDock($b, 'Right')
        [void]$rd.Children.Add($b)
        $mark = '!'; if ($a.Lv -eq 'fail') { $mark = [string][char]0x2715 }
        $m = New-Text $mark -Weight Bold -Color $script:Colors[$a.Lv] -Mono -Margin '0,0,10,0'
        $m.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($m, 'Left')
        [void]$rd.Children.Add($m)
        $tx = New-Object Windows.Controls.StackPanel
        $tx.VerticalAlignment = 'Center'
        [void]$tx.Children.Add((New-Text $a.Title -Weight SemiBold -Wrap))
        [void]$tx.Children.Add((New-Text $a.Detail -Size 12 -Color $script:Colors.muted -Wrap))
        [void]$rd.Children.Add($tx)
        $row.Child = $rd
        [void]$as.Children.Add($row)
    }
    if ($g -and -not $att.Count) { [void]$as.Children.Add((New-Text 'Nothing needs attention right now.' -Color $script:Colors.ok)) }
    $ac.Child = $as
    [void]$p.Children.Add($ac)

    # Favorite tools
    [void]$p.Children.Add((New-Text 'Favorite tools' -Size 16 -Weight SemiBold))
    [void]$p.Children.Add((New-Text 'One click. Results open on the tool''s own page.' -Size 12 -Color $script:Colors.muted -Margin '0,2,0,10'))
    $favs = @(
        @('PC health check', 'Windows > Diagnostics', 'pulse', @{ Do = 'tool'; Cat = 'windows'; Tool = 'healthcheck' }),
        @('Slow PC check', 'Windows > Diagnostics', 'gauge', @{ Do = 'tool'; Cat = 'windows'; Tool = 'slowpc' }),
        @('Clear stuck print jobs', 'Windows > Diagnostics', 'printerx', @{ Do = 'tool'; Cat = 'windows'; Tool = 'printclear' }),
        @('Free up space on C:', 'Windows > Diagnostics', 'trash', @{ Do = 'tool'; Cat = 'windows'; Tool = 'cleanup' }),
        @('Check office server', 'Windows > Diagnostics', 'server', @{ Do = 'tool'; Cat = 'windows'; Tool = 'servercheck' }),
        @('Run network diagnosis', 'Internet Issues', 'wifi', @{ Do = 'tool'; Cat = 'internet'; Tool = 'diagnose' }),
        @('Quick network fix', 'Internet Issues', 'bolt', @{ Do = 'tool'; Cat = 'internet'; Tool = 'quickfix' }),
        @('X-ray sensor check', 'Dental > Imaging', 'dental', @{ Do = 'goto'; Cat = 'dental'; Tab = 'img'; Prog = '' }))
    $fw = New-Object Windows.Controls.WrapPanel
    $fw.Margin = '0,0,0,8'
    foreach ($f in $favs) { [void]$fw.Children.Add((New-FixTile $f[0] $f[1] '' $f[2] $f[3] 260)) }
    [void]$p.Children.Add($fw)

    # This office + recent activity
    $bot = New-Object Windows.Controls.WrapPanel
    $oc = New-Card -Width 430 -Padding '16'
    $oc.Margin = '0,0,14,14'
    $os = New-Object Windows.Controls.StackPanel
    [void]$os.Children.Add((New-Label 'This office'))
    $srvText = 'Not set up'; $srvColor = $script:Colors.muted
    if ($cfg) {
        $srvText = [string]$cfg.Unc; $srvColor = $script:Colors.text
        if ($sv -and $sv.Configured) { $srvText += '  -  ' + [string]$sv.Headline; $srvColor = $script:Colors[[string]$sv.Level] }
    }
    $pmName = 'Not set'; $imgName = 'Not set'
    if ($o.Pm -and (Get-DentalProgram $o.Pm)) { $pmName = (Get-DentalProgram $o.Pm).name }
    if ($o.Img -and (Get-DentalProgram $o.Img)) { $imgName = (Get-DentalProgram $o.Img).name }
    $foundText = @($script:Dental.Programs | Where-Object { $script:Dental.Found.ContainsKey([string]$_.id) } | ForEach-Object { $_.name + ' ' + $script:Dental.Found[[string]$_.id] }) -join ', '
    if (-not $foundText) { $foundText = 'No dental software' }
    foreach ($r in @(@('Server', $srvText, $srvColor), @('Practice software', $pmName, $script:Colors.text), @('Imaging', $imgName, $script:Colors.text), @('Found on this PC', $foundText, $script:Colors.text))) {
        $d = New-Object Windows.Controls.DockPanel
        $d.Margin = '0,8,0,0'
        $k = New-Text $r[0] -Size 12 -Color $script:Colors.muted
        $k.Width = 120
        [Windows.Controls.DockPanel]::SetDock($k, 'Left')
        [void]$d.Children.Add($k)
        [void]$d.Children.Add((New-Text $r[1] -Weight SemiBold -Color $r[2] -Wrap))
        [void]$os.Children.Add($d)
    }
    $ob = New-Object Windows.Controls.WrapPanel
    $ob.Margin = '0,12,0,0'
    $b1 = New-ActionButton 'Office server' @{ Do = 'goto'; Cat = 'windows'; Tab = 'diag'; Prog = $null }
    $b1.Margin = '0,0,8,0'
    [void]$ob.Children.Add($b1)
    [void]$ob.Children.Add((New-ActionButton 'Dental software' @{ Do = 'goto'; Cat = 'dental'; Tab = 'pm'; Prog = '' }))
    [void]$os.Children.Add($ob)
    $oc.Child = $os
    [void]$bot.Children.Add($oc)

    $hc = New-Card -Width 430 -Padding '16'
    $hc.Margin = '0,0,14,14'
    $hsp = New-Object Windows.Controls.StackPanel
    [void]$hsp.Children.Add((New-Label 'Recent on this PC'))
    $items = @(Get-History | Select-Object -First 6)
    if (-not $items.Count) { [void]$hsp.Children.Add((New-Text 'Nothing yet. Actions run with TechTools show here.' -Color $script:Colors.muted -Margin '0,8,0,0')) }
    foreach ($h in $items) {
        $d = New-Object Windows.Controls.DockPanel
        $d.Margin = '0,8,0,0'
        $when = ''
        try { $dt = [datetime]$h.At; if ($dt.Date -eq (Get-Date).Date) { $when = $dt.ToString('HH:mm') } else { $when = $dt.ToString('MMM d') } } catch { }
        $w = New-Text $when -Size 11 -Color $script:Colors.muted -Mono -Margin '10,0,0,0'
        [Windows.Controls.DockPanel]::SetDock($w, 'Right')
        [void]$d.Children.Add($w)
        $ok = ([string]$h.Status -eq 'done')
        $m = New-Text $(if ($ok) { [string][char]0x2713 } else { [string][char]0x2715 }) -Weight Bold -Color $(if ($ok) { $script:Colors.ok } else { $script:Colors.fail }) -Mono -Margin '0,0,8,0'
        [Windows.Controls.DockPanel]::SetDock($m, 'Left')
        [void]$d.Children.Add($m)
        $label = [string]$h.Name
        if ($h.Detail) { $label += '  -  ' + [string]$h.Detail }
        $lt = New-Text $label -Wrap
        $lt.MaxHeight = 40
        [void]$d.Children.Add($lt)
        [void]$hsp.Children.Add($d)
    }
    $hc.Child = $hsp
    [void]$bot.Children.Add($hc)
    [void]$p.Children.Add($bot)

    if (-not $script:IsAdmin) {
        [void]$p.Children.Add((New-Text 'Not running as administrator. Most repairs need admin rights: close this window and start TechTools again with "Run as administrator".' -Color $script:Colors.warn -Wrap -Margin '0,10,0,0'))
    }
}
