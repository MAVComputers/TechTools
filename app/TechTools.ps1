<#
  MAV TechTools - main window.
  Normally started by run.ps1 (the launcher). To run from a clone:
      powershell -ExecutionPolicy Bypass -File .\app\TechTools.ps1
  -SmokeTest builds every page without showing the window (used by CI).
  Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
#>
param(
    [string]$ConfigRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'TechTools.Core.ps1')

# ------------------------------------------------------------------ setup ---
$script:Catalog = Import-TTCatalog -Root $ConfigRoot
$script:Version = '0.1.0'
try { $script:Version = [string](Read-TTJson (Join-Path $ConfigRoot 'manifest.json')).version } catch { }

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# TechTools always runs elevated so every script and install has admin rights.
# If started without them, restart through UAC. A tech without admin rights can
# type an admin account in the UAC prompt. If UAC is refused, stop here.
if (-not $script:IsAdmin -and -not $SmokeTest) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $PSCommandPath + '"'), '-ConfigRoot', ('"' + $ConfigRoot.TrimEnd('\') + '"'))
    } catch {
        [void][System.Windows.MessageBox]::Show(('TechTools needs administrator rights so its scripts and installs work.' + [Environment]::NewLine + [Environment]::NewLine +
            'Start it again and choose Yes in the Windows prompt, or enter an admin account if asked.'), 'MAV TechTools', 'OK', 'Warning')
    }
    exit
}
$script:LogDir = Join-Path $env:ProgramData 'MAVTechTools\Logs'
try { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null } catch {
    $script:LogDir = Join-Path $env:LOCALAPPDATA 'MAVTechTools\Logs'
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}
$script:LogFile = Join-Path $script:LogDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $env:COMPUTERNAME + '.log')
$script:Sync = New-TTSync -LogFile $script:LogFile

$script:State = @{
    Page = 'home'; Tab = @{}; Sel = @{}; Choice = @{}; Query = ''
    NetStatus = $null; NetChecked = 'Not checked yet'; Diag = $null
    RestartNeeded = $false; RestartWhy = (New-Object System.Collections.ArrayList); RestartScheduled = $false
    Health = $null; HealthError = ''; Pdf = $null; Server = $null; ServerError = ''
    Notices = @{}; Pane = @{}
}
$script:SeenVersion = -1
$script:Halo = $null
$script:HaloProblem = ''

$xamlText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml'), [System.Text.Encoding]::UTF8)
$script:Window = [Windows.Markup.XamlReader]::Parse($xamlText)
$script:UI = @{}
foreach ($n in @('LogoPath', 'NavPanel', 'PcText', 'AdminChip', 'AdminText', 'VersionText', 'MainScroll', 'PagePanel',
        'SummaryText', 'OverallBar', 'CancelBtn', 'ClearBtn', 'LogsBtn', 'RestartBanner', 'RestartWhyText',
        'RestartNowBtn', 'RestartLaterBtn', 'NoJobsText', 'JobList', 'ConsoleList', 'CopyLogBtn')) {
    $script:UI[$n] = $script:Window.FindName($n)
}
$script:ConsoleItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:UI.ConsoleList.ItemsSource = $script:ConsoleItems

# ---------------------------------------------------------------- helpers ---
$script:Colors = @{
    text = '#E6EDF5'; muted = '#8A99AD'; dim = '#5D6B80'; accent = '#24A7E0'; line = '#1E2A3B'
    ok = '#34D399'; warn = '#FBBF24'; fail = '#F87171'; idle = '#5D6B80'
    plain = '#C9D4E3'; info = '#E6EDF5'; step = '#7DD3FC'
}
$script:BrushCache = @{}
function Get-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) {
        $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
        $b.Freeze()
        $script:BrushCache[$Hex] = $b
    }
    return $script:BrushCache[$Hex]
}

function New-Text {
    param([string]$Text, [double]$Size = 13, [string]$Color = '#E6EDF5', [string]$Weight = 'Normal',
        [string]$Margin = '0', [switch]$Mono, [switch]$Wrap)
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = Get-Brush $Color
    $t.FontWeight = [Windows.FontWeights]::$Weight
    $t.Margin = $Margin
    if ($Mono) { $t.FontFamily = 'Consolas' }
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    return $t
}

$script:Icons = @{
    send    = 'M22,2 L11,13 M22,2 L15,22 L11,13 L2,9 Z'
    home    = 'M3,11 L12,4 L21,11 M5,10 L5,20 L19,20 L19,10'
    windows = 'M3,3 H11 V11 H3 Z M13,3 H21 V11 H13 Z M3,13 H11 V21 H3 Z M13,13 H21 V21 H13 Z'
    dental  = 'M7,3 C4.5,3 3,5 3,7.5 C3,10.5 4.5,12 5,14.5 C5.5,17.5 6,21 7.5,21 C9,21 9.5,17 12,17 C14.5,17 14,21 15.5,21 C17,21 17.5,17.5 18,14.5 C18.5,12 20,10.5 20,7.5 C20,5 18.5,3 16,3 C14.2,3 13.4,4 12,4 C10.6,4 9.8,3 7,3 Z'
    eye     = 'M2,12 C5,6 9,5 12,5 C15,5 19,6 22,12 C19,18 15,19 12,19 C9,19 5,18 2,12 Z M9,12 A3,3 0 1 1 15,12 A3,3 0 1 1 9,12 Z'
    wifi    = 'M2,8.5 A15,15 0 0 1 22,8.5 M5,12 A10,10 0 0 1 19,12 M8.5,15.5 A5,5 0 0 1 15.5,15.5 M11,19 A1,1 0 1 1 13,19 A1,1 0 1 1 11,19'
    bolt    = 'M13,2 L4,14 L11,14 L10,22 L19,10 L12,10 Z'
    play    = 'M7,4 L20,12 L7,20 Z'
    refresh = 'M20,11 A8,8 0 1 0 17.7,16.7 M20,4 L20,11 L13,11'
    pulse   = 'M3,12 L7,12 L10,4 L14,20 L17,12 L21,12'
    file    = 'M6,2 H14 L20,8 V22 H6 Z M14,2 V8 H20'
    folder  = 'M3,6 H10 L12,8 H21 V19 H3 Z'
    trash   = 'M4,7 H20 M10,11 V17 M14,11 V17 M6,7 L7,20 H17 L18,7 M9,7 V4 H15 V7'
    gauge   = 'M12,13 L16,9 M4,17 A8,8 0 1 1 20,17'
    printer = 'M7,8 V3 H17 V8 M5,16 H3 V8 H21 V16 H19 M7,13 H17 V21 H7 Z'
    printerx = 'M7,8 V3 H17 V8 M5,16 H3 V8 H21 V12 M7,13 H13 V21 H7 Z M16,15 L21,20 M21,15 L16,20'
    alert   = 'M12,3 L22,21 L2,21 Z M12,10 V15 M12,18 V18.5'
    wrench  = 'M14,6 A4,4 0 0 0 19,11 L10,20 A2.1,2.1 0 0 1 7,17 L16,8 M14,6 L17,3'
    battery = 'M3,8 H18 V16 H3 Z M21,11 V13 M6,11 V13 M9,11 V13'
    clock   = 'M12,7 V12 L15,14 M3,12 A9,9 0 1 1 21,12 A9,9 0 1 1 3,12'
    server  = 'M4,4 H20 V10 H4 Z M4,14 H20 V20 H4 Z M8,7 H8.5 M8,17 H8.5'
}
function New-Icon {
    param([string]$Name, [double]$Size = 16, [string]$Color = '#E6EDF5', [switch]$Fill)
    $p = New-Object Windows.Shapes.Path
    try { $p.Data = [Windows.Media.Geometry]::Parse($script:Icons[$Name]) } catch { }
    if ($Fill) { $p.Fill = Get-Brush $Color } else { $p.Stroke = Get-Brush $Color; $p.StrokeThickness = 1.8 }
    $p.StrokeLineJoin = 'Round'; $p.StrokeStartLineCap = 'Round'; $p.StrokeEndLineCap = 'Round'
    $box = New-Object Windows.Controls.Canvas
    $box.Width = 24; $box.Height = 24
    [void]$box.Children.Add($p)
    $vb = New-Object Windows.Controls.Viewbox
    $vb.Width = $Size; $vb.Height = $Size
    $vb.Child = $box
    return $vb
}

function Get-Cat { param([string]$Id) return ($script:Catalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1) }
function Get-CurrentTab {
    param($Cat)
    $t = $script:State.Tab[$Cat.Id]
    if (-not $t) { $t = $Cat.Tabs[0].Id }
    return $t
}
function Test-Picked {
    param($Cat, $Tool)
    $key = $Cat.Id + ':' + $Tool.Id
    if ($Tool.Type -eq 'choice') { $v = $script:State.Choice[$key]; return ($v -and $v -ne 'none') }
    return [bool]$script:State.Sel[$key]
}

function Add-ConsoleLine {
    param([string]$Text, [string]$Tone = 'plain', [string]$Time)
    if (-not $Time) { $Time = (Get-Date).ToString('HH:mm:ss') }
    $color = $script:Colors[$Tone]
    if (-not $color) { $color = $script:Colors.plain }
    $script:ConsoleItems.Add([pscustomobject]@{ Time = $Time; Text = $Text; Color = $color })
    while ($script:ConsoleItems.Count -gt 1500) { $script:ConsoleItems.RemoveAt(0) }
    $script:UI.ConsoleList.ScrollIntoView($script:ConsoleItems[$script:ConsoleItems.Count - 1])
}

function Add-Jobs {
    param($Jobs)
    foreach ($j in @($Jobs)) {
        [void]$script:Sync.Jobs.Add($j)
        Add-ConsoleLine ('Queued: ' + $j.Name) 'muted'
        try { [System.IO.File]::AppendAllText($script:LogFile, ('{0} [queued] {1}{2}' -f (Get-Date).ToString('HH:mm:ss'), $j.Name, [Environment]::NewLine)) } catch { }
    }
    $script:Sync.Version++
}

function Invoke-Tool {
    param([string]$CatId, [string]$ToolId)
    $cat = Get-Cat $CatId
    $tool = $cat.Tools | Where-Object { $_.Id -eq $ToolId } | Select-Object -First 1
    if ($tool) { Add-Jobs @(New-TTJob -Category $cat -Tool $tool) }
}

function Test-ToolBusy {
    param([string]$ToolId)
    foreach ($j in $script:Sync.Jobs.ToArray()) {
        if ($j.ToolId -eq $ToolId -and ($j.Status -eq 'queued' -or $j.Status -eq 'running')) { return $true }
    }
    return $false
}

# ------------------------------------------------------------------ pages ---
function Show-Page {
    param([string]$Id)
    $script:State.Page = $Id
    $script:State.Query = ''
    Update-Nav
    Render-Page
    $script:UI.MainScroll.ScrollToTop()
    $cat = Get-Cat $Id
    if ($cat -and $cat.StatusPanel -and $null -eq $script:State.NetStatus -and -not (Test-ToolBusy 'netstatus')) {
        Invoke-Tool $cat.Id 'netstatus'
    }
}

function Update-Nav {
    foreach ($b in $script:UI.NavPanel.Children) {
        if ($b.Uid -eq $script:State.Page) { $b.Tag = 'active' } else { $b.Tag = '' }
    }
}

function Build-Nav {
    $items = @([pscustomobject]@{ Id = 'home'; Title = 'Home'; Icon = 'home' }) +
        @($script:Catalog | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Title = $_.Title; Icon = $_.Icon } })
    foreach ($it in $items) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $script:Window.FindResource('NavBtn')
        $b.Uid = $it.Id
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $ic = New-Icon -Name $it.Icon -Size 16 -Color '#A9B6C8'
        $ic.Margin = '0,0,8,0'
        [void]$sp.Children.Add($ic)
        [void]$sp.Children.Add((New-Text $it.Title -Weight SemiBold -Color '#E6EDF5'))
        $b.Content = $sp
        $b.Add_Click({ Show-Page $this.Uid })
        [void]$script:UI.NavPanel.Children.Add($b)
    }
}

function Render-Page {
    $script:UI.PagePanel.Children.Clear()
    $script:TabBadges = @{}
    $script:SectionCounts = @()
    $script:StatusHost = $null
    $script:SectionsHost = $null
    $script:HealthHost = $null
    $script:ServerHost = $null
    if ($script:State.Page -eq 'home') { Render-Home } else { Render-Category (Get-Cat $script:State.Page) }
}

function Add-PageHeader {
    param([string]$Eyebrow, [string]$Title, [string]$Blurb)
    $p = $script:UI.PagePanel
    [void]$p.Children.Add((New-Text $Eyebrow.ToUpper() -Size 11 -Color $script:Colors.accent -Mono))
    [void]$p.Children.Add((New-Text $Title -Size 30 -Weight SemiBold -Margin '0,6,0,6'))
    if ($Blurb) { [void]$p.Children.Add((New-Text $Blurb -Size 14 -Color $script:Colors.muted -Wrap -Margin '0,0,0,18')) }
}

