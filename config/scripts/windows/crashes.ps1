# Crash and BSOD history (Windows > Diagnostics). Read-only: last 30 days.
# Functions are in diag.ps1. Keep this file ASCII-only.

Write-Step 'Looking for blue screens and crash dumps'
Add-TTPart 'Blue screens' { Get-TTBsodSection -Days 30 }

Write-Step 'Looking for unexpected shutdowns'
Add-TTPart 'Unexpected shutdowns' { Get-TTShutdownSection -Days 30 }

Write-Step 'Looking for program crashes and hangs'
Add-TTPart 'App crashes and hangs' { Get-TTAppCrashSection -Days 30 }

Write-Step 'Saving the report'
Complete-TTReport -Title 'Crash and BSOD History' -Prefix 'Crashes' -Tool 'crashes'
