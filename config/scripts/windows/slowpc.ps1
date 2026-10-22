# Slow PC check (Windows > Diagnostics). Read-only: watches the PC for 30
# seconds and ends with a "likely cause" line. Functions are in diag.ps1.
# Keep this file ASCII-only.

Write-Step 'Checking uptime since the last restart'
Add-TTPart 'Uptime' { Get-TTUptimeSection }
$up = $TTReportParts[$TTReportParts.Count - 1]

Write-Step 'Watching CPU, memory and disk for 30 seconds'
$sample = $null
$script:TTSample = $null
Add-TTPart 'CPU, memory and disk' { $script:TTSample = Get-TTSlowSample -Seconds 30; Get-TTPressureSection $script:TTSample }
$sample = $script:TTSample

Write-Step 'Checking free space on C:'
Add-TTPart 'C: drive' { Get-TTSystemDriveSection }
$drive = $TTReportParts[$TTReportParts.Count - 1]

Write-Step 'Listing startup apps'
Add-TTPart 'Startup apps' { Get-TTStartupSection }
$startup = $TTReportParts[$TTReportParts.Count - 1]

Write-Step 'Working out the likely cause'
$plan = Get-TTActivePlan
$data = [pscustomobject]@{
    CpuAvg = $(if ($sample) { $sample.CpuAvg } else { 0 }); MemAvg = $(if ($sample) { $sample.MemAvg } else { 0 }); DiskAvg = $(if ($sample) { $sample.DiskAvg } else { 0 })
    CpuTop = $(if ($sample -and @($sample.TopCpu).Count -and $sample.TopCpu[0].Cpu -ge 20) { $sample.TopCpu[0].Name } else { '' })
    MemTop = $(if ($sample -and @($sample.TopMem).Count) { $sample.TopMem[0].Name } else { '' })
    Kind = $drive.Kind; FreePct = $drive.FreePct; FreeGb = $drive.FreeGb
    Days = $up.Days; FastStartup = $up.FastStartup; Startup = $startup.Enabled; Plan = $plan.Name
}
$cause = Get-TTSlowCause $data
Add-TTPart 'Likely cause' { Get-TTLikelyCauseSection $cause }

Write-Step 'Saving the report'
Complete-TTReport -Title 'Slow PC Check' -Prefix 'SlowPC' -Tool 'slowpc' -Lead ('Likely cause: ' + $cause.Text) -LeadLevel $cause.Level
