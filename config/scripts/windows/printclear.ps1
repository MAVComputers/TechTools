# Clear stuck print jobs (Windows > Diagnostics): restarts the Print Spooler,
# deletes every waiting job, then re-checks printers and scanners.
# Keep this file ASCII-only.

Write-Step 'Restarting the Print Spooler and clearing the queue'
Add-TTPart 'Clear stuck print jobs' { Clear-TTPrintQueue }

Write-Step 'Checking the Print Spooler'
Add-TTPart 'Print Spooler' { Get-TTSpoolerSection }

Write-Step 'Checking printers and whether they answer on the network'
Add-TTPart 'Printers' { Get-TTPrintersSection }

Write-Step 'Checking the print queue again'
Add-TTPart 'Print queue' { Get-TTPrintJobsSection }

Write-Step 'Checking scanners (WIA and TWAIN) and imaging devices'
Add-TTPart 'Scanners and imaging devices' { Get-TTScannersSection }

Write-Step 'Saving the report'
Complete-TTReport -Title 'Printer and Scanner Check' -Prefix 'Printers' -Tool 'printscan' -Lead 'Print queue cleared and spooler restarted.' -LeadLevel 'ok'
