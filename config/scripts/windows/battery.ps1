# Battery and power report (Windows > Diagnostics). Read-only.
# Functions are in diag.ps1. Keep this file ASCII-only.

$hasBattery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0

Write-Step 'Checking battery wear'
Add-TTPart 'Battery' { Get-TTBatterySection -Folder (Get-TTReportFolder) }

Write-Step 'Reading the power plan and sleep settings'
Add-TTPart 'Power plan' { Get-TTPowerPlanSection -HasBattery $hasBattery }

Write-Step 'Checking what keeps the PC awake and recent wake-ups'
Add-TTPart 'Sleep and wake' { Get-TTSleepSection }

Write-Step 'Saving the report'
Complete-TTReport -Title 'Battery and Power Report' -Prefix 'Power' -Tool 'battery'
