# Time and domain sync (Windows > Diagnostics). Read-only.
# Functions are in diag.ps1. Keep this file ASCII-only.

Write-Step 'Checking the domain and domain controller'
Add-TTPart 'Domain' { Get-TTDomainSection }
$dom = $TTReportParts[$TTReportParts.Count - 1]
$dc = ''
if ($dom.PSObject.Properties['Dc']) { $dc = [string]$dom.Dc }

Write-Step 'Checking the clock against a time server'
Add-TTPart 'Clock and time sync' { Get-TTTimeSection -Dc $dc }

Write-Step 'Saving the report'
Complete-TTReport -Title 'Time and Domain Sync' -Prefix 'TimeSync' -Tool 'timesync'