function Render-Home {
    Add-PageHeader 'Home' 'What are we fixing today?' 'Pick a category to see its tools. Every run shows up in the Action Center on the right.'
    $wrap = New-Object Windows.Controls.WrapPanel
    $wrap.Margin = '0,8,0,0'
    foreach ($cat in $script:Catalog) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $script:Window.FindResource('TileBtn')
        $b.Uid = $cat.Id
        $sp = New-Object Windows.Controls.StackPanel
        $iconBox = New-Object Windows.Controls.Border
        $iconBox.Width = 44; $iconBox.Height = 44; $iconBox.CornerRadius = 10
        $iconBox.BorderBrush = Get-Brush '#1D5A78'; $iconBox.BorderThickness = 1
        $iconBox.HorizontalAlignment = 'Left'
        $iconBox.Child = (New-Icon -Name $cat.Icon -Size 22 -Color $script:Colors.accent)
        [void]$sp.Children.Add($iconBox)
        [void]$sp.Children.Add((New-Text $cat.LongTitle -Size 19 -Weight SemiBold -Margin '0,14,0,6'))
        [void]$sp.Children.Add((New-Text $cat.Tiles -Color $script:Colors.muted -Wrap))
        if ($cat.ComingSoon) { $foot = 'Coming soon' ; $fc = $script:Colors.dim }
        else { $foot = ('{0} tools  >' -f @($cat.Tools | Where-Object { -not $_.Hidden }).Count); $fc = $script:Colors.accent }
        [void]$sp.Children.Add((New-Text $foot -Size 12 -Color $fc -Mono -Margin '0,16,0,0'))
        $b.Content = $sp
        $b.Add_Click({ Show-Page $this.Uid })
        [void]$wrap.Children.Add($b)
    }
    [void]$script:UI.PagePanel.Children.Add($wrap)
    if (-not $script:IsAdmin) {
        [void]$script:UI.PagePanel.Children.Add((New-Text 'Not running as administrator. Most repairs need admin rights: close this window and start TechTools again with "Run as administrator".' -Color $script:Colors.warn -Wrap -Margin '0,10,0,0'))
    }
}

function New-Card {
    param([double]$Width = 0, [string]$Padding = '16')
    $c = New-Object Windows.Controls.Border
    $c.Background = Get-Brush '#0E1520'
    $c.BorderBrush = Get-Brush $script:Colors.line
    $c.BorderThickness = 1
    $c.CornerRadius = 14
    $c.Padding = $Padding
    if ($Width -gt 0) { $c.Width = $Width }
    return $c
}

function New-Button {
    param([string]$Text, [string]$Style = 'Btn', [string]$Icon, [string]$IconColor = '#E6EDF5')
    $b = New-Object Windows.Controls.Button
    $b.Style = $script:Window.FindResource($Style)
    if ($Icon) {
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $ic = New-Icon -Name $Icon -Size 14 -Color $IconColor
        $ic.Margin = '0,0,8,0'
        [void]$sp.Children.Add($ic)
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = $Text
        $tb.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($tb)
        $b.Content = $sp
    } else { $b.Content = $Text }
    return $b
}

function Render-Category {
    param($Cat)
    Add-PageHeader ('Home / ' + $Cat.Title) $Cat.LongTitle $Cat.Blurb
    $p = $script:UI.PagePanel
    if ($Cat.ComingSoon) {
        $card = New-Card -Padding '22'
        $sp = New-Object Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Text 'Coming soon' -Size 17 -Weight SemiBold))
        [void]$sp.Children.Add((New-Text ('The ' + $Cat.LongTitle + ' tools are planned (' + $Cat.Tiles + '). This version ships Internet Issues first.') -Color $script:Colors.muted -Wrap -Margin '0,6,0,0'))
        $card.Child = $sp
        [void]$p.Children.Add($card)
        return
    }
    $current = Get-CurrentTab $Cat

    # Sub-section tabs
    if ($Cat.Tabs.Count -gt 1 -or $Cat.Tabs[0].Id -ne 'main') {
        $bar = New-Object Windows.Controls.Border
        $bar.BorderBrush = Get-Brush $script:Colors.line
        $bar.BorderThickness = '0,0,0,1'
        $bar.Margin = '0,0,0,18'
        $tw = New-Object Windows.Controls.WrapPanel
        foreach ($tab in $Cat.Tabs) {
            $b = New-Object Windows.Controls.Button
            $b.Style = $script:Window.FindResource('TabBtn')
            $b.Uid = $tab.Id
            $b.Margin = '0,0,0,-1'
            if ($tab.Id -eq $current) { $b.Tag = 'active' }
            $sp = New-Object Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $tt = New-Object Windows.Controls.TextBlock
            $tt.Text = $tab.Title
            $tt.VerticalAlignment = 'Center'
            [void]$sp.Children.Add($tt)
            $badge = New-Object Windows.Controls.Border
            $badge.Background = Get-Brush '#0E2A3A'
            $badge.CornerRadius = 9
            $badge.Padding = '7,1'
            $badge.Margin = '8,0,0,0'
            $badge.Visibility = 'Collapsed'
            $bt = New-Text '0' -Size 11 -Color $script:Colors.accent -Mono
            $badge.Child = $bt
            [void]$sp.Children.Add($badge)
            $script:TabBadges[$tab.Id] = @{ Border = $badge; Text = $bt }
            $b.Content = $sp
            $b.Add_Click({
                $script:State.Tab[$script:State.Page] = $this.Uid
                $script:State.Query = ''
                Render-Page
            })
            [void]$tw.Children.Add($b)
        }
        $bar.Child = $tw
        [void]$p.Children.Add($bar)
    }

    # Live status panel (Internet)
    if ($Cat.StatusPanel) {
        $script:StatusHost = New-Object Windows.Controls.StackPanel
        $script:StatusHost.Margin = '0,0,0,18'
        [void]$p.Children.Add($script:StatusHost)
        Render-Status
    }

    # Clear: reset Diagnostics results as if TechTools was just opened
    $hasReports = @($Cat.Tools | Where-Object { ($_.Effect -eq 'serverstatus' -or $_.Effect -eq 'healthreport') -and $_.Tab -eq $current }).Count -gt 0
    $busyReports = $null -ne (Get-BusyReportTool) -or (Test-ToolBusy 'servercheck') -or (Test-ToolBusy 'serverreauth')
    if ($hasReports -and ($script:State.Health -or $script:State.Server -or $script:State.HealthError -or $script:State.ServerError) -and -not $busyReports) {
        $clr = New-Button 'Clear' -Icon 'trash'
        $clr.HorizontalAlignment = 'Right'
        $clr.Margin = '0,-6,0,12'
        $clr.ToolTip = 'Clear results, finished actions and the console, as if TechTools was just opened. The session log file is kept.'
        $clr.Add_Click({ Clear-Diagnostics })
        [void]$p.Children.Add($clr)
    }

    # Office server card (Windows > Diagnostics)
    if (@($Cat.Tools | Where-Object { $_.Effect -eq 'serverstatus' -and -not $_.Hidden -and $_.Tab -eq $current }).Count -gt 0) {
        $script:ServerHost = New-Object Windows.Controls.StackPanel
        [void]$p.Children.Add($script:ServerHost)
        Render-Server
    }

    # Quick actions for this tab
    $quick = @($Cat.Tools | Where-Object { $_.Type -eq 'quick' -and -not $_.Hidden -and $_.Tab -eq $current })
    if ($quick.Count -gt 0 -and @($quick | Where-Object { $_.Group }).Count -gt 0) {
        # Equal-size tiles grouped under headings (Windows > Diagnostics)
        [void]$p.Children.Add((New-Text 'QUICK ACTIONS - RUN IMMEDIATELY' -Size 11 -Color $script:Colors.muted -Mono -Margin '0,0,0,8'))
        $groups = @()
        foreach ($q in $quick) { $g = $q.Group; if (-not $g) { $g = 'More' }; if ($groups -notcontains $g) { $groups += $g } }
        foreach ($g in $groups) {
            $head = New-Object Windows.Controls.Border
            $head.BorderBrush = Get-Brush $script:Colors.line
            $head.BorderThickness = '0,0,0,1'
            $head.Padding = '0,0,0,4'
            $head.Margin = '0,4,0,8'
            $head.Child = (New-Text $g -Size 14 -Weight SemiBold -Color $script:Colors.accent)
            [void]$p.Children.Add($head)
            $qw = New-Object Windows.Controls.WrapPanel
            $qw.Margin = '0,0,0,8'
            foreach ($q in @($quick | Where-Object { $(if ($_.Group) { $_.Group } else { 'More' }) -eq $g })) {
                [void]$qw.Children.Add((New-QuickTile $q))
            }
            [void]$p.Children.Add($qw)
        }
    } elseif ($quick.Count -gt 0) {
        [void]$p.Children.Add((New-Text 'QUICK ACTIONS - RUN IMMEDIATELY' -Size 11 -Color $script:Colors.muted -Mono -Margin '0,0,0,8'))
        $qw = New-Object Windows.Controls.WrapPanel
        $qw.Margin = '0,0,0,18'
        foreach ($q in $quick) {
            $b = New-Object Windows.Controls.Button
            $b.Style = $script:Window.FindResource('Btn')
            $b.Padding = '14,8'
            $b.Margin = '0,0,10,10'
            $b.Uid = $q.Id
            if ($q.Info) { $b.ToolTip = $q.Info }
            $sp = New-Object Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $ic = New-Icon -Name 'bolt' -Size 16 -Color $script:Colors.accent
            $ic.Margin = '0,0,10,0'
            [void]$sp.Children.Add($ic)
            $tx = New-Object Windows.Controls.StackPanel
            $label = $q.Label
            if ($q.Restart) { $label += '  (restart)' }
            [void]$tx.Children.Add((New-Text $label -Weight SemiBold))
            if ($q.Cmd) { [void]$tx.Children.Add((New-Text $q.Cmd -Size 11 -Color $script:Colors.muted -Mono)) }
            [void]$sp.Children.Add($tx)
            $b.Content = $sp
            $b.Add_Click({ Invoke-QuickTool $this.Uid })
            [void]$qw.Children.Add($b)
        }
        [void]$p.Children.Add($qw)
    }

    # Notices for buttons pressed this session (for example an installer password)
    foreach ($q in $quick) {
        if ($q.Notice -and $script:State.Notices[$q.Id]) { [void]$p.Children.Add((New-NoticeCard $q)) }
    }

    # PC health report (Windows > Diagnostics)
    if (@($Cat.Tools | Where-Object { $_.Effect -eq 'healthreport' -and $_.Tab -eq $current }).Count -gt 0) {
        $script:HealthHost = New-Object Windows.Controls.StackPanel
        [void]$p.Children.Add($script:HealthHost)
        Render-Health
    }

    # Tabs with only quick actions (or reports) skip the checklist toolbar.
    $pickable = @($Cat.Tools | Where-Object { $_.Type -ne 'quick' -and -not $_.Hidden })
    if ($pickable.Count -eq 0) { return }

    # Toolbar
    $tb = New-Object Windows.Controls.Border
    $tb.Background = Get-Brush '#0A1019'
    $tb.BorderBrush = Get-Brush $script:Colors.line
    $tb.BorderThickness = 1
    $tb.CornerRadius = 12
    $tb.Padding = '10'
    $tb.Margin = '0,0,0,16'
    $dock = New-Object Windows.Controls.DockPanel
    $run = New-Button 'Run selected' -Style 'PrimaryBtn' -Icon 'play' -IconColor '#04121A'
    $run.Padding = '18,0'
    $run.Margin = '10,0,0,0'
    [Windows.Controls.DockPanel]::SetDock($run, 'Right')
    $run.Add_Click({ Start-Selected })
    $script:RunBtn = $run
    [void]$dock.Children.Add($run)
    $script:SelCountText = New-Text '' -Size 12 -Color $script:Colors.muted -Mono -Margin '10,0,0,0'
    $script:SelCountText.VerticalAlignment = 'Center'
    $script:SelCountText.ToolTip = 'Picks are kept when you switch tabs, and run together.'
    [Windows.Controls.DockPanel]::SetDock($script:SelCountText, 'Right')
    [void]$dock.Children.Add($script:SelCountText)
    $def = New-Button 'Select defaults'
    $def.Margin = '0,0,8,0'
    $def.Add_Click({ Set-TabSelection -Defaults })
    [Windows.Controls.DockPanel]::SetDock($def, 'Left')
    [void]$dock.Children.Add($def)
    $clr = New-Button 'Clear selection'
    $clr.Margin = '0,0,8,0'
    $clr.Add_Click({ Set-TabSelection })
    [Windows.Controls.DockPanel]::SetDock($clr, 'Left')
    [void]$dock.Children.Add($clr)
    $search = New-Object Windows.Controls.TextBox
    $search.Style = $script:Window.FindResource('SearchBox')
    $search.Tag = 'Search all ' + $Cat.Title + ' tools'
    $search.Text = $script:State.Query
    $search.Add_TextChanged({ $script:State.Query = $this.Text; Render-Sections })
    [void]$dock.Children.Add($search)
    $tb.Child = $dock
    [void]$p.Children.Add($tb)

    $script:SectionsHost = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add($script:SectionsHost)
    Render-Sections
}

