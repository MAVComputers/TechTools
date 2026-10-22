# PC Health Check (Windows > Diagnostics).
# Runs every check in order, writes one console line per check, saves an HTML
# report next to the session log and hands the sections to the window, which
# shows them on the Diagnostics tab. The functions live in _shared.ps1.
# Keep this file ASCII-only.

$sections = New-Object System.Collections.ArrayList
function Add-TTPart {
    param([string]$Title, [scriptblock]$Check)
    $s = Invoke-TTHealthPart $Title $Check
    [void]$sections.Add($s)
    Write-TTHealthSummary $s
}

Write-Step 'Reading PC name, Windows version and memory'
Add-TTPart 'System' { Get-TTHealthSystem }

Write-Step 'Checking drives, free space and drive health'
Add-TTPart 'Drives and health' { Get-TTHealthDisks }

Write-Step 'Reading network settings'
Add-TTPart 'Network' { Get-TTHealthNetwork }

Write-Step 'Pinging google.com, yahoo.com and msn.com'
Add-TTPart 'Ping tests' { Get-TTHealthPing }

Write-Step 'Running internet speed test (about 15 seconds)'
Add-TTPart 'Internet speed' { Get-TTHealthSpeed }

Write-Step 'Reading the last 10 errors from the event logs'
Add-TTPart 'Event log' { Get-TTHealthEvents }

Write-Step 'Finding the busiest processes'
Add-TTPart 'Top processes' { Get-TTHealthProcesses }

Write-Step 'Checking shared folders'
Add-TTPart 'Shared folders' { Get-TTHealthShares }

Write-Step 'Listing printers and driver dates'
Add-TTPart 'Printers' { Get-TTHealthPrinters }

Write-Step 'Checking for pending Windows updates (can take a minute)'
Add-TTPart 'Windows Update' { Get-TTHealthUpdates }

Write-Step 'Checking Webroot, SentinelOne, Bitdefender and CrowdStrike'
Add-TTPart 'Antivirus and EDR' { Get-TTHealthSecurity }

Write-Step 'Saving the report'
$folder = $env:TEMP
if ($Sync -and $Sync.LogFile) { $folder = Split-Path -Parent $Sync.LogFile }
$html = New-TTHealthReport -Sections $sections -Folder $folder
Write-Info ('Report saved: ' + $html)
Set-Result ([pscustomobject]@{ Sections = @($sections); Html = $html; At = (Get-Date); Pc = $env:COMPUTERNAME; Title = 'PC Health Check'; Tool = 'healthcheck'; Lead = ''; LeadLevel = '' })
