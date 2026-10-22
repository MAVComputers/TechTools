# Printer and scanner check (Windows > Diagnostics). Read-only.
# Functions are in diag.ps1. Keep this file ASCII-only.

Write-Step 'Checking the Print Spooler'
Add-TTPart 'Print Spooler' { Get-TTSpoolerSection }

Write-Step 'Checking printers and whether they answer on the network'
Add-TTPart 'Printers' { Get-TTPrintersSection }

Write-Step 'Looking for stuck print jobs'
Add-TTPart 'Print queue' { Get-TTPrintJobsSection }

Write-Step 'Checking scanners (WIA and TWAIN) and imaging devices'
Add-TTPart 'Scanners and imaging devices' { Get-TTScannersSection }

Write-Step 'Saving the report'
Complete-TTReport -Title 'Printer and Scanner Check' -Prefix 'Printers' -Tool 'printscan'