function Render-Sections {
    $host_ = $script:SectionsHost
    if ($null -eq $host_) { return }
    $host_.Children.Clear()
    $script:SectionCounts = @()
    $cat = Get-Cat $script:State.Page
    $current = Get-CurrentTab $cat
    $q = ([string]$script:State.Query).Trim().ToLower()
    $tabTitles = @{}
    foreach ($t in $cat.Tabs) { $tabTitles[$t.Id] = $t.Title }

    $tools = @($cat.Tools | Where-Object { $_.Type -ne 'quick' -and -not $_.Hidden })
    if ($q) {
        $tools = @($tools | Where-Object { ($_.Label + ' ' + $_.Info + ' ' + $_.Cmd + ' ' + $_.Package + ' ' + $_.Section).ToLower().Contains($q) })
    } else {
        $tools = @($tools | Where-Object { $_.Tab -eq $current })
    }
    if ($tools.Count -eq 0) {
        $msg = 'Nothing on this tab yet.'
        if ($q) { $msg = 'No tools match that search.' }
        [void]$host_.Children.Add((New-Text $msg -Color $script:Colors.muted))
        Update-Counts
        return
    }

    $order = New-Object System.Collections.ArrayList
    $groups = @{}
    foreach ($t in $tools) {
        $name = $t.Section
        if ($q -and $cat.Tabs.Count -gt 1) { $name = $tabTitles[$t.Tab] + ' - ' + $t.Section }
        if (-not $groups.ContainsKey($name)) { $groups[$name] = New-Object System.Collections.ArrayList; [void]$order.Add($name) }
        [void]$groups[$name].Add($t)
    }

    if (-not $q) {
        Render-SidePane $cat $order $groups
        Update-Counts
        return
    }

    # Search results: matching tools from every section, as cards
    $wrap = New-Object Windows.Controls.WrapPanel
    [void]$host_.Children.Add($wrap)
    foreach ($name in $order) {
        $card = New-Card -Width 380
        $card.Margin = '0,0,16,16'
        $card.VerticalAlignment = 'Top'
        $sp = New-Object Windows.Controls.StackPanel
        $hd = New-Object Windows.Controls.DockPanel
        $hd.Margin = '6,0,4,0'
        $cnt = New-Text '' -Size 11 -Color $script:Colors.muted -Mono
        $cnt.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
        [void]$hd.Children.Add($cnt)
        # Section header in the accent color, underlined, so it stands apart from the tweaks
        [void]$hd.Children.Add((New-Text $name -Size 15 -Weight SemiBold -Color $script:Colors.accent))
        $hdLine = New-Object Windows.Controls.Border
        $hdLine.BorderBrush = Get-Brush $script:Colors.line; $hdLine.BorderThickness = '0,0,0,1'
        $hdLine.Padding = '0,0,0,8'; $hdLine.Margin = '0,0,0,6'; $hdLine.Child = $hd
        [void]$sp.Children.Add($hdLine)
        $script:SectionCounts += @{ Text = $cnt; Tools = @($groups[$name]) }

        foreach ($t in $groups[$name]) { [void]$sp.Children.Add((New-ToolItem $cat $t)) }
        $card.Child = $sp
        [void]$wrap.Children.Add($card)
    }
    Update-Counts
}

function Render-SidePane {
    # Side menu of sections on the left, the chosen section's tools on the right.
    param($cat, $order, $groups)
    $current = Get-CurrentTab $cat
    $paneKey = $cat.Id + ':' + $current
    $chosen = $script:State.Pane[$paneKey]
    if (-not $chosen -or -not $groups.ContainsKey($chosen)) { $chosen = $order[0] }

    $frame = New-Card -Padding '0'
    $grid = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '240'
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = '*'
    [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
    $grid.MinHeight = 360

    $navBorder = New-Object Windows.Controls.Border
    $navBorder.Background = Get-Brush '#0A1019'
    $navBorder.BorderBrush = Get-Brush $script:Colors.line
    $navBorder.BorderThickness = '0,0,1,0'
    $navBorder.CornerRadius = '14,0,0,14'
    $navBorder.Padding = '8'
    $nav = New-Object Windows.Controls.StackPanel
    foreach ($name in $order) {
        $active = ($name -eq $chosen)
        $b = New-Object Windows.Controls.Button
        $b.Style = $script:Window.FindResource('Btn')
        $b.HorizontalContentAlignment = 'Stretch'
        $b.Padding = '10,8'
        $b.Margin = '0,0,0,4'
        $b.BorderThickness = '3,0,0,0'
        if ($active) { $b.Background = Get-Brush '#12324A'; $b.BorderBrush = Get-Brush $script:Colors.accent }
        else { $b.Background = Get-Brush 'Transparent'; $b.BorderBrush = Get-Brush 'Transparent' }
        $row = New-Object Windows.Controls.DockPanel
        $cnt = New-Text '' -Size 11 -Color $script:Colors.muted -Mono
        $cnt.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
        [void]$row.Children.Add($cnt)
        $nm = New-Text $name
        $nm.TextTrimming = 'CharacterEllipsis'
        if ($active) { $nm.FontWeight = 'SemiBold' }
        [void]$row.Children.Add($nm)
        $b.Content = $row
        $b.Tag = $name
        $b.Add_Click({ $script:State.Pane[(Get-PaneKey)] = [string]$this.Tag; Render-Sections })
        [void]$nav.Children.Add($b)
        $script:SectionCounts += @{ Text = $cnt; Tools = @($groups[$name]) }
    }
    $navBorder.Child = $nav
    [Windows.Controls.Grid]::SetColumn($navBorder, 0)
    [void]$grid.Children.Add($navBorder)

    $right = New-Object Windows.Controls.StackPanel
    $right.Margin = '18,14,18,16'
    $hd = New-Object Windows.Controls.DockPanel
    $cnt = New-Text '' -Size 11 -Color $script:Colors.muted -Mono
    $cnt.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
    [void]$hd.Children.Add($cnt)
    [void]$hd.Children.Add((New-Text $chosen -Size 16 -Weight SemiBold -Color $script:Colors.accent))
    $hdLine = New-Object Windows.Controls.Border
    $hdLine.BorderBrush = Get-Brush $script:Colors.line; $hdLine.BorderThickness = '0,0,0,1'
    $hdLine.Padding = '0,0,0,8'; $hdLine.Margin = '0,0,0,8'; $hdLine.Child = $hd
    [void]$right.Children.Add($hdLine)
    $script:SectionCounts += @{ Text = $cnt; Tools = @($groups[$chosen]) }
    $items = New-Object Windows.Controls.WrapPanel
    foreach ($t in $groups[$chosen]) {
        $el = New-ToolItem $cat $t -Compact
        $el.Width = 300
        $el.Margin = '0,4,16,6'
        [void]$items.Children.Add($el)
    }
    [void]$right.Children.Add($items)
    [Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$grid.Children.Add($right)

    $frame.Child = $grid
    [void]$script:SectionsHost.Children.Add($frame)
}

function Get-PaneKey {
    $cat = Get-Cat $script:State.Page
    return ($cat.Id + ':' + (Get-CurrentTab $cat))
}

function New-ToolItem {
    # One checkbox or dropdown for a tool. -Compact leaves out the command line (it shows on hover).
    param($cat, $t, [switch]$Compact)
    $key = $cat.Id + ':' + $t.Id
    if ($t.Type -eq 'choice') {
        $box = New-Object Windows.Controls.StackPanel
        $box.Margin = '8,6,8,8'
        if ($t.Info) { $box.ToolTip = $t.Info }
        [void]$box.Children.Add((New-Text $t.Label -Margin '0,0,0,6'))
        $cb = New-Object Windows.Controls.ComboBox
        $cb.Tag = $key
        $none = New-Object Windows.Controls.ComboBoxItem
        $none.Content = 'No change'; $none.Tag = 'none'
        [void]$cb.Items.Add($none)
        $sel = 0; $i = 1
        foreach ($o in $t.Options) {
            $it = New-Object Windows.Controls.ComboBoxItem
            $it.Content = $o.Label; $it.Tag = $o.Value
            [void]$cb.Items.Add($it)
            if ($script:State.Choice[$key] -eq $o.Value) { $sel = $i }
            $i++
        }
        $cb.SelectedIndex = $sel
        $cb.Add_SelectionChanged({
            if ($this.SelectedItem) { $script:State.Choice[[string]$this.Tag] = [string]$this.SelectedItem.Tag }
            Update-Counts
        })
        [void]$box.Children.Add($cb)
        return $box
    } else {
        $chk = New-Object Windows.Controls.CheckBox
        $chk.Tag = $key
        $chk.IsChecked = [bool]$script:State.Sel[$key]
        if ($t.Info) { $chk.ToolTip = $t.Info }
        $content = New-Object Windows.Controls.StackPanel
        $line = New-Object Windows.Controls.WrapPanel
        [void]$line.Children.Add((New-Text $t.Label -Wrap))
        if ($t.Restart) {
            $chip = New-Object Windows.Controls.Border
            $chip.BorderBrush = Get-Brush '#5A4A1F'; $chip.BorderThickness = 1; $chip.CornerRadius = 8
            $chip.Padding = '6,0'; $chip.Margin = '8,1,0,0'; $chip.VerticalAlignment = 'Center'
            $chip.Child = (New-Text 'RESTART' -Size 9 -Color $script:Colors.warn -Mono)
            [void]$line.Children.Add($chip)
        }
        [void]$content.Children.Add($line)
        if ($t.Cmd -and -not $Compact) { [void]$content.Children.Add((New-Text $t.Cmd -Size 11 -Color $script:Colors.muted -Mono -Wrap -Margin '0,2,0,0')) }
        if ($Compact -and $t.Cmd) { $chk.ToolTip = ((([string]$t.Info) + [Environment]::NewLine + $t.Cmd).Trim()) }
        $chk.Content = $content
        $chk.Add_Click({ $script:State.Sel[[string]$this.Tag] = [bool]$this.IsChecked; Update-Counts })
        return $chk
    }
}

function Update-Counts {
    $cat = Get-Cat $script:State.Page
    if (-not $cat -or $cat.ComingSoon) { return }
    $total = 0
    $perTab = @{}
    foreach ($t in $cat.Tools) {
        if (Test-Picked $cat $t) { $total++; $perTab[$t.Tab] = 1 + [int]$perTab[$t.Tab] }
    }
    foreach ($id in @($script:TabBadges.Keys)) {
        $n = [int]$perTab[$id]
        $script:TabBadges[$id].Text.Text = [string]$n
        if ($n -gt 0) { $script:TabBadges[$id].Border.Visibility = 'Visible' } else { $script:TabBadges[$id].Border.Visibility = 'Collapsed' }
    }
    foreach ($sc in $script:SectionCounts) {
        $picked = @($sc.Tools | Where-Object { Test-Picked $cat $_ }).Count
        $sc.Text.Text = ('{0}/{1}' -f $picked, @($sc.Tools).Count)
    }
    if ($script:SelCountText) { $script:SelCountText.Text = ('{0} selected in {1}' -f $total, $cat.Title) }
    if ($script:RunBtn) { $script:RunBtn.IsEnabled = ($total -gt 0) }
}

function Set-TabSelection {
    param([switch]$Defaults)
    $cat = Get-Cat $script:State.Page
    $current = Get-CurrentTab $cat
    foreach ($t in @($cat.Tools | Where-Object { $_.Tab -eq $current -and $_.Type -ne 'quick' })) {
        $key = $cat.Id + ':' + $t.Id
        if ($t.Type -eq 'choice') {
            if ($Defaults) { $script:State.Choice[$key] = $t.Default } else { $script:State.Choice.Remove($key) }
        } else {
            if ($Defaults -and $t.Type -eq 'check') { $script:State.Sel[$key] = [bool]$t.Default } else { $script:State.Sel.Remove($key) }
        }
    }
    Render-Sections
}

function Start-Selected {
    $cat = Get-Cat $script:State.Page
    $jobs = Get-TTSelectionJobs -Category $cat -Sel $script:State.Sel -Choice $script:State.Choice
    if ($jobs.Count -eq 0) { return }
    Add-Jobs $jobs
}

# ---------------------------------------------------- Internet status panel ---
function Render-Status {
    $h = $script:StatusHost
    if ($null -eq $h) { return }
    $h.Children.Clear()
    $cat = Get-Cat $script:State.Page

    $card = New-Card -Padding '16'
    $card.Background = Get-Brush '#0A1019'
    $sp = New-Object Windows.Controls.StackPanel

    $top = New-Object Windows.Controls.DockPanel
    $top.Margin = '0,0,0,12'
    $btns = New-Object Windows.Controls.StackPanel
    $btns.Orientation = 'Horizontal'
    [Windows.Controls.DockPanel]::SetDock($btns, 'Right')
    $busy = (Test-ToolBusy 'netstatus') -or (Test-ToolBusy 'diagnose')
    $ref = New-Button 'Refresh' -Icon 'refresh'
    $ref.Margin = '0,0,8,0'
    $ref.IsEnabled = -not $busy
    $ref.Add_Click({ Invoke-Tool $script:State.Page 'netstatus'; Render-Status })
    [void]$btns.Children.Add($ref)
    $dg = New-Button 'Run full diagnosis' -Icon 'pulse' -IconColor $script:Colors.accent
    $dg.BorderBrush = Get-Brush $script:Colors.accent
    $dg.Background = Get-Brush '#0E2A3A'
    $dg.IsEnabled = -not $busy
    $dg.Add_Click({ Invoke-Tool $script:State.Page 'diagnose'; Render-Status })
    [void]$btns.Children.Add($dg)
    [void]$top.Children.Add($btns)
    $titles = New-Object Windows.Controls.StackPanel
    $titles.Orientation = 'Horizontal'
    [void]$titles.Children.Add((New-Text 'Connection status' -Size 16 -Weight SemiBold))
    $checked = $script:State.NetChecked
    if ($busy) { $checked = 'Checking...' }
    $ct = New-Text $checked -Size 11 -Color $script:Colors.muted -Mono -Margin '12,0,0,0'
    $ct.VerticalAlignment = 'Center'
    [void]$titles.Children.Add($ct)
    [void]$top.Children.Add($titles)
    [void]$sp.Children.Add($top)

    $grid = New-Object Windows.Controls.WrapPanel
    foreach ($c in (Get-TTStatusCards $script:State.NetStatus)) {
        $col = $script:Colors[$c.Level]
        $b = New-Card -Width 186 -Padding '12'
        $b.CornerRadius = 10
        $b.Margin = '0,0,10,10'
        if ($c.Level -eq 'warn') { $b.BorderBrush = Get-Brush '#5A4A1F' }
        if ($c.Level -eq 'fail') { $b.BorderBrush = Get-Brush '#5A2626' }
        $cs = New-Object Windows.Controls.StackPanel
        $lab = New-Object Windows.Controls.StackPanel
        $lab.Orientation = 'Horizontal'
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8; $dot.Fill = Get-Brush $col; $dot.Margin = '0,0,6,0'; $dot.VerticalAlignment = 'Center'
        [void]$lab.Children.Add($dot)
        [void]$lab.Children.Add((New-Text $c.Label.ToUpper() -Size 11 -Color $script:Colors.muted -Mono))
        [void]$cs.Children.Add($lab)
        $v = New-Text ([string]$c.Value) -Size 15 -Weight SemiBold -Margin '0,4,0,2'
        $v.TextTrimming = 'CharacterEllipsis'
        $v.ToolTip = [string]$c.Value
        [void]$cs.Children.Add($v)
        $dcol = $script:Colors.muted
        if ($c.Level -eq 'warn' -or $c.Level -eq 'fail') { $dcol = $col }
        $d = New-Text ([string]$c.Detail) -Size 12 -Color $dcol
        $d.TextTrimming = 'CharacterEllipsis'
        $d.ToolTip = [string]$c.Detail
        [void]$cs.Children.Add($d)
        $b.Child = $cs
        [void]$grid.Children.Add($b)
    }
    [void]$sp.Children.Add($grid)

    $diag = $script:State.Diag
    if ($diag) {
        $dc = New-Card -Padding '14'
        $dc.CornerRadius = 10
        $dc.Margin = '0,4,0,0'
        if ($diag.Problems -gt 0) { $dc.BorderBrush = Get-Brush '#5A4A1F' } else { $dc.BorderBrush = Get-Brush '#1F4D3D' }
        $ds = New-Object Windows.Controls.StackPanel
        $title = 'Diagnosis: no problems found'
        if ($diag.Problems -eq 1) { $title = 'Diagnosis: 1 problem found' }
        elseif ($diag.Problems -gt 1) { $title = ('Diagnosis: {0} problems found' -f $diag.Problems) }
        $dh = New-Object Windows.Controls.DockPanel
        $when = New-Text ('Ran ' + $diag.At) -Size 11 -Color $script:Colors.muted -Mono
        [Windows.Controls.DockPanel]::SetDock($when, 'Right')
        [void]$dh.Children.Add($when)
        [void]$dh.Children.Add((New-Text $title -Size 15 -Weight SemiBold))
        $dh.Margin = '0,0,0,8'
        [void]$ds.Children.Add($dh)
        foreach ($f in $diag.Findings) {
            $row = New-Object Windows.Controls.DockPanel
            $row.Margin = '0,2,0,2'
            $mark = [string][char]0x2713
            if ($f.Level -eq 'warn') { $mark = '!' }
            if ($f.Level -eq 'fail') { $mark = [string][char]0x2715 }
            $m = New-Text $mark -Weight Bold -Color $script:Colors[$f.Level] -Mono -Margin '0,0,10,0'
            $m.Width = 14
            [Windows.Controls.DockPanel]::SetDock($m, 'Left')
            [void]$row.Children.Add($m)
            [void]$row.Children.Add((New-Text $f.Text -Wrap))
            [void]$ds.Children.Add($row)
        }
        if (@($diag.Recommend).Count -gt 0) {
            $names = @()
            foreach ($r in $diag.Recommend) {
                $tool = $cat.Tools | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
                if ($tool) {
                    $n = $tool.Label
                    if ($r.Value) { $o = $tool.Options | Where-Object { $_.Value -eq $r.Value } | Select-Object -First 1; if ($o) { $n = 'DNS: ' + $o.Label } }
                    $names += $n
                }
            }
            $fx = New-Object Windows.Controls.DockPanel
            $fx.Margin = '0,10,0,0'
            $apply = New-Button 'Select recommended fixes' -Style 'PrimaryBtn'
            $apply.Margin = '10,0,0,0'
            [Windows.Controls.DockPanel]::SetDock($apply, 'Right')
            $apply.Add_Click({ Select-Recommended })
            [void]$fx.Children.Add($apply)
            $rt = New-Text ('Recommended: ' + ($names -join ', ')) -Color '#C9D4E3' -Wrap
            $rt.VerticalAlignment = 'Center'
            [void]$fx.Children.Add($rt)
            [void]$ds.Children.Add($fx)
        }
        $dc.Child = $ds
        [void]$sp.Children.Add($dc)
    }
    $card.Child = $sp
    [void]$h.Children.Add($card)
}

# ------------------------------------------------------- Office server ---
$script:ServerConfigPath = Join-Path $env:ProgramData 'MAVTechTools\server.json'

function New-QuickTile {
    # One equal-size tile: icon box, label, short description.
    param($Tool)
    $b = New-Object Windows.Controls.Button
    $b.Style = $script:Window.FindResource('Btn')
    $b.Width = 300
    $b.Height = 76
    $b.Margin = '0,0,10,10'
    $b.Padding = '14,0'
    $b.HorizontalContentAlignment = 'Stretch'
    $b.Uid = $Tool.Id
    if ($Tool.Info) { $b.ToolTip = $Tool.Info }
    $grid = New-Object Windows.Controls.DockPanel
    $box = New-Object Windows.Controls.Border
    $box.Width = 40; $box.Height = 40
    $box.CornerRadius = 10
    $box.BorderThickness = 1
    $box.BorderBrush = Get-Brush '#1D5A78'
    $box.Background = Get-Brush '#0A1622'
    $box.Margin = '0,0,12,0'
    $icon = 'bolt'
    if ($Tool.Icon -and $script:Icons.ContainsKey($Tool.Icon)) { $icon = $Tool.Icon }
    $ic = New-Icon -Name $icon -Size 20 -Color $script:Colors.accent
    $ic.HorizontalAlignment = 'Center'; $ic.VerticalAlignment = 'Center'
    $box.Child = $ic
    [Windows.Controls.DockPanel]::SetDock($box, 'Left')
    [void]$grid.Children.Add($box)
    $tx = New-Object Windows.Controls.StackPanel
    $tx.VerticalAlignment = 'Center'
    $label = $Tool.Label
    if ($Tool.Restart) { $label += '  (restart)' }
    $lt = New-Text $label -Weight SemiBold
    $lt.TextTrimming = 'CharacterEllipsis'
    [void]$tx.Children.Add($lt)
    if ($Tool.Cmd) {
        $ct = New-Text $Tool.Cmd -Size 12 -Color $script:Colors.muted -Wrap -Margin '0,3,0,0'
        $ct.MaxHeight = 32
        $ct.TextTrimming = 'CharacterEllipsis'
        [void]$tx.Children.Add($ct)
    }
    [void]$grid.Children.Add($tx)
    $b.Content = $grid
    $b.Add_Click({ Invoke-QuickTool $this.Uid })
    return $b
}

function New-NoticeCard {
    # Card with a title, a line of text and an optional value with a Copy button.
    param($Tool)
    $n = $Tool.Notice
    $card = New-Card -Padding '18'
    $card.Background = Get-Brush '#0A1019'
    $card.BorderBrush = Get-Brush '#1D5A78'
    $card.Margin = '0,0,0,16'
    $dock = New-Object Windows.Controls.DockPanel
    $hide = New-Button 'Hide'
    $hide.VerticalAlignment = 'Top'
    $hide.Tag = $Tool.Id
    $hide.Add_Click({ $script:State.Notices.Remove([string]$this.Tag); Render-Page })
    [Windows.Controls.DockPanel]::SetDock($hide, 'Right')
    [void]$dock.Children.Add($hide)
    $sp = New-Object Windows.Controls.StackPanel
    $title = $n.Title
    if (-not $title) { $title = $Tool.Label }
    [void]$sp.Children.Add((New-Text $title.ToUpper() -Size 11 -Color $script:Colors.accent -Mono))
    if ($n.Text) { [void]$sp.Children.Add((New-Text $n.Text -Color $script:Colors.plain -Wrap -Margin '0,6,0,0')) }
    if ($n.Copy) {
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = '0,10,0,0'
        $box = New-Object Windows.Controls.TextBox
        $box.Text = $n.Copy
        $box.IsReadOnly = $true
        $box.FontFamily = 'Consolas'
        $box.FontSize = 20
        $box.Padding = '12,6'
        $box.Background = Get-Brush '#0E1520'
        $box.Foreground = Get-Brush $script:Colors.text
        $box.BorderBrush = Get-Brush '#263449'
        $box.VerticalContentAlignment = 'Center'
        [void]$row.Children.Add($box)
        $copy = New-Button 'Copy' -Style 'PrimaryBtn' -Icon 'file' -IconColor '#04121A'
        $copy.Margin = '10,0,0,0'
        $copy.Tag = $n.Copy
        $copy.Add_Click({
            try { [Windows.Clipboard]::SetText([string]$this.Tag); Add-ConsoleLine 'Copied to the clipboard.' 'ok' }
            catch { Add-ConsoleLine ('Could not copy: ' + $_.Exception.Message) 'warn' }
        })
        [void]$row.Children.Add($copy)
        [void]$sp.Children.Add($row)
    }
    [void]$dock.Children.Add($sp)
    $card.Child = $dock
    return $card
}

function Clear-Diagnostics {
    $script:State.Health = $null
    $script:State.HealthError = ''
    $script:State.Server = $null
    $script:State.ServerError = ''
    foreach ($j in $script:Sync.Jobs.ToArray()) { if ($j.Status -ne 'queued' -and $j.Status -ne 'running') { $script:Sync.Jobs.Remove($j) } }
    $script:Sync.Version++
    $script:ConsoleItems.Clear()
    Add-ConsoleLine 'Cleared. Ready for the next check.' 'muted'
    Render-Page
    $script:UI.MainScroll.ScrollToTop()
}

function Invoke-QuickTool {
    param([string]$Id)
    if ($Id -eq 'servercheck' -and -not (Get-ServerConfig)) {
        if (-not (Show-ServerSetup)) { return }
    }
    Invoke-Tool $script:State.Page $Id
    $tool = @((Get-Cat $script:State.Page).Tools | Where-Object { $_.Id -eq $Id })[0]
    if ($tool -and $tool.Notice -and -not $script:State.Notices[$Id]) { $script:State.Notices[$Id] = $true; Render-Page; return }
    if ($script:HealthHost) { Render-Health }
    if ($script:ServerHost) { Render-Server }
}

function Get-ServerConfig {
    if (-not (Test-Path -LiteralPath $script:ServerConfigPath)) { return $null }
    try { $c = [System.IO.File]::ReadAllText($script:ServerConfigPath) | ConvertFrom-Json } catch { return $null }
    if (-not $c.Unc) { return $null }
    return $c
}

function New-Dialog {
    # A small dark dialog. Returns @{ Window; Panel } ; add fields to Panel.
    param([string]$Title, [string]$Message, [string]$OkText = 'OK')
    $w = New-Object Windows.Window
    $w.Title = 'MAV TechTools - ' + $Title
    $w.Width = 480
    $w.SizeToContent = 'Height'
    $w.ResizeMode = 'NoResize'
    $w.WindowStartupLocation = 'CenterOwner'
    $w.Background = Get-Brush '#0A1019'
    $w.FontFamily = 'Segoe UI'
    $w.Resources = $script:Window.Resources
    try { $w.Owner = $script:Window } catch { $w.WindowStartupLocation = 'CenterScreen' }
    $outer = New-Object Windows.Controls.StackPanel
    $outer.Margin = '24,20,24,20'
    [void]$outer.Children.Add((New-Text $Title -Size 18 -Weight SemiBold))
    if ($Message) { [void]$outer.Children.Add((New-Text $Message -Color $script:Colors.muted -Wrap -Margin '0,6,0,14')) }
    $panel = New-Object Windows.Controls.StackPanel
    [void]$outer.Children.Add($panel)
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = '0,18,0,0'
    $cancel = New-Button 'Cancel'
    $cancel.IsCancel = $true
    $cancel.Margin = '0,0,8,0'
    [void]$row.Children.Add($cancel)
    $ok = New-Button $OkText -Style 'PrimaryBtn'
    $ok.IsDefault = $true
    $ok.Padding = '16,0'
    $ok.Tag = $w
    $ok.Add_Click({ $this.Tag.DialogResult = $true })
    [void]$row.Children.Add($ok)
    [void]$outer.Children.Add($row)
    $w.Content = $outer
    return @{ Window = $w; Panel = $panel }
}

function Add-DialogField {
    param($Dialog, [string]$Label, [string]$Value = '', [switch]$Password, [string]$Hint = '')
    [void]$Dialog.Panel.Children.Add((New-Text $Label -Weight SemiBold -Margin '0,8,0,4'))
    if ($Password) { $box = New-Object Windows.Controls.PasswordBox } else { $box = New-Object Windows.Controls.TextBox; $box.Text = $Value }
    $box.Background = Get-Brush '#0E1520'
    $box.Foreground = Get-Brush $script:Colors.text
    $box.BorderBrush = Get-Brush '#263449'
    $box.CaretBrush = Get-Brush $script:Colors.text
    $box.Padding = '8,7'
    $box.FontSize = 14
    [void]$Dialog.Panel.Children.Add($box)
    if ($Hint) { [void]$Dialog.Panel.Children.Add((New-Text $Hint -Size 11 -Color $script:Colors.muted -Wrap -Margin '0,4,0,0')) }
    return $box
}

function Show-ServerSetup {
    # Asks for the office server share; saves it on this PC only.
    $cfg = Get-ServerConfig
    $unc = ''; $drive = ''
    if ($cfg) { $unc = [string]$cfg.Unc; $drive = [string]$cfg.Drive }
    while ($true) {
        $d = New-Dialog 'Office server' 'Saved on this PC only (C:\ProgramData\MAVTechTools). No passwords are stored here.' 'Save and check'
        $box = Add-DialogField $d 'Server share' $unc -Hint 'For example \\OFFICE-SRV\Data or \\192.168.1.10\Shared'
        [void]$d.Panel.Children.Add((New-Text 'Drive letter (optional)' -Weight SemiBold -Margin '0,12,0,4'))
        $cb = New-Object Windows.Controls.ComboBox
        $none = New-Object Windows.Controls.ComboBoxItem; $none.Content = 'Keep the drives the user already has'; $none.Tag = ''
        [void]$cb.Items.Add($none)
        $cb.SelectedIndex = 0
        foreach ($c in [char[]]'DEFGHIJKLMNOPQRSTUVWXYZ') {
            $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = "${c}:"; $it.Tag = "${c}:"
            [void]$cb.Items.Add($it)
            if ($drive -eq "${c}:") { $cb.SelectedItem = $it }
        }
        [void]$d.Panel.Children.Add($cb)
        [void]$d.Panel.Children.Add((New-Text 'Used when the user has no drive mapped to this server yet.' -Size 11 -Color $script:Colors.muted -Wrap -Margin '0,4,0,0'))
        $box.Focus() | Out-Null
        if (-not $d.Window.ShowDialog()) { return $false }
        $unc = $box.Text.Trim().TrimEnd('\')
        $drive = [string]$cb.SelectedItem.Tag
        if ($unc -match '^\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+') { break }
        [void][Windows.MessageBox]::Show('Enter the share as \\SERVER\Share (two backslashes, the server, then the share name).', 'MAV TechTools', 'OK', 'Warning')
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:ServerConfigPath) -Force | Out-Null
    $json = [ordered]@{ Unc = $unc; Drive = $drive; Saved = (Get-Date).ToString('s') } | ConvertTo-Json
    [System.IO.File]::WriteAllText($script:ServerConfigPath, $json)
    $script:State.Server = $null
    $script:State.ServerError = ''
    Add-ConsoleLine ('Office server set to ' + $unc) 'info'
    return $true
}

function Show-LoginDialog {
    param([string]$Title, [string]$Message, [string]$User)
    $d = New-Dialog $Title $Message 'Test and save'
    $ub = Add-DialogField $d 'Username' $User -Hint 'For example OFFICE-SRV\frontdesk, DOMAIN\user or user@domain.com'
    $pb = Add-DialogField $d 'Password' -Password
    if ($User) { $pb.Focus() | Out-Null } else { $ub.Focus() | Out-Null }
    if (-not $d.Window.ShowDialog()) { return $null }
    if (-not $ub.Text.Trim() -or $pb.SecurePassword.Length -eq 0) { Add-ConsoleLine 'Username and password are both needed.' 'warn'; return $null }
    return (New-Object System.Management.Automation.PSCredential($ub.Text.Trim(), $pb.SecurePassword))
}

function New-LockDialog {
    # The startup password window, styled like the demo: borderless dark card,
    # MAV logo, centered title. Returns @{ Window; Panel; Box }.
    param([string]$Problem = '')
    $w = New-Object Windows.Window
    $w.Title = 'MAV TechTools - Unlock'
    $w.Width = 440
    $w.SizeToContent = 'Height'
    $w.ResizeMode = 'NoResize'
    $w.WindowStyle = 'None'
    $w.AllowsTransparency = $true
    $w.Background = [Windows.Media.Brushes]::Transparent
    $w.FontFamily = 'Segoe UI'
    $w.ShowInTaskbar = $true
    $w.Topmost = $true
    $w.WindowStartupLocation = 'CenterScreen'
    $w.Resources = $script:Window.Resources
    $w.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch { } })

    $card = New-Object Windows.Controls.Border
    $card.Margin = '20'
    $card.CornerRadius = '16'
    $card.Background = Get-Brush '#0A1019'
    $card.BorderBrush = Get-Brush '#263449'
    $card.BorderThickness = '1'
    $card.Padding = '28,26,28,24'
    $fx = New-Object Windows.Media.Effects.DropShadowEffect
    $fx.Color = [Windows.Media.Colors]::Black; $fx.BlurRadius = 30; $fx.ShadowDepth = 6; $fx.Opacity = 0.55
    $card.Effect = $fx

    $outer = New-Object Windows.Controls.StackPanel
    try {
        $logo = New-Object Windows.Shapes.Path
        $logo.Data = [Windows.Media.Geometry]::Parse(([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'logo.path.txt'))).Trim())
        $logo.Fill = Get-Brush '#24A7E0'
        $logo.Stretch = 'Uniform'
        $glow = New-Object Windows.Media.Effects.DropShadowEffect
        $glow.Color = [Windows.Media.ColorConverter]::ConvertFromString('#24A7E0'); $glow.BlurRadius = 14; $glow.ShadowDepth = 0; $glow.Opacity = 0.55
        $logo.Effect = $glow
        $vb = New-Object Windows.Controls.Viewbox
        $vb.Width = 64; $vb.Height = 64
        $vb.HorizontalAlignment = 'Center'
        $vb.Margin = '0,0,0,10'
        $vb.Child = $logo
        [void]$outer.Children.Add($vb)
    } catch { }
    $title = New-Text 'Unlock TechTools' -Size 21 -Weight SemiBold
    $title.HorizontalAlignment = 'Center'
    [void]$outer.Children.Add($title)
    $msg = New-Text 'Enter the MAV team password to open TechTools.' -Color $script:Colors.muted -Wrap -Margin '0,6,0,16'
    $msg.HorizontalAlignment = 'Center'; $msg.TextAlignment = 'Center'
    [void]$outer.Children.Add($msg)

    $panel = New-Object Windows.Controls.StackPanel
    [void]$outer.Children.Add($panel)
    $d = @{ Window = $w; Panel = $panel }
    $box = Add-DialogField $d 'Team password' -Password
    $box.Padding = '10,9'
    if ($Problem) { [void]$panel.Children.Add((New-Text $Problem -Size 13 -Color $script:Colors.fail -Wrap -Margin '0,8,0,0')) }
    [void]$panel.Children.Add((New-Text '5 wrong tries closes TechTools.' -Size 12 -Color $script:Colors.muted -Wrap -Margin '0,8,0,0'))

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = '0,20,0,0'
    $cancel = New-Button 'Cancel'
    $cancel.IsCancel = $true
    $cancel.Margin = '0,0,8,0'
    [void]$row.Children.Add($cancel)
    $ok = New-Button 'Unlock' -Style 'PrimaryBtn'
    $ok.IsDefault = $true
    $ok.Padding = '18,0'
    $ok.Tag = $w
    $ok.Add_Click({ $this.Tag.DialogResult = $true })
    [void]$row.Children.Add($ok)
    [void]$outer.Children.Add($row)

    $card.Child = $outer
    $w.Content = $card
    $d.Box = $box
    return $d
}

function Request-TeamPassword {
    # Asks for the team password before the main window opens. False = do not open.
    $authPath = Join-Path (Join-Path $ConfigRoot 'config') 'auth.json'
    $auth = $null
    try { $auth = Read-TTJson $authPath } catch { }
    if (-not $auth) {
        [void][Windows.MessageBox]::Show('TechTools could not load its password file. Run the start command again.', 'MAV TechTools', 'OK', 'Error')
        return $false
    }
    $problem = ''
    for ($try = 1; $try -le 5; $try++) {
        $d = New-LockDialog $problem
        $d.Window.Add_ContentRendered({ $this.Activate() | Out-Null })
        $d.Box.Focus() | Out-Null
        if (-not $d.Window.ShowDialog()) { return $false }
        $ok = $false
        if ($d.Box.SecurePassword.Length -gt 0) {
            $ok = Test-TTPassword -Password (ConvertFrom-TTSecure $d.Box.SecurePassword) -Auth $auth
        }
        if ($ok) { Open-HaloConfig (ConvertFrom-TTSecure $d.Box.SecurePassword); return $true }
        Start-Sleep -Milliseconds 800
        $problem = 'Wrong password. {0} tries left.' -f (5 - $try)
    }
    [void][Windows.MessageBox]::Show('Too many wrong passwords. TechTools will close.', 'MAV TechTools', 'OK', 'Warning')
    return $false
}

function Open-HaloConfig {
    # Reads config/halo.json and unlocks its key with the team password. Key stays in memory only.
    param([string]$Password)
    $script:Halo = $null
    $path = Join-Path (Join-Path $ConfigRoot 'config') 'halo.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try { $cfg = Read-TTJson $path } catch { return }
    $secret = Unprotect-TTSecret -Box $cfg.secret -Password $Password
    if (-not $secret) { $script:HaloProblem = 'The HaloPSA key could not be unlocked with this password.'; return }
    $script:Halo = @{ Url = [string]$cfg.url; Tenant = [string]$cfg.tenant; ClientId = [string]$cfg.clientId; Outcome = [string]$cfg.outcome; Scope = [string]$cfg.scope; Secret = $secret }
}

function Show-HaloSend {
    # Asks for the ticket number, then queues the send job.
    $res = $script:State.Health
    if (-not $res) { return }
    if (-not $script:Halo) {
        $why = 'HaloPSA is not set up in TechTools yet.'
        if ($script:HaloProblem) { $why = $script:HaloProblem }
        [void][Windows.MessageBox]::Show($why, 'MAV TechTools', 'OK', 'Information')
        return
    }
    $title = 'PC Health Check'
    if ($res.PSObject.Properties['Title'] -and $res.Title) { $title = [string]$res.Title }
    $ticket = ''
    while ($true) {
        $d = New-Dialog 'Send to HaloPSA ticket' ('Adds a private note with the ' + $title + ' summary to the ticket, posted as MAV Tech Tools.') 'Send to ticket'
        $box = Add-DialogField $d 'Ticket number' $ticket -Hint 'For example 10482'
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = 'Attach the full report (PDF)'
        $cb.IsChecked = $true
        $cb.Foreground = Get-Brush $script:Colors.text
        $cb.Margin = '0,12,0,0'
        [void]$d.Panel.Children.Add($cb)
        $box.Focus() | Out-Null
        if (-not $d.Window.ShowDialog()) { return }
        $ticket = $box.Text.Trim()
        if (Test-TTTicketNumber $ticket) { break }
        [void][Windows.MessageBox]::Show('Enter the ticket number (digits only).', 'MAV TechTools', 'OK', 'Warning')
    }
    $sections = @($res.Sections)
    $fails = @($sections | Where-Object { $_.Level -eq 'fail' }).Count
    $warns = @($sections | Where-Object { $_.Level -eq 'warn' }).Count
    $headline = 'Everything checked looks healthy'
    if ($fails) { $headline = ('{0} problem(s) and {1} warning(s) found' -f $fails, $warns) }
    elseif ($warns) { $headline = ('{0} warning(s), nothing failing' -f $warns) }
    $note = ConvertTo-TTHaloNote -Report $res -Headline $headline -Pc ([string]$res.Pc) -RunBy ($env:USERDOMAIN + '\' + $env:USERNAME)
    $cat = Get-Cat 'windows'
    $tool = @($cat.Tools | Where-Object { $_.Id -eq 'halosend' })[0]
    if (-not $tool) { return }
    $job = New-TTJob -Category $cat -Tool $tool
    $job.Name = 'Send ' + $title + ' to HaloPSA #' + $ticket.TrimStart('#')
    $job.Input = @{ Url = $script:Halo.Url; Tenant = $script:Halo.Tenant; ClientId = $script:Halo.ClientId; Secret = $script:Halo.Secret
        Outcome = $script:Halo.Outcome; Scope = $script:Halo.Scope; Ticket = $ticket; NoteHtml = $note; Html = [string]$res.Html; AttachPdf = [bool]$cb.IsChecked }
    Add-Jobs @($job)
}

function Start-ServerReauth {
    param([string]$Mode)
    $st = $script:State.Server
    $cfg = Get-ServerConfig
    if (-not $cfg) { return }
    if ($Mode -eq 'trust') {
        $cred = Show-LoginDialog 'Repair domain trust' 'Enter a domain admin account (DOMAIN\admin). It is used once to reset this PC''s domain account and is not saved.' ''
    } else {
        $for = 'the signed-in user'
        if ($st -and $st.ConsoleUser) { $for = $st.ConsoleUser }
        $u = ''
        if ($st) { $u = [string]$st.SavedUser }
        $cred = Show-LoginDialog 'Re-authenticate' ('Login for ' + $cfg.Unc + '. It is tested first, then saved in Credential Manager for ' + $for + ' and the mapped drives are reconnected.') $u
    }
    if (-not $cred) { return }
    $cat = Get-Cat 'windows'
    $tool = $cat.Tools | Where-Object { $_.Id -eq 'serverreauth' } | Select-Object -First 1
    $job = New-TTJob -Category $cat -Tool $tool
    if ($Mode -eq 'trust') { $job.Name = 'Repair domain trust' }
    $job.Input = @{ Mode = $Mode; Credential = $cred }
    Add-Jobs @($job)
    Render-Server
}

function Render-Server {
    $h = $script:ServerHost
    if ($null -eq $h) { return }
    $h.Children.Clear()
    $cfg = Get-ServerConfig
    $st = $script:State.Server
    $busy = (Test-ToolBusy 'servercheck') -or (Test-ToolBusy 'serverreauth')

    $level = 'idle'
    if ($st -and $st.Configured) { $level = $st.Level }
    $card = New-Card -Padding '18'
    $card.Margin = '0,0,0,14'
    if ($level -eq 'fail') { $card.BorderBrush = Get-Brush '#5A2626' } elseif ($level -eq 'warn') { $card.BorderBrush = Get-Brush '#5A4A1F' }
    $sp = New-Object Windows.Controls.StackPanel

    $dock = New-Object Windows.Controls.DockPanel
    $btns = New-Object Windows.Controls.WrapPanel
    $btns.VerticalAlignment = 'Top'
    [Windows.Controls.DockPanel]::SetDock($btns, 'Right')
    $addBtn = {
        param($text, $style, $icon, $action)
        $ic = '#E6EDF5'
        if ($style -eq 'PrimaryBtn') { $ic = '#04121A' }
        $b = New-Button $text -Style $style -Icon $icon -IconColor $ic
        $b.Margin = '8,0,0,8'
        $b.Tag = $action
        $b.IsEnabled = -not $busy
        $b.Add_Click({ & ([scriptblock]::Create([string]$this.Tag)) })
        [void]$btns.Children.Add($b)
    }
    if (-not $cfg) {
        & $addBtn 'Set up server' 'PrimaryBtn' 'folder' 'if (Show-ServerSetup) { Invoke-QuickTool servercheck }'
    } else {
        if ($st -and $st.Configured) {
            & $addBtn 'Check again' 'Btn' 'refresh' 'Invoke-QuickTool servercheck'
            $style = 'Btn'
            if ($st.NeedsAuth) { $style = 'PrimaryBtn' }
            & $addBtn 'Re-authenticate' $style 'bolt' 'Start-ServerReauth login'
            if ($st.NeedsTrust) { & $addBtn 'Repair domain trust' 'PrimaryBtn' 'bolt' 'Start-ServerReauth trust' }
        } else {
            & $addBtn 'Check now' 'PrimaryBtn' 'play' 'Invoke-QuickTool servercheck'
        }
        & $addBtn 'Change server' 'Btn' 'folder' 'if (Show-ServerSetup) { Invoke-QuickTool servercheck }'
    }
    [void]$dock.Children.Add($btns)

    $head = New-Object Windows.Controls.StackPanel
    [void]$head.Children.Add((New-Text 'OFFICE SERVER' -Size 11 -Color $script:Colors.accent -Mono))
    $title = 'Not set up on this PC'
    if ($cfg) { $title = [string]$cfg.Unc }
    [void]$head.Children.Add((New-Text $title -Size 20 -Weight SemiBold -Margin '0,2,0,4'))
    $line = New-Object Windows.Controls.StackPanel
    $line.Orientation = 'Horizontal'
    $headline = ''
    if (-not $cfg) { $headline = 'Enter the server share once; it is remembered on this PC.' }
    elseif ($busy) { $headline = 'Checking...' }
    elseif ($st -and $st.Configured) { $headline = $st.Headline }
    elseif ($script:State.ServerError) { $headline = 'Last check failed: ' + $script:State.ServerError; $level = 'fail' }
    else { $headline = 'Not checked yet' }
    $hc = $script:Colors.muted
    if ($level -eq 'ok' -or $level -eq 'warn' -or $level -eq 'fail') { $hc = $script:Colors[$level] }
    if ($busy) { $hc = $script:Colors.step }
    if ($st -and $st.Configured -and -not $busy) {
        $dot = New-Dot $level 11
        $dot.Margin = '0,0,8,0'
        [void]$line.Children.Add($dot)
    }
    $ht = New-Text $headline -Size 14 -Weight SemiBold -Color $hc -Wrap
    $ht.MaxWidth = 560
    [void]$line.Children.Add($ht)
    if ($st -and $st.At -and -not $busy) { [void]$line.Children.Add((New-Text ('Checked ' + ([datetime]$st.At).ToString('HH:mm')) -Size 11 -Color $script:Colors.muted -Mono -Margin '12,3,0,0')) }
    [void]$head.Children.Add($line)
    [void]$dock.Children.Add($head)
    [void]$sp.Children.Add($dock)

    if ($st -and $st.Configured) {
        $g = New-Object Windows.Controls.Grid
        $g.Margin = '0,12,0,0'
        foreach ($w in @('22', 'Auto', '*')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
        $i = 0
        foreach ($c in @($st.Checks)) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = 'Auto'; [void]$g.RowDefinitions.Add($rd)
            $mark = [string][char]0x2713
            if ($c.Level -eq 'warn') { $mark = '!' }
            if ($c.Level -eq 'fail') { $mark = [string][char]0x2715 }
            $m = New-Text $mark -Weight Bold -Color $script:Colors[$c.Level] -Mono -Margin '0,3,0,3'
            [Windows.Controls.Grid]::SetRow($m, $i)
            [void]$g.Children.Add($m)
            $n = New-Text $c.Name -Weight SemiBold -Margin '0,3,18,3'
            [Windows.Controls.Grid]::SetRow($n, $i); [Windows.Controls.Grid]::SetColumn($n, 1)
            [void]$g.Children.Add($n)
            $dc = $script:Colors.plain
            if ($c.Level -eq 'fail') { $dc = $script:Colors.fail }
            $t = New-Text $c.Detail -Color $dc -Wrap -Margin '0,3,0,3'
            [Windows.Controls.Grid]::SetRow($t, $i); [Windows.Controls.Grid]::SetColumn($t, 2)
            [void]$g.Children.Add($t)
            $i++
        }
        [void]$sp.Children.Add($g)
    }
    $card.Child = $sp
    [void]$h.Children.Add($card)
}

# ------------------------------------------------------ PC health report ---
$script:HealthLabel = @{ ok = 'OK'; warn = 'CHECK'; fail = 'PROBLEM'; info = 'INFO' }
$script:HealthBorder = @{ ok = '#1F4D3D'; warn = '#5A4A1F'; fail = '#5A2626'; info = '#1E2A3B' }

function New-Dot {
    param([string]$Level, [double]$Size = 10)
    $d = New-Object Windows.Shapes.Ellipse
    $d.Width = $Size; $d.Height = $Size
    $c = $script:Colors[$Level]
    if (-not $c) { $c = $script:Colors.muted }
    $d.Fill = Get-Brush $c
    $d.VerticalAlignment = 'Center'
    return $d
}

function New-Chip {
    param([string]$Level)
    $chip = New-Object Windows.Controls.Border
    $chip.BorderBrush = Get-Brush $script:HealthBorder[$Level]
    $chip.BorderThickness = 1
    $chip.CornerRadius = 9
    $chip.Padding = '8,1'
    $chip.Margin = '10,0,0,0'
    $chip.VerticalAlignment = 'Center'
    $c = $script:Colors[$Level]
    if ($Level -eq 'info') { $c = $script:Colors.muted }
    $chip.Child = (New-Text $script:HealthLabel[$Level] -Size 10 -Color $c -Mono)
    return $chip
}

function New-HealthTable {
    param($Table)
    $cols = @($Table.Columns)
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,4,0,12'
    [void]$sp.Children.Add((New-Text ([string]$Table.Caption).ToUpper() -Size 10 -Color $script:Colors.muted -Mono -Margin '0,0,0,6'))
    $g = New-Object Windows.Controls.Grid
    foreach ($c in $cols) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = 'Auto'
        [void]$g.ColumnDefinitions.Add($cd)
    }
    $rows = @($Table.Rows)
    $n = [math]::Max(1, $rows.Count) + 1
    for ($i = 0; $i -lt $n; $i++) {
        $rd = New-Object Windows.Controls.RowDefinition
        $rd.Height = 'Auto'
        [void]$g.RowDefinitions.Add($rd)
    }
    $line = Get-Brush $script:Colors.line
    for ($c = 0; $c -lt $cols.Count; $c++) {
        $t = New-Text $cols[$c] -Size 11 -Color $script:Colors.muted -Weight SemiBold -Margin '0,0,18,6'
        [Windows.Controls.Grid]::SetColumn($t, $c)
        [void]$g.Children.Add($t)
    }
    if ($rows.Count -eq 0) {
        $t = New-Text 'None' -Color $script:Colors.muted -Margin '0,4,0,4'
        [Windows.Controls.Grid]::SetRow($t, 1)
        [Windows.Controls.Grid]::SetColumnSpan($t, $cols.Count)
        [void]$g.Children.Add($t)
    }
    for ($r = 0; $r -lt $rows.Count; $r++) {
        $row = $rows[$r]
        $lv = [string]$row._Level
        $bg = New-Object Windows.Controls.Border
        $bg.BorderBrush = $line
        $bg.BorderThickness = '0,1,0,0'
        if ($lv -eq 'warn') { $bg.Background = Get-Brush '#1F1A0C' }
        elseif ($lv -eq 'fail') { $bg.Background = Get-Brush '#2A1414' }
        [Windows.Controls.Grid]::SetRow($bg, $r + 1)
        [Windows.Controls.Grid]::SetColumnSpan($bg, $cols.Count)
        [void]$g.Children.Add($bg)
        for ($c = 0; $c -lt $cols.Count; $c++) {
            $color = $script:Colors.text
            if ($c -gt 0 -and ($lv -eq 'warn' -or $lv -eq 'fail')) { $color = $script:Colors[$lv] }
            $t = New-Text ([string]$row.($cols[$c])) -Size 12 -Color $color -Wrap -Margin '0,5,18,5'
            $t.MaxWidth = 380
            [Windows.Controls.Grid]::SetRow($t, $r + 1)
            [Windows.Controls.Grid]::SetColumn($t, $c)
            [void]$g.Children.Add($t)
        }
    }
    $sv = New-Object Windows.Controls.ScrollViewer
    $sv.HorizontalScrollBarVisibility = 'Auto'
    $sv.VerticalScrollBarVisibility = 'Disabled'
    $sv.Content = $g
    [void]$sp.Children.Add($sv)
    return $sp
}

function New-HealthSection {
    param($Sec)
    $card = New-Card -Padding '18'
    $card.Margin = '0,0,0,14'
    if ($Sec.Level -eq 'warn' -or $Sec.Level -eq 'fail') { $card.BorderBrush = Get-Brush $script:HealthBorder[$Sec.Level] }
    $sp = New-Object Windows.Controls.StackPanel
    $hd = New-Object Windows.Controls.StackPanel
    $hd.Orientation = 'Horizontal'
    [void]$hd.Children.Add((New-Text $Sec.Title -Size 17 -Weight SemiBold))
    [void]$hd.Children.Add((New-Chip $Sec.Level))
    [void]$sp.Children.Add($hd)
    [void]$sp.Children.Add((New-Text $Sec.Summary -Color $script:Colors.muted -Wrap -Margin '0,4,0,10'))
    foreach ($n in @($Sec.Notes)) {
        $nb = New-Object Windows.Controls.Border
        $nb.Background = Get-Brush '#0A1019'
        $nc = $script:Colors[$n.Level]
        if (-not $nc -or $n.Level -eq 'info') { $nc = $script:Colors.muted }
        $nb.BorderBrush = Get-Brush $nc
        $nb.BorderThickness = '3,0,0,0'
        $nb.CornerRadius = 6
        $nb.Padding = '10,6'
        $nb.Margin = '0,0,0,8'
        $nb.Child = (New-Text $n.Text -Wrap)
        [void]$sp.Children.Add($nb)
    }
    $facts = @($Sec.Facts)
    if ($facts.Count) {
        $g = New-Object Windows.Controls.Grid
        $g.Margin = '0,0,0,10'
        foreach ($w in @('Auto', '*')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
        for ($i = 0; $i -lt $facts.Count; $i++) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = 'Auto'; [void]$g.RowDefinitions.Add($rd)
            $l = New-Text $facts[$i].Label -Color $script:Colors.muted -Margin '0,2,24,2'
            [Windows.Controls.Grid]::SetRow($l, $i)
            [void]$g.Children.Add($l)
            $vc = $script:Colors.text
            if ($facts[$i].Level -eq 'warn' -or $facts[$i].Level -eq 'fail') { $vc = $script:Colors[$facts[$i].Level] }
            $v = New-Text $facts[$i].Value -Color $vc -Wrap -Margin '0,2,0,2'
            [Windows.Controls.Grid]::SetRow($v, $i)
            [Windows.Controls.Grid]::SetColumn($v, 1)
            [void]$g.Children.Add($v)
        }
        [void]$sp.Children.Add($g)
    }
    foreach ($t in @($Sec.Tables)) { [void]$sp.Children.Add((New-HealthTable $t)) }
    $card.Child = $sp
    return $card
}

function Get-BusyReportTool {
    # The report tool (effect healthreport) that is queued or running on this page, if any.
    $cat = $script:Catalog | Where-Object { $_.Id -eq $script:State.Page }
    if (-not $cat) { return $null }
    foreach ($t in @($cat.Tools | Where-Object { $_.Effect -eq 'healthreport' })) {
        if (Test-ToolBusy $t.Id) { return $t }
    }
    return $null
}

function Render-Health {
    $h = $script:HealthHost
    if ($null -eq $h) { return }
    $h.Children.Clear()
    $res = $script:State.Health
    $busyTool = Get-BusyReportTool
    $busy = $null -ne $busyTool
    $resTool = 'healthcheck'
    if ($res -and $res.PSObject.Properties['Tool'] -and $res.Tool) { $resTool = [string]$res.Tool }
    # A different check is running: show that instead of the old report.
    if ($busy -and $res -and $busyTool.Id -ne $resTool) { $res = $null }

    if ($null -eq $res) {
        $card = New-Card -Padding '22'
        $sp = New-Object Windows.Controls.StackPanel
        if ($busy) {
            [void]$sp.Children.Add((New-Text ($busyTool.Label + ' running...') -Size 17 -Weight SemiBold))
            [void]$sp.Children.Add((New-Text 'Progress shows in the Action Center; the results will appear here.' -Color $script:Colors.muted -Wrap -Margin '0,6,0,0'))
        } else {
            [void]$sp.Children.Add((New-Text 'No results yet' -Size 17 -Weight SemiBold))
            $msg = 'Press one of the buttons above. The results show here, and you can save them as a PDF.'
            if ($script:State.HealthError) { $msg = 'The last check failed: ' + $script:State.HealthError }
            [void]$sp.Children.Add((New-Text $msg -Color $script:Colors.muted -Wrap -Margin '0,6,0,0'))
        }
        $card.Child = $sp
        [void]$h.Children.Add($card)
        return
    }

    $sections = @($res.Sections)
    $fails = @($sections | Where-Object { $_.Level -eq 'fail' }).Count
    $warns = @($sections | Where-Object { $_.Level -eq 'warn' }).Count
    $overall = 'ok'
    $headline = 'Everything checked looks healthy'
    if ($fails) { $overall = 'fail'; $headline = ('{0} problem(s) and {1} warning(s) found' -f $fails, $warns) }
    elseif ($warns) { $overall = 'warn'; $headline = ('{0} warning(s), nothing failing' -f $warns) }

    # Header: who, when, overall result, export buttons
    $top = New-Card -Padding '18'
    $top.Background = Get-Brush '#0A1019'
    $top.BorderBrush = Get-Brush $script:HealthBorder[$overall]
    $top.Margin = '0,0,0,14'
    $dock = New-Object Windows.Controls.DockPanel
    $btns = New-Object Windows.Controls.WrapPanel
    $btns.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($btns, 'Right')
    $pdf = New-Button 'Save as PDF' -Style 'PrimaryBtn' -Icon 'file' -IconColor '#04121A'
    $pdf.Margin = '8,0,0,0'
    $pdf.IsEnabled = ($null -eq $script:State.Pdf)
    if ($script:State.Pdf) { $pdf.Content = 'Making PDF...' }
    $pdf.Add_Click({ Save-HealthPdf })
    $open = New-Button 'Open report' -Icon 'file'
    $open.Margin = '8,0,0,0'
    $open.ToolTip = 'Opens the full report in the browser (print or email it from there)'
    $open.Add_Click({ if ($script:State.Health -and (Test-Path $script:State.Health.Html)) { Start-Process -FilePath $script:State.Health.Html } })
    $again = New-Button 'Run again' -Icon 'refresh'
    $again.Margin = '8,0,0,0'
    $again.IsEnabled = -not $busy
    $again.Tag = $resTool
    $again.Add_Click({ Invoke-Tool $script:State.Page ([string]$this.Tag); Render-Health })
    $halo = New-Button 'Send to ticket' -Icon 'send'
    $halo.Margin = '8,0,0,0'
    $halo.ToolTip = 'Adds the results to a HaloPSA ticket as a private note from MAV Tech Tools'
    if (-not $script:Halo) { $halo.Opacity = 0.6; $halo.ToolTip = 'HaloPSA is not set up in TechTools yet' }
    $halo.Add_Click({ Show-HaloSend })
    [void]$btns.Children.Add($again)
    [void]$btns.Children.Add($open)
    [void]$btns.Children.Add($halo)
    [void]$btns.Children.Add($pdf)
    [void]$dock.Children.Add($btns)
    $who = New-Object Windows.Controls.StackPanel
    $title = 'PC Health Check'
    if ($res.PSObject.Properties['Title'] -and $res.Title) { $title = [string]$res.Title }
    [void]$who.Children.Add((New-Text $title.ToUpper() -Size 11 -Color $script:Colors.accent -Mono))
    [void]$who.Children.Add((New-Text ([string]$res.Pc) -Size 24 -Weight SemiBold -Margin '0,2,0,4'))
    $line = New-Object Windows.Controls.StackPanel
    $line.Orientation = 'Horizontal'
    $dot = New-Dot $overall 12
    $dot.Margin = '0,0,8,0'
    [void]$line.Children.Add($dot)
    [void]$line.Children.Add((New-Text $headline -Size 15 -Weight SemiBold -Color $script:Colors[$overall]))
    $when = 'Checked ' + ([datetime]$res.At).ToString('yyyy-MM-dd HH:mm')
    if ($busy) { $when = 'Running a new check...' }
    [void]$line.Children.Add((New-Text $when -Size 11 -Color $script:Colors.muted -Mono -Margin '14,3,0,0'))
    [void]$who.Children.Add($line)
    if ($res.PSObject.Properties['Lead'] -and $res.Lead) {
        $lv = 'info'
        if ($res.LeadLevel) { $lv = [string]$res.LeadLevel }
        $leadCol = $script:Colors.text
        if ($script:Colors.ContainsKey($lv)) { $leadCol = $script:Colors[$lv] }
        [void]$who.Children.Add((New-Text ([string]$res.Lead) -Size 14 -Weight SemiBold -Color $leadCol -Wrap -Margin '0,10,0,0'))
    }
    [void]$dock.Children.Add($who)
    $top.Child = $dock
    [void]$h.Children.Add($top)

    # Detail cards first (built now so the summary tiles can jump to them)
    $cards = @()
    foreach ($sec in $sections) { $cards += (New-HealthSection $sec) }

    # Summary tiles: one per check, problems first
    $grid = New-Object Windows.Controls.WrapPanel
    $grid.Margin = '0,0,0,8'
    $rank = @{ fail = 0; warn = 1; ok = 2; info = 3 }
    $order = @(0..($sections.Count - 1) | Sort-Object { $rank[$sections[$_].Level] }, { $_ })
    foreach ($i in $order) {
        $sec = $sections[$i]
        $b = New-Object Windows.Controls.Button
        $b.Style = $script:Window.FindResource('Btn')
        $b.Width = 268
        $b.Margin = '0,0,10,10'
        $b.Padding = '12,10'
        $b.HorizontalContentAlignment = 'Left'
        $b.BorderBrush = Get-Brush $script:HealthBorder[$sec.Level]
        $b.Tag = $cards[$i]
        $b.ToolTip = 'Jump to details'
        $sp = New-Object Windows.Controls.StackPanel
        $t = New-Object Windows.Controls.StackPanel
        $t.Orientation = 'Horizontal'
        $d = New-Dot $sec.Level 9
        $d.Margin = '0,0,8,0'
        [void]$t.Children.Add($d)
        [void]$t.Children.Add((New-Text $sec.Title -Weight SemiBold))
        [void]$sp.Children.Add($t)
        $sum = New-Text $sec.Summary -Size 12 -Color $script:Colors.muted -Wrap -Margin '0,4,0,0'
        $sum.MaxHeight = 34
        $sum.TextTrimming = 'CharacterEllipsis'
        [void]$sp.Children.Add($sum)
        $b.Content = $sp
        $b.Add_Click({ $this.Tag.BringIntoView() })
        [void]$grid.Children.Add($b)
    }
    [void]$h.Children.Add($grid)
    foreach ($c in $cards) { [void]$h.Children.Add($c) }
}

function Find-Edge {
    foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Save-HealthPdf {
    $res = $script:State.Health
    if (-not $res -or -not (Test-Path $res.Html)) { Add-ConsoleLine 'Run a check first.' 'warn'; return }
    $pdf = [System.IO.Path]::ChangeExtension($res.Html, '.pdf')
    $edge = Find-Edge
    if (-not $edge) {
        Add-ConsoleLine 'Microsoft Edge not found: opening the report so you can Print > Save as PDF.' 'warn'
        Start-Process -FilePath $res.Html
        return
    }
    if (Test-Path $pdf) { Remove-Item $pdf -Force -ErrorAction SilentlyContinue }
    $profile_ = Join-Path $env:TEMP ('MAVTechTools-pdf-' + [guid]::NewGuid().ToString('N'))
    $args_ = @('--headless', '--disable-gpu', '--no-first-run', '--no-pdf-header-footer', ('--user-data-dir="' + $profile_ + '"'),
        ('--print-to-pdf="' + $pdf + '"'), ('"' + ([Uri]$res.Html).AbsoluteUri + '"'))
    try {
        $proc = Start-Process -FilePath $edge -ArgumentList $args_ -WindowStyle Hidden -PassThru
    } catch {
        Add-ConsoleLine ('Could not start Edge: ' + $_.Exception.Message + '. Opening the report instead.') 'warn'
        Start-Process -FilePath $res.Html
        return
    }
    $script:State.Pdf = @{ Proc = $proc; Path = $pdf; Html = $res.Html; Profile = $profile_; Until = (Get-Date).AddSeconds(60) }
    Add-ConsoleLine 'Making PDF...' 'step'
    Render-Health
}

function Update-PdfJob {
    # Called by the UI timer while a PDF is being made.
    $job = $script:State.Pdf
    if ($null -eq $job) { return }
    $ready = (Test-Path $job.Path) -and ((Get-Item $job.Path).Length -gt 0)
    if (-not $job.Proc.HasExited -and -not $ready -and (Get-Date) -lt $job.Until) { return }
    if ($ready -and -not $job.Proc.HasExited -and (Get-Date) -lt $job.Until) { return }
    $script:State.Pdf = $null
    try { Remove-Item -Path $job.Profile -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if ($ready) {
        Add-ConsoleLine ('PDF saved: ' + $job.Path) 'ok'
        Start-Process -FilePath $job.Path
    } else {
        Add-ConsoleLine 'The PDF could not be made. Opening the report: use Print > Save as PDF.' 'warn'
        Start-Process -FilePath $job.Html
    }
    if ($script:HealthHost) { Render-Health }
}

function Select-Recommended {
    $cat = Get-Cat $script:State.Page
    $diag = $script:State.Diag
    if (-not $diag) { return }
    $firstTab = $null
    foreach ($r in $diag.Recommend) {
        $tool = $cat.Tools | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
        if (-not $tool) { continue }
        if (-not $firstTab) { $firstTab = $tool.Tab; $script:State.Pane[$cat.Id + ':' + $tool.Tab] = $tool.Section }
        $key = $cat.Id + ':' + $tool.Id
        if ($tool.Type -eq 'choice') { $script:State.Choice[$key] = $r.Value } else { $script:State.Sel[$key] = $true }
    }
    if ($firstTab) { $script:State.Tab[$cat.Id] = $firstTab }
    Add-ConsoleLine 'Selected the recommended fixes. Review them, then press Run selected.' 'info'
    Render-Page
}

# --------------------------------------------------------- Action Center ---
function Update-ActionCenter {
    $jobs = $script:Sync.Jobs.ToArray()
    $colors = @{ queued = $script:Colors.muted; running = $script:Colors.accent; done = $script:Colors.ok; failed = $script:Colors.fail; cancelled = $script:Colors.dim }
    $labels = @{ queued = 'Queued'; running = 'Running'; done = 'Done'; failed = 'Failed'; cancelled = 'Cancelled' }
    $items = New-Object System.Collections.ArrayList
    for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
        $j = $jobs[$i]
        $status = [string]$j.Status
        $color = $colors[$status]
        $statusText = $labels[$status]
        if ($status -eq 'done' -and [int]$j.Warnings -gt 0) { $color = $script:Colors.warn; $statusText = 'Warnings' }
        switch ($status) {
            'queued' { $detail = $j.CategoryTitle + '  waiting' }
            'cancelled' { $detail = $j.CategoryTitle + '  skipped' }
            'failed' { $detail = [string]$j.Error }
            'done' { $detail = $j.CategoryTitle + '  finished' }
            default { $detail = ('{0}  step {1} of {2}: {3}' -f $j.CategoryTitle, [math]::Max(1, [int]$j.Step), $j.Steps, $j.StepText) }
        }
        $border = $script:Colors.line
        if ($status -eq 'running') { $border = '#1D5A78' }
        [void]$items.Add([pscustomobject]@{
            Name = $j.Name; Detail = $detail; StatusText = $statusText; Color = $color; Border = $border
            Percent = [int]$j.Percent; PercentText = ([string][int]$j.Percent + '%')
        })
    }
    $script:UI.JobList.ItemsSource = $items
    if ($items.Count -gt 0) { $script:UI.NoJobsText.Visibility = 'Collapsed' } else { $script:UI.NoJobsText.Visibility = 'Visible' }

    $live = @($jobs | Where-Object { $_.Status -ne 'cancelled' })
    $done = @($live | Where-Object { $_.Status -eq 'done' }).Count
    $failed = @($live | Where-Object { $_.Status -eq 'failed' }).Count
    if ($live.Count -gt 0) {
        $sum = 0
        foreach ($j in $live) { if ($j.Status -eq 'failed') { $sum += 100 } else { $sum += [int]$j.Percent } }
        $script:UI.OverallBar.Value = [int]($sum / $live.Count)
        $text = ('{0}/{1} done' -f $done, $live.Count)
        if ($failed) { $text += (' - {0} failed' -f $failed) }
        $script:UI.SummaryText.Text = $text
        if ($failed) { $script:UI.SummaryText.Foreground = Get-Brush $script:Colors.fail } else { $script:UI.SummaryText.Foreground = Get-Brush $script:Colors.muted }
    } else {
        $script:UI.OverallBar.Value = 0
        $script:UI.SummaryText.Text = 'idle'
        $script:UI.SummaryText.Foreground = Get-Brush $script:Colors.muted
    }
}

function Complete-FinishedJobs {
    $statusChanged = $false
    $healthChanged = $false
    $serverChanged = $false
    foreach ($j in $script:Sync.Jobs.ToArray()) {
        if ($j.Handled -or ($j.Status -ne 'done' -and $j.Status -ne 'failed')) { continue }
        $j.Handled = $true
        if ($j.Status -eq 'done' -and $j.Restart) {
            $script:State.RestartNeeded = $true
            if ($script:State.RestartWhy -notcontains $j.Name) { [void]$script:State.RestartWhy.Add($j.Name) }
            Add-ConsoleLine ('Restart needed to finish: ' + $j.Name) 'warn'
        }
        if ($j.Effect -eq 'serverstatus') {
            $serverChanged = $true
            if ($j.Status -eq 'done' -and $j.Result) {
                if ($j.Result.Configured) { $script:State.Server = $j.Result } else { $script:State.Server = $null }
                $script:State.ServerError = ''
            } else { $script:State.ServerError = [string]$j.Error }
        }
        if ($j.Effect -eq 'healthreport') {
            $healthChanged = $true
            if ($j.Status -eq 'done' -and $j.Result) { $script:State.Health = $j.Result; $script:State.HealthError = '' }
            else { $script:State.HealthError = [string]$j.Error }
        }
        if ($j.Effect -eq 'netstatus' -or $j.Effect -eq 'diagnose') {
            $statusChanged = $true
            if ($j.Status -eq 'done' -and $j.Result) {
                $script:State.NetStatus = $j.Result.Status
                $script:State.NetChecked = 'Checked ' + (Get-Date).ToString('HH:mm:ss')
                if ($j.Effect -eq 'diagnose') {
                    $script:State.Diag = [pscustomobject]@{
                        At = (Get-Date).ToString('HH:mm:ss'); Findings = @($j.Result.Findings)
                        Recommend = @($j.Result.Recommend); Problems = @($j.Result.Findings | Where-Object { $_.Level -ne 'ok' }).Count
                    }
                }
            } else { $script:State.NetChecked = 'Last check failed' }
        }
    }
    if ($statusChanged) { Render-Status }
    if ($healthChanged -and $script:HealthHost) { Render-Health }
    if ($serverChanged -and $script:ServerHost) { Render-Server }
    Update-RestartBanner
}

function Update-RestartBanner {
    if ($script:State.RestartNeeded) {
        $script:UI.RestartBanner.Visibility = 'Visible'
        if ($script:State.RestartScheduled) {
            $script:UI.RestartWhyText.Text = 'Restart scheduled. Windows will restart in about a minute.'
            $script:UI.RestartNowBtn.Content = 'Cancel restart'
        } else {
            $script:UI.RestartWhyText.Text = 'To finish: ' + ($script:State.RestartWhy -join ', ') + '.'
            $script:UI.RestartNowBtn.Content = 'Restart in 60 s'
        }
    } else { $script:UI.RestartBanner.Visibility = 'Collapsed' }
}

function Invoke-Tick {
    try {
        $line = $null
        $n = 0
        while ($n -lt 300 -and $script:Sync.Log.TryDequeue([ref]$line)) { Add-ConsoleLine $line.Text $line.Tone $line.Time; $n++ }
        if ($script:State.Pdf) { Update-PdfJob }
        if ($script:Sync.Version -ne $script:SeenVersion) {
            $script:SeenVersion = $script:Sync.Version
            Update-ActionCenter
            Complete-FinishedJobs
        }
    } catch { Add-ConsoleLine ('UI error: ' + $_.Exception.Message) 'fail' }
}

# ------------------------------------------------------------ wire up UI ---
try { $script:UI.LogoPath.Data = [Windows.Media.Geometry]::Parse(([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'logo.path.txt'))).Trim()) } catch { }
$script:UI.VersionText.Text = 'v' + $script:Version
$os = ''
try { $os = ((Get-CimInstance -ClassName Win32_OperatingSystem).Caption -replace '^Microsoft\s+', '') } catch { }
$script:UI.PcText.Text = ($env:COMPUTERNAME + '  ' + $os).Trim()
if (-not $script:IsAdmin) {
    $script:UI.AdminText.Text = 'Not admin'
    $script:UI.AdminText.Foreground = Get-Brush $script:Colors.fail
    $script:UI.AdminChip.BorderBrush = Get-Brush '#5A2626'
}

$script:UI.CancelBtn.Add_Click({
    foreach ($j in $script:Sync.Jobs.ToArray()) { if ($j.Status -eq 'queued') { $j.Status = 'cancelled' } }
    $script:Sync.Version++
    Add-ConsoleLine 'Queued actions cancelled' 'muted'
})
$script:UI.ClearBtn.Add_Click({
    foreach ($j in $script:Sync.Jobs.ToArray()) { if ($j.Status -ne 'queued' -and $j.Status -ne 'running') { $script:Sync.Jobs.Remove($j) } }
    $script:Sync.Version++
})
$script:UI.LogsBtn.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList $script:LogDir })
$script:UI.CopyLogBtn.Add_Click({
    $text = ($script:ConsoleItems | ForEach-Object { $_.Time + '  ' + $_.Text }) -join [Environment]::NewLine
    if ($text) { [Windows.Clipboard]::SetText($text) }
})
$script:UI.RestartNowBtn.Add_Click({
    if ($script:State.RestartScheduled) {
        & shutdown.exe /a | Out-Null
        $script:State.RestartScheduled = $false
        Add-ConsoleLine 'Restart cancelled' 'info'
    } else {
        $ans = [Windows.MessageBox]::Show('Restart this PC in 60 seconds? Ask the user to save their work first.', 'MAV TechTools', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
        & shutdown.exe /r /t 60 /c 'Restart started by MAV TechTools' | Out-Null
        $script:State.RestartScheduled = $true
        Add-ConsoleLine 'Restart scheduled in 60 seconds' 'warn'
    }
    Update-RestartBanner
})
$script:UI.RestartLaterBtn.Add_Click({
    $script:State.RestartNeeded = $false
    Add-ConsoleLine 'Restart postponed. Remember to restart before closing the ticket.' 'muted'
    Update-RestartBanner
})

Build-Nav
Show-Page 'home'
Add-ConsoleLine ('MAV TechTools v' + $script:Version + ' on ' + $env:COMPUTERNAME) 'info'
Add-ConsoleLine ('Log file: ' + $script:LogFile) 'muted'
if (-not $script:IsAdmin) { Add-ConsoleLine 'Not running as administrator. Most repairs will fail.' 'warn' }

# ------------------------------------------------------------ smoke test ---
if ($SmokeTest) {
    $errors = 0
    foreach ($k in @($script:Icons.Keys)) {
        try { [void][Windows.Media.Geometry]::Parse($script:Icons[$k]) } catch { Write-Host ('FAIL icon does not parse: ' + $k); $errors++ }
    }
    foreach ($c in $script:Catalog) { foreach ($t in @($c.Tools | Where-Object { $_.Icon })) {
        if (-not $script:Icons.ContainsKey($t.Icon)) { Write-Host ('FAIL unknown icon ' + $t.Icon + ' on ' + $t.Id); $errors++ } } }
    foreach ($cat in $script:Catalog) {
        Show-Page $cat.Id
        foreach ($tab in $cat.Tabs) { $script:State.Tab[$cat.Id] = $tab.Id; Render-Page }
        $script:State.Query = 'dns'; Render-Sections; $script:State.Query = ''
        if (-not $cat.ComingSoon -and $script:SectionsHost -and $script:SectionsHost.Children.Count -lt 1) { Write-Host ('FAIL nothing rendered on ' + $cat.Id); $errors++ }
        # Side menu: pick the last section and render again
        $secs = @($cat.Tools | Where-Object { $_.Type -ne 'quick' -and -not $_.Hidden -and $_.Tab -eq (Get-CurrentTab $cat) } | ForEach-Object { $_.Section } | Select-Object -Unique)
        if ($secs.Count -gt 1) { $script:State.Pane[(Get-PaneKey)] = $secs[-1]; Render-Sections
            if ($script:SectionsHost.Children.Count -ne 1) { Write-Host ('FAIL side menu did not render on ' + $cat.Id); $errors++ } }
    }
    $script:State.Page = 'internet'
    $script:State.NetStatus = [pscustomobject]@{ Adapter = 'Ethernet'; AdapterDetail = 'Test'; IPv4 = '192.168.1.42'; Dhcp = $true; Apipa = $false
        Gateway = '192.168.1.1'; GatewayMs = 2; GatewayLost = 0; GatewaySent = 4; Dns = @('192.168.1.1'); DnsMs = 380; DnsFailed = 0; DnsTotal = 3
        InternetMs = 14; InternetOk = $true; HttpOk = $true; CaptivePortal = $false; PublicIp = '203.0.113.24'; ProxyOn = $false; ProxyDetail = '' }
    $script:State.Diag = [pscustomobject]@{ At = 'now'; Problems = 1
        Findings = @([pscustomobject]@{ Level = 'ok'; Text = 'ok' }, [pscustomobject]@{ Level = 'warn'; Text = 'slow' })
        Recommend = @([pscustomobject]@{ Id = 'flushdns'; Value = $null }, [pscustomobject]@{ Id = 'dns'; Value = 'cloudflare' }) }
    Render-Page
    Select-Recommended
    $script:State.Page = 'windows'
    $fakeSec = [pscustomobject]@{ Title = 'Drives and health'; Level = 'fail'; Summary = '1 drive - FAILURE SIGNS FOUND'
        Facts = @([pscustomobject]@{ Label = 'PC name'; Value = 'TEST-PC'; Level = '' })
        Tables = @([pscustomobject]@{ Caption = 'Physical drives'; Columns = @('Disk', 'Model', 'Problems')
            Rows = @([pscustomobject]@{ Disk = '0'; Model = 'Test SSD'; Problems = '12 uncorrected read errors'; _Level = 'fail' }) },
            [pscustomobject]@{ Caption = 'Empty'; Columns = @('A'); Rows = @() })
        Notes = @([pscustomobject]@{ Text = 'Back up now.'; Level = 'fail' }) }
    $okSec = [pscustomobject]@{ Title = 'System'; Level = 'ok'; Summary = 'TEST-PC'; Facts = @(); Tables = @(); Notes = @() }
    $script:State.Health = [pscustomobject]@{ Sections = @($okSec, $fakeSec); Html = (Join-Path $env:TEMP 'none.html'); At = (Get-Date); Pc = 'TEST-PC' }
    Render-Page
    if ($null -eq $script:HealthHost -or $script:HealthHost.Children.Count -lt 4) { Write-Host 'FAIL health report did not render'; $errors++ }
    # Another report type (Slow PC check) with a likely-cause line
    $script:State.Health = [pscustomobject]@{ Sections = @($okSec, $fakeSec); Html = (Join-Path $env:TEMP 'none.html'); At = (Get-Date); Pc = 'TEST-PC'
        Title = 'Slow PC Check'; Tool = 'slowpc'; Lead = 'Likely cause: C: drive is nearly full (4 GB free).'; LeadLevel = 'fail' }
    Render-Page
    if ($null -eq $script:HealthHost -or $script:HealthHost.Children.Count -lt 4) { Write-Host 'FAIL slow PC report did not render'; $errors++ }
    $script:State.Server = [pscustomobject]@{ Configured = $true; Unc = '\\OFFICE-SRV\Data'; Server = 'OFFICE-SRV'; Share = 'Data'; Drive = 'S:'
        Level = 'fail'; Headline = 'Login problem: the server rejected the saved login'; NeedsAuth = $true; NeedsTrust = $true
        SavedUser = 'OFFICE-SRV\frontdesk'; ConsoleUser = 'PC\frontdesk'; SameUser = $true; Drives = @(); At = (Get-Date)
        Checks = @([pscustomobject]@{ Name = 'File sharing'; Level = 'ok'; Detail = 'Server answers' }, [pscustomobject]@{ Name = 'Share access'; Level = 'fail'; Detail = 'Rejected' }) }
    Render-Server
    if ($null -eq $script:ServerHost -or $script:ServerHost.Children.Count -ne 1) { Write-Host 'FAIL server card did not render'; $errors++ }
    Clear-Diagnostics
    if ($script:State.Health -or $script:State.Server) { Write-Host 'FAIL Clear did not reset results'; $errors++ }
    # Notice card (installer password) after an install button is pressed
    $script:State.Page = 'dental'; $script:State.Tab['dental'] = '3p'
    Render-Page; $before = $script:UI.PagePanel.Children.Count
    $script:State.Notices['mouthwatch'] = $true
    Render-Page
    if ($script:UI.PagePanel.Children.Count -ne $before + 1) { Write-Host 'FAIL notice card did not render'; $errors++ }
    $script:State.Notices = @{}
    $script:State.Page = 'internet'
    Render-Page
    $net = Get-Cat 'internet'
    if (-not $script:State.Sel['internet:flushdns'] -or $script:State.Choice['internet:dns'] -ne 'cloudflare') { Write-Host 'FAIL recommended fixes not selected'; $errors++ }
    $jobs = Get-TTSelectionJobs -Category $net -Sel $script:State.Sel -Choice $script:State.Choice
    $script:Sync.Jobs.Clear()
    foreach ($j in $jobs) { $j.Status = 'cancelled'; [void]$script:Sync.Jobs.Add($j) }
    $script:Sync.Version++
    Invoke-Tick
    if ($script:UI.JobList.Items.Count -ne $jobs.Count) { Write-Host 'FAIL job list did not render'; $errors++ }
    $script:Window.Content.Measure((New-Object Windows.Size 1440, 900))
    $script:Window.Content.Arrange((New-Object Windows.Rect 0, 0, 1440, 900))
    # Startup password window builds, and the shipped password file is valid
    $lock = New-LockDialog 'Wrong password. 4 tries left.'
    if (-not $lock.Box -or $lock.Panel.Children.Count -lt 3) { Write-Host 'FAIL password window did not build'; $errors++ }
    try { $a = Read-TTJson (Join-Path (Join-Path $ConfigRoot 'config') 'auth.json'); if ([string]$a.kdf -ne 'pbkdf2-sha256' -or -not $a.hash) { throw 'bad' } }
    catch { Write-Host 'FAIL config/auth.json missing or invalid'; $errors++ }
    if ($errors) { exit 1 }
    Write-Host 'Smoke test passed: every page rendered'
    exit 0
}

# ------------------------------------------------------------------- run ---
# Ask for the team password before anything runs or the window shows.
if (-not (Request-TeamPassword)) { exit }
Add-ConsoleLine 'Unlocked with the team password' 'muted'
# From here on, a problem in one click must not close the whole window.
$ErrorActionPreference = 'Continue'
$script:Window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    $e.Handled = $true
    try { Add-ConsoleLine ('UI error: ' + $e.Exception.Message) 'fail' } catch { }
})
$script:Worker = Start-TTWorker -Sync $script:Sync
$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:Timer.Add_Tick({ Invoke-Tick })
$script:Timer.Start()

$script:Window.Add_Closing({
    param($sender, $e)
    $running = @($script:Sync.Jobs.ToArray() | Where-Object { $_.Status -eq 'running' -or $_.Status -eq 'queued' })
    if ($running.Count -gt 0) {
        $ans = [Windows.MessageBox]::Show('Actions are still running. Close anyway?', 'MAV TechTools', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { $e.Cancel = $true; return }
    }
    $script:Timer.Stop()
    Stop-TTWorker -Worker $script:Worker -Sync $script:Sync
})

[void]$script:Window.ShowDialog()
